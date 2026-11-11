#!/bin/bash
# Lab check for kai-scheduler/gpu-fractioning#175 after its review fixes (branch review/175-fixes of
# openinferencefabric/gpu-fractioning): fractiond --gpu-vendor=amd, built from that branch, on the first AMD-only
# node, as the DaemonSet in its docs/amd guide. Run on the first node after  sudo ./oif install  (multi-node):
#   sudo tests/lab/gf175-reapply.sh [git-ref]      default ref: review/175-fixes (the PR branch once it passes)
# Checks:
#   1. readiness: ready once dmem.capacity (host cgroup, mounted read-only) lists a GPU VRAM region
#   2. create path: a container with a 4Gi limit gets dmem.max = 4096 MiB on its own cgroup; no dmem.min
#   3. re-apply: a container created while fractiond is down starts uncapped, and gets its dmem.max set in place,
#      without a restart, when fractiond comes back (retroactive enforcement on AMD)
#   4. fail-closed: a container naming a GPU with no dmem region is refused by fractiond with a clear error
# Builds an image on the AMD node (podman, imported into containerd), runs it next to oif's own oif-fractiond with
# another NRI name and index, and creates busybox pods (BUSYBOX_IMAGE) in namespace oif-gf175. Everything is deleted at the end
# (the image stays in containerd: oif.local/gf175/fractiond:test).
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
multi_node || { echo "needs a multi-node install (OIF_NODES)"; exit 2; }
REF=${1:-review/175-fixes}
NS=oif-gf175; IMG=oif.local/gf175/fractiond:test

FAILS=0; N=0
check() { N=$((N + 1)); if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi; }
info() { echo "  INFO  $*"; }
finish_() { echo "gf175: $((N - FAILS))/$N checks passed"; [ "$FAILS" = 0 ]; exit $?; }

AMD_NODE=$(amd_only_nodes | head -1)
[ -n "$AMD_NODE" ] || { echo "no node with AMD GPUs only"; exit 2; }
cleanup() { kc delete namespace "$NS" --ignore-not-found --wait=true >/dev/null 2>&1; }
cleanup; trap cleanup EXIT

echo "== build fractiond from openinferencefabric/gpu-fractioning $REF on $AMD_NODE"
amd_node_run "$AMD_NODE" "set -e; d=\$(mktemp -d); trap 'rm -rf \$d' EXIT
  git clone -q --depth 1 --branch '$REF' https://github.com/openinferencefabric/gpu-fractioning \$d/src
  git -C \$d/src log -1 --format='  commit %h %s'
  podman build -q -t $IMG -f \$d/src/fractioning-manager/fractiond/build/Dockerfile \$d/src >/dev/null
  podman save $IMG | ctr -n k8s.io images import - >/dev/null
  echo '  image imported into containerd'" || { echo "build failed"; exit 1; }

GPU=$(amd_node_run "$AMD_NODE" "awk '\$1 ~ /^drm\\/.*\\/vram\$/ {split(\$1, a, \"/\"); print a[2]; exit}' /sys/fs/cgroup/dmem.capacity")
[ -n "$GPU" ] || { echo "no GPU VRAM region in $AMD_NODE's dmem.capacity: kernel before 6.15?"; exit 2; }
info "AMD node $AMD_NODE, GPU $GPU, kernel $(amd_node_run "$AMD_NODE" 'uname -r'), runc $(amd_node_run "$AMD_NODE" 'runc --version 2>/dev/null | head -1 | cut -d" " -f3')"

kc create namespace "$NS" >/dev/null
ds() {   # node selector value: the DaemonSet runs on AMD_NODE, or nowhere (fractiond down)
  kc -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: gf175-fractiond}
