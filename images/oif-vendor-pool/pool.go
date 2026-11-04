// T-129 (ADR-032): one GPU vendor per workload. Which node pool a new pod in a Run:ai project must run in, and the
// JSON patch that pins it there. Pure logic; the cluster lookups are passed in.
package main

import "strings"

const (
	vendorLabel = "oif.ai/gpu-vendor" // node label of the GPU nodes, also the label key of Run:ai pools nvidia and amd
	poolLabel   = "runai/node-pool"   // Run:ai's node pool of a pod (and of a workload object)
)

var vendorResource = map[string]string{"nvidia.com/gpu": "nvidia", "amd.com/gpu": "amd"}

// Pod: the fields of a pod the decision reads.
type Pod struct {
	Metadata struct {
		Name            string            `json:"name"`
		GenerateName    string            `json:"generateName"`
		Namespace       string            `json:"namespace"`
		Labels          map[string]string `json:"labels"`
		OwnerReferences []OwnerRef        `json:"ownerReferences"`
	} `json:"metadata"`
	Spec struct {
		NodeSelector   map[string]string `json:"nodeSelector"`
		Affinity       *Affinity         `json:"affinity"`
		Containers     []Container       `json:"containers"`
		InitContainers []Container       `json:"initContainers"`
	} `json:"spec"`
}

// Affinity: the required node affinity, where Run:ai writes a workload's node pools (one term per pool).
type Affinity struct {
	NodeAffinity *struct {
		Required *struct {
			Terms []struct {
				MatchExpressions []struct {
					Key      string   `json:"key"`
					Operator string   `json:"operator"`
					Values   []string `json:"values"`
				} `json:"matchExpressions"`
			} `json:"nodeSelectorTerms"`
		} `json:"requiredDuringSchedulingIgnoredDuringExecution"`
	} `json:"nodeAffinity"`
}

type OwnerRef struct {
	APIVersion string `json:"apiVersion"`
	Kind       string `json:"kind"`
	Name       string `json:"name"`
	Controller bool   `json:"controller"`
}

type Container struct {
	Resources struct {
		Limits   map[string]any `json:"limits"`
		Requests map[string]any `json:"requests"`
	} `json:"resources"`
}

type PatchOp struct {
	Op    string `json:"op"`
	Path  string `json:"path"`
	Value any    `json:"value"`
}

// ResourceVendor: the vendor whose GPU resource the pod asks for, "" for none or for both (refused by
// oif-one-gpu-vendor).
func ResourceVendor(p *Pod) string {
	seen := map[string]bool{}
	for _, c := range append(append([]Container{}, p.Spec.Containers...), p.Spec.InitContainers...) {
		for _, m := range []map[string]any{c.Resources.Limits, c.Resources.Requests} {
			for r := range m {
				if v, ok := vendorResource[r]; ok {
					seen[v] = true
				}
			}
		}
	}
	if len(seen) != 1 {
		return ""
	}
	for v := range seen {
		return v
	}
	return ""
}

// AllowedVendors: the GPU vendors the pod's required node affinity allows, nil when it does not limit them (no
// affinity, or a term without an oif.ai/gpu-vendor In expression).
func AllowedVendors(p *Pod) map[string]bool {
	a := p.Spec.Affinity
	if a == nil || a.NodeAffinity == nil || a.NodeAffinity.Required == nil || len(a.NodeAffinity.Required.Terms) == 0 {
		return nil
	}
	allowed := map[string]bool{}
	for _, t := range a.NodeAffinity.Required.Terms {
		limited := false
		for _, e := range t.MatchExpressions {
			if e.Key == vendorLabel && e.Operator == "In" {
				limited = true
				for _, v := range e.Values {
					allowed[v] = true
				}
			}
		}
		if !limited {
			return nil
		}
	}
	return allowed
}

// Refuse: why the pod cannot be admitted, "" if it can. T-140 (ADR-032 amendment 2026-11-04): a pod asking for one
// vendor's GPU in a workload limited to the other vendor's pools is refused rather than moved to its vendor's pool,
// so the user's vendor choice is never switched silently (Run:ai's "GPU devices" is always nvidia.com/gpu).
func Refuse(p *Pod) string {
	v, allowed := ResourceVendor(p), AllowedVendors(p)
	if v == "" || allowed == nil || allowed[v] {
		return ""
	}
	other := "nvidia"
	if v == "nvidia" {
		other = "amd"
	}
	if !allowed[other] {
		return ""
	}
	if v == "nvidia" {
		return "this workload runs in the AMD GPU pool but asks for nvidia.com/gpu (Run:ai's \"GPU devices\"): for whole AMD GPUs choose AMD as the GPU vendor, or ask for amd.com/gpu"
	}
	return "this workload runs in the NVIDIA GPU pool but asks for amd.com/gpu: choose NVIDIA as the GPU vendor, or run it in the AMD GPU pool"
}

// OwnPool: the pool the pod already chose (a vendor node selector or a pool label), "" if none.
func OwnPool(p *Pod) string {
	if v := p.Spec.NodeSelector[vendorLabel]; v != "" {
		return v
	}
	return p.Metadata.Labels[poolLabel]
}

// Decide: the vendor pool to pin the pod to and why, and the patch; no patch when the pod chose a pool itself,
// when nothing names a vendor, or when no node has that vendor's GPUs (a single node with both vendors).
//   - a pod that asks for nvidia.com/gpu or amd.com/gpu runs on that vendor's nodes (KAI counts every GPU alike and
//     would otherwise place it in the other vendor's pool when its own is full);
//   - any other pod takes the pool of the workload that owns it (a Dynamo frontend without a GPU next to its worker).
func Decide(p *Pod, ownerPool func() (pool, owner string), hasNodes func(vendor string) bool) (pool, why string, patch []PatchOp) {
	if OwnPool(p) != "" {
		return "", "", nil
	}
	pool, why = ResourceVendor(p), "it asks for that vendor's GPU"
	if pool == "" {
		var owner string
		pool, owner = ownerPool()
		why = "its workload " + owner + " is in that pool"
	}
	if pool != "nvidia" && pool != "amd" || !hasNodes(pool) {
		return "", "", nil
	}
	return pool, why, append(addKey("/metadata/labels", p.Metadata.Labels == nil, poolLabel, pool),
		addKey("/spec/nodeSelector", p.Spec.NodeSelector == nil, vendorLabel, pool)...)
}

func addKey(path string, missing bool, key, value string) []PatchOp {
	if missing {
		return []PatchOp{{Op: "add", Path: path, Value: map[string]string{key: value}}}
	}
	esc := strings.NewReplacer("~", "~0", "/", "~1").Replace(key)
	return []PatchOp{{Op: "add", Path: path + "/" + esc, Value: value}}
}
