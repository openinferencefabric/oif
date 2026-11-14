package main

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func dom(vendor string, alloc, inUse int) Domain {
	return Domain{Capacity: map[string]int{vendor: alloc}, Allocatable: map[string]int{vendor: alloc}, InUse: map[string]int{vendor: inUse}}
}

// The vendor is chosen before the Job exists: the preferred one when it has room, else one with room, else the
// preferred (or first) one, where the job waits.
func TestChooseVendor(t *testing.T) {
	lab := []Domain{dom("nvidia", 1, 0), dom("amd", 1, 0)}
	nvBusy := []Domain{dom("nvidia", 1, 1), dom("amd", 1, 0)}
	cases := []struct {
		name    string
		prefer  string
		gpus    int
		domains []Domain
		want    string
	}{
		{"no preference, both free: nvidia first (T-134 adds a vendor order)", "", 1, lab, "nvidia"},
		{"prefer amd, it has room", "amd", 1, lab, "amd"},
		{"prefer nvidia, it is busy, amd has room: amd (soft preference)", "nvidia", 1, nvBusy, "amd"},
		{"no preference, nvidia busy: amd", "", 1, nvBusy, "amd"},
		{"nothing has room: the preferred vendor, where it waits", "amd", 2, lab, "amd"},
		{"nothing has room, no preference: the first vendor present", "", 2, []Domain{dom("amd", 1, 0)}, "amd"},
		{"prefer a vendor the cluster does not have: the other", "nvidia", 1, []Domain{dom("amd", 1, 0)}, "amd"},
		{"room summed over domains", "", 2, []Domain{dom("amd", 1, 0), dom("amd", 1, 0), dom("nvidia", 1, 0)}, "amd"},
		{"no GPUs at all", "", 1, nil, ""},
	}
	for _, c := range cases {
		if got, _ := ChooseVendor(c.prefer, c.gpus, c.domains); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

func lookup(m map[string]any, path ...string) any {
	var v any = m
	for _, p := range path {
		mm, ok := v.(map[string]any)
		if !ok {
			return nil
		}
		v = mm[p]
	}
	return v
}

func job(t *testing.T, a AIJob, vendor, pool string, domainsOfVendor int) map[string]any {
	t.Helper()
	b, _ := json.Marshal(JobFor(a, vendor, pool, domainsOfVendor))
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestJobFor(t *testing.T) {
	a := AIJob{Name: "llm-ft", Namespace: "runai-team-a", UID: "u-1", Spec: Spec{
		Model: "Qwen/Qwen3-8B", Precision: "bf16", GPUCount: 1,
		Template: Container{Image: "img:1", Command: []string{"python", "train.py"}, Env: []EnvVar{{Name: "A", Value: "1"}}}}}

	// one pod on NVIDIA in pool nvidia
	m := job(t, a, "nvidia", "nvidia", 2)
	if lookup(m, "metadata", "name") != "llm-ft" || lookup(m, "metadata", "namespace") != "runai-team-a" {
		t.Errorf("name: %v", lookup(m, "metadata"))
	}
	if lookup(m, "metadata", "labels", "runai/node-pool") != "nvidia" || lookup(m, "spec", "template", "metadata", "labels", "runai/node-pool") != "nvidia" {
		t.Errorf("pool label on the Job and its pods: %v", lookup(m, "metadata", "labels"))
	}
	owner := lookup(m, "metadata", "ownerReferences").([]any)[0].(map[string]any)
	if owner["kind"] != "AIJob" || owner["uid"] != "u-1" || owner["controller"] != true {
		t.Errorf("owner: %v", owner)
	}
	pod := lookup(m, "spec", "template", "spec").(map[string]any)
	if pod["schedulerName"] != "runai-scheduler" || pod["runtimeClassName"] != "nvidia" || pod["restartPolicy"] != "Never" {
		t.Errorf("pod spec: %v", pod)
	}
	c := pod["containers"].([]any)[0].(map[string]any)
	if lookup(c, "resources", "limits", "nvidia.com/gpu") != "1" || c["image"] != "img:1" {
		t.Errorf("container: %v", c)
	}
	env, _ := json.Marshal(c["env"])
	for _, e := range []string{`{"name":"A","value":"1"}`, `{"name":"OIF_MODEL","value":"Qwen/Qwen3-8B"}`, `{"name":"OIF_PRECISION","value":"bf16"}`, `{"name":"OIF_GPU_VENDOR","value":"nvidia"}`} {
		if !strings.Contains(string(env), e) {
			t.Errorf("env %s missing in %s", e, env)
		}
	}
	if anns := lookup(m, "metadata", "annotations"); anns != nil && len(anns.(map[string]any)) > 0 {
		t.Errorf("one pod, no domain requirement: no KAI annotations, got %v", anns)
	}
	if lookup(m, "spec", "parallelism") != 1.0 || lookup(m, "spec", "completions") != 1.0 || lookup(m, "spec", "backoffLimit") != 0.0 {
		t.Errorf("job spec: %v", lookup(m, "spec"))
	}

	// AMD, single-node cluster (pool default: no pool label), no runtime class, no model given
	a2 := a
	a2.Spec.Model, a2.Spec.Precision = "", ""
	m = job(t, a2, "amd", "", 1)
	if lookup(m, "metadata", "labels", "runai/node-pool") != nil || lookup(m, "spec", "template", "spec", "runtimeClassName") != nil {
		t.Errorf("AMD in the default pool: %v", m)
	}
	c = lookup(m, "spec", "template", "spec", "containers").([]any)[0].(map[string]any)
	if lookup(c, "resources", "limits", "amd.com/gpu") != "1" || strings.Contains(func() string { b, _ := json.Marshal(c["env"]); return string(b) }(), "OIF_MODEL") {
		t.Errorf("AMD container: %v", c)
	}

	// four pods that must stay in one domain, in a pool with several domains: a gang with the required level
	a3 := a
	a3.Spec.Workers, a3.Spec.GPUCount, a3.Spec.Placement.RequireSameDomain = 4, 2, true
	m = job(t, a3, "nvidia", "nvidia", 3)
	want := map[string]any{"kai.scheduler/batch-min-member": "4", "kai.scheduler/topology": "oif-accelerator",
		"kai.scheduler/topology-required-placement": "oif.ai/accelerator-domain", "kai.scheduler/topology-preferred-placement": "kubernetes.io/hostname"}
	if !reflect.DeepEqual(lookup(m, "metadata", "annotations"), want) {
		t.Errorf("gang in one domain: %v", lookup(m, "metadata", "annotations"))
	}
	if lookup(m, "spec", "parallelism") != 4.0 || lookup(m, "spec", "completions") != 4.0 {
		t.Errorf("four pods: %v", lookup(m, "spec"))
	}
	// the same in a pool inside one domain: no required level (stock KAI would never place it, T-141)
	m = job(t, a3, "nvidia", "nvidia", 1)
	if _, ok := lookup(m, "metadata", "annotations").(map[string]any)["kai.scheduler/topology-required-placement"]; ok {
		t.Errorf("pool inside one domain: required level set anyway")
	}
}

func TestVendorOfJob(t *testing.T) {
	a := AIJob{Name: "x", Namespace: "n", Spec: Spec{GPUCount: 1, Template: Container{Image: "i"}}}
	for _, v := range []string{"nvidia", "amd"} {
		b, _ := json.Marshal(JobFor(a, v, v, 1))
		var j KubeJob
		_ = json.Unmarshal(b, &j)
		if got := j.Vendor(); got != v {
			t.Errorf("vendor of the %s Job: %q", v, got)
		}
	}
}

func TestStatusOf(t *testing.T) {
	nodeDomain := map[string]string{"gpu-nvidia": "gpu-nvidia", "gpu-amd": "gpu-amd"}
	run := func(phase string, node string) PodInfo { return PodInfo{Phase: phase, Node: node} }
	cases := []struct {
		name  string
		job   KubeJob
		pods  []PodInfo
		phase string
		nodes []string
	}{
		{"created, nothing placed", KubeJob{}, []PodInfo{run("Pending", "")}, "Pending", nil},
		{"placed, starting", KubeJob{}, []PodInfo{run("Pending", "gpu-nvidia")}, "Pending", []string{"gpu-nvidia"}},
		{"running", KubeJob{}, []PodInfo{run("Running", "gpu-nvidia")}, "Running", []string{"gpu-nvidia"}},
		{"done", KubeJob{Status: JobState{Succeeded: 1}}, []PodInfo{run("Succeeded", "gpu-nvidia")}, "Succeeded", []string{"gpu-nvidia"}},
		{"failed", KubeJob{Status: JobState{Failed: 1}}, []PodInfo{run("Failed", "gpu-nvidia")}, "Failed", []string{"gpu-nvidia"}},
	}
	for _, c := range cases {
		c.job.Spec.Completions = 1
		s := StatusOf("nvidia", "chosen", c.job, c.pods, nodeDomain)
		if s.Phase != c.phase || !reflect.DeepEqual(s.Nodes, c.nodes) || s.Vendor != "nvidia" || s.CrossVendor || s.Message != "chosen" {
			t.Errorf("%s: %+v", c.name, s)
		}
		if c.nodes != nil && !reflect.DeepEqual(s.Domains, []string{"gpu-nvidia"}) {
			t.Errorf("%s: domains %v", c.name, s.Domains)
		}
	}
}