spec:
  selector: {matchLabels: {app: gf175-fractiond}}
  template:
    metadata: {labels: {app: gf175-fractiond}}
    spec:
      nodeSelector: {kubernetes.io/hostname: "$1"}
      priorityClassName: system-node-critical
      automountServiceAccountToken: false
      containers:
        - name: fractiond
          image: $IMG
          imagePullPolicy: Never
          args: [--gpu-vendor=AMD, --plugin-name=gf175-test, --plugin-idx=30, --map-dir=/run/fractiond/map, --log-level=debug]
          securityContext: {runAsUser: 0, readOnlyRootFilesystem: true, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          readinessProbe: {httpGet: {path: /readyz, port: 8093}, periodSeconds: 2}
          volumeMounts:
            - {name: nri, mountPath: /var/run/nri}
            - {name: run, mountPath: /run/fractiond}
            - {name: cgroup, mountPath: /host/sys/fs/cgroup, readOnly: true}
      volumes:
        - {name: nri, hostPath: {path: /var/run/nri, type: Directory}}
        - {name: run, emptyDir: {}}
        - {name: cgroup, hostPath: {path: /sys/fs/cgroup, type: Directory}}
EOF
}
pod() {   # name gpu-address
  kc -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  annotations:
    nvidia.com/container.main.gpu-memory.limit: 4Gi
    nvidia.com/container.main.gpus.devices: "$2"
spec:
  nodeName: $AMD_NODE
  terminationGracePeriodSeconds: 0
  containers: [{name: main, image: $BUSYBOX_IMAGE, command: [sleep, infinity]}]
EOF
}
ctr_file() {   # pod file: a file of the pod's main container cgroup ("" if not found)
  local id; id=$(kc -n "$NS" get pod "$1" -o jsonpath='{.status.containerStatuses[0].containerID}'); id=${id#containerd://}
  [ -n "$id" ] || return 1
  amd_node_run "$AMD_NODE" "d=\$(find /sys/fs/cgroup/kubepods.slice -type d -name 'cri-containerd-$id.scope' | head -1); cat \$d/$2"
}
cap_mib() { ctr_file "$1" dmem.max | awk -v g="$GPU" '$1 == "drm/" g "/vram" { if ($2 == "max") print "max"; else print int($2 / 1048576) }'; }
ready() { kc -n "$NS" rollout status ds/gf175-fractiond --timeout=120s; }
fdlogs() { kc -n "$NS" logs ds/gf175-fractiond 2>/dev/null; }
log_has() { fdlogs | grep -q "$1"; }
reapplied() { fdlogs | grep 're-applying' | grep -Eq "pod.{0,3}$1"; }   # text (pod=x) or JSON ("pod":"x")
not_reapplied() { ! reapplied "$1"; }
no_min() { ! ctr_file capped dmem.min | grep -q "$GPU/vram [1-9]"; }
refused() { echo "$EV" | grep -q 'has no dmem VRAM region'; }

echo "== 1. readiness"
ds "$AMD_NODE"
check "fractiond ready on $AMD_NODE (--gpu-vendor=AMD, upper case, accepted)" ready
check "it found the GPU's dmem region through the read-only host cgroup mount" log_has 'dmem regions found'

echo "== 2. create path"
pod capped "$GPU"
kc -n "$NS" wait --for=condition=Ready pod/capped --timeout=120s >/dev/null 2>&1
info "capped: dmem.max $(cap_mib capped) MiB"
check "a new 4Gi container is capped at 4096 MiB on its own cgroup" test "$(cap_mib capped)" = 4096
check "no dmem.min is written" no_min

echo "== 3. re-apply after a restart"
ds nowhere-gf175
kc -n "$NS" wait --for=delete pod -l app=gf175-fractiond --timeout=120s >/dev/null 2>&1
pod late "$GPU"
kc -n "$NS" wait --for=condition=Ready pod/late --timeout=120s >/dev/null 2>&1
LATE_BEFORE=$(cap_mib late); info "late, created while fractiond was down: dmem.max $LATE_BEFORE"
check "a container created while fractiond is down starts uncapped" test "$LATE_BEFORE" = max
RESTARTS=$(kc -n "$NS" get pod late -o jsonpath='{.status.containerStatuses[0].restartCount}')
ds "$AMD_NODE"; ready >/dev/null 2>&1; sleep 3
LATE_AFTER=$(cap_mib late); info "late, after fractiond reconnected: dmem.max $LATE_AFTER"
check "fractiond's return sets its dmem.max to 4096 MiB in place" test "$LATE_AFTER" = 4096
check "without restarting it" test "$(kc -n "$NS" get pod late -o jsonpath='{.status.containerStatuses[0].restartCount}')" = "$RESTARTS"
check "the log names the re-applied container" reapplied late
check "and leaves the already-capped one alone" not_reapplied capped
check "the first container is still capped" test "$(cap_mib capped)" = 4096

echo "== 4. fail-closed on a GPU with no dmem region"
pod nogpu 0000:ff:1f.7
sleep 8
EV=$(kc -n "$NS" get events --field-selector involvedObject.name=nogpu -o jsonpath='{.items[*].message}')
info "nogpu events: $(echo "$EV" | grep -o 'has no dmem VRAM region[^;]*' | head -1)"
check "it is refused by fractiond with the clear error, not by runc" refused

echo "== fractiond log (AMD lines)"
fdlogs | grep -E 'dmem|AMD|re-applying|not ready' | tail -12 | sed 's/^/    /'
finish_
