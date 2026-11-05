#!/bin/bash
# Spike S-9 (P1.4 step 0, ADR-020 amendment 2026-11-05): does KAI's topology-aware scheduling keep a multi-GPU job
# inside one accelerator domain? The lab has one GPU per node, so this adds fake 8-GPU nodes (KWOK v0.8.0: nodes and
# pods that exist only in the API, kept Running by the KWOK controller) in two NVIDIA domains and one AMD domain,
# schedules Jobs through Run:ai's KAI and reads where they land. Everything is removed at the end (also on Ctrl+C).
# Changes while it runs: KWOK controller in kube-system, five fake nodes (tainted, in pools nvidia and amd), one
# Topology, Jobs in team-c, team-c's quota raised in pools nvidia and amd (put back to 1 and 1).
#   sudo tests/lab/s9-fake-topology.sh           all cases
#   sudo tests/lab/s9-fake-topology.sh --debug   the first case only, with what KAI saw and did
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

KWOK_VERSION=v0.8.0
KWOK_SHA256=a4c16e6431e382dcb5c1903139344b7a68652f16a6460337fe17a678a426f405         # kwok.yaml
KWOK_STAGE_SHA256=2f28d95564ec43056c0873f7a25ac7d2a5bba4c8496c72f8b3ee73fd4f54ee24   # stage-fast.yaml
DOMAIN_LABEL=oif.ai/accelerator-domain
TOPO=oif-s9
W=$(mktemp -d)
FAILS=0; N=0
check() { N=$((N + 1)); if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi; }
info() { echo "  INFO  $*"; }

NS=$(runai_api project-pools team-c nvidia=40 amd=24)
cleanup() {
  kc -n "$NS" delete job -l app.kubernetes.io/part-of=oif-s9 --ignore-not-found --wait=true >/dev/null 2>&1
  kc delete topologies.kai.scheduler "$TOPO" --ignore-not-found >/dev/null 2>&1
  kc delete node -l app.kubernetes.io/part-of=oif-s9 --ignore-not-found >/dev/null 2>&1
  [ -s "$W/stage-fast.yaml" ] && kc delete -f "$W/stage-fast.yaml" --ignore-not-found >/dev/null 2>&1
  [ -s "$W/kwok.yaml" ] && kc delete -f "$W/kwok.yaml" --ignore-not-found >/dev/null 2>&1
  runai_api project-pools team-c nvidia=1 amd=1 >/dev/null 2>&1
  rm -rf "$W"
}
trap cleanup EXIT

echo "S-9 fake multi-GPU nodes and KAI topology (KWOK $KWOK_VERSION)"
for f in kwok.yaml:$KWOK_SHA256 stage-fast.yaml:$KWOK_STAGE_SHA256; do
  curl -fsSL -o "$W/${f%%:*}" "https://github.com/kubernetes-sigs/kwok/releases/download/$KWOK_VERSION/${f%%:*}" \
    && echo "${f#*:}  $W/${f%%:*}" | sha256sum -c - >/dev/null || { echo "cannot fetch or verify ${f%%:*}"; exit 1; }
done
kc apply -f "$W/kwok.yaml" >/dev/null && kc apply -f "$W/stage-fast.yaml" >/dev/null
check "KWOK controller running" kc -n kube-system rollout status deploy/kwok-controller --timeout=180s

fake_node() {   # name vendor domain: 8 GPUs of that vendor, tainted so only the test pods go there
  kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Node
metadata:
  name: $1
  annotations: {kwok.x-k8s.io/node: fake}
  labels: {app.kubernetes.io/part-of: oif-s9, type: kwok, kubernetes.io/hostname: $1, oif.ai/gpu-vendor: $2, $DOMAIN_LABEL: $3}
spec:
  taints: [{key: kwok.x-k8s.io/node, value: fake, effect: NoSchedule}]
status:
  allocatable: {cpu: "64", memory: 512Gi, pods: "110", $2.com/gpu: "8"}
  capacity: {cpu: "64", memory: 512Gi, pods: "110", $2.com/gpu: "8"}
EOF
}
fake_node s9-nv-a1 nvidia nv-a; fake_node s9-nv-a2 nvidia nv-a; fake_node s9-nv-b1 nvidia nv-b
fake_node s9-amd-a1 amd amd-a; fake_node s9-amd-a2 amd amd-a
check "five fake GPU nodes Ready (2 in domain nv-a, 1 in nv-b, 2 in amd-a)" \
  kc wait node -l app.kubernetes.io/part-of=oif-s9 --for=condition=Ready --timeout=120s
kc apply -f - >/dev/null <<EOF
apiVersion: kai.scheduler/v1alpha1
kind: Topology
metadata: {name: $TOPO}
spec:
  levels:
  - nodeLabel: $DOMAIN_LABEL
  - nodeLabel: kubernetes.io/hostname
EOF
check "Topology $TOPO (levels: domain, host)" kc get topologies.kai.scheduler "$TOPO"
sleep 20   # the schedulers pick up the new nodes and the Topology

