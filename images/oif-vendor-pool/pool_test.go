package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func pod(t *testing.T, s string) *Pod {
	t.Helper()
	var p Pod
	if err := json.Unmarshal([]byte(s), &p); err != nil {
		t.Fatal(err)
	}
	return &p
}

func TestDecide(t *testing.T) {
	both := func(string) bool { return true }
	for _, tc := range []struct {
		name, pod, owner, want string
		nodes                  func(string) bool
		patch                  string
	}{
		{"nvidia GPU, no pool", `{"spec":{"containers":[{"resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}`, "", "nvidia", both,
			`[{"op":"add","path":"/metadata/labels","value":{"runai/node-pool":"nvidia"}},{"op":"add","path":"/spec/nodeSelector","value":{"oif.ai/gpu-vendor":"nvidia"}}]`},
		{"amd GPU in an init container, labels and selector present", `{"metadata":{"labels":{"app":"x"}},"spec":{"nodeSelector":{"zone":"a"},"initContainers":[{"resources":{"requests":{"amd.com/gpu":"1"}}}]}}`, "", "amd", both,
			`[{"op":"add","path":"/metadata/labels/runai~1node-pool","value":"amd"},{"op":"add","path":"/spec/nodeSelector/oif.ai~1gpu-vendor","value":"amd"}]`},
		{"chose a pool by label", `{"metadata":{"labels":{"runai/node-pool":"amd"}},"spec":{"containers":[{"resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}`, "", "", both, ""},
		{"chose a pool by selector", `{"spec":{"nodeSelector":{"oif.ai/gpu-vendor":"nvidia"},"containers":[{}]}}`, "nvidia", "", both, ""},
		{"both vendors", `{"spec":{"containers":[{"resources":{"limits":{"nvidia.com/gpu":"1","amd.com/gpu":"1"}}}]}}`, "", "", both, ""},
		{"no GPU, workload in pool nvidia", `{"spec":{"containers":[{}]}}`, "nvidia", "nvidia", both,
			`[{"op":"add","path":"/metadata/labels","value":{"runai/node-pool":"nvidia"}},{"op":"add","path":"/spec/nodeSelector","value":{"oif.ai/gpu-vendor":"nvidia"}}]`},
		{"no GPU, workload in pool default", `{"spec":{"containers":[{}]}}`, "default", "", both, ""},
		{"no GPU, no workload pool", `{"spec":{"containers":[{}]}}`, "", "", both, ""},
		{"fraction by annotation, workload in pool amd", `{"metadata":{"annotations":{"gpu-fraction":"0.5"}},"spec":{"containers":[{}]}}`, "amd", "amd", both,
			`[{"op":"add","path":"/metadata/labels","value":{"runai/node-pool":"amd"}},{"op":"add","path":"/spec/nodeSelector","value":{"oif.ai/gpu-vendor":"amd"}}]`},
		{"no node with that vendor (one node with both)", `{"spec":{"containers":[{"resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}`, "", "", func(string) bool { return false }, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, _, patch := Decide(pod(t, tc.pod), func() (string, string) { return tc.owner, "Kind/x" }, tc.nodes)
			if got != tc.want {
				t.Fatalf("pool = %q, want %q", got, tc.want)
			}
			b, _ := json.Marshal(patch)
			if tc.patch == "" && patch != nil || tc.patch != "" && string(b) != tc.patch {
				t.Fatalf("patch = %s, want %s", b, tc.patch)
			}
		})
	}
}

func TestOwnerPool(t *testing.T) {
	// ReplicaSet -> Deployment -> DynamoComponentDeployment (pool label) : the first owner with a pool wins
	objs := map[string]string{
		"apps/v1/ReplicaSet/fe-1":                         `{"metadata":{"ownerReferences":[{"apiVersion":"apps/v1","kind":"Deployment","name":"fe","controller":true}]}}`,
		"apps/v1/Deployment/fe":                           `{"metadata":{"ownerReferences":[{"apiVersion":"nvidia.com/v1alpha1","kind":"DynamoComponentDeployment","name":"q","controller":true}]}}`,
		"nvidia.com/v1alpha1/DynamoComponentDeployment/q": `{"metadata":{"labels":{"runai/node-pool":"nvidia"}}}`,
	}
	get := func(apiVersion, kind, ns, name string) (map[string]any, error) {
		var m map[string]any
		s, ok := objs[apiVersion+"/"+kind+"/"+name]
		if !ok {
			return nil, errNotFound
		}
		return m, json.Unmarshal([]byte(s), &m)
	}
	refs := []OwnerRef{{APIVersion: "apps/v1", Kind: "ReplicaSet", Name: "fe-1", Controller: true}}
	pool, owner := ownerPool(get, "ns", refs)
	if pool != "nvidia" || owner != "DynamoComponentDeployment/q" {
		t.Fatalf("got %q from %q", pool, owner)
	}
	if pool, _ := ownerPool(get, "ns", []OwnerRef{{APIVersion: "apps/v1", Kind: "ReplicaSet", Name: "gone", Controller: true}}); pool != "" {
		t.Fatalf("missing owner: got %q", pool)
	}
}

func TestRefuse(t *testing.T) {
	// Run:ai writes a workload's node pools as OR'd required terms; pool default is runai/node-pool DoesNotExist
	aff := func(terms ...string) string {
		return `"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[` + strings.Join(terms, ",") + `]}}}`
	}
	vendor := func(v string) string {
		return `{"matchExpressions":[{"key":"oif.ai/gpu-vendor","operator":"In","values":["` + v + `"]}]}`
	}
	dflt := `{"matchExpressions":[{"key":"runai/node-pool","operator":"DoesNotExist"}]}`
	nv := `"containers":[{"resources":{"limits":{"nvidia.com/gpu":"1"}}}]`
	amd := `"containers":[{"resources":{"limits":{"amd.com/gpu":"1"}}}]`
	for _, tc := range []struct {
		name, spec string
		refused    bool
	}{
		{"GPU devices in pool amd only (the T-140 spike)", aff(vendor("amd")) + `,` + nv, true},
		{"amd.com/gpu in pool nvidia only", aff(vendor("nvidia")) + `,` + amd, true},
		{"GPU devices in pool nvidia", aff(vendor("nvidia")) + `,` + nv, false},
		{"amd.com/gpu in pool amd", aff(vendor("amd")) + `,` + amd, false},
		{"GPU devices, pools amd and nvidia", aff(vendor("amd"), vendor("nvidia")) + `,` + nv, false},
		{"GPU devices, pools amd and default (default does not limit the vendor)", aff(vendor("amd"), dflt) + `,` + nv, false},
		{"GPU devices, no affinity", nv, false},
		{"fraction (no GPU resource) in pool amd", aff(vendor("amd")) + `,"containers":[{}]`, false},
		{"both vendors' GPUs (oif-one-gpu-vendor refuses it)", aff(vendor("amd")) + `,"containers":[{"resources":{"limits":{"nvidia.com/gpu":"1","amd.com/gpu":"1"}}}]`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			msg := Refuse(pod(t, `{"spec":{`+tc.spec+`}}`))
			if (msg != "") != tc.refused {
				t.Fatalf("refused = %q, want refused %v", msg, tc.refused)
			}
			if tc.refused && !strings.Contains(msg, "GPU vendor") {
				t.Fatalf("message does not say what to choose: %q", msg)
			}
		})
	}
}
