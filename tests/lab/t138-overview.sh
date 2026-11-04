#!/bin/bash
# Acceptance test for T-138 (Run:ai Overview "Allocated GPU devices" stays 0), run on the first node after  sudo ./oif
# install. The cluster's Run:ai metrics must reach the control plane (Thanos receive), and the Overview's telemetry
# must count what is allocated: a whole NVIDIA GPU, then also half an AMD GPU. Sets team-c's quota to 1 GPU in pool
# nvidia and 1 in pool amd (as T-123 does), creates and deletes two test pods in team-c's namespace; otherwise
# read-only.
#   sudo tests/lab/t138-overview.sh
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
is() { [ "$(python3 -c "print(abs(float('${1:-nan}') - $2) < 0.01)" 2>/dev/null)" = True ]; }
tele() { runai_api telemetry "$1" 2>/dev/null; }
wait_tele() {   # type value seconds: until the Overview's telemetry shows the value
  local i
  for i in $(seq 1 $(($3 / 15))); do is "$(tele "$1")" "$2" && return 0; sleep 15; done
  return 1
}
ring_size() {   # endpoints in the Thanos receive hashring
  kc -n "$THANOS_NS" get configmap "$THANOS_RECEIVE" -o json | python3 -c 'import json, sys
d = json.load(sys.stdin)["data"]; k = next(k for k in d if k.endswith(".json")); print(sum(len(h["endpoints"]) for h in json.loads(d[k])))'
}
refused_writes() {   # remote writes to the control plane refused in the last 2 minutes, over Run:ai's Prometheus copies
  local p n=0
  for p in $(kc -n runai get pods -l app.kubernetes.io/name=prometheus -o name); do
    n=$((n + $(kc -n runai logs "$p" -c prometheus --since=2m 2>/dev/null | grep -c "Failed to send batch")))
  done
  echo "$n"
}
writes_accepted() {   # no refused write for 2 minutes, within 6 (a run right after the repair still sees older ones)
  local i
  for i in $(seq 1 24); do [ "$(refused_writes)" = 0 ] && return 0; sleep 15; done
  return 1
}
receivers_own_endpoint() {   # each running receiver pod (not only the StatefulSet) names itself on the headless service
  local n
  n=$(kc -n "$THANOS_NS" get pods -l app.kubernetes.io/component=receive,app.kubernetes.io/name=thanos -o json | python3 -c 'import json, sys
pods = json.load(sys.stdin)["items"]
ok = [p for p in pods if p["status"].get("phase") == "Running" and any(a.startswith("--receive.local-endpoint=$(NAME).") and "-headless." in a
      for c in p["spec"]["containers"] if c["name"] == "receive" for a in c.get("args", []))]
print(len(ok) if len(ok) == len(pods) else -1)')
  [ "$n" = "$(kc -n "$THANOS_NS" get sts "$THANOS_RECEIVE" -o jsonpath='{.spec.replicas}')" ]
}

NS=$(runai_api project-pools team-c nvidia=1 amd=1)
cleanup() { kc -n "$NS" delete pod -l app.kubernetes.io/part-of=oif-t138 --ignore-not-found --wait=true >/dev/null 2>&1; }
cleanup; trap cleanup EXIT
pod() {   # name pool resource-or-fraction
  local extra res
  if [ "$3" = half ]; then extra="annotations: {gpu-fraction: \"0.5\"}"; res=""; else extra=""; res=", resources: {limits: {$3: 1}}"; fi
  kc -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  labels: {app.kubernetes.io/part-of: oif-t138, runai/node-pool: $2}
  $extra
spec:
  schedulerName: runai-scheduler
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
    - {name: main, image: $BUSYBOX_IMAGE, command: [sleep, "3600"]$res}
EOF
}

echo "T-138 Run:ai Overview counts allocated GPUs (project team-c: 1 GPU in nvidia, 1 in amd)"
if platform_ha; then
  replicas=$(kc -n "$THANOS_NS" get sts "$THANOS_RECEIVE" -o jsonpath='{.spec.replicas}')
  check "Thanos receive hashring lists all $replicas receivers" [ "$(ring_size)" = "$replicas" ]
  check "the receivers are on their headless service" \
    [ "$(kc -n "$THANOS_NS" get sts "$THANOS_RECEIVE" -o jsonpath='{.spec.serviceName}')" = "$THANOS_RECEIVE-headless" ]
  check "every receiver pod restarted with its own endpoint (not 127.0.0.1)" receivers_own_endpoint
else
  info "fewer than 3 control-plane nodes: one receiver, ring checks skipped"
fi
check "no remote write refused by the control plane for 2 minutes" writes_accepted
check "the control plane holds the cluster's metrics" runai_metrics_stored

info "before: allocated $(tele ALLOCATED_GPUS), total $(tele TOTAL_GPUS), free $(tele FREE_GPUS)"
pod t138-nvidia nvidia nvidia.com/gpu
kc -n "$NS" wait pod/t138-nvidia --for=condition=Ready --timeout=180s >/dev/null || info "t138-nvidia not ready"
check "Overview: 1 allocated GPU device with a whole NVIDIA GPU" wait_tele ALLOCATED_GPUS 1 300
pod t138-amd-half amd half
kc -n "$NS" wait pod/t138-amd-half --for=condition=Ready --timeout=180s >/dev/null || info "t138-amd-half not ready"
check "Overview: 1.5 with half an AMD GPU as well" wait_tele ALLOCATED_GPUS 1.5 300
check "Overview: free GPUs reported" bash -c '[ "$1" != none ] && [ -n "$1" ]' _ "$(tele FREE_GPUS)"
info "with both pods: allocated $(tele ALLOCATED_GPUS), total $(tele TOTAL_GPUS), free $(tele FREE_GPUS), idle $(tele IDLE_ALLOCATED_GPUS)"

echo "T-138: $((N - FAILS))/$N checks passed"
[ "$FAILS" = 0 ]
