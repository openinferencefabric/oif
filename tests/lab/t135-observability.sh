#!/bin/bash
# T-135 lab check: the oif:domain_* and oif:aijob_* series and their Grafana row. kube-state-metrics copies the node's
# accelerator domain and the pod's AIJob label; the domain series agree with the AcceleratorDomain view; a running
# AIJob shows in oif:aijob_gpu_requested and in its domain's use; no AIJob spans both vendors; Grafana serves the row.
# Changes while it runs: one AIJob in project team-c's namespace (deleted at the end, also on Ctrl+C).
#   sudo tests/lab/t135-observability.sh
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
val() { prom_query "$1" | awk '{print $NF}' | head -1; }   # PromQL -> its single value
val_is() { [ "$(val "$1")" = "$2" ]; }
NS=$(runai_api project-pools team-c nvidia=1 amd=1) || { echo "  FAIL  project team-c: $NS"; exit 1; }
cleanup() { kc -n "$NS" delete aijob t135 --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup EXIT
DOMAINS=$(kc get acceleratordomains -o jsonpath='{range .items[*]}{.status.domain}{"\n"}{end}')

echo "T-135 oif:domain_* and oif:aijob_* series, Grafana"
check "kube-state-metrics copies the domain and AIJob labels" bash -c '[[ "$1" == *oif.ai/accelerator-domain* && "$1" == *oif.ai/aijob* ]]' _ \
  "$(kc -n monitoring get deploy -l app.kubernetes.io/name=kube-state-metrics -o jsonpath='{.items[0].spec.template.spec.containers[0].args}')"
check "every GPU node's domain in kube_node_labels (within 2 min)" wait_for "node labels" 120 10 \
  val_is 'count(kube_node_labels{label_oif_ai_accelerator_domain!=""})' "$(wc -l <<< "$DOMAINS")"
for d in $DOMAINS; do
  a=$(kc get acceleratordomain "$d" -o jsonpath='{.status.allocatableGPUs}')
  check "$d: oif:domain_gpu_allocatable = $a, as the AcceleratorDomain view (within 2 min)" wait_for "$d allocatable" 120 10 \
    val_is "sum(oif:domain_gpu_allocatable{domain=\"$d\"})" "$a"
done
info "$(prom_query 'oif:domain_gpu_util_ratio' | sed -E 's/.*domain=([^,]+),vendor=([a-z]+) (.*)/\1 (\2) \3/' | paste -sd';' -)"

# a running AIJob: its vendor's AIJob GPUs and its domain's use go to 1
cat <<EOF | kc apply -f - >/dev/null
{"apiVersion": "oif.ai/v1alpha1", "kind": "AIJob", "metadata": {"name": "t135", "namespace": "$NS"},
 "spec": {"gpuCount": 1, "template": {"image": "$BUSYBOX_IMAGE", "command": ["sleep", "600"]}}}
EOF
running() { [ "$(kc -n "$NS" get aijob t135 -o jsonpath='{.status.phase}')" = Running ]; }
check "AIJob t135 running (within 3 min)" wait_for "t135 running" 180 5 running
v=$(kc -n "$NS" get aijob t135 -o jsonpath='{.status.vendor}'); d=$(kc -n "$NS" get aijob t135 -o jsonpath='{.status.domains[0]}')
info "t135: vendor $v, domain $d"
check "oif:aijob_gpu_requested{vendor=$v, phase=Running} = 1 (within 2 min)" wait_for "aijob series" 120 10 \
  val_is "sum(oif:aijob_gpu_requested{vendor=\"$v\", namespace=\"$NS\", phase=\"Running\"})" 1
check "oif:domain_gpu_in_use{domain=$d} = 1 (within 2 min)" wait_for "domain in use" 120 10 val_is "sum(oif:domain_gpu_in_use{domain=\"$d\"})" 1
check "oif:aijob_cross_vendor = 0" val_is 'oif:aijob_cross_vendor' 0
cleanup
check "after the AIJob: its domain's use back to 0 (within 3 min)" wait_for "domain free" 180 10 val_is "sum(oif:domain_gpu_in_use{domain=\"$d\"})" 0

# Grafana serves the new row
host=grafana.$(runai_domain); ip=$(first_ip "$METALLB_RANGE")
netrc=$(mktemp); chmod 600 "$netrc"; printf 'machine %s login admin password %s\n' "$host" "$GRAFANA_ADMIN_PASSWORD" > "$netrc"
titles=$(curl -fsS -m 20 --netrc-file "$netrc" --cacert "$PKI/ca.crt" --resolve "$host:443:$ip" "https://$host/api/dashboards/uid/oif-scheduling" 2>/dev/null \
  | python3 -c 'import json, sys; print("\n".join(p.get("title", "") for p in json.load(sys.stdin)["dashboard"]["panels"]))'); rm -f "$netrc"
for t in "Accelerator domains and AIJobs" "GPUs per accelerator domain" "AIJob GPUs by vendor" "AIJobs on more than one vendor"; do
  check "Grafana: OIF Scheduling has \"$t\"" grep -qxF "$t" <<< "$titles"
done

echo "T-135: $((N - FAILS))/$N checks passed"
[ "$FAILS" = 0 ]
