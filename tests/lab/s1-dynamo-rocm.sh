#!/bin/bash
# Spike S-1 (ADR-002): Dynamo on ROCm. Run on the first node after  sudo ./oif install  on the multi-node cluster
# (Dynamo platform installed, T-201) with the W7900 in pool amd and project team-c (AMD quota 1 GPU, nothing running).
# Creates Dynamo deployment s1-qwen in team-c's namespace (tests/lab/s1-dynamo-rocm.yaml: vLLM's ROCm image with
# Dynamo's wheels added at start) and a load Job in namespace oif-s1; deletes both at the end. The first start pulls
# the ROCm vLLM image (about 12 GB) and the model.
#   sudo tests/lab/s1-dynamo-rocm.sh            all: deployment, chat (plain and streaming), 10 min AIPerf at 8
#   sudo tests/lab/s1-dynamo-rocm.sh --short    AIPerf for 1 minute (a quick check; the spike needs the full run)
#   sudo tests/lab/s1-dynamo-rocm.sh --keep     leave the deployment running afterwards (delete it by hand:
#                                               kubectl -n runai-team-c delete dynamographdeployment s1-qwen)
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
DURATION=600; KEEP=0
for a in "$@"; do case $a in --short) DURATION=60 ;; --keep) KEEP=1 ;; *) echo "unknown option $a"; exit 2 ;; esac; done
NS=runai-team-c; A=s1-qwen; LOADNS=oif-s1; PORT=18001; MODEL=Qwen/Qwen3-0.6B

