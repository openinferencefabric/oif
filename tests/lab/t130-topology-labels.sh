#!/bin/bash
# T-130 lab check: agent oif-topology labels each GPU node with its accelerator domain, fabric and scale-out zone; a
# node annotation overrides the domain (a Helios rack's UALink domain) and removing it restores the detected one; the
# agent may change only its own node and only those labels. The lab's GPUs are one PCIe GPU per node, so each GPU node
# is its own domain (multi-GPU and rack shapes: images/oif-topology unit tests and tests/lab/s9-fake-topology.sh).
# Changes while it runs: two annotations on one GPU node (removed at the end, also on Ctrl+C).
#   sudo tests/lab/t130-topology-labels.sh
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
lbl() { kc get node "$1" -o jsonpath="{.metadata.labels.oif\.ai/$2}"; }
AGENT=system:serviceaccount:oif-topology:oif-topology

# real nodes with a GPU, and without
GPU_NODES=$(kc get nodes -l 'type notin (kwok)' -o jsonpath='{range .items[*]}{.metadata.name} {.status.allocatable.nvidia\.com/gpu}{.status.allocatable.amd\.com/gpu}{"\n"}{end}' | awk '$2 != "" && $2 != "0" {print $1}')
OTHER_NODES=$(kc get nodes -l 'type notin (kwok)' -o jsonpath='{range .items[*]}{.metadata.name} {.status.allocatable.nvidia\.com/gpu}{.status.allocatable.amd\.com/gpu}{"\n"}{end}' | awk '$2 == "" || $2 == "0" {print $1}')
T=$(head -1 <<< "$GPU_NODES")   # the node the override is tried on
cleanup() { [ -n "$T" ] && kc annotate node "$T" oif.ai/accelerator-domain- oif.ai/accelerator-fabric- >/dev/null 2>&1; }
trap cleanup EXIT

echo "T-130 accelerator domains as node labels (agent oif-topology)"
check "agent running on every real node" bash -c '[ "$1" -gt 0 ] && [ "$1" = "$2" ]' _ \
  "$(kc -n oif-topology get ds oif-topology -o jsonpath='{.status.desiredNumberScheduled}')" \
  "$(kc -n oif-topology get ds oif-topology -o jsonpath='{.status.numberReady}')"
check "the lab has GPU nodes ($(paste -sd' ' <<< "$GPU_NODES"))" test -n "$GPU_NODES"
for n in $GPU_NODES; do
  info "$n: domain $(lbl "$n" accelerator-domain), fabric $(lbl "$n" accelerator-fabric), zone $(lbl "$n" scaleout-zone)"
  check "$n: its own domain over PCIe (one GPU), zone default" \
    bash -c '[ "$1" = "$2" ] && [ "$3" = pcie ] && [ "$4" = default ]' _ "$(lbl "$n" accelerator-domain)" "$n" \
    "$(lbl "$n" accelerator-fabric)" "$(lbl "$n" scaleout-zone)"
done
check "nodes without GPUs carry no domain ($(paste -sd' ' <<< "$OTHER_NODES"))" \
  bash -c 'for n in $1; do [ -z "$(kubectl --kubeconfig "$2" get node "$n" -o jsonpath="{.metadata.labels.oif\.ai/accelerator-domain}")" ] || exit 1; done' _ "$OTHER_NODES" "$KCFG"

# the administrator names a domain no driver reports (a Helios rack); the agent follows within its interval
kc annotate node "$T" oif.ai/accelerator-domain=t130-rack oif.ai/accelerator-fabric=ualoe --overwrite >/dev/null
check "annotation on $T: domain t130-rack, fabric ualoe (within 2 min)" \
  wait_for "override" 120 5 bash -c '[ "$(kubectl --kubeconfig "$1" get node "$2" -o jsonpath="{.metadata.labels.oif\.ai/accelerator-domain} {.metadata.labels.oif\.ai/accelerator-fabric}")" = "t130-rack ualoe" ]' _ "$KCFG" "$T"
kc annotate node "$T" oif.ai/accelerator-domain- oif.ai/accelerator-fabric- >/dev/null
check "annotation removed: $T is its own domain again (within 2 min)" \
  wait_for "restore" 120 5 bash -c '[ "$(kubectl --kubeconfig "$1" get node "$2" -o jsonpath="{.metadata.labels.oif\.ai/accelerator-domain} {.metadata.labels.oif\.ai/accelerator-fabric}")" = "$2 pcie" ]' _ "$KCFG" "$T"

# policy oif-topology-own-node, tried as the agent (impersonated, with the node its token would name)
O=$(printf '%s\n%s\n' "$GPU_NODES" "$OTHER_NODES" | grep -vx "$T" | grep . | head -1)   # another real node
check "the agent may set its labels on its own node" \
  kc label node "$T" oif.ai/scaleout-zone=default --overwrite --as="$AGENT" --as-user-extra="authentication.kubernetes.io/node-name=$T"
check "another real node to try: $O" kc get node "$O"
check "the agent may not change another node ($O)" \
  bash -c '! kubectl --kubeconfig "$1" label node "$2" oif.ai/scaleout-zone=t130 --overwrite --as="$3" --as-user-extra="authentication.kubernetes.io/node-name=$4"' _ "$KCFG" "$O" "$AGENT" "$T"
check "the agent may not change other labels of its node" \
  bash -c '! kubectl --kubeconfig "$1" label node "$2" oif.ai/gpu-vendor=t130 --overwrite --as="$3" --as-user-extra="authentication.kubernetes.io/node-name=$2"' _ "$KCFG" "$T" "$AGENT"
check "the agent may not taint its node" \
  bash -c '! kubectl --kubeconfig "$1" taint node "$2" t130=x:NoSchedule --as="$3" --as-user-extra="authentication.kubernetes.io/node-name=$2"' _ "$KCFG" "$T" "$AGENT"
info "agent log on $T: $(kc -n oif-topology logs "$(kc -n oif-topology get pods -o wide --no-headers | awk -v n="$T" '$7 == n {print $1}')" 2>/dev/null | tail -1 | cut -c1-200)"

echo "T-130: $((N - FAILS))/$N checks passed"
[ "$FAILS" = 0 ]
