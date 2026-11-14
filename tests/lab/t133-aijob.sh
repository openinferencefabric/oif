#!/bin/bash
# T-133 lab check: AIJob (controller oif-aijob). The admission rules (no cross-vendor job, no spec change); a job that
# prefers AMD runs on the AMD GPU; one that prefers AMD while it is busy runs on NVIDIA (a soft preference); a job that
# names no vendor gets one, as a plain Job with a concrete GPU resource; status shows vendor, domain and crossVendor; a
# plain GPU pod is not touched. The lab has one GPU per worker, so every job here is one pod with one GPU.
# Changes while it runs: AIJobs and their Jobs in project team-c's namespace (deleted at the end, also on Ctrl+C).
#   sudo tests/lab/t133-aijob.sh
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
NS=$(runai_api project-pools team-c nvidia=1 amd=1) || { echo "  FAIL  project team-c: $NS"; exit 1; }
st() { kc -n "$NS" get aijob "$1" -o jsonpath="{.status.$2}" 2>/dev/null; }
phase_is() { [ "$(st "$1" phase)" = "$2" ]; }
in_use_is() { [ "$(kc get acceleratordomain "$1" -o jsonpath='{.status.inUseGPUs}')" = "$2" ]; }
both_free() { in_use_is "$nv_dom" 0 && in_use_is "$amd_dom" 0; }
pod_running() { [ "$(kc -n "$NS" get pod "$1" -o jsonpath='{.status.phase}')" = Running ]; }
cleanup() { kc -n "$NS" delete aijobs -l app.kubernetes.io/part-of=oif-t133 --ignore-not-found --wait=false >/dev/null 2>&1
  kc -n "$NS" delete pod t133-plain --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup EXIT
aijob() {   # name [preferVendor] [extra placement JSON]: an AIJob of one pod with one GPU that sleeps
  local p="{}"; [ -n "${2:-}" ] && p="{\"preferVendor\": \"$2\"}"; [ -n "${3:-}" ] && p=$3
  cat <<EOF
{"apiVersion": "oif.ai/v1alpha1", "kind": "AIJob",
 "metadata": {"name": "$1", "namespace": "$NS", "labels": {"app.kubernetes.io/part-of": "oif-t133"}},
 "spec": {"model": "Qwen/Qwen3-0.6B", "precision": "bf16", "gpuCount": 1,
          "template": {"image": "$BUSYBOX_IMAGE", "command": ["sh", "-c", "echo \$OIF_GPU_VENDOR \$OIF_MODEL; sleep 600"]},
          "placement": $p}}
EOF
}
nv_node=$(node_with nvidia.com/gpu); amd_node=$(node_with amd.com/gpu)
nv_dom=$(kc get node "$nv_node" -o jsonpath='{.metadata.labels.oif\.ai/accelerator-domain}')
amd_dom=$(kc get node "$amd_node" -o jsonpath='{.metadata.labels.oif\.ai/accelerator-domain}')
cleanup; wait_for "old test jobs gone" 120 5 bash -c '[ -z "$(kubectl --kubeconfig "$1" -n "$2" get pods -l app.kubernetes.io/managed-by=oif -o name 2>/dev/null | grep t133)" ]' _ "$KCFG" "$NS" >/dev/null 2>&1

echo "T-133 AIJob (controller oif-aijob), project namespace $NS"
check "oif-aijob running" bash -c '[ "$(kubectl --kubeconfig "$1" -n oif-aijob get deploy oif-aijob -o jsonpath="{.status.readyReplicas}")" = 1 ]' _ "$KCFG"
wait_for "GPUs free (an earlier test's pods may still be stopping)" 180 5 both_free >/dev/null 2>&1
check "both GPUs free before the test" both_free

# admission
out=$(aijob t133-cross "" '{"allowCrossVendor": true}' | kc apply --dry-run=server -f - 2>&1)
check "allowCrossVendor: true is refused" grep -q "cross-vendor jobs (allowCrossVendor: true) are not supported yet" <<< "$out"
aijob t133-amd amd | kc apply -f - >/dev/null
check "an AIJob's spec cannot change" bash -c 'kubectl --kubeconfig "$1" -n "$2" patch aijob t133-amd --type merge -p "{\"spec\": {\"gpuCount\": 2}}" 2>&1 | grep -q "cannot change"' _ "$KCFG" "$NS"

# preferVendor amd, AMD free: AMD
check "t133-amd (prefers AMD): Running within 3 min" wait_for "t133-amd running" 180 5 phase_is t133-amd Running
info "t133-amd: $(kc -n "$NS" get aijob t133-amd --no-headers 2>&1); $(st t133-amd message)"
check "t133-amd: vendor amd, domain $amd_dom, nodes [$amd_node], crossVendor false" \
  bash -c '[ "$1" = "amd [\"$2\"] [\"$3\"] false" ]' _ "$(st t133-amd vendor) $(st t133-amd domains) $(st t133-amd nodes) $(st t133-amd crossVendor)" "$amd_dom" "$amd_node"
check "its Job asks for amd.com/gpu: 1, in pool amd" bash -c '[ "$1" = "1 amd" ]' _ \
  "$(kc -n "$NS" get job t133-amd -o jsonpath='{.spec.template.spec.containers[0].resources.limits.amd\.com/gpu} {.metadata.labels.runai/node-pool}')"
check "the container got OIF_GPU_VENDOR and OIF_MODEL" bash -c 'kubectl --kubeconfig "$1" -n "$2" logs job/t133-amd | grep -qx "amd Qwen/Qwen3-0.6B"' _ "$KCFG" "$NS"

# preferVendor amd, AMD busy: NVIDIA (soft); the controller reads the AcceleratorDomain view, refreshed every 30 s
check "the domain view shows the AMD GPU in use (within 90 s)" wait_for "amd in use" 90 5 in_use_is "$amd_dom" 1
aijob t133-soft amd | kc apply -f - >/dev/null
check "t133-soft (prefers AMD, AMD busy): Running within 3 min" wait_for "t133-soft running" 180 5 phase_is t133-soft Running
info "t133-soft: $(st t133-soft message)"
check "t133-soft: vendor nvidia, domain $nv_dom (a soft preference)" bash -c '[ "$1" = "nvidia [\"$2\"]" ]' _ "$(st t133-soft vendor) $(st t133-soft domains)" "$nv_dom"
check "its Job asks for nvidia.com/gpu: 1 with runtime class nvidia" bash -c '[ "$1" = "1 nvidia" ]' _ \
  "$(kc -n "$NS" get job t133-soft -o jsonpath='{.spec.template.spec.containers[0].resources.limits.nvidia\.com/gpu} {.spec.template.spec.runtimeClassName}')"

# no vendor at all, once both are free again
kc -n "$NS" delete aijob t133-amd t133-soft --wait=true >/dev/null 2>&1
check "deleting an AIJob deletes its Job" wait_for "jobs gone" 120 5 bash -c '[ -z "$(kubectl --kubeconfig "$1" -n "$2" get job t133-amd t133-soft -o name 2>/dev/null)" ]' _ "$KCFG" "$NS"
wait_for "both GPUs free in the view" 120 5 both_free >/dev/null 2>&1
aijob t133-any | kc apply -f - >/dev/null
check "t133-any (no vendor): Running within 3 min" wait_for "t133-any running" 180 5 phase_is t133-any Running
info "t133-any: $(kc -n "$NS" get aijob t133-any --no-headers 2>&1); $(st t133-any message)"
check "t133-any: a vendor, its domain, crossVendor false" bash -c '[[ "$1" =~ ^(nvidia|amd)\ \[\"[^\"]+\"\]\ false$ ]]' _ "$(st t133-any vendor) $(st t133-any domains) $(st t133-any crossVendor)"

# a plain GPU pod (no AIJob), on the vendor t133-any left free, is not touched by the controller
pv=amd; po=""; [ "$(st t133-any vendor)" = amd ] && { pv=nvidia; po='"runtimeClassName":"nvidia",'; }
kc -n "$NS" run t133-plain --restart=Never --image="$BUSYBOX_IMAGE" --overrides='{"spec":{'"$po"'"schedulerName":"runai-scheduler","containers":[{"name":"p","image":"'"$BUSYBOX_IMAGE"'","command":["sleep","60"],"resources":{"limits":{"'"$pv"'.com/gpu":"1"}}}]}}' >/dev/null 2>&1
check "a plain $pv GPU pod still runs (within 3 min)" wait_for "plain pod" 180 5 pod_running t133-plain
check "and carries no AIJob label" test -z "$(kc -n "$NS" get pod t133-plain -o jsonpath='{.metadata.labels.oif\.ai/aijob}')"
info "oif-aijob log: $(kc -n oif-aijob logs deploy/oif-aijob 2>/dev/null | tail -1 | cut -c1-200)"

echo "T-133: $((N - FAILS))/$N checks passed"
[ "$FAILS" = 0 ]
