#!/bin/bash
# T-129 stage vendor-pool: installed only with several nodes and both GPU vendors, removed otherwise; what reruns it;
# the manifest fails open, covers only Run:ai project namespaces and carries the refusal policy. kubectl and the build
# are stubbed; the calls are recorded.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
OIF_HOME=$ROOT
for f in "$ROOT"/installer/stages/60-runai.sh "$ROOT"/installer/stages/61-vendor-pool.sh; do
  # shellcheck source=/dev/null
  . "$f" || { echo "      FAIL: cannot load $f"; exit 1; }
done
CALLS=$SANDBOX/calls
kc() { echo "kubectl $*" >> "$CALLS"; case "$*" in *"apply -f -"*) cat > /dev/null ;; esac; return 0; }
go_image_build() { echo "build $1 $3" >> "$CALLS"; }
runai_patch_spread() { echo "spread $1 $2" >> "$CALLS"; }
vendor_pool_cert() { echo "cert" >> "$CALLS"; }
PKI=$SANDBOX/pki; mkdir -p "$PKI"; echo "CA" > "$PKI/ca.crt"
NV=1; AMD=1; MULTI=1
gpu_count() { [ "$1" = nvidia ] && echo "$NV" || echo "$AMD"; }
multi_node() { [ "$MULTI" = 1 ]; }
run() { rm -f "$CALLS"; ( stage_vendor_pool ) > "$SANDBOX/out" 2>&1; }

run
grep -q "^build oif-vendor-pool oif.local/oif/oif-vendor-pool:" "$CALLS" || fail "both vendors: webhook image built"
grep -q "^spread oif-vendor-pool " "$CALLS" || fail "image copied to the other nodes"
grep -q "kubectl -n oif-vendor-pool create secret tls oif-vendor-pool-tls" "$CALLS" || fail "TLS secret created"
grep -q "kubectl apply -f $OIF_STATE/vendor-pool.yaml" "$CALLS" || fail "manifest applied"
grep -q "rollout status deploy/oif-vendor-pool" "$CALLS" || fail "waits for the webhook"

for case in "AMD=0" "NV=0" "MULTI=0"; do
  NV=1; AMD=1; MULTI=1; eval "$case"; run
  grep -q "^build" "$CALLS" && fail "$case: nothing built"
  grep -q "kubectl delete mutatingwebhookconfiguration oif-vendor-pool" "$CALLS" || fail "$case: webhook removed"
  grep -q "kubectl delete validatingadmissionpolicy oif-vendor-agnostic-gpu" "$CALLS" || fail "$case: policy removed"
done

a=$(vendor_pool_rev); echo "// x" >> "$SANDBOX/extra.go"
b=$(VENDOR_POOL_SRC=$SANDBOX vendor_pool_rev 2>/dev/null)
[ "$a" != "$b" ] || fail "changing the webhook's source reruns the stage"

out=$(VENDOR_POOL_IMAGE=img:x VENDOR_POOL_CA=Y2E= SYSTEM_LABEL=node-role.kubernetes.io/runai-system render "$ROOT/platform/kubernetes/vendor-pool.yaml")
grep -q "failurePolicy: Ignore" <<< "$out" || fail "the webhook fails open"
grep -q "reinvocationPolicy: IfNeeded" <<< "$out" || fail "Run:ai's webhooks see the pool it sets"
[ "$(grep -c "matchExpressions: \[{key: runai/queue, operator: Exists}\]" <<< "$out")" = 2 ] \
  || fail "webhook and policy cover only Run:ai project namespaces"
grep -q "name: oif-vendor-agnostic-gpu" <<< "$out" || fail "refusal policy present"
grep -q "caBundle: Y2E=" <<< "$out" || fail "the webhook trusts oif's CA"
finish
