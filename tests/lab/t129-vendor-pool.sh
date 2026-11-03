#!/bin/bash
# Acceptance test for T-129 (one GPU vendor per workload), run on the first node after  sudo ./oif install  on several
# nodes with both GPU vendors. Creates and deletes test pods and a Deployment in project team-c's namespace; otherwise
# read-only. team-c has 1 NVIDIA GPU of quota (T-123).
#   sudo tests/lab/t129-vendor-pool.sh
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
multi_node || { echo "T-129 needs a multi-node install (OIF_NODES)"; exit 2; }

FAILS=0; N=0
check() { N=$((N + 1)); if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi; }
info() { echo "  INFO  $*"; }
finish_() { echo "T-129: $((N - FAILS))/$N checks passed"; [ "$FAILS" = 0 ]; exit $?; }

NS=$(runai_api project-pools team-c nvidia=1 amd=1)
cleanup() { kc -n "$NS" delete pod,deployment -l app.kubernetes.io/part-of=oif-t129 --ignore-not-found --wait=true >/dev/null 2>&1; }
cleanup; trap cleanup EXIT
sel() { kc -n "$NS" get pod "$1" -o jsonpath='{.spec.nodeSelector.oif\.ai/gpu-vendor}'; }
poollabel() { kc -n "$NS" get pod "$1" -o jsonpath='{.metadata.labels.runai/node-pool}'; }
gpu_pod() {   # name resource [extra metadata line]: a sleeping pod for Run:ai's scheduler, no node pool of its own
  local res=""; [ -n "$2" ] && res=", resources: {limits: {$2: 1}}"
  kc -n "$NS" "${DRY[@]}" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  labels: {app.kubernetes.io/part-of: oif-t129${4:-}}
  ${3:-}
spec:
  schedulerName: runai-scheduler
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
    - {name: main, image: $BUSYBOX_IMAGE, command: [sleep, "3600"]$res}
EOF
}
DRY=()

echo "T-129 one GPU vendor per workload"
check "webhook oif-vendor-pool ready" kc -n oif-vendor-pool rollout status deploy/oif-vendor-pool --timeout=30s
check "webhook registered, failing open" bash -c "kubectl --kubeconfig $KCFG get mutatingwebhookconfiguration oif-vendor-pool -o jsonpath='{.webhooks[0].failurePolicy}' | grep -qx Ignore"
check "policy oif-vendor-agnostic-gpu bound" kc get validatingadmissionpolicybinding oif-vendor-agnostic-gpu

# 1. a pod asking for nvidia.com/gpu stays with NVIDIA, also when team-c's NVIDIA quota is full and the AMD GPU is free
gpu_pod t129-hold nvidia.com/gpu >/dev/null
wait_for "t129-hold running" 300 5 bash -c "[ \"\$(kubectl --kubeconfig $KCFG -n $NS get pod t129-hold -o jsonpath='{.status.phase}')\" = Running ]" >/dev/null
check "an nvidia.com/gpu pod is pinned to pool nvidia (label and node selector)" bash -c "[ '$(poollabel t129-hold)' = nvidia ] && [ '$(sel t129-hold)' = nvidia ]"
check "it runs on the NVIDIA node" bash -c "kubectl --kubeconfig $KCFG -n $NS get pod t129-hold -o jsonpath='{.spec.nodeName}' | xargs -I{} kubectl --kubeconfig $KCFG get node {} -L oif.ai/gpu-vendor --no-headers | grep -qw nvidia"
gpu_pod t129-spill nvidia.com/gpu >/dev/null
sleep 60
info "t129-spill: phase $(kc -n "$NS" get pod t129-spill -o jsonpath='{.status.phase}') node '$(kc -n "$NS" get pod t129-spill -o jsonpath='{.spec.nodeName}')'; $(kc -n "$NS" get events --field-selector involvedObject.name=t129-spill -o jsonpath='{.items[-1:].message}' 2>/dev/null | cut -c1-150)"
check "a second one waits on NVIDIA quota instead of moving to the AMD GPU (UI-10b)" \
  bash -c "[ \"\$(kubectl --kubeconfig $KCFG -n $NS get pod t129-spill -o jsonpath='{.status.phase}')\" = Pending ] && [ -z \"\$(kubectl --kubeconfig $KCFG -n $NS get pod t129-spill -o jsonpath='{.spec.nodeName}')\" ]"
kc -n "$NS" delete pod t129-hold t129-spill --wait=true >/dev/null 2>&1

# 2. a GPU fraction that names no vendor: refused unless it chose a pool
DRY=(--dry-run=server)
out=$(gpu_pod t129-anyvendor "" "annotations: {gpu-fraction: \"0.5\"}" 2>&1)
info "$(cut -c1-200 <<< "$out")"
check "a fraction without a vendor, pools nvidia and amd: refused with the T-129 message" grep -q "choose one GPU vendor" <<< "$out"
check "the same fraction in pool amd is accepted" gpu_pod t129-amdfrac "" "annotations: {gpu-fraction: \"0.5\"}" ", runai/node-pool: amd"
check "an amd.com/gpu pod is accepted and pinned to pool amd" bash -c "kubectl --kubeconfig $KCFG -n $NS create --dry-run=server -o jsonpath='{.spec.nodeSelector.oif\.ai/gpu-vendor}' -f - <<'EOF' | grep -qx amd
apiVersion: v1
kind: Pod
metadata: {name: t129-amd, labels: {app.kubernetes.io/part-of: oif-t129}}
spec:
  schedulerName: runai-scheduler
  containers: [{name: main, image: $BUSYBOX_IMAGE, command: [sleep, '1'], resources: {limits: {amd.com/gpu: 1}}}]
EOF"
DRY=()

# 3. a pod without a GPU takes the pool of the workload that owns it (the Dynamo frontend case, S-4)
kc -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: t129-frontend
  labels: {app.kubernetes.io/part-of: oif-t129, runai/node-pool: nvidia}
spec:
  replicas: 1
  selector: {matchLabels: {app: t129-frontend}}
  template:
    metadata: {labels: {app: t129-frontend, app.kubernetes.io/part-of: oif-t129}}
    spec:
      terminationGracePeriodSeconds: 1
      containers: [{name: main, image: $BUSYBOX_IMAGE, command: [sleep, "3600"]}]
EOF
wait_for "t129-frontend pod created" 120 3 bash -c "kubectl --kubeconfig $KCFG -n $NS get pod -l app=t129-frontend -o name | grep -q ." >/dev/null
fp=$(kc -n "$NS" get pod -l app=t129-frontend -o jsonpath='{.items[0].metadata.name}')
check "a GPU-less pod of a Deployment in pool nvidia is pinned to nvidia" bash -c "[ '$(poollabel "$fp")' = nvidia ] && [ '$(sel "$fp")' = nvidia ]"
info "webhook log: $(kc -n oif-vendor-pool logs deploy/oif-vendor-pool 2>/dev/null | grep -E 't129-(hold|spill|frontend)' | tail -3 | sed 's/^.*pod /pod /' | paste -sd';' | cut -c1-300)"
finish_
