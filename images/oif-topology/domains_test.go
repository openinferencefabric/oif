package main

import (
	"encoding/json"
	"reflect"
	"testing"
)

func gpuNode(name, domain, fabric string, ready bool, alloc map[string]string) ClusterNode {
	labels := map[string]string{}
	if domain != "" {
		labels[domainLabel], labels[fabricLabel], labels[zoneLabel] = domain, fabric, "default"
	}
	return ClusterNode{Node: Node{Name: name, Labels: labels, Allocatable: alloc}, Capacity: alloc, Ready: ready}
}

// The lab (one GPU per worker), a node with both vendors, an NVLink clique over two nodes, pods that count and pods
// that do not.
func TestDomains(t *testing.T) {
	nv := map[string]string{"nvidia.com/gpu": "1"}
	amd := map[string]string{"amd.com/gpu": "1"}
	nodes := []ClusterNode{
		{Node: Node{Name: "cp1", Labels: map[string]string{}, Allocatable: map[string]string{"cpu": "8"}}, Ready: true},
		gpuNode("gpu-nvidia", "gpu-nvidia", "pcie", true, nv),
		gpuNode("gpu-amd", "gpu-amd", "pcie", true, amd),
		gpuNode("mixed", "mixed", "pcie", false, map[string]string{"nvidia.com/gpu": "1", "amd.com/gpu": "1"}),
		gpuNode("gb-t02", "nvl-clique.1", "nvlink", true, map[string]string{"nvidia.com/gpu": "4"}),
		gpuNode("gb-t01", "nvl-clique.1", "nvlink", true, map[string]string{"nvidia.com/gpu": "4"}),
		gpuNode("starting", "", "", true, map[string]string{"nvidia.com/gpu": "0"}), // no domain label yet: in no domain
	}
	nodes[1].Capacity = map[string]string{"nvidia.com/gpu": "1"}
	nodes[1].Allocatable = map[string]string{"nvidia.com/gpu": "0"} // a GPU the device plugin no longer offers
	pods := []Pod{
		{Node: "gpu-amd", Phase: "Running", Requests: map[string]string{"amd.com/gpu": "1"}},
		{Node: "gpu-amd", Phase: "Succeeded", Requests: map[string]string{"amd.com/gpu": "1"}}, // finished: frees its GPU
		{Node: "gb-t01", Phase: "Running", Requests: map[string]string{"nvidia.com/gpu": "4"}},
		{Node: "gb-t02", Phase: "Pending", Requests: map[string]string{"nvidia.com/gpu": "2"}}, // bound, starting: holds them
		{Node: "gb-t02", Phase: "Running", Requests: map[string]string{"cpu": "1"}},
		{Node: "", Phase: "Pending", Requests: map[string]string{"nvidia.com/gpu": "1"}}, // not placed yet
	}
	got := map[string]Domain{}
	for _, d := range Domains(nodes, pods) {
		got[d.Name] = d
	}
	want := map[string]Domain{
		"gpu-nvidia": {Name: "gpu-nvidia", Vendor: "nvidia", Fabric: "pcie", Zone: "default", Nodes: []string{"gpu-nvidia"},
			Capacity: map[string]int{"nvidia": 1}, Allocatable: map[string]int{"nvidia": 0}, InUse: map[string]int{"nvidia": 0}, Ready: true},
		"gpu-amd": {Name: "gpu-amd", Vendor: "amd", Fabric: "pcie", Zone: "default", Nodes: []string{"gpu-amd"},
			Capacity: map[string]int{"amd": 1}, Allocatable: map[string]int{"amd": 1}, InUse: map[string]int{"amd": 1}, Ready: true},
		"mixed": {Name: "mixed", Vendor: "mixed", Fabric: "pcie", Zone: "default", Nodes: []string{"mixed"},
			Capacity: map[string]int{"nvidia": 1, "amd": 1}, Allocatable: map[string]int{"nvidia": 1, "amd": 1}, InUse: map[string]int{"nvidia": 0, "amd": 0},
			NotReady: []string{"mixed"}},
		"nvl-clique.1": {Name: "nvl-clique.1", Vendor: "nvidia", Fabric: "nvlink", Zone: "default", Nodes: []string{"gb-t01", "gb-t02"},
			Capacity: map[string]int{"nvidia": 8}, Allocatable: map[string]int{"nvidia": 8}, InUse: map[string]int{"nvidia": 6}, Ready: true},
	}
	if !reflect.DeepEqual(got, want) {
		for k := range want {
			if !reflect.DeepEqual(got[k], want[k]) {
				t.Errorf("domain %s:\n got  %+v\n want %+v", k, got[k], want[k])
			}
		}
		if len(got) != len(want) {
			t.Errorf("domains: got %d, want %d", len(got), len(want))
		}
	}
}

