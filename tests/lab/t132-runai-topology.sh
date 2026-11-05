#!/bin/bash
# T-132 lab check: Run:ai network topology oif-accelerator (zone > accelerator domain > host) is linked to the GPU node
# pools and written as KAI Topology oif-accelerator; a workload submitted through Run:ai gets it with a preferred
# placement on one host, and a workload asking for one domain gets the required level; both run on their GPU node.
# Packing on multi-GPU domains: sudo S9_TOPOLOGY=oif-accelerator tests/lab/s9-fake-topology.sh (fake nodes).
# Sets team-c's quota to 1 GPU in pool nvidia and 1 in pool amd (as T-123 does); the trainings it submits are deleted.
#   sudo tests/lab/t132-runai-topology.sh
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
multi_node || { echo "T-132's lab check needs the multi-node install with both GPU vendors"; exit 2; }

FAILS=0; N=0
check() { N=$((N + 1)); if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi; }
info() { echo "  INFO  $*"; }
NS=$(runai_api project-pools team-c nvidia=1 amd=1)
RUNAI_URL="https://$(runai_domain)"
export RUNAI_URL RUNAI_CA="$PKI/ca.crt" BUSYBOX="$BUSYBOX_IMAGE" NS
RUNAI_USER=$(kc -n runai-backend get configmap runai-backend-tenants-manager -o jsonpath='{.data.ADMIN_USERNAME}')
RUNAI_PASSWORD=$(kc -n runai-backend get secret runai-backend-gen-tenants-manager -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d)
export RUNAI_USER RUNAI_PASSWORD
api() { PYTHONPATH="$OIF_HOME/installer/tools" python3 "$ROOT/tests/lab/t132-submit.py" "$@"; }
trap 'api cleanup >/dev/null 2>&1' EXIT
left=$(api cleanup 2>&1); [ -z "$left" ] || info "left from an earlier run: $(paste -sd' ' <<< "$left")"

echo "T-132 domain-aware packing through Run:ai (network topology $RUNAI_TOPOLOGY)"
tops=$(runai_api network-topologies)
sed 's/^/        /' <<< "$tops"
check "Run:ai: $RUNAI_TOPOLOGY Ready, levels zone > domain > host, node pools amd and nvidia" \
  grep -qE "^$RUNAI_TOPOLOGY .*phase=Ready levels=oif.ai/scaleout-zone,oif.ai/accelerator-domain,kubernetes.io/hostname pools=(amd,nvidia|nvidia,amd)$" <<< "$tops"
check "Run:ai: no topology left by spike S-9 (oif-s9)" bash -c '! grep -q "^oif-s9 " <<< "$1"' _ "$tops"
levels=$(kc get topologies.kai.scheduler "$RUNAI_TOPOLOGY" -o jsonpath='{.spec.levels[*].nodeLabel}')
check "KAI Topology $RUNAI_TOPOLOGY in the cluster ($levels)" \
  test "$levels" = "oif.ai/scaleout-zone oif.ai/accelerator-domain kubernetes.io/hostname"
check "every GPU node carries all three levels" bash -c '[ -z "$1" ]' _ \
  "$(kc get nodes -l 'type notin (kwok)' -o jsonpath='{range .items[*]}{.metadata.name} {.status.allocatable.nvidia\.com/gpu}{.status.allocatable.amd\.com/gpu} {.metadata.labels.oif\.ai/scaleout-zone} {.metadata.labels.oif\.ai/accelerator-domain}{"\n"}{end}' | awk '$2 != "" && $2 != "0" && NF < 4')"

# name compute pool node required-level ("-": none, Run:ai's preferred placement only)
while read -r name compute pool node req; do
  if [ "$req" = - ]; then out=$(api run "$name" "$pool" "$compute"); else out=$(api run "$name" "$pool" "$compute" "$req"); fi
  sed 's/^/        /' <<< "$out"
  check "$name: runs on $node" grep -q "phase=Running node=$node " <<< "$out"
  check "$name: KAI got topology $RUNAI_TOPOLOGY, preferred one host (set by Run:ai)" \
    grep -q "pg-topology=$RUNAI_TOPOLOGY pg-preferred=kubernetes.io/hostname " <<< "$out"
  [ "$req" = - ] || check "$name: KAI got the required level $req" grep -q "pg-required=$req$" <<< "$out"
done <<'CASES'
t132-nvidia {"gpuDevicesRequest":1} nvidia gpu-nvidia -
t132-amd-domain {"gpuDevicesRequest":0,"extendedResources":[{"resource":"amd.com/gpu","quantity":"1"}]} amd gpu-amd oif.ai/accelerator-domain
CASES

echo "T-132: $((N - FAILS))/$N checks passed"
[ "$FAILS" = 0 ]
