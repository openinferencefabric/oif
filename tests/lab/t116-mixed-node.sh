#!/bin/bash
# T-116 lab check on a node with both GPU vendors (T-901, single node): KAI patch 0006 places a pod's whole GPUs of one
# vendor only where that vendor has them free. With the node's NVIDIA GPU taken, a second NVIDIA pod waits (never sent
# to the node because the AMD GPU is free), with 0006's reason; the same for AMD; a pod of the free vendor still runs.
# Project team-a (quota 1) holds a GPU, team-c (quota 2, capped at 1 NVIDIA + 1 AMD) asks for one.
# Changes while it runs: test pods in team-a's and team-c's namespaces (deleted at the end, also on Ctrl+C).
#   sudo tests/lab/t116-mixed-node.sh
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
multi_node && { echo "T-116's lab check needs a single node with both GPU vendors (several nodes: one vendor per pool, T-129)"; exit 2; }

FAILS=0; N=0
check() { N=$((N + 1)); if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi; }
info() { echo "  INFO  $*"; }
NODE=$(node_with nvidia.com/gpu)
[ -n "$NODE" ] && [ "$NODE" = "$(node_with amd.com/gpu)" ] || { echo "  FAIL  no node with both an NVIDIA and an AMD GPU"; exit 1; }
A=$(runai_project team-a 1) || { echo "  FAIL  project team-a: $A"; exit 1; }
C=$(runai_api project team-c 2 2) || { echo "  FAIL  project team-c: $C"; exit 1; }
export BUSYBOX_IMAGE CUDA_SAMPLE_IMAGE
pod() {   # namespace name vendor: a pod with one whole GPU of that vendor, for Run:ai's scheduler
  local t=quota-test.yaml n=gpu-quota-test; [ "$3" = amd ] && t=quota-test-amd.yaml n=amd-quota-test
  NS=$1 NODE_POOL=default render "$OIF_HOME/platform/runai/$t" | sed "s/name: $n\$/name: $2/" | kc apply -f - >/dev/null; }
phase() { kc -n "$1" get pod "$2" -o jsonpath='{.status.phase}' 2>/dev/null; }
running() { [ "$(phase "$1" "$2")" = Running ]; }
reason() { kc -n "$1" get events --field-selector involvedObject.name="$2" -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null; }
refused() {   # namespace pod resource: Pending, on no node, with 0006's reason for that resource
  [ "$(phase "$1" "$2")" = Pending ] && [ -z "$(kc -n "$1" get pod "$2" -o jsonpath='{.spec.nodeName}')" ] \
    && reason "$1" "$2" | grep -q "free $3 of the 1 requested; its other free GPUs are another vendor's"; }
gone() { kc -n "$1" delete pod "${@:2}" --ignore-not-found --wait=true >/dev/null 2>&1; }
cleanup() { gone "$A" t116-hold-nv t116-hold-amd; gone "$C" t116-nv t116-amd t116-nv-ok; }
trap cleanup EXIT

echo "T-116 one vendor's GPUs on a mixed node ($NODE), KAI patch 0006"
info "scheduler image: $(kc -n runai get deploy -o jsonpath='{range .items[*]}{.metadata.name}={.spec.template.spec.containers[0].image}{"\n"}{end}' | grep '^runai-scheduler' | cut -d= -f2 | sort -u | paste -sd' ')"
cleanup

# NVIDIA taken: a second NVIDIA pod must wait, although the AMD GPU is free
pod "$A" t116-hold-nv nvidia
check "team-a holds the NVIDIA GPU (within 3 min)" wait_for "hold nvidia" 180 5 running "$A" t116-hold-nv
pod "$C" t116-nv nvidia
check "a second NVIDIA pod waits on no node, 0006's reason (within 2 min)" wait_for "nv refused" 120 5 refused "$C" t116-nv nvidia.com/gpu
info "t116-nv: $(reason "$C" t116-nv | grep -o "node $NODE has.*vendor's" | tail -1)"
gone "$C" t116-nv; gone "$A" t116-hold-nv

# AMD taken: a second AMD pod must wait, although the NVIDIA GPU is free; an NVIDIA pod still runs
pod "$A" t116-hold-amd amd
check "team-a holds the AMD GPU (within 3 min)" wait_for "hold amd" 180 5 running "$A" t116-hold-amd
pod "$C" t116-amd amd
check "a second AMD pod waits on no node, 0006's reason (within 2 min)" wait_for "amd refused" 120 5 refused "$C" t116-amd amd.com/gpu
info "t116-amd: $(reason "$C" t116-amd | grep -o "node $NODE has.*vendor's" | tail -1)"
gone "$C" t116-amd
pod "$C" t116-nv-ok nvidia
check "an NVIDIA pod runs while the AMD GPU is taken (within 3 min)" wait_for "nv ok" 180 5 running "$C" t116-nv-ok

echo "T-116: $((N - FAILS))/$N checks passed"
[ "$FAILS" = 0 ]