FAILS=0; N=0
check() { N=$((N + 1)); if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi; }
info() { echo "  INFO  $*"; }
phase() { kc -n "$NS" get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
pod_of() { kc -n "$NS" get pods -o name 2>/dev/null | sed -n "s|^pod/\($A-$1-.*\)|\1|p" | head -1; }
on_amd() {   # pod: in pool amd (its label) on a node of that pool (oif.ai/gpu-vendor=amd)
  local n; n=$(kc -n "$NS" get pod "$1" -o jsonpath='{.spec.nodeName}')
  [ "$(kc -n "$NS" get pod "$1" -o jsonpath='{.metadata.labels.runai/node-pool}')" = amd ] \
    && [ "$(kc get node "$n" -o jsonpath='{.metadata.labels.oif\.ai/gpu-vendor}')" = amd ]; }
cleanup() {
  [ "$KEEP" = 1 ] || kc -n "$NS" delete dynamographdeployment "$A" --ignore-not-found --wait=true >/dev/null 2>&1
  kc delete namespace "$LOADNS" --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup EXIT

multi_node || { echo "S-1 needs the multi-node install with pool amd (OIF_NODES)"; exit 2; }
kc get crd dynamographdeployments.nvidia.com >/dev/null 2>&1 || { echo "Dynamo platform not installed (T-201)"; exit 2; }
used=$(kc -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -v "^$A-" | grep -c Running)
[ "$used" = 0 ] || { echo "team-c already runs $used pod(s): stop them first (the test needs its AMD quota free)"; exit 2; }
KEEP=0 cleanup

echo "S-1 Dynamo $DYNAMO_VERSION on ROCm: $VLLM_ROCM_IMAGE"
submit() { sed -e "s|__NAME__|$A|" -e "s|__IMAGE__|$VLLM_ROCM_IMAGE|" "$ROOT/tests/lab/s1-dynamo-rocm.yaml" | kc -n "$NS" apply -f -; }
check "deployment $A accepted" submit
wl=""; for _ in $(seq 18); do wl=$(runai_api workloads 2>/dev/null | grep "^$A "); [ -n "$wl" ] && break; sleep 10; done
info "Run:ai: ${wl:-not listed after 3 min}"
listed() { [[ $wl =~ ^$A\ DynamoGraphDeployment\ [^\ ]+\ team-c$ ]]; }
check "Run:ai lists $A as a DynamoGraphDeployment in team-c" listed

echo "  ...   waiting for the worker (first start pulls the image and the model, installs Dynamo; up to 40 min)"
wait_for "$A worker ready" 2400 15 bash -c "kubectl --kubeconfig $KCFG -n $NS get pods --no-headers | grep '^$A-worker-' | grep -q ' 1/1 .*Running'" >/dev/null 2>&1
kc -n "$NS" get pods -o wide -L runai/node-pool --no-headers 2>/dev/null | grep "^$A-" | sed 's/^/        /'
w=$(pod_of worker); fe=$(pod_of frontend)
for c in frontend worker; do
  p=$(pod_of "$c"); [ -n "$p" ] || continue
  kc -n "$NS" logs "$p" 2>/dev/null | grep -E '^S1-' | sed "s/^/        $c: /"
done
vers=$(kc -n "$NS" logs "$w" 2>/dev/null | grep '^S1-VERSIONS' | tail -1)
restarts=$(kc -n "$NS" get pod "$w" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
info "worker restarts: ${restarts:-?}"
rocm_stack() {   # vLLM may carry a local version (0.31.0+rocm...)
  local re_vllm=' vllm=0\.31\.0[+ ]'
  [[ $vers =~ hip=[0-9] && $vers =~ $re_vllm && $vers == *" dynamo=$DYNAMO_VERSION "* && $vers == *unchanged=yes* ]]; }
check "worker running" test "$(phase "$w")" = Running
check "worker: ROCm torch (HIP), vLLM 0.31.0, Dynamo $DYNAMO_VERSION, engine stack unchanged by the install" rocm_stack
check "worker in pool amd, on the AMD node" on_amd "$w"
check "worker holds amd.com/gpu 1" test "$(kc -n "$NS" get pod "$w" -o jsonpath='{.spec.containers[0].resources.limits.amd\.com/gpu}')" = 1
check "worker scheduled by Run:ai's KAI (pod group)" bash -c "kubectl --kubeconfig $KCFG -n $NS get podgroups -o name | grep -q 'pg-$A-worker-'"
check "frontend in pool amd too" on_amd "$fe"

kc -n "$NS" port-forward "svc/$A-frontend" "$PORT:8000" >/dev/null 2>&1 & pf=$!
sleep 5
out=$(python3 - "$PORT" "$MODEL" <<'PY'
import json, sys, time, urllib.request
port, model = sys.argv[1], sys.argv[2]
base = f"http://127.0.0.1:{port}/v1"
def post(path, body, timeout=180):
    return urllib.request.urlopen(urllib.request.Request(base + path, json.dumps(body).encode(), {"Content-Type": "application/json"}), timeout=timeout)
models = []
for _ in range(24):   # the worker registers with the frontend shortly after it is ready
    try:
        models = [m["id"] for m in json.load(urllib.request.urlopen(base + "/models", timeout=10))["data"]]
    except Exception:
        pass
    if model in models:
        break
    time.sleep(5)
print("models", " ".join(models) or "-")
msg = [{"role": "user", "content": "Say hello in five words."}]
try:
    out = json.load(post("/chat/completions", {"model": model, "messages": msg, "max_tokens": 40}))
    print("chat", out["usage"]["completion_tokens"], out["choices"][0]["message"]["content"][:80].replace("\n", " "))
except Exception as e:
    print("chat error", e)
try:
    chunks, done, text = 0, False, ""
    for line in post("/chat/completions", {"model": model, "messages": msg, "max_tokens": 40, "stream": True}):
        line = line.decode().strip()
        if line == "data: [DONE]":
            done = True
        elif line.startswith("data: "):
            chunks += 1
            for c in json.loads(line[6:]).get("choices", []):
                text += (c.get("delta") or {}).get("content") or ""
    print("stream", chunks, "done" if done else "no-done", text[:60].replace("\n", " "))
except Exception as e:
    print("stream error", e)
PY
)
kill "$pf" 2>/dev/null
sed 's/^/        /' <<< "$out"
check "worker registered: frontend lists $MODEL" grep -q "^models .*$MODEL" <<< "$out"
check "chat completion through the Dynamo frontend" grep -qE '^chat [1-9][0-9]* ' <<< "$out"
check "streaming chat: several chunks and [DONE]" grep -qE '^stream ([2-9]|[1-9][0-9]+) done' <<< "$out"

echo "S-1 AIPerf $AIPERF_VERSION: concurrency 8 for $DURATION s (chat, streaming)"
kc create namespace "$LOADNS" >/dev/null 2>&1
kc -n "$LOADNS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: aiperf}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      nodeSelector: {oif.ai/gpu-vendor: amd}   # the image is already on that node
      tolerations: [{operator: Exists}]
      containers:
        - name: aiperf
          image: $VLLM_ROCM_IMAGE
          env: [{name: PIP_BREAK_SYSTEM_PACKAGES, value: "1"}, {name: PIP_ROOT_USER_ACTION, value: ignore}]
          command: [bash, -c]
          args:
            - |
              set -e
              python3 -m venv /tmp/ap && /tmp/ap/bin/pip install -q aiperf==$AIPERF_VERSION
              /tmp/ap/bin/aiperf profile --model $MODEL --url http://$A-frontend.$NS.svc.cluster.local:8000 \
                --endpoint-type chat --streaming --concurrency 8 --benchmark-duration $DURATION \
                --isl 128 --output-tokens-mean 128 --artifact-dir /tmp/out > /tmp/console.txt 2>&1 \
                || { tail -40 /tmp/console.txt; exit 1; }
              tail -30 /tmp/console.txt
              python3 - <<'PY'
              import glob, json
              f = (glob.glob("/tmp/out/**/profile_export_aiperf.json", recursive=True) or [None])[0]
              d = json.load(open(f)) if f else {}
              def stat(k, s="avg"):
                  v = d.get(k)
                  if isinstance(v, dict):
                      return v.get(s, v.get("avg"))
                  return v
              errs = stat("error_request_count") or 0
              summ = d.get("error_summary") or []
              print("S1-AIPERF requests=%s errors=%s error_kinds=%d throughput_rps=%s ttft_p50_ms=%s itl_p50_ms=%s tokens_per_s=%s" % (
                  stat("request_count"), errs, len(summ), stat("request_throughput"), stat("time_to_first_token", "p50"),
                  stat("inter_token_latency", "p50"), stat("output_token_throughput")))
              if not d:
                  print("S1-AIPERF no export file")
              PY
EOF
wait_for "AIPerf finished" $((DURATION + 900)) 15 bash -c "kubectl --kubeconfig $KCFG -n $LOADNS get job aiperf -o jsonpath='{.status.conditions[*].type}' | grep -qE 'Complete|Failed'" >/dev/null 2>&1
log=$(kc -n "$LOADNS" logs job/aiperf 2>/dev/null)
tail -32 <<< "$log" | sed 's/^/        /'
res=$(grep '^S1-AIPERF requests=' <<< "$log" | tail -1)
check "AIPerf Job completed" bash -c "kubectl --kubeconfig $KCFG -n $LOADNS get job aiperf -o jsonpath='{.status.succeeded}' | grep -qx 1"
no_errors() { [[ $res =~ requests=[1-9] && $res =~ \ errors=0(\.0)?\  && $res == *" error_kinds=0 "* ]]; }
check "AIPerf: requests served, 0 errors" no_errors
check "worker did not restart under load" test "$(kc -n "$NS" get pod "$w" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)" = "${restarts:-x}"

cleanup
[ "$KEEP" = 1 ] && info "deployment $A left running (--keep)"
echo "S-1: $((N - FAILS))/$N checks passed$([ "$DURATION" = 600 ] || echo " (--short: not the spike's 10-minute run)")"
[ "$FAILS" = 0 ]
