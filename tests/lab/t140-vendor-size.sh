#!/bin/bash
# Acceptance test for T-140 (GPU vendor and size as one choice), run on the first node after  sudo ./oif install  on
# several nodes with both GPU vendors. Submits trainings to team-c through the Run:ai API the way the patched form
# does (vendor = node pool; whole AMD GPUs as amd.com/gpu), one at a time so each has its GPU, and deletes them.
# Sets team-c's quota to 1 GPU in pool nvidia and 1 in pool amd (as T-123 does); otherwise read-only.
#   sudo tests/lab/t140-vendor-size.sh            presets, labels, placements, the refusal, the patched UI
#   sudo tests/lab/t140-vendor-size.sh --dynamo   also the half-GPU Dynamo sample on NVIDIA (pulls ~20 GB if not cached)
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
multi_node || { echo "T-140 needs a multi-node install with both GPU vendors"; exit 2; }

FAILS=0; N=0
check() { N=$((N + 1)); if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi; }
info() { echo "  INFO  $*"; }
NS=$(runai_api project-pools team-c nvidia=1 amd=1)
RUNAI_URL="https://$(runai_domain)"
export RUNAI_URL RUNAI_CA="$PKI/ca.crt" BUSYBOX="$BUSYBOX_IMAGE" NS
RUNAI_USER=$(kc -n runai-backend get configmap runai-backend-tenants-manager -o jsonpath='{.data.ADMIN_USERNAME}')
RUNAI_PASSWORD=$(kc -n runai-backend get secret runai-backend-gen-tenants-manager -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d)
export RUNAI_USER RUNAI_PASSWORD
api() { PYTHONPATH="$OIF_HOME/installer/tools" python3 "$ROOT/tests/lab/t140-submit.py" "$@"; }
trap 'api cleanup >/dev/null 2>&1' EXIT
api cleanup >/dev/null 2>&1

echo "T-140 GPU vendor and size (project team-c: 1 GPU in nvidia, 1 in amd)"
presets=$(api presets)
check "compute presets for both vendors and every size (8)" bash -c '[ "$(wc -w <<< "$1")" = 8 ]' _ "$presets"
info "presets: $presets"
mib=$(kc get node gpu-amd -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.memory}' 2>/dev/null)
check "gpu-amd carries its GPU memory for KAI (nvidia.com/gpu.memory, oif's)" \
  bash -c '[ "$1" -gt 40000 ] && [ "$2" = set ]' _ "${mib:-0}" "$(kc get node gpu-amd -o jsonpath='{.metadata.labels.oif\.ai/gpu-memory-label}')"
check "the NVIDIA node keeps its own GPU memory label (not oif's)" \
  bash -c '[ -n "$1" ] && [ -z "$2" ]' _ "$(kc get node gpu-nvidia -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.memory}')" \
  "$(kc get node gpu-nvidia -o jsonpath='{.metadata.labels.oif\.ai/gpu-memory-label}')"

# name compute-json pool expected-node expected-allocated-gpus ("-": by memory, the share is printed)
while read -r name compute pools node gpus; do
  out=$(api run "$name" "$compute" "$pools")
  sed 's/^/        /' <<< "$out"
  if [ "$gpus" = - ]; then check "$name: runs on $node" grep -q "phase=Running node=$node " <<< "$out"
  else check "$name: runs on $node, $gpus GPU" grep -q "phase=Running node=$node gpus=$gpus " <<< "$out"; fi
done <<'CASES'
t140-nvidia-1 {"gpuDevicesRequest":1} nvidia gpu-nvidia 1
t140-nvidia-quarter {"gpuDevicesRequest":1,"gpuRequestType":"portion","gpuPortionRequest":0.25} nvidia gpu-nvidia 0.25
t140-amd-1 {"gpuDevicesRequest":0,"extendedResources":[{"resource":"amd.com/gpu","quantity":"1"}]} amd gpu-amd 1
t140-amd-half {"gpuDevicesRequest":1,"gpuRequestType":"portion","gpuPortionRequest":0.5} amd gpu-amd 0.5
t140-amd-12g {"gpuDevicesRequest":1,"gpuRequestType":"memory","gpuMemoryRequest":"12G"} amd gpu-amd -
CASES

out=$(api refused t140-amd-devices '{"gpuDevicesRequest":1}' amd)
sed 's/^/        /' <<< "$out"
check "GPU devices in pool amd: no pod, refused with the vendor hint" grep -q "refused=yes" <<< "$out"

pod=$(kc -n runai-backend get pods -l app=runai-backend-frontend -o name 2>/dev/null | head -1)
[ -n "$pod" ] || pod=$(kc -n runai-backend get pods -o name | grep frontend | head -1)
check "the Run:ai UI serves the GPU vendor choice (patch 0005)" \
  bash -c 'kubectl --kubeconfig "$1" -n runai-backend exec "$2" -- sh -c "grep -rl oif-gpu-vendor /usr/share/nginx/html/assets | head -1" | grep -q .' _ "$KCFG" "$pod"

if [ "${1:-}" = --dynamo ]; then
  kc -n "$NS" delete dynamographdeployment qwen-nvidia-half-gpu --ignore-not-found --wait=true >/dev/null 2>&1
  kc -n "$NS" apply -f "$ROOT/platform/dynamo/samples/nvidia-half-gpu.yaml" >/dev/null
  w=""
  for _ in $(seq 1 80); do
    w=$(kc -n "$NS" get pods -l nvidia.com/dynamo-component-type=worker -o jsonpath='{range .items[*]}{.status.phase} {.metadata.annotations.runai-allocated-gpus}{"\n"}{end}' 2>/dev/null | head -1)
    [[ $w == "Running 0.5"* ]] && break; sleep 15
  done
  check "Dynamo half-GPU sample: worker Running on 0.5 GPU" grep -q "^Running 0.5" <<< "$w"
  kc -n "$NS" delete dynamographdeployment qwen-nvidia-half-gpu --ignore-not-found --wait=false >/dev/null 2>&1
fi
echo "T-140: $((N - FAILS))/$N checks passed"
[ "$FAILS" = 0 ]
