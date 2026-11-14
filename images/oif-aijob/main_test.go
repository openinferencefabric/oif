package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// One pass against a fake API server, on the lab's shape (one NVIDIA and one AMD GPU, each its own domain):
// - new: no Job yet, prefers AMD, in a project namespace: a Job on AMD is created, status Pending, vendor amd;
// - running: its Job and pod exist on the NVIDIA node: status Running, domain gpu-nvidia, unchanged message kept;
// - stray: in a namespace that is no Run:ai project: Failed, no Job;
// - same: status already right: not patched again.
func TestSync(t *testing.T) {
	var calls []string
	posted := map[string]map[string]any{}
	statuses := map[string]Status{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		calls = append(calls, r.Method+" "+r.URL.Path)
		switch {
		case r.Method == "GET" && r.URL.Path == aijobAPI:
			io.WriteString(w, `{"items": [
			  {"metadata": {"name": "new", "namespace": "runai-team-a", "uid": "u1"}, "spec": {"gpuCount": 1, "model": "m", "template": {"image": "i"}, "placement": {"preferVendor": "amd"}}},
			  {"metadata": {"name": "running", "namespace": "runai-team-a", "uid": "u2"}, "spec": {"gpuCount": 1, "template": {"image": "i"}},
			   "status": {"phase": "Pending", "vendor": "nvidia", "crossVendor": false, "message": "nvidia: it has room for 1 GPUs"}},
			  {"metadata": {"name": "stray", "namespace": "default", "uid": "u3"}, "spec": {"gpuCount": 1, "template": {"image": "i"}}},
			  {"metadata": {"name": "same", "namespace": "runai-team-a", "uid": "u4"}, "spec": {"gpuCount": 1, "template": {"image": "i"}},
			   "status": {"crossVendor": false, "message": "m0", "phase": "Succeeded", "vendor": "amd", "nodes": ["gpu-amd"], "domains": ["gpu-amd"]}}]}`)
		case r.URL.Path == "/apis/oif.ai/v1alpha1/acceleratordomains":
			io.WriteString(w, `{"items": [
			  {"status": {"capacity": {"nvidia": 1}, "allocatable": {"nvidia": 1}, "inUse": {"nvidia": 1}}},
			  {"status": {"capacity": {"amd": 1}, "allocatable": {"amd": 1}, "inUse": {"amd": 0}}}]}`)
		case r.URL.Path == "/api/v1/nodes":
			io.WriteString(w, `{"items": [{"metadata": {"name": "gpu-nvidia", "labels": {"oif.ai/accelerator-domain": "gpu-nvidia"}}},
			  {"metadata": {"name": "gpu-amd", "labels": {"oif.ai/accelerator-domain": "gpu-amd"}}}]}`)
		case r.URL.Path == "/apis/batch/v1/jobs":
			io.WriteString(w, `{"items": [
			  {"metadata": {"namespace": "runai-team-a", "labels": {"oif.ai/aijob": "running"}},
			   "spec": {"completions": 1, "template": {"spec": {"containers": [{"resources": {"limits": {"nvidia.com/gpu": "1"}}}]}}}, "status": {}},
			  {"metadata": {"namespace": "runai-team-a", "labels": {"oif.ai/aijob": "same"}},
			   "spec": {"completions": 1, "template": {"spec": {"containers": [{"resources": {"limits": {"amd.com/gpu": "1"}}}]}}}, "status": {"succeeded": 1}}]}`)
		case r.URL.Path == "/api/v1/pods":
			io.WriteString(w, `{"items": [
			  {"metadata": {"namespace": "runai-team-a", "labels": {"oif.ai/aijob": "running"}}, "spec": {"nodeName": "gpu-nvidia"}, "status": {"phase": "Running"}},
			  {"metadata": {"namespace": "runai-team-a", "labels": {"oif.ai/aijob": "same"}}, "spec": {"nodeName": "gpu-amd"}, "status": {"phase": "Succeeded"}}]}`)
		case r.URL.Path == "/api/v1/namespaces":
			if !strings.Contains(r.URL.RawQuery, "runai%2Fqueue") {
				t.Errorf("namespaces not filtered by runai/queue: %s", r.URL.RawQuery)
			}
			io.WriteString(w, `{"items": [{"metadata": {"name": "runai-team-a"}}]}`)
		case r.Method == "POST":
			var j map[string]any
			_ = json.Unmarshal(body, &j)
			posted[r.URL.Path] = j
			w.WriteHeader(http.StatusCreated)
		case r.Method == "PATCH":
			var p []struct {
				Value Status `json:"value"`
			}
			_ = json.Unmarshal(body, &p)
			statuses[strings.Split(r.URL.Path, "/")[7]] = p[0].Value
		default:
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
	}))
	defer srv.Close()
	msg, err := sync(&kube{base: srv.URL, http: srv.Client()}, map[string]string{"nvidia": "nvidia", "amd": "amd"})
	if err != nil {
		t.Fatal(err)
	}
	j := posted["/apis/batch/v1/namespaces/runai-team-a/jobs"]
	if j == nil || lookup(j, "metadata", "name") != "new" || lookup(j, "metadata", "labels", "runai/node-pool") != "amd" {
		t.Errorf("Job for new: %v", j)
	}
	if len(posted) != 1 {
		t.Errorf("only the new AIJob gets a Job: %v", posted)
	}
	if s := statuses["new"]; s.Phase != "Pending" || s.Vendor != "amd" || !strings.HasPrefix(s.Message, "amd: the preferred vendor") {
		t.Errorf("new: %+v", s)
	}
	if s := statuses["running"]; s.Phase != "Running" || s.Vendor != "nvidia" || strings.Join(s.Domains, ",") != "gpu-nvidia" || s.Message != "nvidia: it has room for 1 GPUs" {
		t.Errorf("running: %+v", s)
	}
	if s := statuses["stray"]; s.Phase != "Failed" || !strings.Contains(s.Message, "not a Run:ai project") {
		t.Errorf("stray: %+v", s)
	}
	if _, ok := statuses["same"]; ok {
		t.Errorf("same: patched although unchanged")
	}
	if !strings.Contains(msg, "runai-team-a/new amd Pending") {
		t.Errorf("message: %s", msg)
	}
}
