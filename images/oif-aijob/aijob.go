package main

// T-133 (ADR-019): an AIJob says what to run and how many GPUs, not whose. The controller picks the vendor before the
// Job exists (a pod must name nvidia.com/gpu or amd.com/gpu; KAI cannot choose between them) and writes a plain Job
// that Run:ai's scheduler places in that vendor's node pool under the project's quota.

import (
	"sort"
	"strconv"
	"strings"
)

// Spec: the AIJob's spec (immutable: the CRD refuses changes).
type Spec struct {
	Model     string    `json:"model,omitempty"`     // passed to the container as OIF_MODEL
	Precision string    `json:"precision,omitempty"` // passed as OIF_PRECISION
	GPUCount  int       `json:"gpuCount"`            // per pod
	Workers   int       `json:"workers,omitempty"`   // pods, default 1
	Template  Container `json:"template"`
	Placement Placement `json:"placement,omitempty"`
}

// Container: the only parts of a pod an AIJob sets (no host paths, privileges or other pod fields).
type Container struct {
	Image   string   `json:"image"`
	Command []string `json:"command,omitempty"`
	Args    []string `json:"args,omitempty"`
	Env     []EnvVar `json:"env,omitempty"`
}

type EnvVar struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

// Placement: soft vendor preference and the domain requirement; allowCrossVendor true is refused by the CRD.
type Placement struct {
	PreferVendor      string `json:"preferVendor,omitempty"`
	RequireSameDomain *bool  `json:"requireSameDomain,omitempty"` // unset: the PlacementPolicy's
	AllowCrossVendor  bool   `json:"allowCrossVendor,omitempty"`
}

type AIJob struct {
	Name, Namespace, UID string
	Spec                 Spec
}

func (s Spec) workers() int {
	if s.Workers < 1 {
		return 1
	}
	return s.Workers
}

// Domain: an AcceleratorDomain's GPU counts per vendor (T-131).
type Domain struct {
	Capacity    map[string]int `json:"capacity"`
	Allocatable map[string]int `json:"allocatable"`
	InUse       map[string]int `json:"inUse"`
}

var defaultOrder = []string{"nvidia", "amd"} // without a PlacementPolicy

// Policy: a PlacementPolicy's spec (T-134). "default" in a project's namespace applies there, "default" in the
// controller's namespace to every project without one.
type Policy struct {
	VendorPriority    []string `json:"vendorPriority,omitempty"`
	RequireSameDomain *bool    `json:"requireSameDomain,omitempty"`
}

// Placement after the defaults: the order vendors are tried in, the domain requirement, and the policy that applied.
type Resolved struct {
	Order             []string
	RequireSameDomain bool
	Source            string
}

// Effective: the AIJob's own requireSameDomain when set, else the namespace policy's, else the cluster policy's; the
// vendor order from the namespace policy, else the cluster's, else nvidia, amd (vendors a policy leaves out come last).
func Effective(own *bool, ns string, nsPolicy, clusterPolicy *Policy, clusterNS string) Resolved {
	r := Resolved{Order: defaultOrder}
	for _, p := range []struct {
		pol  *Policy
		name string
	}{{clusterPolicy, clusterNS}, {nsPolicy, ns}} { // the namespace's last: it wins
		if p.pol == nil {
			continue
		}
		r.Source = "PlacementPolicy " + p.name + "/default"
		if len(p.pol.VendorPriority) > 0 {
			r.Order = p.pol.VendorPriority
		}
		if p.pol.RequireSameDomain != nil {
			r.RequireSameDomain = *p.pol.RequireSameDomain
		}
	}
	if own != nil {
		r.RequireSameDomain = *own
	}
	r.Order = dedupe(append(append([]string{}, r.Order...), defaultOrder...))
	return r
}

