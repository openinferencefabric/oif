// oif-vendor-pool (T-129, ADR-032): a mutating admission webhook for pods in Run:ai project namespaces. It pins a
// pod to one GPU vendor's node pool (label runai/node-pool and node selector oif.ai/gpu-vendor) when the pod asks for
// that vendor's GPU, or when the workload that owns it is in that pool. It never refuses a pod: on any doubt it
// leaves the pod as it is (the webhook also fails open).
package main

import (
	"encoding/json"
	"flag"
	"io"
	"log"
	"net/http"
)

type review struct {
	APIVersion string    `json:"apiVersion"`
	Kind       string    `json:"kind"`
	Request    *request  `json:"request,omitempty"`
	Response   *response `json:"response,omitempty"`
}

type request struct {
	UID       string          `json:"uid"`
	Namespace string          `json:"namespace"`
	Object    json.RawMessage `json:"object"`
}

type response struct {
	UID       string `json:"uid"`
	Allowed   bool   `json:"allowed"`
	PatchType string `json:"patchType,omitempty"`
	Patch     []byte `json:"patch,omitempty"`
}

func main() {
	listen := flag.String("listen", ":8443", "HTTPS address")
	cert := flag.String("cert", "/tls/tls.crt", "serving certificate")
	key := flag.String("key", "/tls/tls.key", "serving key")
	flag.Parse()
	k, err := newKube()
	if err != nil {
		log.Fatalf("oif-vendor-pool: no service account: %v", err)
	}
	http.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) })
	http.HandleFunc("/mutate", func(w http.ResponseWriter, r *http.Request) { mutate(w, r, k) })
	log.Printf("oif-vendor-pool: listening on %s", *listen)
	log.Fatal(http.ListenAndServeTLS(*listen, *cert, *key, nil))
}

func mutate(w http.ResponseWriter, r *http.Request, k *kube) {
	var rv review
	body, err := io.ReadAll(io.LimitReader(r.Body, 4<<20))
	if err != nil || json.Unmarshal(body, &rv) != nil || rv.Request == nil {
		http.Error(w, "not an AdmissionReview", http.StatusBadRequest)
		return
	}
	out := &response{UID: rv.Request.UID, Allowed: true}
	var p Pod
	if json.Unmarshal(rv.Request.Object, &p) == nil {
		ns := p.Metadata.Namespace
		if ns == "" {
			ns = rv.Request.Namespace
		}
		owner := func() (string, string) { return ownerPool(k.get, ns, p.Metadata.OwnerReferences) }
		if pool, why, patch := Decide(&p, owner, k.hasNodes); patch != nil {
			if b, err := json.Marshal(patch); err == nil {
				out.PatchType, out.Patch = "JSONPatch", b
				name := p.Metadata.Name
				if name == "" {
					name = p.Metadata.GenerateName + "*"
				}
				log.Printf("pod %s/%s: pool %s (%s)", ns, name, pool, why)
			}
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(review{APIVersion: "admission.k8s.io/v1", Kind: "AdmissionReview", Response: out})
}
