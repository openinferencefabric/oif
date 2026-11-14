package main

// T-131 (ADR-019 amendment 2026-11-05): the AcceleratorDomain objects, a read-only view of the domains the node labels
// define (the scheduler reads the labels, never these objects). One object per oif.ai/accelerator-domain value: its
// vendor, fabric, zone, nodes, and GPUs (capacity, allocatable, in use by pods bound to its nodes) per vendor.

import (
	"bytes"
	"encoding/json"
	"sort"
	"strings"
)

// ClusterNode: a node as the domain view needs it (Node.Allocatable is the allocatable GPUs).
type ClusterNode struct {
	Node
	Capacity map[string]string
	Ready    bool
}

// Pod: a pod's node, phase and resource requests summed over its containers.
type Pod struct {
	Node     string
	Phase    string
	Requests map[string]string
}

// Domain: one accelerator domain as the view shows it.
type Domain struct {
	Name, Vendor, Fabric, Zone   string
	Nodes                        []string
	Capacity, Allocatable, InUse map[string]int // per vendor: nvidia, amd
	Ready                        bool
	NotReady                     []string
}

func add(m map[string]int, resources map[string]string) {
	nvidia, amd := gpus(resources)
	m["nvidia"] += nvidia
	m["amd"] += amd
}

// Domains: the domains of the labelled GPU nodes, sorted by name. A pod counts while it is bound to a node and not
// finished (Pending on a node holds its GPUs too); KAI's reservation pods behind GPU fractions count as whole GPUs.
func Domains(nodes []ClusterNode, pods []Pod) []Domain {
	byName := map[string]*Domain{}
	domainOf := map[string]*Domain{}
	for _, n := range nodes {
		name := n.Labels[domainLabel]
		if name == "" {
			continue
		}
		d := byName[name]
		if d == nil {
			d = &Domain{Name: name, Fabric: n.Labels[fabricLabel], Zone: n.Labels[zoneLabel], Ready: true,
				Capacity: map[string]int{}, Allocatable: map[string]int{}, InUse: map[string]int{}}
			byName[name] = d
		}
		domainOf[n.Name] = d
		d.Nodes = append(d.Nodes, n.Name)
		if !n.Ready {
			d.Ready = false
			d.NotReady = append(d.NotReady, n.Name)
		}
		add(d.Capacity, n.Capacity)
		add(d.Allocatable, n.Allocatable)
		add(d.InUse, nil) // zero, not missing, while nothing runs
	}
	for _, p := range pods {
		if d := domainOf[p.Node]; d != nil && p.Phase != "Succeeded" && p.Phase != "Failed" {
			add(d.InUse, p.Requests)
		}
	}
	out := make([]Domain, 0, len(byName))
	for _, d := range byName {
		nv, amd := d.Capacity["nvidia"] > 0, d.Capacity["amd"] > 0
		switch {
		case nv && amd:
			d.Vendor = "mixed"
		case amd:
			d.Vendor = "amd"
		default:
			d.Vendor = "nvidia"
		}
		for _, m := range []map[string]int{d.Capacity, d.Allocatable, d.InUse} { // only the vendors the domain has
			if !nv {
				delete(m, "nvidia")
			}
			if !amd {
				delete(m, "amd")
			}
		}
		sort.Strings(d.Nodes)
		sort.Strings(d.NotReady)
		out = append(out, *d)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// objectName: the domain's object name (a DNS name: lower case, no underscores; a label value may have both).
func objectName(domain string) string {
	return strings.ReplaceAll(strings.ToLower(domain), "_", "-")
}

// Condition: the Ready condition of a domain.
type Condition struct {
	Type    string `json:"type"`
	Status  string `json:"status"`
	Reason  string `json:"reason"`
	Message string `json:"message,omitempty"`
}

// Status: the AcceleratorDomain object's status.
type Status struct {
	Domain          string         `json:"domain"` // the label value
	Vendor          string         `json:"vendor"`
	Fabric          string         `json:"fabric"`
	Zone            string         `json:"zone"`
	Nodes           []string       `json:"nodes"`
	Capacity        map[string]int `json:"capacity"`
	Allocatable     map[string]int `json:"allocatable"`
	InUse           map[string]int `json:"inUse"`
	AllocatableGPUs int            `json:"allocatableGPUs"` // totals, for kubectl's columns
	InUseGPUs       int            `json:"inUseGPUs"`
	Conditions      []Condition    `json:"conditions"`
}

func sum(m map[string]int) (n int) {
	for _, v := range m {
		n += v
	}
	return
}

func (d Domain) Status() Status {
	c := Condition{Type: "Ready", Status: "True", Reason: "NodesReady"}
	if !d.Ready {
		c = Condition{Type: "Ready", Status: "False", Reason: "NodesNotReady", Message: "not ready: " + strings.Join(d.NotReady, ", ")}
	}
	return Status{Domain: d.Name, Vendor: d.Vendor, Fabric: d.Fabric, Zone: d.Zone, Nodes: d.Nodes,
		Capacity: d.Capacity, Allocatable: d.Allocatable, InUse: d.InUse,
		AllocatableGPUs: sum(d.Allocatable), InUseGPUs: sum(d.InUse), Conditions: []Condition{c}}
}

// Plan: the objects to create, the ones whose status to update and the ones to delete, by object name. have holds the
// existing objects' status as the API server returned it.
func Plan(have map[string]json.RawMessage, want []Domain) (create, update, del []string) {
	seen := map[string]bool{}
	for _, d := range want {
		name := objectName(d.Name)
		seen[name] = true
		st, _ := json.Marshal(d.Status())
		old, ok := have[name]
		switch {
		case !ok:
			create = append(create, name)
		case !sameJSON(old, st):
			update = append(update, name)
		}
	}
	for name := range have {
		if !seen[name] {
			del = append(del, name)
		}
	}
	sort.Strings(create)
	sort.Strings(update)
	sort.Strings(del)
	return
}

// sameJSON: equal after decoding (the API server returns the fields in its own order).
func sameJSON(a, b []byte) bool {
	var x, y any
	if json.Unmarshal(a, &x) != nil || json.Unmarshal(b, &y) != nil {
		return bytes.Equal(a, b)
	}
	xb, _ := json.Marshal(x)
	yb, _ := json.Marshal(y)
	return bytes.Equal(xb, yb)
}
