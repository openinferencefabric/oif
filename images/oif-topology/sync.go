package main

// T-131: one pass of the AcceleratorDomain view: read nodes and the pods bound to them, then create, update or delete
// the objects so each domain's status matches (Plan in domains.go).

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

const domainAPI = "/apis/oif.ai/v1alpha1/acceleratordomains"

func syncDomains(k *kube) (string, error) {
	var nl struct {
		Items []struct {
			Metadata struct {
				Name   string            `json:"name"`
				Labels map[string]string `json:"labels"`
			} `json:"metadata"`
			Status struct {
				Capacity    map[string]string `json:"capacity"`
				Allocatable map[string]string `json:"allocatable"`
				Conditions  []struct {
					Type   string `json:"type"`
					Status string `json:"status"`
				} `json:"conditions"`
			} `json:"status"`
		} `json:"items"`
	}
	if err := k.do(http.MethodGet, "/api/v1/nodes", "", nil, &nl); err != nil {
		return "", err
	}
	nodes := make([]ClusterNode, 0, len(nl.Items))
	for _, n := range nl.Items {
		ready := false
		for _, c := range n.Status.Conditions {
			ready = ready || c.Type == "Ready" && c.Status == "True"
		}
		nodes = append(nodes, ClusterNode{Node: Node{Name: n.Metadata.Name, Labels: n.Metadata.Labels, Allocatable: n.Status.Allocatable},
			Capacity: n.Status.Capacity, Ready: ready})
	}

	var pl struct {
		Items []struct {
			Spec struct {
				NodeName   string `json:"nodeName"`
				Containers []struct {
					Resources struct {
						Requests map[string]string `json:"requests"`
					} `json:"resources"`
				} `json:"containers"`
			} `json:"spec"`
			Status struct {
				Phase string `json:"phase"`
			} `json:"status"`
		} `json:"items"`
	}
	sel := url.QueryEscape("spec.nodeName!=,status.phase!=Succeeded,status.phase!=Failed")
	if err := k.do(http.MethodGet, "/api/v1/pods?fieldSelector="+sel, "", nil, &pl); err != nil {
		return "", err
	}
	pods := make([]Pod, 0, len(pl.Items))
	for _, p := range pl.Items {
		req := map[string]string{}
		for _, c := range p.Spec.Containers {
			for r, v := range c.Resources.Requests {
				n, err := strconv.Atoi(v)
				if err != nil {
					continue // CPU, memory: not counted
				}
				have, _ := strconv.Atoi(req[r])
				req[r] = strconv.Itoa(have + n)
			}
		}
		pods = append(pods, Pod{Node: p.Spec.NodeName, Phase: p.Status.Phase, Requests: req})
	}

	var dl struct {
		Items []struct {
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
			Status json.RawMessage `json:"status"`
		} `json:"items"`
	}
	if err := k.do(http.MethodGet, domainAPI, "", nil, &dl); err != nil {
		return "", err
	}
	have := map[string]json.RawMessage{}
	for _, d := range dl.Items {
		have[d.Metadata.Name] = d.Status
	}

	want := Domains(nodes, pods)
	create, update, del := Plan(have, want)
	byObject := map[string]Domain{}
	for _, d := range want {
		byObject[objectName(d.Name)] = d
	}
	for _, name := range create {
		obj, _ := json.Marshal(map[string]any{"apiVersion": "oif.ai/v1alpha1", "kind": "AcceleratorDomain",
			"metadata": map[string]any{"name": name, "labels": map[string]string{"app.kubernetes.io/managed-by": "oif"}}})
		if err := k.do(http.MethodPost, domainAPI, "application/json", obj, nil); err != nil {
			return "", err
		}
	}
	for _, name := range append(append([]string{}, create...), update...) { // status is a subresource: set after create
		patch, _ := json.Marshal([]map[string]any{{"op": "add", "path": "/status", "value": byObject[name].Status()}})
		if err := k.do(http.MethodPatch, domainAPI+"/"+name+"/status", "application/json-patch+json", patch, nil); err != nil {
			return "", err
		}
	}
	for _, name := range del {
		if err := k.do(http.MethodDelete, domainAPI+"/"+name, "", nil, nil); err != nil {
			return "", err
		}
	}

	parts := make([]string, 0, len(want))
	for _, d := range want {
		s := d.Status()
		parts = append(parts, fmt.Sprintf("%s %s %d/%d in use", d.Name, d.Vendor, s.InUseGPUs, s.AllocatableGPUs))
	}
	return fmt.Sprintf("domains: %s (created %d, updated %d, deleted %d)", strings.Join(parts, "; "), len(create), len(update), len(del)), nil
}