func dedupe(in []string) []string {
	seen, out := map[string]bool{}, []string{}
	for _, v := range in {
		if !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	return out
}

// ChooseVendor: the preferred vendor when it has room for all the job's GPUs, else the first vendor in order with
// room, else the preferred (or first) vendor the cluster has, where the job waits for room. "" without GPUs.
func ChooseVendor(prefer string, gpus int, domains []Domain, order []string) (string, string) {
	free, present := map[string]int{}, map[string]bool{}
	for _, d := range domains {
		for v, c := range d.Capacity {
			if c > 0 {
				present[v] = true
			}
			free[v] += d.Allocatable[v] - d.InUse[v]
		}
	}
	if prefer != "" {
		order = append([]string{prefer}, order...)
	}
	for _, v := range order {
		if present[v] && free[v] >= gpus {
			if v == prefer {
				return v, v + ": the preferred vendor, it has room"
			}
			return v, v + ": it has room for " + strconv.Itoa(gpus) + " GPUs"
		}
	}
	for _, v := range order {
		if present[v] {
			return v, v + ": no vendor has room for " + strconv.Itoa(gpus) + " GPUs now; the job waits here"
		}
	}
	return "", "the cluster has no GPUs"
}

// JobFor: the Job for an AIJob on one vendor. pool is the vendor's Run:ai node pool ("": the default pool, no label);
// domains is how many accelerator domains that vendor's GPUs are in.
func JobFor(a AIJob, vendor, pool string, domains int) map[string]any {
	n := a.Spec.workers()
	labels := map[string]string{"app.kubernetes.io/managed-by": "oif", "oif.ai/aijob": a.Name}
	if pool != "" {
		labels["runai/node-pool"] = pool
	}
	ann := map[string]string{}
	if n > 1 {
		ann["kai.scheduler/batch-min-member"] = strconv.Itoa(n) // one gang: all pods or none (spike S-9)
	}
	if p := a.Spec.Placement.RequireSameDomain; p != nil && *p {
		// both, or KAI ignores the required level (T-132); Run:ai adds no topology to a workload with its own kai.scheduler/ keys
		ann["kai.scheduler/topology"] = "oif-accelerator"
		ann["kai.scheduler/topology-preferred-placement"] = "kubernetes.io/hostname"
		if domains > 1 { // a pool inside one domain: every placement is in it already, and stock KAI never places it (T-141)
			ann["kai.scheduler/topology-required-placement"] = "oif.ai/accelerator-domain"
		}
	}
	env := append([]EnvVar{}, a.Spec.Template.Env...)
	for _, e := range []EnvVar{{"OIF_MODEL", a.Spec.Model}, {"OIF_PRECISION", a.Spec.Precision}, {"OIF_GPU_VENDOR", vendor}} {
		if e.Value != "" {
			env = append(env, e)
		}
	}
	pod := map[string]any{
		"schedulerName": "runai-scheduler", "restartPolicy": "Never",
		"containers": []any{map[string]any{
			"name": "main", "image": a.Spec.Template.Image, "command": a.Spec.Template.Command, "args": a.Spec.Template.Args, "env": env,
			"resources": map[string]any{"limits": map[string]string{vendor + ".com/gpu": strconv.Itoa(a.Spec.GPUCount)}},
		}},
	}
	if vendor == "nvidia" {
		pod["runtimeClassName"] = "nvidia"
	}
	return map[string]any{
		"apiVersion": "batch/v1", "kind": "Job",
		"metadata": map[string]any{
			"name": a.Name, "namespace": a.Namespace, "labels": labels, "annotations": ann,
			"ownerReferences": []any{map[string]any{"apiVersion": "oif.ai/v1alpha1", "kind": "AIJob", "name": a.Name, "uid": a.UID,
				"controller": true, "blockOwnerDeletion": true}},
		},
		"spec": map[string]any{
			"parallelism": n, "completions": n, "backoffLimit": 0,
			"template": map[string]any{"metadata": map[string]any{"labels": labels}, "spec": pod},
		},
	}
}

// KubeJob: the parts of a Job the status needs.
type KubeJob struct {
	Spec struct {
		Completions int `json:"completions"`
		Template    struct {
			Spec struct {
				Containers []struct {
					Resources struct {
						Limits map[string]string `json:"limits"`
					} `json:"resources"`
				} `json:"containers"`
			} `json:"spec"`
		} `json:"template"`
	} `json:"spec"`
	Status JobState `json:"status"`
}

type JobState struct {
	Succeeded int `json:"succeeded"`
	Failed    int `json:"failed"`
}

// Vendor: the vendor the Job was made for (the controller's choice survives a lost status write).
func (j KubeJob) Vendor() string {
	for _, c := range j.Spec.Template.Spec.Containers {
		for r := range c.Resources.Limits {
			if v, ok := strings.CutSuffix(r, ".com/gpu"); ok {
				return v
			}
		}
	}
	return ""
}

type PodInfo struct {
	Phase, Node string
}

// Status: the AIJob's status.
type Status struct {
	Phase       string   `json:"phase"` // Pending, Running, Succeeded, Failed
	Vendor      string   `json:"vendor,omitempty"`
	Domains     []string `json:"domains,omitempty"`
	Nodes       []string `json:"nodes,omitempty"`
	CrossVendor bool     `json:"crossVendor"`
	Message     string   `json:"message,omitempty"`
}

// StatusOf: the status from the Job and its pods; domains from the pods' nodes.
func StatusOf(vendor, message string, j KubeJob, pods []PodInfo, nodeDomain map[string]string) Status {
	s := Status{Phase: "Pending", Vendor: vendor, Message: message}
	nodes, domains := map[string]bool{}, map[string]bool{}
	for _, p := range pods {
		if p.Phase == "Running" {
			s.Phase = "Running"
		}
		if p.Node != "" {
			nodes[p.Node] = true
			if d := nodeDomain[p.Node]; d != "" {
				domains[d] = true
			}
		}
	}
	switch {
	case j.Status.Failed > 0:
		s.Phase = "Failed"
	case j.Spec.Completions > 0 && j.Status.Succeeded >= j.Spec.Completions:
		s.Phase = "Succeeded"
	}
	s.Nodes, s.Domains = keys(nodes), keys(domains)
	return s
}

func keys(m map[string]bool) []string {
	if len(m) == 0 {
		return nil
	}
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
