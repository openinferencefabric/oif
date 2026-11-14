#!/bin/bash
# T-141 (ADR-032 amendment 2026-11-14): which KAI a cluster gets. Stock KAI without AMD GPUs or with AMD_FRACTIONS=none;
# the patched KAI wherever a node has an AMD GPU, also a node with both vendors (patch 0006, T-116); AMD fractions
# (oif-amd-share, fractiond) only with a node whose GPUs are all AMD. kubectl and the image build are stubbed.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
OIF_HOME=$ROOT
for f in "$ROOT"/installer/stages/70-gpu-amd.sh "$ROOT"/installer/stages/75-amd-fractions.sh; do
  # shellcheck source=/dev/null
  . "$f" || { echo "      FAIL: cannot load $f"; exit 1; }
done
CALLS=$SANDBOX/calls; NODES=""
node() { echo "{\"metadata\": {\"name\": \"$1\"}, \"status\": {\"allocatable\": {\"amd.com/gpu\": \"$2\", \"nvidia.com/gpu\": \"$3\"}}}"; }
cluster() {   # name:amd:nvidia ...: the nodes kubectl lists
  local n a v items=(); for x in "$@"; do IFS=: read -r n a v <<< "$x"; items+=("$(node "$n" "$a" "$v")"); done
  NODES="{\"items\": [$(IFS=,; echo "${items[*]}")]}"; }
kc() {
  echo "kubectl $*" >> "$CALLS"
  case "$*" in
    "get nodes -o json") echo "$NODES" ;;
    *"get deploy -o name"*) echo deployment.apps/binder; echo deployment.apps/runai-scheduler-default ;;
    *"get deploy binder -o jsonpath"*) echo binder ;;
    *"apply -f -"*) cat > /dev/null ;;
  esac
  return 0
}
# the build, the image spread and the waits are not what this test is about
amd_fractions_build() { echo "build $1" >> "$CALLS"; }
runai_patch_spread() { echo "spread $1" >> "$CALLS"; }
wait_for() { return 0; }
pool_for() { echo "$1"; }
amd_vram_cap() { echo "vram-cap $1" >> "$CALLS"; VRAM_CAP_MSG="cap"; }
run() { rm -f "$CALLS"; touch "$CALLS"; ( stage_amd_fractions ) > "$SANDBOX/out" 2>&1; }   # a subshell: die exits

AMD_FRACTIONS=""
cluster cp1:0:0 nv:0:1;            eq "$(kai_patch_plan)" stock "NVIDIA only:"
cluster cp1:0:0 mixed:1:1;         eq "$(kai_patch_plan)" kai "AMD GPUs only on a node with NVIDIA GPUs too:"
cluster cp1:0:0 nv:0:1 amd:1:0;    eq "$(kai_patch_plan)" kai+share "a node with AMD GPUs only:"
cluster cp1:0:0 mixed:1:1 amd:1:0; eq "$(kai_patch_plan)" kai+share "mixed and AMD-only nodes:"
AMD_FRACTIONS=none;                eq "$(kai_patch_plan)" stock "AMD_FRACTIONS=none:"
AMD_FRACTIONS=""
NODES="";                          no_ kai_patch_plan
eq "$(kai_patch_plan)" unknown "nodes not listed: unknown, never stock:"
run; grep -q "cannot list the nodes" "$SANDBOX/out" || fail "nodes not listed: the stage stops"
grep -q "op.:.remove" "$CALLS" && fail "nodes not listed: patched images left alone"

cluster cp1:0:0 nv:0:1 amd:1:0; a=$(amd_fractions_rev); cluster cp1:0:0 mixed:1:1; b=$(amd_fractions_rev)
[ "$a" != "$b" ] || fail "the stage reruns when the plan changes (kai+share -> kai)"

cluster cp1:0:0 nv:0:1; run
grep -q "op.:.remove.,.path.:./spec/runai-scheduler/image" "$CALLS" || fail "NVIDIA only: KAI's stock images back"
grep -q "^build" "$CALLS" && fail "NVIDIA only: nothing built"
grep -q "no AMD GPU in the cluster: KAI's stock images" "$SANDBOX/out" || fail "NVIDIA only: message"

cluster cp1:0:0 mixed:1:1; run
grep -q "^build " "$CALLS" || fail "mixed node: patched KAI built"
grep -q "patch runaiconfig runai --type merge" "$CALLS" || fail "mixed node: RunaiConfig points at the patched images"
grep -q "op.:.remove.,.path.:./spec/runai-scheduler/image" "$CALLS" && fail "mixed node: patched images kept"
grep -q "delete namespace oif-system" "$CALLS" || fail "mixed node: no AMD sharing plugin"
grep -q "^vram-cap" "$CALLS" && fail "mixed node: no VRAM cap"
grep -q "whole GPUs, one vendor per pod (patch 0006)" "$SANDBOX/out" || fail "mixed node: message"

cluster cp1:0:0 nv:0:1 amd:1:0; run
grep -q "^vram-cap amd" "$CALLS" || fail "AMD-only node: fractions with the VRAM cap there"
grep -q "delete namespace oif-system" "$CALLS" && fail "AMD-only node: the sharing plugin stays"
grep -q "AMD GPUs on amd can be shared" "$SANDBOX/out" || fail "AMD-only node: message"
finish
