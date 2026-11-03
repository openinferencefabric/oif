#!/bin/bash
# Acceptance test for T-201 (Dynamo platform in oif install), run on the first node after  sudo ./oif install  on a
# multi-node cluster with an NVIDIA GPU node in pool nvidia and project team-c (NVIDIA quota 1 GPU, nothing running).
# Creates two Dynamo deployments in team-c's namespace (the S-4 deployment, tests/lab/s4-dynamo-agg.yaml) and deletes
# them at the end. The first start pulls Dynamo's vLLM image (about 20 GB) unless the node has it.
#   sudo tests/lab/t201-dynamo.sh                 platform, then a deployment submitted with kubectl: Run:ai lists it,
#                                                 KAI places it in pool nvidia, chat works, a second one waits on quota
#   sudo tests/lab/t201-dynamo.sh --platform      the platform checks only (read-only)
#   sudo tests/lab/t201-dynamo.sh --expect-off    after DYNAMO=none in .env and  sudo ./oif install --reconfigure
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); OIF_HOME=$ROOT; SELF=$ROOT/oif
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 2; }
# shellcheck source=../../versions.env
. "$ROOT/versions.env"
for f in "$ROOT"/installer/lib/*.sh "$ROOT"/installer/stages/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done
INTERACTIVE=0; TLOG=/dev/null
config_load_saved
MODE=${1:-}
NS=runai-team-c; A=t201-qwen; B=t201-qwen-2; PORT=18000

FAILS=0; N=0
check() { N=$((N + 1)); if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi; }
info() { echo "  INFO  $*"; }
finish_() { echo "T-201: $((N - FAILS))/$N checks passed"; [ "$FAILS" = 0 ]; exit $?; }

# ---------------------------------------------------------------- DYNAMO=none: nothing of Dynamo left
if [ "$MODE" = --expect-off ]; then
  echo "T-201 Dynamo off (DYNAMO=none)"
  check "no Helm release $DYNAMO_RELEASE" bash -c "! helm --kubeconfig $KCFG -n $DYNAMO_NS status $DYNAMO_RELEASE"
  for c in $DYNAMO_CRDS; do check "no CRD $c.nvidia.com" bash -c "! kubectl --kubeconfig $KCFG get crd $c.nvidia.com"; done
  check "no namespace $DYNAMO_NS" bash -c "! kubectl --kubeconfig $KCFG get namespace $DYNAMO_NS"
  finish_
fi

# ---------------------------------------------------------------- the platform
echo "T-201 Dynamo $DYNAMO_VERSION platform"
check "Helm release $DYNAMO_RELEASE deployed in $DYNAMO_NS" bash -c "helm --kubeconfig $KCFG -n $DYNAMO_NS status $DYNAMO_RELEASE | grep -q 'STATUS: deployed'"
check "chart version $DYNAMO_VERSION" bash -c "helm --kubeconfig $KCFG -n $DYNAMO_NS list -o json | grep -q '\"chart\":\"dynamo-platform-$DYNAMO_VERSION\"'"
for c in $DYNAMO_CRDS; do check "CRD $c.nvidia.com" kc get crd "$c.nvidia.com"; done
check "operator available" kc -n "$DYNAMO_NS" wait deploy --all --for=condition=Available --timeout=60s
check "no Grove or bundled KAI running" bash -c "[ -z \"\$(kubectl --kubeconfig $KCFG -n $DYNAMO_NS get deploy,statefulset,daemonset -o name | grep -Ei 'grove|kai')\" ]"
check "oif's values in use (bundled KAI off)" bash -c "helm --kubeconfig $KCFG -n $DYNAMO_NS get values $DYNAMO_RELEASE -o json | python3 -c 'import json,sys; g=json.load(sys.stdin)[\"global\"]; sys.exit(g[\"kai-scheduler\"][\"install\"] or g[\"grove\"][\"install\"])'"
[ "$MODE" = --platform ] && finish_

# ---------------------------------------------------------------- a deployment through kubectl, under Run:ai
submit() {   # name: the S-4 deployment under another name, applied to team-c's namespace
  sed "s/^  name: s4-qwen\$/  name: $1/" "$ROOT/tests/lab/s4-dynamo-agg.yaml" | kc -n "$NS" apply -f -; }
pods_of() { kc -n "$NS" get pods -o wide -L runai/node-pool --no-headers 2>/dev/null | grep -E "^$1-(frontend|worker)-"; }
on_nvidia() {   # pod: in pool nvidia (its label) on a node of that pool (oif.ai/gpu-vendor=nvidia)
  local n; n=$(kc -n "$NS" get pod "$1" -o jsonpath='{.spec.nodeName}')
  [ "$(kc -n "$NS" get pod "$1" -o jsonpath='{.metadata.labels.runai/node-pool}')" = nvidia ] \
    && [ "$(kc get node "$n" -o jsonpath='{.metadata.labels.oif\.ai/gpu-vendor}')" = nvidia ]; }
phase() { kc -n "$NS" get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
pod_of() {   # deployment component(frontend|worker): its pod's name
  kc -n "$NS" get pods -o name 2>/dev/null | sed -n "s|^pod/\($1-$2-.*\)|\1|p" | head -1; }
cleanup() { kc -n "$NS" delete dynamographdeployment "$A" "$B" --ignore-not-found --wait=true >/dev/null 2>&1; }
trap cleanup EXIT

multi_node || { echo "the deployment test needs a multi-node install with pool nvidia (OIF_NODES)"; exit 2; }
used=$(kc -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c Running)
[ "$used" = 0 ] || { echo "team-c already runs $used pod(s): stop them first (the test needs its NVIDIA quota free)"; exit 2; }
cleanup

echo "T-201 a Dynamo deployment submitted with kubectl to project team-c"
check "deployment $A accepted" submit "$A"
wl=""; for _ in $(seq 18); do wl=$(runai_api workloads 2>/dev/null | grep "^$A "); [ -n "$wl" ] && break; sleep 10; done
info "Run:ai: ${wl:-not listed after 3 min}"
listed() { [[ $wl =~ ^$A\ DynamoGraphDeployment\ [^\ ]+\ team-c$ ]]; }
check "Run:ai lists $A as a DynamoGraphDeployment in team-c" listed
echo "  ...   waiting for the worker (first start pulls the image and the model, up to 25 min)"
wait_for "$A worker running" 1500 15 bash -c "kubectl --kubeconfig $KCFG -n $NS get pods --no-headers | grep '^$A-worker-' | grep -q ' 1/1 .*Running'" >/dev/null 2>&1
pods_of "$A" | sed 's/^/        /'
w=$(pod_of "$A" worker); fe=$(pod_of "$A" frontend)
check "worker running" test "$(phase "$w")" = Running
check "worker in pool nvidia, on an NVIDIA node" on_nvidia "$w"
check "worker scheduled by Run:ai's KAI (pod group)" bash -c "kubectl --kubeconfig $KCFG -n $NS get podgroups -o name | grep -q 'pg-$A-worker-'"
check "frontend in pool nvidia too (per-pod label)" on_nvidia "$fe"

kc -n "$NS" port-forward "svc/$A-frontend" "$PORT:8000" >/dev/null 2>&1 & pf=$!
sleep 5
reply=$(python3 - "$PORT" <<'PY'
import json, sys, urllib.request
port = sys.argv[1]
body = {"model": "Qwen/Qwen3-0.6B", "messages": [{"role": "user", "content": "Say hello in five words."}], "max_tokens": 40}
req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", json.dumps(body).encode(), {"Content-Type": "application/json"})
try:
    out = json.load(urllib.request.urlopen(req, timeout=120))
    print(out["usage"]["completion_tokens"], out["choices"][0]["message"]["content"][:80].replace("\n", " "))
except Exception as e:
    print("error", e)
PY
)
kill "$pf" 2>/dev/null
info "chat: $reply"
answered() { [[ $reply =~ ^[1-9][0-9]*\  ]]; }   # completion tokens, then the text
check "chat completion through the Dynamo frontend" answered

echo "T-201 a second deployment over team-c's quota"
check "deployment $B accepted" submit "$B"
wait_for "$B worker refused by the scheduler" 240 10 bash -c "kubectl --kubeconfig $KCFG -n $NS get events | grep '$B-worker' | grep -q OverQuota" >/dev/null 2>&1
ev=$(kc -n "$NS" get events 2>/dev/null | grep "$B-worker" | grep -o 'NonPreemptibleOverQuota[^.]*' | head -1)
info "scheduler: ${ev:-no over-quota event}"
w2=$(pod_of "$B" worker)
check "$B worker waits (Pending)" test "$(phase "$w2")" = Pending
check "reason: over quota" test -n "$ev"
check "$A still serves" test "$(phase "$w")" = Running

cleanup
check "both deployments deleted" bash -c "[ -z \"\$(kubectl --kubeconfig $KCFG -n $NS get dynamographdeployments --no-headers 2>/dev/null)\" ]"
finish_
