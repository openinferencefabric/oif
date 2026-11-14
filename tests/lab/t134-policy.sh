#!/bin/bash
# T-134 lab check: PlacementPolicy, the defaults for a namespace's AIJobs. Its schema (known vendors, no repeats); the
# namespace's policy sets the vendor order of an AIJob that names none (acceptance check 5); the cluster's policy (in
# oif-aijob) applies where a namespace has none; a policy's requireSameDomain reaches the Job's KAI annotations unless the
# AIJob says otherwise (one domain per vendor on the lab: no required level, T-141).
# Changes while it runs: PlacementPolicies in team-c's namespace and oif-aijob, AIJobs in team-c's namespace (deleted at
# the end, also on Ctrl+C). It does not run when oif-aijob already has a policy "default" (it would change every project).
#   sudo tests/lab/t134-policy.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); OIF_HOME=$ROOT
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 2; }
# shellcheck source=../../versions.env
. "$ROOT/versions.env"
for f in "$ROOT"/installer/lib/*.sh "$ROOT"/installer/stages/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done
INTERACTIVE=0; TLOG=/dev/null
config_load_saved

FAILS=0; N=0
check() { N=$((N + 1)); if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi; }
info() { echo "  INFO  $*"; }
kc get placementpolicy -n oif-aijob default >/dev/null 2>&1 && { echo "  oif-aijob has a PlacementPolicy default already: not changing it"; exit 2; }
NS=$(runai_api project-pools team-c nvidia=1 amd=1) || { echo "  FAIL  project team-c: $NS"; exit 1; }
st() { kc -n "$NS" get aijob "$1" -o jsonpath="{.status.$2}" 2>/dev/null; }
vendor_is() { [ "$(st "$1" vendor)" = "$2" ]; }
in_use_is() { [ "$(kc get acceleratordomain "$1" -o jsonpath='{.status.inUseGPUs}')" = "$2" ]; }
nv_node=$(node_with nvidia.com/gpu); amd_node=$(node_with amd.com/gpu)
nv_dom=$(kc get node "$nv_node" -o jsonpath='{.metadata.labels.oif\.ai/accelerator-domain}')
amd_dom=$(kc get node "$amd_node" -o jsonpath='{.metadata.labels.oif\.ai/accelerator-domain}')
both_free() { in_use_is "$nv_dom" 0 && in_use_is "$amd_dom" 0; }
cleanup() { kc -n "$NS" delete aijobs -l app.kubernetes.io/part-of=oif-t134 --ignore-not-found --wait=false >/dev/null 2>&1
  kc -n "$NS" delete placementpolicy default --ignore-not-found >/dev/null 2>&1
  kc -n oif-aijob delete placementpolicy default --ignore-not-found >/dev/null 2>&1; }
trap 'cleanup; wait_for "GPUs free again" 180 5 both_free >/dev/null 2>&1' EXIT   # the next test starts clean
policy() {   # namespace spec-JSON
  echo "{\"apiVersion\": \"oif.ai/v1alpha1\", \"kind\": \"PlacementPolicy\", \"metadata\": {\"name\": \"default\", \"namespace\": \"$1\"}, \"spec\": $2}"; }
aijob() {   # name [placement JSON]: one pod, one GPU, no vendor
  local p='{}'; [ -n "${2:-}" ] && p=$2
  echo "{\"apiVersion\": \"oif.ai/v1alpha1\", \"kind\": \"AIJob\", \"metadata\": {\"name\": \"$1\", \"namespace\": \"$NS\", \"labels\": {\"app.kubernetes.io/part-of\": \"oif-t134\"}},
   \"spec\": {\"gpuCount\": 1, \"template\": {\"image\": \"$BUSYBOX_IMAGE\", \"command\": [\"sleep\", \"600\"]}, \"placement\": $p}}"; }
done_with() { kc -n "$NS" delete aijob "$@" --wait=true >/dev/null 2>&1; wait_for "GPUs free in the view" 120 5 both_free >/dev/null 2>&1; }
ann() { kc -n "$NS" get job "$1" -o jsonpath="{.metadata.annotations.kai\.scheduler/$2}" 2>/dev/null; }

echo "T-134 PlacementPolicy, project namespace $NS"
cleanup; wait_for "GPUs free in the view" 120 5 both_free >/dev/null 2>&1
check "both GPUs free before the test" both_free
check "an unknown vendor is refused" bash -c '! kubectl --kubeconfig "$1" apply --dry-run=server -f - <<< "$2"' _ "$KCFG" "$(policy "$NS" '{"vendorPriority": ["intel"]}')"
check "a vendor twice is refused" bash -c '! kubectl --kubeconfig "$1" apply --dry-run=server -f - <<< "$2"' _ "$KCFG" "$(policy "$NS" '{"vendorPriority": ["amd", "amd"]}')"

# the namespace's policy: AMD first
policy "$NS" '{"vendorPriority": ["amd", "nvidia"]}' | kc apply -f - >/dev/null
kc -n "$NS" get placementpolicy 2>&1 | sed 's/^/        /'
aijob t134-ns | kc apply -f - >/dev/null
check "no vendor, namespace policy amd first: AMD (within 1 min)" wait_for "t134-ns vendor" 60 5 vendor_is t134-ns amd
info "t134-ns: $(st t134-ns message)"
check "the status names the policy" bash -c '[[ "$1" == *"PlacementPolicy $2/default"* ]]' _ "$(st t134-ns message)" "$NS"
kc -n "$NS" delete placementpolicy default >/dev/null; done_with t134-ns

# no namespace policy: the cluster's, in oif-aijob
policy oif-aijob '{"vendorPriority": ["amd"]}' | kc apply -f - >/dev/null
aijob t134-cluster | kc apply -f - >/dev/null
check "no vendor, no namespace policy, cluster policy amd: AMD (within 1 min)" wait_for "t134-cluster vendor" 60 5 vendor_is t134-cluster amd
check "the status names the cluster's policy" bash -c '[[ "$1" == *"PlacementPolicy oif-aijob/default"* ]]' _ "$(st t134-cluster message)"
kc -n oif-aijob delete placementpolicy default >/dev/null; done_with t134-cluster

# requireSameDomain from the policy, unless the AIJob says
policy "$NS" '{"requireSameDomain": true}' | kc apply -f - >/dev/null
aijob t134-dom | kc apply -f - >/dev/null
aijob t134-own '{"requireSameDomain": false}' | kc apply -f - >/dev/null
check "policy requireSameDomain: the Job gets KAI's topology (within 1 min)" wait_for "t134-dom topology" 60 5 bash -c '[ "$(kubectl --kubeconfig "$1" -n "$2" get job t134-dom -o jsonpath="{.metadata.annotations.kai\.scheduler/topology}" 2>/dev/null)" = oif-accelerator ]' _ "$KCFG" "$NS"
check "one domain per vendor on the lab: no required level (stock KAI would never place it)" test -z "$(ann t134-dom topology-required-placement)"
check "the AIJob's own requireSameDomain: false wins: no topology on its Job" bash -c '[ -n "$(kubectl --kubeconfig "$1" -n "$2" get job t134-own -o name 2>/dev/null)" ] && [ -z "$3" ]' _ "$KCFG" "$NS" "$(ann t134-own topology)"
info "oif-aijob log: $(kc -n oif-aijob logs deploy/oif-aijob 2>/dev/null | tail -1 | cut -c1-200)"

echo "T-134: $((N - FAILS))/$N checks passed"
[ "$FAILS" = 0 ]