job() {   # name pods gpus-each vendor [required-level]
  local ann=""
  [ -n "${5:-}" ] && ann="annotations: {kai.scheduler/topology: $TOPO, kai.scheduler/topology-required-placement: $5}"
  kc -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $1
  labels: {app.kubernetes.io/part-of: oif-s9}
  $ann
spec:
  parallelism: $2
  completions: $2
  backoffLimit: 0
  template:
    metadata:
      labels: {app.kubernetes.io/part-of: oif-s9, runai/node-pool: $4}
    spec:
      schedulerName: runai-scheduler
      restartPolicy: Never
      tolerations: [{key: kwok.x-k8s.io/node, operator: Exists, effect: NoSchedule}]
      nodeSelector: {type: kwok}
      containers: [{name: main, image: busybox, command: [sleep, "600"], resources: {limits: {$4.com/gpu: "$3"}}}]
EOF
}
placed() {   # job: "node domain" per pod, or "Pending" for unplaced pods
  local p n
  for p in $(kc -n "$NS" get pods -l job-name="$1" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'); do
    n=$(kc -n "$NS" get pod "$p" -o jsonpath='{.spec.nodeName}')
    if [ -n "$n" ]; then echo "$n $(kc get node "$n" -o jsonpath="{.metadata.labels.oif\.ai/accelerator-domain}")"; else echo Pending; fi
  done
}
wait_placed() {   # job pods seconds
  local i
  for i in $(seq 1 $(($3 / 5))); do [ "$(placed "$1" | grep -vc Pending)" -ge "$2" ] && return 0; sleep 5; done
  return 1
}
domains() { placed "$1" | awk '$1 != "Pending" {print $2}' | sort -u | paste -sd' '; }

# 1. 3 pods x 4 NVIDIA GPUs, required in one domain: nv-a (16 GPUs) is the only one large enough
job s9-pack 3 4 nvidia "$DOMAIN_LABEL"
wait_placed s9-pack 3 120; info "s9-pack: $(placed s9-pack | paste -sd',')"
if [ "${1:-}" = --debug ]; then   # what KAI saw and did for s9-pack, then clean up
  echo "== fake nodes: allocatable GPUs, pool labels"
  kc get node -l app.kubernetes.io/part-of=oif-s9 -o jsonpath='{range .items[*]}{.metadata.name} gpu={.status.allocatable.nvidia\.com/gpu}{.status.allocatable.amd\.com/gpu} pool={.metadata.labels.runai/node-pool} vendor={.metadata.labels.oif\.ai/gpu-vendor} domain={.metadata.labels.oif\.ai/accelerator-domain}{"\n"}{end}'
  echo "== pods: node, GPU limits, pod group"
  kc -n "$NS" get pods -l job-name=s9-pack -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName} {.spec.containers[0].resources.limits} pg={.metadata.annotations.pod-group-name}{"\n"}{end}'
  echo "== pod groups"
  for pg in $(kc -n "$NS" get podgroups.scheduling.run.ai -o name 2>/dev/null | grep -i s9-pack); do
    kc -n "$NS" get "$pg" -o yaml | grep -E "^  (minMember|topologyConstraint|queue)|^    (preferredTopologyLevel|requiredTopologyLevel|topology)|subGroups|minSubGroup|^  annotations" -A1 | head -30
  done
  echo "== scheduler (pool nvidia) log for s9-pack"
  kc -n runai logs deploy/runai-scheduler-nvidia --since=5m 2>/dev/null | grep -i -E "s9-pack|s9-nv|topolog" | tail -40 | cut -c1-400
  echo "== binder log for s9-pack"
  kc -n runai logs deploy/binder --since=5m 2>/dev/null | grep -i "s9-pack" | tail -10 | cut -c1-300
  exit 0
fi
check "3 x 4 GPUs, required same domain: all in one domain" bash -c '[ "$1" = nv-a ]' _ "$(domains s9-pack)"
kc -n "$NS" delete job s9-pack --wait=true >/dev/null

# 2. larger than any domain (3 x 8 = 24 > 16), required same domain: waits, never split
job s9-toolarge 3 8 nvidia "$DOMAIN_LABEL"
sleep 45; info "s9-toolarge: $(placed s9-toolarge | paste -sd',')"
check "3 x 8 GPUs, required same domain, no domain big enough: nothing placed" bash -c '[ "$(grep -vc Pending <<< "$1")" = 0 ]' _ "$(placed s9-toolarge)"
reason=$(kc -n "$NS" get pods -l job-name=s9-toolarge -o jsonpath='{.items[0].status.conditions[0].message}' 2>/dev/null)
info "why: ${reason:0:220}"
kc -n "$NS" delete job s9-toolarge --wait=true >/dev/null

# 3. control: the same 3 x 4 without a topology constraint may spread over domains (information only)
job s9-free 3 4 nvidia
wait_placed s9-free 3 120; info "without topology: $(placed s9-free | paste -sd',') -> domains: $(domains s9-free)"
kc -n "$NS" delete job s9-free --wait=true >/dev/null

# 4. AMD: 2 x 8 GPUs, required in one domain: amd-a (2 nodes x 8)
job s9-amd 2 8 amd "$DOMAIN_LABEL"
wait_placed s9-amd 2 120; info "s9-amd: $(placed s9-amd | paste -sd',')"
check "AMD 2 x 8 GPUs, required same domain: both in amd-a" bash -c '[ "$1" = amd-a ]' _ "$(domains s9-amd)"
kc -n "$NS" delete job s9-amd --wait=true >/dev/null

# 5. the real GPU nodes were not used by any test pod
check "no test pod on a real node" bash -c '! kubectl --kubeconfig "$1" -n "$2" get pods -l app.kubernetes.io/part-of=oif-s9 -o wide 2>/dev/null | grep -E "gpu-(nvidia|amd) "' _ "$KCFG" "$NS"

echo "S-9: $((N - FAILS))/$N checks passed (cleanup follows)"
[ "$FAILS" = 0 ]