// Object names are DNS names; a label value may hold upper case and underscores.
func TestObjectName(t *testing.T) {
	for in, want := range map[string]string{"gpu-amd": "gpu-amd", "xgmi-0x5F1B": "xgmi-0x5f1b", "rack_1.a": "rack-1.a"} {
		if got := objectName(in); got != want {
			t.Errorf("objectName(%q) = %q, want %q", in, got, want)
		}
	}
}

// What the controller sends: new domains created, changed ones updated, unchanged ones left alone, gone ones deleted.
func TestPlan(t *testing.T) {
	a := Domain{Name: "gpu-amd", Vendor: "amd", Fabric: "pcie", Zone: "default", Nodes: []string{"gpu-amd"},
		Capacity: map[string]int{"amd": 1}, Allocatable: map[string]int{"amd": 1}, InUse: map[string]int{"amd": 0}, Ready: true}
	n := Domain{Name: "gpu-nvidia", Vendor: "nvidia", Fabric: "pcie", Zone: "default", Nodes: []string{"gpu-nvidia"},
		Capacity: map[string]int{"nvidia": 1}, Allocatable: map[string]int{"nvidia": 1}, InUse: map[string]int{"nvidia": 0}, Ready: true}
	busy := a
	busy.InUse = map[string]int{"amd": 1}
	raw := func(d Domain) json.RawMessage { b, _ := json.Marshal(d.Status()); return b }
	have := map[string]json.RawMessage{"gpu-amd": raw(a), "old-node": raw(n)}
	create, update, del := Plan(have, []Domain{busy, n})
	if !reflect.DeepEqual(create, []string{"gpu-nvidia"}) || !reflect.DeepEqual(update, []string{"gpu-amd"}) || !reflect.DeepEqual(del, []string{"old-node"}) {
		t.Errorf("Plan: create %v update %v delete %v", create, update, del)
	}
	create, update, del = Plan(map[string]json.RawMessage{"gpu-amd": raw(busy), "gpu-nvidia": raw(n)}, []Domain{busy, n})
	if len(create)+len(update)+len(del) != 0 {
		t.Errorf("Plan, nothing changed: create %v update %v delete %v", create, update, del)
	}
}

// The status the object shows: totals for kubectl's columns, the Ready condition naming the nodes that are not.
func TestStatus(t *testing.T) {
	d := Domain{Name: "mixed", Vendor: "mixed", Fabric: "pcie", Zone: "default", Nodes: []string{"mixed"},
		Capacity: map[string]int{"nvidia": 1, "amd": 1}, Allocatable: map[string]int{"nvidia": 1, "amd": 1}, InUse: map[string]int{"nvidia": 1, "amd": 0},
		NotReady: []string{"mixed"}}
	s := d.Status()
	if s.AllocatableGPUs != 2 || s.InUseGPUs != 1 || s.Domain != "mixed" {
		t.Errorf("totals: %+v", s)
	}
	if len(s.Conditions) != 1 || s.Conditions[0].Type != "Ready" || s.Conditions[0].Status != "False" || s.Conditions[0].Message != "not ready: mixed" {
		t.Errorf("condition: %+v", s.Conditions)
	}
	d.Ready, d.NotReady = true, nil
	if c := d.Status().Conditions[0]; c.Status != "True" || c.Reason != "NodesReady" {
		t.Errorf("ready condition: %+v", c)
	}
}
