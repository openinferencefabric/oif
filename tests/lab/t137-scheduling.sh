#!/bin/bash
# Acceptance test for T-137 (OIF Scheduling dashboard on several node pools), run on the first node after  sudo ./oif
# install  on several nodes with both GPU vendors. Sets team-c's quota to 1 GPU in pool nvidia and 1 in pool amd (as
# T-123 does), creates and deletes two test pods in team-c's namespace; otherwise read-only.
#   sudo tests/lab/t137-scheduling.sh
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
multi_node || { echo "T-137 needs a multi-node install (OIF_NODES)"; exit 2; }

FAILS=0; N=0
check() { N=$((N + 1)); if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi; }
info() { echo "  INFO  $*"; }
finish_() { echo "T-137: $((N - FAILS))/$N checks passed"; [ "$FAILS" = 0 ]; exit $?; }
val() { prom_query "$1" | awk '{print $NF}' | head -1; }   # PromQL -> its single value
is() { [ "$(python3 -c "print(abs(float('${1:-nan}') - $2) < 0.01)")" = True ]; }
wait_val() {   # what PromQL value seconds: until the query gives the value (prom_query is a function: no bash -c)
  local i
  for i in $(seq 1 $(($3 / 15))); do is "$(val "$1")" "$2" && return 0; sleep 15; done
  return 1
}

NS=$(runai_api project-pools team-c nvidia=1 amd=1)
cleanup() { kc -n "$NS" delete pod -l app.kubernetes.io/part-of=oif-t137 --ignore-not-found --wait=true >/dev/null 2>&1; }
cleanup; trap cleanup EXIT
pod() {   # name pool resource-or-fraction
  local extra res
  if [ "$3" = half ]; then extra="annotations: {gpu-fraction: \"0.5\"}"; res=""; else extra=""; res=", resources: {limits: {$3: 1}}"; fi
  kc -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  labels: {app.kubernetes.io/part-of: oif-t137, runai/node-pool: $2}
  $extra
spec:
  schedulerName: runai-scheduler
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
    - {name: main, image: $BUSYBOX_IMAGE, command: [sleep, "3600"]$res}
EOF
}

echo "T-137 Scheduling dashboard on several node pools (project team-c: 1 GPU in nvidia, 1 in amd)"
wait_val 'oif:project_gpu_deserved{project="team-c"}' 2 180
info "per pool: $(prom_query 'oif:project_pool_gpu_deserved{project="team-c"}' | sed -E 's/.*nodepool=([a-z]+).* ([0-9.]+)$/\1=\2/' | paste -sd' ')"
check "team-c's quota is 2 GPUs (1 nvidia + 1 amd), as in Run:ai" is "$(val 'oif:project_gpu_deserved{project="team-c"}')" 2
check "only projects are counted (department queues have no project)" bash -c "[ -n \"\$1\" ] && ! grep -v 'project=' <<< \"\$1\"" _ "$(prom_query 'oif:project_gpu_deserved')"

pod t137-nvidia nvidia nvidia.com/gpu
pod t137-amd-half amd half
wait_for "both pods running" 600 5 bash -c "[ \"\$(kubectl --kubeconfig $KCFG -n $NS get pods -l app.kubernetes.io/part-of=oif-t137 --field-selector status.phase=Running -o name | wc -l)\" = 2 ]" >/dev/null
wait_val 'oif:project_gpu_allocated{project="team-c"}' 1.5 240
info "allocated per pool: $(prom_query 'oif:project_pool_gpu_allocated{project="team-c"}' | sed -E 's/.*nodepool=([a-z]+).* ([0-9.]+)$/\1=\2/' | paste -sd' ')"
check "team-c's allocated GPUs are 1.5 (a whole NVIDIA GPU and half an AMD one)" is "$(val 'oif:project_gpu_allocated{project="team-c"}')" 1.5
check "per pool: 1 in nvidia" is "$(val 'oif:project_pool_gpu_allocated{project="team-c",nodepool="nvidia"}')" 1
check "per pool: 0.5 in amd" is "$(val 'oif:project_pool_gpu_allocated{project="team-c",nodepool="amd"}')" 0.5

host=grafana.$(runai_domain); ip=$(first_ip "$METALLB_RANGE")
netrc=$(mktemp); chmod 600 "$netrc"; printf 'machine %s login admin password %s\n' "$host" "$GRAFANA_ADMIN_PASSWORD" > "$netrc"
dash=$(curl -fsS -m 20 --netrc-file "$netrc" --cacert "$PKI/ca.crt" --resolve "$host:443:$ip" "https://$host/api/dashboards/uid/oif-scheduling" 2>/dev/null)
rm -f "$netrc"
check "Grafana serves the dashboard with the per-pool table" grep -q 'Project quotas by node pool' <<< "$dash"
check "the per-vendor caps panel explains why it is empty on several nodes" grep -q 'each vendor has its own node pool' <<< "$dash"
finish_
