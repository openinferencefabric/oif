// oif-aijob (T-133, ADR-019): turns each AIJob into a Job on one GPU vendor and keeps the AIJob's status (vendor,
// domains, nodes, phase). One replica; every pass lists AIJobs, Jobs, pods, nodes and AcceleratorDomains.
package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"reflect"
	"strings"
	"time"
)

func main() {
	every := flag.Duration("interval", 10*time.Second, "how often to look again")
	poolsFlag := flag.String("pools", "nvidia=nvidia,amd=amd", "each vendor's Run:ai node pool; empty = the default pool")
	policyNS := flag.String("policy-namespace", "oif-aijob", "where PlacementPolicy default applies to every project without its own")
	flag.Parse()
	pools := map[string]string{}
	for _, kv := range strings.Split(*poolsFlag, ",") {
		if v, p, ok := strings.Cut(kv, "="); ok {
			pools[v] = p
		}
	}
	k, err := newKube()
	if err != nil {
		log.Fatalf("oif-aijob: no service account: %v", err)
	}
	last := ""
	for {
		if msg, err := sync(k, pools, *policyNS); err != nil {
			log.Printf("aijobs: %v", err)
		} else if msg != last {
			log.Print(msg)
			last = msg
		}
		time.Sleep(*every)
	}
}

const aijobAPI = "/apis/oif.ai/v1alpha1/aijobs"

type meta struct {
	Name      string            `json:"name"`
	Namespace string            `json:"namespace"`
	UID       string            `json:"uid"`
	Labels    map[string]string `json:"labels"`
}

