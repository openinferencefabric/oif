package main

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

var errNotFound = errors.New("not found")

type getter func(apiVersion, kind, ns, name string) (map[string]any, error)

// ownerPool: the node pool of the workload that owns a pod: the first object up the owner chain (ReplicaSet,
// Deployment, a Dynamo or Run:ai workload ...) that carries the runai/node-pool label.
func ownerPool(get getter, ns string, refs []OwnerRef) (pool, owner string) {
	for depth := 0; depth < 6 && len(refs) > 0; depth++ {
		ref := refs[0]
		for _, r := range refs {
			if r.Controller {
				ref = r
			}
		}
		obj, err := get(ref.APIVersion, ref.Kind, ns, ref.Name)
		if err != nil {
			return "", ""
		}
		meta, _ := obj["metadata"].(map[string]any)
		if labels, _ := meta["labels"].(map[string]any); labels != nil {
			if p, _ := labels[poolLabel].(string); p != "" {
				return p, ref.Kind + "/" + ref.Name
			}
		}
		refs = nil
		if list, _ := meta["ownerReferences"].([]any); list != nil {
			b, _ := json.Marshal(list)
			_ = json.Unmarshal(b, &refs)
		}
	}
	return "", ""
}

// kube: the API server, reached with the pod's service account.
type kube struct {
	base, token string
	http        *http.Client
	mu          sync.Mutex
	plural      map[string]string    // apiVersion/kind -> resource
	nodes       map[string]time.Time // vendor -> when nodes with its GPUs were last seen
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
		http:   &http.Client{Timeout: 2 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}}},
		plural: map[string]string{}, nodes: map[string]time.Time{},
	}, nil
}

func (k *kube) getJSON(path string, out any) error {
	req, _ := http.NewRequest(http.MethodGet, k.base+path, nil)
	req.Header.Set("Authorization", "Bearer "+k.token)
	resp, err := k.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return errNotFound
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: %s", path, resp.Status)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func groupPath(apiVersion string) string {
	if !strings.Contains(apiVersion, "/") {
		return "/api/" + apiVersion
	}
	return "/apis/" + apiVersion
}

// resource: the plural name of a kind, from API discovery (cached).
func (k *kube) resource(apiVersion, kind string) (string, error) {
	key := apiVersion + "/" + kind
	k.mu.Lock()
	r, ok := k.plural[key]
	k.mu.Unlock()
	if ok {
		return r, nil
	}
	var list struct {
		Resources []struct {
			Name, Kind string
			Namespaced bool
		} `json:"resources"`
	}
	if err := k.getJSON(groupPath(apiVersion), &list); err != nil {
		return "", err
	}
	for _, res := range list.Resources {
		if res.Kind == kind && !strings.Contains(res.Name, "/") {
			k.mu.Lock()
			k.plural[key] = res.Name
			k.mu.Unlock()
			return res.Name, nil
		}
	}
	return "", errNotFound
}

func (k *kube) get(apiVersion, kind, ns, name string) (map[string]any, error) {
	res, err := k.resource(apiVersion, kind)
	if err != nil {
		return nil, err
	}
	var obj map[string]any
	return obj, k.getJSON(fmt.Sprintf("%s/namespaces/%s/%s/%s", groupPath(apiVersion), url.PathEscape(ns), res, url.PathEscape(name)), &obj)
}

// hasNodes: some node carries oif.ai/gpu-vendor=<vendor> (cached for a minute; on error, assume yes: the stage
// installs this only where the vendors have nodes of their own).
func (k *kube) hasNodes(vendor string) bool {
	k.mu.Lock()
	seen, ok := k.nodes[vendor]
	k.mu.Unlock()
	if ok && time.Since(seen) < time.Minute {
		return true
	}
	var list struct {
		Items []any `json:"items"`
	}
	if err := k.getJSON("/api/v1/nodes?limit=1&labelSelector="+url.QueryEscape(vendorLabel+"="+vendor), &list); err != nil {
		return true
	}
	if len(list.Items) == 0 {
		return false
	}
	k.mu.Lock()
	k.nodes[vendor] = time.Now()
	k.mu.Unlock()
	return true
}
