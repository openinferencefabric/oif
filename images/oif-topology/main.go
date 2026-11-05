// oif-topology (T-130, ADR-019 amendment 2026-11-05): runs on every GPU node and labels its own node with the
// accelerator domain (the GPUs a job can use over one scale-up fabric), the fabric and the scale-out zone, for KAI's
// topology-aware scheduling. Reads sysfs (read only) and the node's own labels and annotations; changes only its three
// labels, on its own node (ValidatingAdmissionPolicy oif-topology-own-node).
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
	"strings"
	"time"
)

func main() {
	sys := flag.String("sys", "/host/sys", "the node's sysfs")
	every := flag.Duration("interval", time.Minute, "how often to look again")
	once := flag.Bool("once", false, "print the decision for this node and exit, changing nothing")
	flag.Parse()
	name := os.Getenv("NODE_NAME")
	if name == "" {
		log.Fatal("oif-topology: NODE_NAME not set")
	}
	k, err := newKube()
	if err != nil {
		log.Fatalf("oif-topology: no service account: %v", err)
	}
	last := ""
	for {
		if msg, err := reconcile(k, name, *sys, *once); err != nil {
			log.Printf("node %s: %v", name, err)
		} else if msg != last {
			log.Printf("node %s: %s", name, msg)
			last = msg
		}
		if *once {
			return
		}
		time.Sleep(*every)
	}
}

func reconcile(k *kube, name, sys string, dry bool) (string, error) {
	var obj struct {
		Metadata struct {
			Labels      map[string]string `json:"labels"`
			Annotations map[string]string `json:"annotations"`
		} `json:"metadata"`
		Status struct {
			Allocatable map[string]string `json:"allocatable"`
		} `json:"status"`
	}
	if err := k.do(http.MethodGet, "/api/v1/nodes/"+url.PathEscape(name), "", nil, &obj); err != nil {
		return "", err
	}
	n := Node{Name: name, Labels: obj.Metadata.Labels, Annotations: obj.Metadata.Annotations, Allocatable: obj.Status.Allocatable}
	want, why := Decide(n, readHardware(sys))
	msg := fmt.Sprintf("%s=%s %s=%s %s=%s (%s)", domainLabel, want[domainLabel], fabricLabel, want[fabricLabel], zoneLabel, want[zoneLabel], why)
	if want == nil {
		msg = "no labels (" + why + ")"
	}
	p := Patch(n.Labels, want)
	if p == nil || dry {
		return msg, nil
	}
	body, _ := json.Marshal(map[string]any{"metadata": map[string]any{"labels": p}})
	if err := k.do(http.MethodPatch, "/api/v1/nodes/"+url.PathEscape(name), "application/merge-patch+json", body, nil); err != nil {
		return "", err
	}
	return "labelled: " + msg, nil
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
	if resp.StatusCode != http.StatusOK {
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
