#!/bin/bash
# T-130 stage topology: the agent is built and deployed when the cluster has GPUs, removed (with its labels) otherwise;
# what reruns it; the manifest keeps the agent off simulated nodes and limits it to its own node and its three labels.
# kubectl and the build are stubbed; the calls are recorded. The labelling rules are tested in Go
# (images/oif-topology/topology_test.go, run by the image build).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
OIF_HOME=$ROOT
for f in "$ROOT"/installer/stages/60-runai.sh "$ROOT"/installer/stages/61-vendor-pool.sh "$ROOT"/installer/stages/62-topology.sh; do
  # shellcheck source=/dev/null
  . "$f" || { echo "      FAIL: cannot load $f"; exit 1; }
done
CALLS=$SANDBOX/calls
UNLABELLED=""
kc() {
  echo "kubectl $*" >> "$CALLS"
  case "$*" in
    *"apply -f -"*) cat > /dev/null ;;
    "get nodes -l type notin (kwok) -o jsonpath="*) printf 'cp1  \ngpu-nvidia 1 gpu-nvidia\ngpu-amd 1 %s\n' "$UNLABELLED" ;;
  esac
  return 0
}
go_image_build() { echo "build $1 $3" >> "$CALLS"; }
runai_patch_spread() { echo "spread $1 $2" >> "$CALLS"; }
wait_for() { shift 3; "$@"; }
NV=1; AMD=1
gpu_count() { [ "$1" = nvidia ] && echo "$NV" || echo "$AMD"; }
run() { rm -f "$CALLS"; ( stage_topology ) > "$SANDBOX/out" 2>&1; }

UNLABELLED=gpu-amd; run
grep -q "^build oif-topology oif.local/oif/oif-topology:" "$CALLS" || fail "GPUs: agent image built"
grep -q "^spread oif-topology " "$CALLS" || fail "image copied to the other nodes"
grep -q "kubectl apply -f $OIF_STATE/topology.yaml" "$CALLS" || fail "manifest applied"
grep -q "rollout status ds/oif-topology" "$CALLS" || fail "waits for the agent"
[ "$(topology_unlabelled)" = "" ] || fail "a labelled GPU node is not reported"
UNLABELLED=""
[ "$(topology_unlabelled)" = gpu-amd ] || fail "a GPU node without a domain is reported, a node without GPUs is not"

NV=0; AMD=0; run
grep -q "^build" "$CALLS" && fail "no GPUs: nothing built"
grep -q "kubectl delete validatingadmissionpolicy oif-topology-own-node" "$CALLS" || fail "no GPUs: policy removed"
grep -q "kubectl label nodes -l type notin (kwok) oif.ai/accelerator-domain- oif.ai/accelerator-fabric- oif.ai/scaleout-zone-" "$CALLS" \
  || fail "no GPUs: the agent's labels removed from real nodes"

a=$(topology_rev); echo "// x" >> "$SANDBOX/extra.go"
b=$(TOPOLOGY_SRC=$SANDBOX topology_rev 2>/dev/null)
[ "$a" != "$b" ] || fail "changing the agent's source reruns the stage"

out=$(TOPOLOGY_IMAGE=img:x SYSTEM_LABEL=node-role.kubernetes.io/runai-system render "$ROOT/platform/kubernetes/topology.yaml")
grep -q "matchExpressions: \[{key: type, operator: NotIn, values: \[kwok\]}\]" <<< "$out" || fail "the agent stays off simulated nodes"
grep -q "authentication.kubernetes.io/node-name" <<< "$out" || fail "the policy checks the agent's own node"
grep -q "variables.ours" <<< "$out" || fail "the policy limits the agent to its labels"
grep -q "object.spec == oldObject.spec" <<< "$out" || fail "the policy keeps taints and annotations"
grep -q "validationActions: \[Deny\]" <<< "$out" || fail "the policy denies"
grep -q "readOnly: true" <<< "$out" || fail "sysfs mounted read only"
grep -q "verbs: \[get, patch\]" <<< "$out" || fail "the agent may only read and patch nodes"
finish
