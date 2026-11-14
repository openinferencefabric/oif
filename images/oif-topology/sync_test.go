package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// One pass against a fake API server: the lab's two GPU workers, a pod on the AMD node, one stale object.
func TestSyncDomains(t *testing.T) {
	var mu sync.Mutex
	var calls []string
	var statuses = map[string]Status{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		calls = append(calls, r.Method+" "+r.URL.Path)
		mu.Unlock()
		switch {
		case r.Method == "GET" && r.URL.Path == "/api/v1/nodes":
			io.WriteString(w, `{"items": [
			  {"metadata": {"name": "cp1", "labels": {}}, "status": {"allocatable": {"cpu": "8"}, "conditions": [{"type": "Ready", "status": "True"}]}},
			  {"metadata": {"name": "gpu-nvidia", "labels": {"oif.ai/accelerator-domain": "gpu-nvidia", "oif.ai/accelerator-fabric": "pcie", "oif.ai/scaleout-zone": "default"}},
			   "status": {"capacity": {"nvidia.com/gpu": "1"}, "allocatable": {"nvidia.com/gpu": "1"}, "conditions": [{"type": "Ready", "status": "True"}]}},
			  {"metadata": {"name": "gpu-amd", "labels": {"oif.ai/accelerator-domain": "gpu-amd", "oif.ai/accelerator-fabric": "pcie", "oif.ai/scaleout-zone": "default"}},
			   "status": {"capacity": {"amd.com/gpu": "1"}, "allocatable": {"amd.com/gpu": "1"}, "conditions": [{"type": "Ready", "status": "True"}]}}]}`)
		case r.Method == "GET" && r.URL.Path == "/api/v1/pods":
			if !strings.Contains(r.URL.RawQuery, "fieldSelector=") {
				t.Errorf("pods listed without a field selector: %s", r.URL.RawQuery)
			}
			io.WriteString(w, `{"items": [{"spec": {"nodeName": "gpu-amd", "containers": [
			  {"resources": {"requests": {"amd.com/gpu": "1", "cpu": "500m"}}}, {"resources": {}}]}, "status": {"phase": "Running"}}]}`)
		case r.Method == "GET" && r.URL.Path == domainAPI:
			io.WriteString(w, `{"items": [{"metadata": {"name": "gpu-nvidia"}, "status": {"domain": "gpu-nvidia"}},
			  {"metadata": {"name": "removed-node"}, "status": {}}]}`)
		case r.Method == "POST" && r.URL.Path == domainAPI:
			w.WriteHeader(http.StatusCreated)
		case r.Method == "PATCH":
			if ct := r.Header.Get("Content-Type"); ct != "application/json-patch+json" {
				t.Errorf("status patch content type %q", ct)
			}
			var p []struct {
				Value Status `json:"value"`
			}
			if err := json.Unmarshal(body, &p); err != nil || len(p) != 1 {
				t.Errorf("status patch %s: %v", body, err)
			}
			statuses[strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, domainAPI+"/"), "/status")] = p[0].Value
		case r.Method == "DELETE":
		default:
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
	}))
	defer srv.Close()
	k := &kube{base: srv.URL, http: srv.Client()}
	msg, err := syncDomains(k)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"GET /api/v1/nodes", "GET /api/v1/pods", "GET " + domainAPI, "POST " + domainAPI,
		"PATCH " + domainAPI + "/gpu-amd/status", "PATCH " + domainAPI + "/gpu-nvidia/status", "DELETE " + domainAPI + "/removed-node"}
	if strings.Join(calls, "\n") != strings.Join(want, "\n") {
		t.Errorf("calls:\n%s\nwant:\n%s", strings.Join(calls, "\n"), strings.Join(want, "\n"))
	}
	if s := statuses["gpu-amd"]; s.Vendor != "amd" || s.InUseGPUs != 1 || s.AllocatableGPUs != 1 || s.Conditions[0].Status != "True" {
		t.Errorf("gpu-amd status: %+v", s)
	}
	if s := statuses["gpu-nvidia"]; s.Vendor != "nvidia" || s.InUseGPUs != 0 {
		t.Errorf("gpu-nvidia status: %+v", s)
	}
	if msg != "domains: gpu-amd amd 1/1 in use; gpu-nvidia nvidia 0/1 in use (created 1, updated 1, deleted 1)" {
		t.Errorf("message: %s", msg)
	}
}
