#!/bin/bash
# T-131 lab check: the AcceleratorDomain view (Deployment oif-domains, CRD acceleratordomains.oif.ai). One object per
# accelerator domain of the GPU nodes, with the right vendor, nodes and GPUs; its in-use count follows a GPU pod; it is
# kept, not re-created; nodes without GPUs have none. The lab's GPU nodes are one PCIe GPU each, so each is its own
# domain (multi-node and mixed domains: images/oif-topology unit tests).
# Changes while it runs: one test pod on the NVIDIA GPU node (namespace oif-t131, deleted at the end, also on Ctrl+C).
#   sudo tests/lab/t131-domains.sh
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
dom() { kc get acceleratordomain "$1" -o jsonpath="{$2}" 2>/dev/null; }   # object field
in_use_is() { [ "$(dom "$1" .status.inUseGPUs)" = "$2" ]; }
cleanup() { kc delete namespace oif-t131 --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup EXIT

GPU_NODES=$(kc get nodes -l 'type notin (kwok)' -o jsonpath='{range .items[*]}{.metadata.name} {.status.allocatable.nvidia\.com/gpu}{.status.allocatable.amd\.com/gpu}{"\n"}{end}' | awk '$2 != "" && $2 != "0" {print $1}')

echo "T-131 AcceleratorDomain view (oif-domains)"
check "oif-domains running" bash -c '[ "$(kubectl --kubeconfig "$1" -n oif-topology get deploy oif-domains -o jsonpath="{.status.readyReplicas}")" = 1 ]' _ "$KCFG"
check "kubectl get acceleratordomains works" kc get acceleratordomains
kc get acceleratordomains 2>&1 | sed 's/^/        /'
for n in $GPU_NODES; do
  d=$(kc get node "$n" -o jsonpath='{.metadata.labels.oif\.ai/accelerator-domain}')
  if [ -n "$(kc get node "$n" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')" ]; then v=nvidia; a=$(kc get node "$n" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
  else v=amd; a=$(kc get node "$n" -o jsonpath='{.status.allocatable.amd\.com/gpu}'); fi
  check "$n: object $d exists" kc get acceleratordomain "$d"
  check "$n: vendor $v, nodes [$n], $a GPU allocatable, Ready" \
    bash -c '[ "$1" = "$2 [\"$3\"] $4 True" ]' _ \
    "$(dom "$d" .status.vendor) $(dom "$d" .status.nodes) $(dom "$d" .status.allocatableGPUs) $(dom "$d" '.status.conditions[?(@.type=="Ready")].status')" "$v" "$n" "$a"
done
check "one object per domain, none for nodes without GPUs" bash -c '[ "$1" = "$2" ]' _ \
  "$(kc get nodes -l oif.ai/accelerator-domain -o jsonpath='{range .items[*]}{.metadata.labels.oif\.ai/accelerator-domain}{"\n"}{end}' | sort -u | wc -l)" \
  "$(kc get acceleratordomains --no-headers | wc -l)"

# in use follows a GPU pod (the controller looks every 30 s)
nv_node=$(node_with nvidia.com/gpu); D=$(kc get node "$nv_node" -o jsonpath='{.metadata.labels.oif\.ai/accelerator-domain}')
created=$(dom "$D" .metadata.creationTimestamp)
check "$D: nothing in use before the test" in_use_is "$D" 0
kc create namespace oif-t131 >/dev/null
kc -n oif-t131 run gpu --restart=Never --image="$CUDA_SAMPLE_IMAGE" --overrides='{"spec":{"runtimeClassName":"nvidia","nodeSelector":{"kubernetes.io/hostname":"'"$nv_node"'"},"containers":[{"name":"gpu","image":"'"$CUDA_SAMPLE_IMAGE"'","command":["sleep","600"],"resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}' >/dev/null
check "a GPU pod runs on $nv_node" wait_for "pod running" 180 5 bash -c '[ "$(kubectl --kubeconfig "$1" -n oif-t131 get pod gpu -o jsonpath="{.status.phase}")" = Running ]' _ "$KCFG"
check "$D: 1 GPU in use (within 90 s)" wait_for "in use 1" 90 5 in_use_is "$D" 1
kc -n oif-t131 delete pod gpu --wait=true >/dev/null 2>&1
check "$D: 0 in use again after the pod is gone (within 90 s)" wait_for "in use 0" 90 5 in_use_is "$D" 0
check "$D: the same object throughout (kept, not re-created)" bash -c '[ -n "$1" ] && [ "$1" = "$2" ]' _ "$created" "$(dom "$D" .metadata.creationTimestamp)"
info "oif-domains log: $(kc -n oif-topology logs deploy/oif-domains 2>/dev/null | tail -1 | cut -c1-200)"

echo "T-131: $((N - FAILS))/$N checks passed"
[ "$FAILS" = 0 ]