func sync(k *kube, pools map[string]string, policyNS string) (string, error) {
	var al struct {
		Items []struct {
			Metadata meta            `json:"metadata"`
			Spec     Spec            `json:"spec"`
			Status   json.RawMessage `json:"status"`
		} `json:"items"`
	}
	if err := k.do(http.MethodGet, aijobAPI, "", nil, &al); err != nil {
		return "", err
	}
	if len(al.Items) == 0 {
		return "aijobs: none", nil
	}

	var dl struct {
		Items []struct {
			Status Domain `json:"status"`
		} `json:"items"`
	}
	if err := k.do(http.MethodGet, "/apis/oif.ai/v1alpha1/acceleratordomains", "", nil, &dl); err != nil {
		return "", err
	}
	domains, domainsOf := []Domain{}, map[string]int{}
	for _, d := range dl.Items {
		domains = append(domains, d.Status)
		for v, c := range d.Status.Capacity {
			if c > 0 {
				domainsOf[v]++
			}
		}
	}

	var nl struct {
		Items []struct {
			Metadata meta `json:"metadata"`
		} `json:"items"`
	}
	if err := k.do(http.MethodGet, "/api/v1/nodes", "", nil, &nl); err != nil {
		return "", err
	}
	nodeDomain := map[string]string{}
	for _, n := range nl.Items {
		nodeDomain[n.Metadata.Name] = n.Metadata.Labels["oif.ai/accelerator-domain"]
	}

	var jl struct {
		Items []struct {
			Metadata meta `json:"metadata"`
			KubeJob
		} `json:"items"`
	}
	sel := "?labelSelector=" + url.QueryEscape("oif.ai/aijob")
	if err := k.do(http.MethodGet, "/apis/batch/v1/jobs"+sel, "", nil, &jl); err != nil {
		return "", err
	}
	jobs := map[string]KubeJob{}
	for _, j := range jl.Items {
		jobs[j.Metadata.Namespace+"/"+j.Metadata.Labels["oif.ai/aijob"]] = j.KubeJob
	}

	var pl struct {
		Items []struct {
			Metadata meta `json:"metadata"`
			Spec     struct {
				NodeName string `json:"nodeName"`
			} `json:"spec"`
			Status struct {
				Phase string `json:"phase"`
			} `json:"status"`
		} `json:"items"`
	}
	if err := k.do(http.MethodGet, "/api/v1/pods"+sel, "", nil, &pl); err != nil {
		return "", err
	}
	pods := map[string][]PodInfo{}
	for _, p := range pl.Items {
		key := p.Metadata.Namespace + "/" + p.Metadata.Labels["oif.ai/aijob"]
		pods[key] = append(pods[key], PodInfo{Phase: p.Status.Phase, Node: p.Spec.NodeName})
	}

	var nsl struct {
		Items []struct {
			Metadata meta `json:"metadata"`
		} `json:"items"`
	}
	if err := k.do(http.MethodGet, "/api/v1/namespaces?labelSelector="+url.QueryEscape("runai/queue"), "", nil, &nsl); err != nil {
		return "", err
	}
	project := map[string]bool{}
	for _, n := range nsl.Items {
		project[n.Metadata.Name] = true
	}

	var ppl struct {
		Items []struct {
			Metadata meta   `json:"metadata"`
			Spec     Policy `json:"spec"`
		} `json:"items"`
	}
	if err := k.do(http.MethodGet, "/apis/oif.ai/v1alpha1/placementpolicies", "", nil, &ppl); err != nil {
		return "", err
	}
	policies := map[string]*Policy{} // namespace: its PlacementPolicy "default"
	for i, p := range ppl.Items {
		if p.Metadata.Name == "default" {
			policies[p.Metadata.Namespace] = &ppl.Items[i].Spec
		}
	}

	var report []string
	for _, a := range al.Items {
		key := a.Metadata.Namespace + "/" + a.Metadata.Name
		var old Status
		_ = json.Unmarshal(a.Status, &old)
		var st Status
		if j, ok := jobs[key]; ok {
			st = StatusOf(j.Vendor(), old.Message, j, pods[key], nodeDomain)
		} else if !project[a.Metadata.Namespace] {
			st = Status{Phase: "Failed", Message: "namespace " + a.Metadata.Namespace + " is not a Run:ai project (no runai/queue label)"}
		} else {
			r := Effective(a.Spec.Placement.RequireSameDomain, a.Metadata.Namespace, policies[a.Metadata.Namespace], policies[policyNS], policyNS)
			vendor, why := ChooseVendor(a.Spec.Placement.PreferVendor, a.Spec.GPUCount*a.Spec.workers(), domains, r.Order)
			if r.Source != "" {
				why += " (" + r.Source + ")"
			}
			if vendor == "" {
				st = Status{Phase: "Failed", Message: why}
			} else {
				aj := AIJob{Name: a.Metadata.Name, Namespace: a.Metadata.Namespace, UID: a.Metadata.UID, Spec: a.Spec}
				aj.Spec.Placement.RequireSameDomain = &r.RequireSameDomain
				body, _ := json.Marshal(JobFor(aj, vendor, pools[vendor], domainsOf[vendor]))
				st = Status{Phase: "Pending", Vendor: vendor, Message: why}
				if err := k.do(http.MethodPost, "/apis/batch/v1/namespaces/"+url.PathEscape(a.Metadata.Namespace)+"/jobs", "application/json", body, nil); err != nil {
					st = Status{Phase: "Pending", Message: "cannot create its Job (tried again): " + err.Error()}
				}
			}
		}
		report = append(report, fmt.Sprintf("%s %s %s", key, st.Vendor, st.Phase))
		if len(a.Status) > 0 && string(a.Status) != "null" && reflect.DeepEqual(old, st) {
			continue
		}
		patch, _ := json.Marshal([]map[string]any{{"op": "add", "path": "/status", "value": st}})
		path := "/apis/oif.ai/v1alpha1/namespaces/" + url.PathEscape(a.Metadata.Namespace) + "/aijobs/" + url.PathEscape(a.Metadata.Name) + "/status"
		if err := k.do(http.MethodPatch, path, "application/json-patch+json", patch, nil); err != nil {
			return "", err
		}
	}
	return "aijobs: " + strings.Join(report, "; "), nil
}

// kube: the API server, reached with the pod's service account.
type kube struct {
	base, token string
	http        *http.Client
}

func newKube() (*kube, error) {
	const sa = "/var/run/secrets/kubernetes.io/serviceaccount/"
	token, err := os.ReadFile(sa + "token")
	if err != nil {
		return nil, err
	}
	ca, err := os.ReadFile(sa + "ca.crt")
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(ca)
	host := os.Getenv("KUBERNETES_SERVICE_HOST")
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	return &kube{
		base: "https://" + host + ":" + os.Getenv("KUBERNETES_SERVICE_PORT"), token: strings.TrimSpace(string(token)),
		http: &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}}},
	}, nil
}

func (k *kube) do(method, path, contentType string, body []byte, out any) error {
	req, _ := http.NewRequest(method, k.base+path, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+k.token)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	resp, err := k.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		var st struct {
			Message string `json:"message"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&st)
		return fmt.Errorf("%s %s: %s %s", method, path, resp.Status, st.Message)
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}
