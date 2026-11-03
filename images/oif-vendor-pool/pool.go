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
		Containers     []Container       `json:"containers"`
		InitContainers []Container       `json:"initContainers"`
	} `json:"spec"`
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
