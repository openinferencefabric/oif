#!/bin/bash
# T-139 hard VRAM cap for AMD fractions: which nodes get fractiond (label oif.ai/amd-vram-cap=dmem), which keep a soft
# share, AMD_VRAM_CAP=none, what reruns the stage, and the setting's check. kubectl and the node check are stubbed;
# the calls are recorded.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
OIF_HOME=$ROOT
# the stage file places itself after runai-amd-templates (70-gpu-amd.sh), so that stage must be registered first
for f in "$ROOT"/installer/stages/70-gpu-amd.sh "$ROOT"/installer/stages/75-amd-fractions.sh; do
  # shellcheck source=/dev/null
  . "$f" || { echo "      FAIL: cannot load $f"; exit 1; }
done
CALLS=$SANDBOX/calls
CAPABLE=" amd-1 "        # nodes whose kernel lists an amdgpu VRAM region in dmem.capacity
LABELLED=""              # nodes carrying oif.ai/amd-vram-cap before the stage
kc() {
  echo "kubectl $*" >> "$CALLS"
  case "$*" in
    *"get nodes -l oif.ai/amd-vram-cap -o name"*) for n in $LABELLED; do echo "node/$n"; done ;;
    *"apply -f -"*) cat > /dev/null ;;   # read the manifest as kubectl does (else render gets a broken pipe)
  esac
  return 0
}
amd_node_run() { case "$2" in grep*) [[ $CAPABLE == *" $1 "* ]] ;; uname*) echo 6.8.0-test ;; esac; }
export FRACTIOND_IMAGE=oif.local/oif/oif-fractiond:x
cap() { rm -f "$CALLS"; VRAM_CAP_MSG=""; amd_vram_cap "$1" > "$SANDBOX/out" 2>&1; }

ok_ v_vram_cap ""
ok_ v_vram_cap dmem
ok_ v_vram_cap none
no_ v_vram_cap soft

AMD_VRAM_CAP=""; cap "amd-1 amd-2"
grep -q "kubectl label node amd-1 oif.ai/amd-vram-cap=dmem --overwrite" "$CALLS" || fail "capable node labelled"
grep -q "kubectl label node amd-2 oif.ai/amd-vram-cap=dmem" "$CALLS" && fail "node without dmem left unlabelled"
grep -q "kubectl apply -f -" "$CALLS" || fail "fractiond DaemonSet applied"
grep -q "rollout status ds/oif-fractiond" "$CALLS" || fail "waits for fractiond"
eq "$VRAM_CAP_MSG" "memory isolation is hard on amd-1, soft on amd-2" "message:"
grep -q "amd-2 (kernel 6.8.0-test): no amdgpu VRAM region" "$SANDBOX/out" || fail "warns about the node that keeps a soft share"

LABELLED="amd-1 amd-3"; cap "amd-1"   # amd-3 lost its AMD-only GPUs or its dmem support: label removed
grep -q "kubectl label node amd-3 oif.ai/amd-vram-cap-" "$CALLS" || fail "stale label removed"
grep -q "kubectl label node amd-1 oif.ai/amd-vram-cap-" "$CALLS" && fail "a node that stays capable keeps its label"
[ "$(grep -n 'amd-vram-cap=dmem' "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n 'amd-vram-cap-' "$CALLS" | head -1 | cut -d: -f1)" ] \
  || fail "capable nodes labelled before stale labels are removed"

LABELLED=""; CAPABLE=" "; cap "amd-1"
grep -q "kubectl apply" "$CALLS" && fail "no capable node: no DaemonSet"
grep -q "kubectl -n oif-system delete daemonset oif-fractiond" "$CALLS" || fail "no capable node: DaemonSet removed"
eq "$VRAM_CAP_MSG" "memory isolation is soft (no node's kernel caps VRAM)" "message:"

CAPABLE=" amd-1 "; LABELLED="amd-1"; AMD_VRAM_CAP=none; cap "amd-1"
grep -q "kubectl -n oif-system delete daemonset oif-fractiond" "$CALLS" || fail "AMD_VRAM_CAP=none: DaemonSet removed"
grep -q "kubectl label node amd-1 oif.ai/amd-vram-cap-" "$CALLS" || fail "AMD_VRAM_CAP=none: label removed"
grep -q "kubectl apply" "$CALLS" && fail "AMD_VRAM_CAP=none: nothing applied"
eq "$VRAM_CAP_MSG" "memory isolation is soft (AMD_VRAM_CAP=none)" "message:"

AMD_VRAM_CAP=""; a=$(amd_fractions_rev); AMD_VRAM_CAP=none; b=$(amd_fractions_rev)
GPU_FRACTIONING_REF=0000000000000000000000000000000000000000; c=$(amd_fractions_rev)
[ "$a" != "$b" ] || fail "changing AMD_VRAM_CAP reruns the stage"
[ "$b" != "$c" ] || fail "a new gpu-fractioning commit rebuilds the images"

# T-140: the GPU memory label of the first version is removed, only where oif set it (marked)
MARKED=""
kc() {
  echo "kubectl $*" >> "$CALLS"
  case "$*" in *"get nodes -l oif.ai/gpu-memory-label -o name"*) for n in $MARKED; do echo "node/$n"; done ;; esac
  return 0
}
rm -f "$CALLS"; MARKED="amd-1"; amd_gpu_memory_unlabel "" > /dev/null
grep -q "kubectl label node amd-1 nvidia.com/gpu.memory- oif.ai/gpu-memory-label-" "$CALLS" || fail "fractions off: label removed"

out=$(render "$ROOT/platform/gpu-amd/amd-vram-cap.yaml")
grep -q "image: $FRACTIOND_IMAGE" <<< "$out" || fail "DaemonSet runs the built fractiond image"
grep -q -- "--gpu-vendor=amd" <<< "$out" || fail "fractiond runs the AMD backend"
grep -q "nodeSelector: {oif.ai/amd-vram-cap: dmem}" <<< "$out" || fail "fractiond only on capable nodes"
grep -q -- "--fail-open" <<< "$out" && fail "fractiond fails closed"
finish
