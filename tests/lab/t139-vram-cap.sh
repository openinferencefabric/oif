#!/bin/bash
# Acceptance test for T-139 (hard VRAM cap for AMD GPU fractions), run on the first node after  sudo ./oif install
# on several nodes with AMD GPU fractions on. Creates and deletes test pods in project team-c's namespace; otherwise
# read-only.
#   sudo tests/lab/t139-vram-cap.sh                 fractiond on the capable AMD nodes, the cap on each fraction pod,
#                                                    a pod that lifts PyTorch's cap stopped at its share, the
#                                                    neighbour unaffected
#   sudo tests/lab/t139-vram-cap.sh --expect-off    after AMD_VRAM_CAP=none in .env and  sudo ./oif install
#                                                    --reconfigure: no fractiond, no node label, no cap on a new pod
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
multi_node || { echo "T-139 needs a multi-node install (OIF_NODES)"; exit 2; }
MODE=${1:-}

FAILS=0; N=0
check() { N=$((N + 1)); if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi; }
info() { echo "  INFO  $*"; }
finish_() { echo "T-139: $((N - FAILS))/$N checks passed"; [ "$FAILS" = 0 ]; exit $?; }

AMD_NODE=$(amd_only_nodes | head -1)
[ -n "$AMD_NODE" ] || { echo "no node with AMD GPUs only"; exit 2; }
NS=$(runai_api project-pools team-c nvidia=1 amd=1)
ROCM=$ROCM_PYTORCH_IMAGE
cleanup() { kc -n "$NS" delete pod -l app.kubernetes.io/part-of=oif-t139 --ignore-not-found --wait=true >/dev/null 2>&1
  kc -n "$NS" delete configmap t139-probe --ignore-not-found >/dev/null 2>&1; }
cleanup; trap cleanup EXIT
logs() { kc -n "$NS" logs "$1" 2>/dev/null; }
pod_cap() {   # pod: dmem.max of its pod cgroup on the AMD node, in MiB ("max" when uncapped)
  local uid; uid=$(kc -n "$NS" get pod "$1" -o jsonpath='{.metadata.uid}')
  amd_node_run "$AMD_NODE" "d=\$(find /sys/fs/cgroup/kubepods.slice -maxdepth 2 -type d -name '*pod${uid//-/_}.slice' | head -1)
    awk '{ if (\$2 == \"max\") print \"max\"; else print int(\$2 / 1048576) }' \$d/dmem.max"
}
vram_mib() { amd_node_run "$AMD_NODE" "awk '{ print int(\$2 / 1048576) }' /sys/fs/cgroup/dmem.capacity | head -1"; }

kc -n "$NS" apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: {name: t139-probe}
data:
  polite.py: |
    import time, torch
    x = torch.empty(20 * 2**30 // 2, dtype=torch.float16, device="cuda")
    print("HOLDING 20 GiB", flush=True)
    while True:
        try:
            y = torch.empty(2**30 // 2, dtype=torch.float16, device="cuda"); del y; ok = "ok"
        except torch.OutOfMemoryError:
            ok = "REFUSED"
        print("one more GiB inside my share:", ok, flush=True); time.sleep(10)
  greedy.py: |
    import time, torch
    torch.cuda.set_per_process_memory_fraction(1.0)   # lifts the share oif set for PyTorch
    held, step = [], 2**30
    while len(held) < 40:
        try:
            held.append(torch.empty(step // 2, dtype=torch.float16, device="cuda"))
        except torch.OutOfMemoryError:
            break
    print("GREEDY HOLDS %d GiB (share 0.5 of %.0f GiB)" % (len(held), torch.cuda.mem_get_info()[1] / 2**30), flush=True)
    time.sleep(3600)
EOF
half_pod() {   # name script
  kc -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  labels: {runai/node-pool: amd, app.kubernetes.io/part-of: oif-t139}
  annotations: {gpu-fraction: "0.5"}
spec:
  schedulerName: runai-scheduler
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  nodeSelector: {kubernetes.io/hostname: $AMD_NODE}
  containers:
    - {name: main, image: $ROCM, command: [python3, -u, /probe/$2], volumeMounts: [{name: probe, mountPath: /probe}]}
  volumes: [{name: probe, configMap: {name: t139-probe}}]
EOF
}
greedy_run() {   # the greedy pod: start it and wait until it reports what it holds
  half_pod t139-greedy greedy.py
  wait_for "t139-greedy done allocating" 900 5 bash -c "kubectl --kubeconfig $KCFG -n $NS logs t139-greedy 2>/dev/null | grep -q 'GREEDY HOLDS'" >/dev/null
  info "$(logs t139-greedy | grep 'GREEDY HOLDS')"
}

# ---------------------------------------------------------------- AMD_VRAM_CAP=none: no fractiond, soft share
if [ "$MODE" = --expect-off ]; then
  echo "T-139 VRAM cap off (AMD_VRAM_CAP=none)"
  check "no fractiond DaemonSet" bash -c "! kubectl --kubeconfig $KCFG -n oif-system get daemonset oif-fractiond"
  check "no node labelled oif.ai/amd-vram-cap" bash -c "[ -z \"\$(kubectl --kubeconfig $KCFG get nodes -l oif.ai/amd-vram-cap -o name)\" ]"
  check "AMD fractions still on (oif-amd-share running)" kc -n oif-system rollout status ds/oif-amd-share --timeout=10s
  greedy_run
  check "a new fraction pod has no cap (dmem.max max)" [ "$(pod_cap t139-greedy)" = max ]
  check "soft share: a pod that lifts PyTorch's cap takes more than its share" \
    bash -c "kubectl --kubeconfig $KCFG -n $NS logs t139-greedy | awk '/GREEDY HOLDS/ { f = \$3 > \$6 * \$8 } END { exit !f }'"
  finish_
fi

# ---------------------------------------------------------------- default: the cap on
echo "T-139 hard VRAM cap for AMD GPU fractions on $AMD_NODE"
info "kernel $(amd_node_run "$AMD_NODE" 'uname -r'); $(amd_node_run "$AMD_NODE" 'cat /sys/fs/cgroup/dmem.capacity' | paste -sd' ')"
check "$AMD_NODE labelled oif.ai/amd-vram-cap=dmem" [ "$(kc get node "$AMD_NODE" -o jsonpath='{.metadata.labels.oif\.ai/amd-vram-cap}')" = dmem ]
check "fractiond ready on every labelled node" kc -n oif-system rollout status ds/oif-fractiond --timeout=60s
fpod=$(kc -n oif-system get pods -l app=oif-fractiond --field-selector "spec.nodeName=$AMD_NODE" -o jsonpath='{.items[0].metadata.name}')
check "fractiond on $AMD_NODE registered with containerd's NRI" bash -c "kubectl --kubeconfig $KCFG -n oif-system logs $fpod | grep -qi synchroniz"
check "fractiond runs the AMD backend" bash -c "kubectl --kubeconfig $KCFG -n oif-system get pod $fpod -o jsonpath='{.spec.containers[0].args}' | grep -q gpu-vendor=amd"

half_pod t139-polite polite.py
wait_for "t139-polite holds 20 GiB" 900 5 bash -c "kubectl --kubeconfig $KCFG -n $NS logs t139-polite 2>/dev/null | grep -q 'HOLDING 20 GiB'" >/dev/null
check "a half-GPU pod holds 20 GiB" grep -q 'HOLDING 20 GiB' <<< "$(logs t139-polite)"
vram=$(vram_mib); cap=$(pod_cap t139-polite); want=$((vram / 2))
info "VRAM $vram MiB; t139-polite dmem.max $cap MiB"
check "its pod cgroup is capped at half the VRAM ($want MiB)" [ "$cap" = "$want" ]
greedy_run
gcap=$(pod_cap t139-greedy)
check "the greedy pod is capped too ($gcap MiB)" [ "$gcap" = "$want" ]
check "hard limit: a pod that lifts PyTorch's cap is stopped at its share" \
  bash -c "kubectl --kubeconfig $KCFG -n $NS logs t139-greedy | awk '/GREEDY HOLDS/ { f = \$3 <= \$6 * \$8 && \$3 > 0 } END { exit !f }'"
sleep 15
check "the neighbour can still take one more GiB inside its share" bash -c "kubectl --kubeconfig $KCFG -n $NS logs t139-polite | tail -1 | grep -q 'inside my share: ok'"
check "fractiond logged both caps" bash -c "[ \$(kubectl --kubeconfig $KCFG -n oif-system logs $fpod | grep 'capped AMD GPU memory' | grep -cE 't139-(polite|greedy)') -ge 2 ]"
finish_
