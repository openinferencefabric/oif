#!/bin/bash
# oif bench: Dynamo against the plain engine it is built on, on the GPU of this node, with AIPerf (ADR-006).
#
#   ./oif bench gpus                   list the GPUs on this node (name, PCI address, memory, usable or why not)
#   sudo ./oif bench [run] [options]   benchmark on this GPU node (plain containers, no Kubernetes in the request path)
#        --gpu N|PCI                   which GPU (number or PCI address from oif bench gpus); asked when not given
#        --profile NAME                bench/profiles/NAME.env: full (default: 4 workloads x 7 concurrencies x 3 repeats), quick, attrib, prefill, decode (B-3a; -8b for Qwen3-8B)
#        --stacks "vllm dynamo-vllm sglang dynamo-sglang"   default: every stack with an image in versions.env
#        --models "Qwen/Qwen3-0.6B Qwen/Qwen3-8B"           Hugging Face ids, asked when not given (Enter keeps the
#                                      default); HF_TOKEN in the environment for gated models
#        --repeats N                   override the profile's repeats (order of the stacks flips every repeat)
#        --out DIR                     default /var/tmp/oif-bench/<date>
#        --trace                       B-1b: per point, CPU of every server process, py-spy profiles of its Python
#                                      processes and the server's /metrics before and after; summary by bench/attrib.py.
#                                      Profiling costs time on the server: use traced points for where time goes only
#   ./oif bench report DIR             rebuild DIR/report.html from DIR/results.jsonl
#
#   stack            image on AMD / on NVIDIA (versions.env)          server
#   vllm             BENCH_VLLM_IMAGE / BENCH_VLLM_CUDA_IMAGE         vllm serve
#   dynamo-vllm      DYNAMO_ROCM_IMAGE / DYNAMO_CUDA_IMAGE            dynamo.frontend + dynamo.vllm worker (aggregated),
#                                                                     FROM the vllm image of the same vendor
#   sglang           BENCH_SGLANG_IMAGE / -                           sglang.launch_server (S-5)
#   dynamo-sglang    DYNAMO_SGLANG_ROCM_IMAGE / -                     dynamo.frontend + dynamo.sglang worker (T-212)
#   vllm-api4        as vllm                                          vllm serve --api-server-count 4 (B-1b, only when
#                                                                     named in --stacks)
#   vllm-rs          as vllm                                          vllm serve with vLLM's Rust frontend,
#                                                                     VLLM_USE_RUST_FRONTEND=1 (B-1b, ditto)
# Each Dynamo image is built FROM its engine image, so engine, torch and ROCm match; the difference measured is
# Dynamo's frontend, request plane and worker wrapper. Same engine arguments within a pair, same AIPerf prompts
# (fixed seed), exact output lengths (ignore_eos), GPU below BENCH_MAX_START_TEMP_C before every point (ADR-009).
# Every server listens on 127.0.0.1 only (host network, nothing reachable from outside the node).
# GPUs: AMD on the amdgpu driver (ROCm stacks), NVIDIA on the nvidia driver with a CDI device (CUDA stacks, B-2). Only
# the chosen GPU is passed to the containers; a GPU with a monitor connected is never offered.
set -uo pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd); ROOT=$(dirname "$HERE")
# shellcheck source=../versions.env
. "$ROOT/versions.env"

say() { echo "== $*"; }
die() { echo "oif bench: $*" >&2; exit 1; }
usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }

cmd=run; case ${1:-} in run) shift ;; report) cmd=report; shift ;; gpus) exec python3 "$HERE/gpus.py" ;; help|-h|--help) usage; exit 0 ;; esac
if [ $cmd = report ]; then [ -d "${1:-}" ] || die "report needs a result directory"; exec python3 "$HERE/report.py" "$1"; fi

GPU_SEL=""; MODELS=""; TRACE=0; DEFAULT_MODELS="Qwen/Qwen3-0.6B Qwen/Qwen3-8B"; STACKS="vllm dynamo-vllm sglang dynamo-sglang"; PROFILE=full; REPEATS=""
OUT=/var/tmp/oif-bench/$(date +%Y%m%d-%H%M)
HF_HOME_HOST=${HF_HOME_HOST:-/var/tmp/oif-bench/hf}
PORT=8000; MAXT=${BENCH_MAX_START_TEMP_C:-60}

while [ $# -gt 0 ]; do case $1 in
  --profile) PROFILE=$2; shift 2 ;; --models) MODELS=$2; shift 2 ;; --stacks) STACKS=$2; shift 2 ;;
  --repeats) REPEATS=$2; shift 2 ;; --out) OUT=$2; shift 2 ;; --gpu) GPU_SEL=$2; shift 2 ;; --trace) TRACE=1; shift ;;
  *) die "unknown option $1 (oif bench help)" ;; esac; done
[ -f "$HERE/profiles/$PROFILE.env" ] || die "no profile $PROFILE in bench/profiles"
# shellcheck source=/dev/null
. "$HERE/profiles/$PROFILE.env"
WORKLOADS=$BENCH_WORKLOADS; CONCS=$BENCH_CONCURRENCY; DUR=$BENCH_DURATION_S; REPEATS=${REPEATS:-$BENCH_REPEATS}
CTX=${BENCH_CTX:-8192}  # server context; a profile with longer prompts raises it (B-3a prefill)
VLLM_ARGS="--max-model-len $CTX --gpu-memory-utilization 0.90 --max-num-seqs 256 --seed 0"
# SGLang on gfx1100: no aiter (Instinct-only), Triton attention (S-5 settles the exact flags).
SGLANG_ARGS="--context-length $CTX --mem-fraction-static 0.85 --max-running-requests 256 --random-seed 0 --attention-backend triton --sampling-backend pytorch"
# B-1a: one oif bench per node (ADR-009: one GPU under load at a time; the server has one fixed port). The lock file
# holds the PID of the run that has it; containers never inherit it (ct closes fd 8), so it ends with this script.
LOCK=${BENCH_LOCK:-/run/lock/oif-bench.lock}
exec 8<>"$LOCK" || die "cannot open the lock file $LOCK"
flock -n 8 || die "another oif bench is running on this node (PID $(tr -dc 0-9 < "$LOCK")): one GPU under load at a time (ADR-009); wait for it to end or stop it"
echo $$ > "$LOCK"
[ "$(id -u)" = 0 ] || die "run with sudo"

image_of() { case $VENDOR:$1 in  # VENDOR is set once the GPU is chosen
  AMD:vllm|AMD:vllm-api4|AMD:vllm-rs) echo "${BENCH_VLLM_IMAGE:-}" ;; AMD:dynamo-vllm) echo "${DYNAMO_ROCM_IMAGE:-}" ;;
  AMD:sglang) echo "${BENCH_SGLANG_IMAGE:-}" ;; AMD:dynamo-sglang) echo "${DYNAMO_SGLANG_ROCM_IMAGE:-}" ;;
  NVIDIA:vllm|NVIDIA:vllm-api4|NVIDIA:vllm-rs) echo "${BENCH_VLLM_CUDA_IMAGE:-}" ;; NVIDIA:dynamo-vllm) echo "${DYNAMO_CUDA_IMAGE:-}" ;;
  NVIDIA:sglang|NVIDIA:dynamo-sglang) echo "" ;;
  *) die "unknown stack $1" ;; esac; }

# ---------------------------------------------------------------- preflight
CT=$(command -v docker || command -v podman) || die "no docker or podman: sudo apt-get install -y podman"
ct() { "$CT" "$@" 8>&-; }   # the container runtime, without the lock
say "oif bench, profile $PROFILE ($REPEATS repeat(s)), stacks: $STACKS, runtime $CT"
# ---------------------------------------------------------------- GPU: list this node's GPUs, ask which one
export BENCH_MIN_VRAM_GIB
mapfile -t GPUS < <(python3 "$HERE/gpus.py" --json)
[ ${#GPUS[@]} -gt 0 ] || die "no AMD or NVIDIA GPU found on this node"
echo "   GPUs on this node:"; python3 "$HERE/gpus.py" | sed 's/^/   /'
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]) or "")' "$1" "$2"; }
pick() {  # number or PCI address -> the GPU's JSON line
  local g; for g in "${GPUS[@]}"; do
    [ "$(field "$g" index)" = "$1" ] || [[ "$(field "$g" pci)" == *"$1" ]] && { echo "$g"; return 0; }
  done; return 1; }
if [ -z "$GPU_SEL" ]; then
  [ -t 0 ] || die "choose the GPU with --gpu N|PCI (see the list above); a detached run cannot ask"
  read -rp "   Which GPU should oif bench use? Number from the list: " GPU_SEL
fi
if [ -z "$MODELS" ]; then
  if [ -t 0 ]; then
    read -rp "   Which model(s)? Hugging Face ids, space-separated [$DEFAULT_MODELS]: " MODELS
  fi
  MODELS=${MODELS:-$DEFAULT_MODELS}
fi
say "models: $MODELS"
G=$(pick "$GPU_SEL") || die "no GPU $GPU_SEL in the list"
[ "$(field "$G" usable)" = True ] || die "GPU $GPU_SEL ($(field "$G" name)) cannot be used: $(field "$G" why_not)"
gpu=$(field "$G" sysfs); GPU_NAME=$(field "$G" name); VENDOR=$(field "$G" vendor); UUID=$(field "$G" uuid)
CARD=/dev/dri/$(field "$G" card); DEVNODE=$(field "$G" dev)   # DEVNODE: held open only by the GPU's users
hw=$(ls -d "$gpu"/hwmon/hwmon* 2>/dev/null | head -1)
say "GPU: $GPU_NAME ($VENDOR) at $(field "$G" pci), $(field "$G" vram_gib) GiB ($DEVNODE)"
use=""; for s in $STACKS; do
  if [ -n "$(image_of "$s")" ]; then use="$use $s"; else echo "   skip $s: no $VENDOR image pinned in versions.env"; fi
done
STACKS=${use# }; [ -n "$STACKS" ] || die "no stack to run"
command -v fuser >/dev/null || die "fuser missing (apt-get install -y psmisc)"
if fuser "$DEVNODE" >/dev/null 2>&1; then
  die "something already uses this GPU ($DEVNODE, pids$(fuser "$DEVNODE" 2>/dev/null)): stop it first (e.g. systemctl stop kubelet)"
fi
mkdir -p "$OUT"/{raw,logs} "$HF_HOME_HOST"
free_gb=$(df -BG --output=avail "$(dirname "$OUT")" | tail -1 | tr -dc 0-9)
[ "$free_gb" -ge 60 ] || die "need 60 GB free next to $OUT, have ${free_gb} GB"

say "pull images"
for s in $STACKS; do
  ct pull -q "$(image_of "$s")" >/dev/null || die "pull $(image_of "$s") failed (network, or a private registry needing $CT login)"
  echo "   $s"
done
if [ "$VENDOR" = NVIDIA ]; then  # the GPU by its CDI name (nvidia-ctk cdi generate), nothing else of the host's GPUs
  GPU_FLAGS=(--device "nvidia.com/gpu=$UUID" --ipc host --network host)
else
  GPU_FLAGS=(--device /dev/kfd --device "$CARD" --device "$DEVNODE" --group-add video --ipc host
             --security-opt seccomp=unconfined --network host)
  getent group render >/dev/null && GPU_FLAGS+=(--group-add "$(getent group render | cut -d: -f3)")
fi
HF_FLAGS=(-v "$HF_HOME_HOST:/hf" -e HF_HOME=/hf)
[ -n "${HF_TOKEN:-}" ] && HF_FLAGS+=(-e HF_TOKEN)

say "versions inside each image"
: > "$OUT/images.jsonl"
for s in $STACKS; do
  img=$(image_of "$s")
  inside=$(ct run --rm --entrypoint python3 "$img" -c '
import importlib.metadata as m, json, torch
d = {"torch": torch.__version__, "hip": torch.version.hip, "cuda": torch.version.cuda}
for p in ("vllm", "sglang", "sgl-kernel", "sglang-kernel", "ai-dynamo", "ai-dynamo-runtime", "triton", "transformers"):
    try: d[p] = m.version(p)
    except Exception: pass
try:
    import os, vllm; d["vllm_rs"] = os.access(os.path.join(os.path.dirname(vllm.__file__), "vllm-rs"), os.X_OK)
except Exception: pass
print(json.dumps(d))' 2>/dev/null) || inside=null
  digest=$(ct image inspect "$img" --format '{{index .RepoDigests 0}}' 2>/dev/null)
  echo "{\"stack\":\"$s\",\"image\":\"$img\",\"digest\":\"$digest\",\"inside\":${inside:-null}}" >> "$OUT/images.jsonl"
  echo "   $s: $inside"
  if [ "$s" = vllm-rs ] && ! grep -q '"vllm_rs": true' <<< "$inside"; then
    echo "   skip vllm-rs: the image has no vllm-rs binary (vLLM's Rust frontend is not built into it)"; drop="${drop:-} $s"
  fi
done
for s in ${drop:-}; do STACKS=$(tr ' ' '\n' <<< "$STACKS" | grep -vx "$s" | xargs); done
[ -n "$STACKS" ] || die "no stack to run"
rd() { cat "$1" 2>/dev/null || true; }
nv() { nvidia-smi -i "$UUID" --query-gpu="$1" --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' '; }
if [ "$VENDOR" = NVIDIA ]; then
  v=$(nv memory.total | cut -d. -f1); vram_total=$(( ${v:-0} * 1048576 )); power_cap=$(nv power.limit | cut -d. -f1)
  drv="nvidia $(nv driver_version)"
else
  vram_total=$(rd "$gpu/mem_info_vram_total"); v=$(rd "$hw/power1_cap"); power_cap=$(( ${v:-0} / 1000000 ))
  drv="amdgpu $(rd /sys/module/amdgpu/version)"
fi
python3 - "$OUT/env.json" <<PY
import json, os, platform, sys
env = {"oif_version": "${OIF_VERSION:-}", "kernel": platform.release(), "cpus": os.cpu_count(),
       "driver": "$drv", "gpu": "$GPU_NAME", "gpu_vendor": "$VENDOR", "gpu_pci": "$(field "$G" pci)",
       "vram_total_bytes": int("${vram_total:-0}" or 0),
       "power_cap_w": int("${power_cap:-0}" or 0), "max_start_temp_c": $MAXT,
       "profile": "$PROFILE", "repeats": $REPEATS, "duration_s": $DUR, "aiperf": "$AIPERF_VERSION",
       "workloads": "$WORKLOADS".split(), "concurrency": [int(c) for c in "$CONCS".split()], "models": "$MODELS".split(),
       "vllm_args": "$VLLM_ARGS", "sglang_args": "$SGLANG_ARGS", "trace": $TRACE, "stacks": "$STACKS".split(),
       "images": [json.loads(l) for l in open("$OUT/images.jsonl")]}
json.dump(env, open(sys.argv[1], "w"), indent=1)
PY

say "models into $HF_HOME_HOST"
first=$(image_of "${STACKS%% *}")
for m in $MODELS; do
  ct run --rm "${HF_FLAGS[@]}" --entrypoint bash "$first" -c \
    "if command -v hf >/dev/null; then hf download $m >/dev/null; else huggingface-cli download $m >/dev/null; fi" \
    || die "download $m failed"
  echo "   $m"
done

say "AIPerf $AIPERF_VERSION (venv in $OUT)"
ct run --rm -v "$OUT:/out" --entrypoint bash "$first" -c \
  "python3 -m venv /out/aiperf-venv && /out/aiperf-venv/bin/pip install -q aiperf==$AIPERF_VERSION" \
  > "$OUT/logs/aiperf-install.log" 2>&1 || die "aiperf install failed: $OUT/logs/aiperf-install.log"
if [ "$TRACE" = 1 ]; then
  say "py-spy $PYSPY_VERSION (venv in $OUT, for --trace)"
  ct run --rm -v "$OUT:/out" --entrypoint bash "$first" -c \
    "python3 -m venv /out/tools-venv && /out/tools-venv/bin/pip install -q py-spy==$PYSPY_VERSION" \
    > "$OUT/logs/py-spy-install.log" 2>&1 || die "py-spy install failed: $OUT/logs/py-spy-install.log"
fi

# ---------------------------------------------------------------- server control
stop_server() { ct rm -f oifb-srv >/dev/null 2>&1; for _ in $(seq 30); do fuser "$DEVNODE" >/dev/null 2>&1 || return 0; sleep 2; done; }
start_server() {  # stack model
  local s=$1 m=$2 img; img=$(image_of "$1")
  local dyn=(-e DYN_DISCOVERY_BACKEND=file -e DYN_FILE_KV=/tmp/dynamo_kv -e DYN_REQUEST_PLANE=tcp -e DYN_SYSTEM_PORT=8081
             -e DYN_SYSTEM_HOST=127.0.0.1 -e DYN_TCP_RPC_HOST=127.0.0.1 -e DYN_TCP_RESPONSE_STREAM_HOST=127.0.0.1)
  stop_server
  case $s in
    vllm)          ct run -d --name oifb-srv "${GPU_FLAGS[@]}" "${HF_FLAGS[@]}" --entrypoint bash "$img" -c \
                     "exec vllm serve $m --host 127.0.0.1 --port $PORT $VLLM_ARGS" ;;
    vllm-api4)     ct run -d --name oifb-srv "${GPU_FLAGS[@]}" "${HF_FLAGS[@]}" --entrypoint bash "$img" -c \
                     "exec vllm serve $m --host 127.0.0.1 --port $PORT --api-server-count 4 $VLLM_ARGS" ;;
    vllm-rs)       ct run -d --name oifb-srv "${GPU_FLAGS[@]}" "${HF_FLAGS[@]}" -e VLLM_USE_RUST_FRONTEND=1 --entrypoint bash "$img" -c \
                     "exec vllm serve $m --host 127.0.0.1 --port $PORT $VLLM_ARGS" ;;
    dynamo-vllm)   ct run -d --name oifb-srv "${GPU_FLAGS[@]}" "${HF_FLAGS[@]}" "${dyn[@]}" --entrypoint bash "$img" -c \
                     "python3 -m dynamo.frontend --http-host 127.0.0.1 --http-port $PORT & exec python3 -m dynamo.vllm --model $m $VLLM_ARGS" ;;
    sglang)        ct run -d --name oifb-srv "${GPU_FLAGS[@]}" "${HF_FLAGS[@]}" -e SGLANG_USE_AITER=0 --entrypoint bash "$img" -c \
                     "exec python3 -m sglang.launch_server --model-path $m --host 127.0.0.1 --port $PORT $SGLANG_ARGS" ;;
    dynamo-sglang) ct run -d --name oifb-srv "${GPU_FLAGS[@]}" "${HF_FLAGS[@]}" "${dyn[@]}" -e SGLANG_USE_AITER=0 --entrypoint bash "$img" -c \
                     "python3 -m dynamo.frontend --http-host 127.0.0.1 --http-port $PORT & exec python3 -m dynamo.sglang --model-path $m $SGLANG_ARGS" ;;
  esac >/dev/null
}
wait_ready() {  # model -> seconds until the first chat is answered; fails after 20 min or when the server exits
  local m=$1 t0; t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt 1200 ]; do
    [ -n "$(ct ps -q -f name=oifb-srv)" ] || return 1
    if curl -sf "http://127.0.0.1:$PORT/v1/models" 2>/dev/null | grep -q "\"$m\"" \
       && curl -sf "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
            -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" >/dev/null 2>&1; then
      echo $(( $(date +%s) - t0 )); return 0
    fi
    sleep 3
  done; return 1
}
junction() {  # hottest sensor: AMD hotspot (temp2), else edge; NVIDIA reports one GPU temperature
  local v; [ "$VENDOR" = NVIDIA ] && { v=$(nv temperature.gpu); echo "${v:-0}"; return; }
  v=$(rd "$hw/temp2_input"); [ -n "$v" ] || v=$(rd "$hw/temp1_input"); echo $(( ${v:-0} / 1000 )); }
vram_used() { local v; if [ "$VENDOR" = NVIDIA ]; then v=$(nv memory.used | cut -d. -f1); echo $(( ${v:-0} * 1048576 )); else rd "$gpu/mem_info_vram_used"; fi; }
gpu_others() {  # pid=name of every process outside the server and this script that holds this GPU open (B-1b: another
                # program shared the GPU mid-run and slowed or failed every later point; the script's own nvidia-smi
                # telemetry holds /dev/nvidiaN and is not "another program")
  python3 "$HERE/proc_sampler.py" --others "$(ct inspect -f '{{.State.Pid}}' oifb-srv 2>/dev/null || echo -1)" "$DEVNODE" "$$"; }
cool_down() {  # ADR-009: wait (up to 10 min) until the GPU is below MAXT; prints the start temperature
  local t0; t0=$(date +%s)
  while [ "$(junction)" -ge "$MAXT" ] && [ $(( $(date +%s) - t0 )) -lt 600 ]; do sleep 5; done
  junction
}

# ---------------------------------------------------------------- --trace (B-1b): where the time goes
scrape() {  # dir when: /metrics of the server (port 8000) and of a Dynamo worker (8081), when they answer
  local port; for port in $PORT 8081; do
    curl -sf --max-time 5 "http://127.0.0.1:$port/metrics" > "$OUT/$1/metrics-$port-$2.txt" 2>/dev/null \
      || rm -f "$OUT/$1/metrics-$port-$2.txt"
  done; }
trace_start() {  # dir: CPU of the server's process tree for the whole point; py-spy on each Python process from 10 s in
                 # (after the warm-up) for the benchmark duration, sampling without pausing the process (--nonblocking).
                 # py-spy can hang unwinding a busy process past its --duration (B-1b: 4 hours on the engine core), so it
                 # runs under timeout; a killed py-spy leaves no profile for that process and the log ends without "Wrote"
  local root pid; scrape "$1" before
  root=$(ct inspect -f '{{.State.Pid}}' oifb-srv)
  python3 "$HERE/proc_sampler.py" "$root" "$OUT/$1/procs.csv" & tp=$!
  tspy=()
  for pid in $(python3 "$HERE/proc_sampler.py" --python "$root"); do
    ( sleep 10; ct run --rm --pid host --privileged -v "$OUT:/out" --entrypoint timeout "$first" -k 10 "$((DUR + 30))" /out/tools-venv/bin/py-spy record \
        --pid "$pid" --duration "$DUR" --rate 100 --nonblocking --format speedscope -o "/out/$1/pyspy-$pid.json" \
        > "$OUT/$1/pyspy-$pid.log" 2>&1 ) & tspy+=($!)
  done; }
trace_stop() {  # dir
  scrape "$1" after
  kill "$tp" 2>/dev/null; wait "$tp" 2>/dev/null
  [ ${#tspy[@]} -gt 0 ] && wait "${tspy[@]}" 2>/dev/null; }

# ---------------------------------------------------------------- run
total=$(( REPEATS * $(wc -w <<< "$MODELS") * $(wc -w <<< "$STACKS") * $(wc -w <<< "$WORKLOADS") * $(wc -w <<< "$CONCS") ))
say "plan: $total points of ${DUR}s plus warm-ups, start-ups and cool-downs; results in $OUT"
trap 'stop_server; kill $(jobs -p) 2>/dev/null' EXIT
n=0
for rep in $(seq "$REPEATS"); do
  order=$STACKS; [ $((rep % 2)) = 0 ] && order=$(tr ' ' '\n' <<< "$STACKS" | tac | xargs)
  for model in $MODELS; do
    tag=${model//\//_}
    for stack in $order; do
      say "repeat $rep  $model  $stack"
      log="$OUT/logs/server-$rep-$tag-$stack.log"
      t_case=$(date +%s)
      start_server "$stack" "$model"
      if ! ready=$(wait_ready "$model"); then
        ct logs oifb-srv > "$log" 2>&1; echo "   not ready; last lines of $log:"; tail -15 "$log" | sed 's/^/     /'
        echo "{\"type\":\"startup\",\"rep\":$rep,\"model\":\"$model\",\"stack\":\"$stack\",\"ready_s\":null}" >> "$OUT/results.jsonl"
        stop_server; continue
      fi
      vram=$(vram_used)
      echo "   ready in ${ready}s, VRAM $(( ${vram:-0} / 1048576 )) MiB"
      echo "{\"type\":\"startup\",\"rep\":$rep,\"model\":\"$model\",\"stack\":\"$stack\",\"ready_s\":$ready,\"vram_bytes\":${vram:-0}}" >> "$OUT/results.jsonl"
      for wl in $WORKLOADS; do
        IFS=: read -r wname isl osl <<< "$wl"
        for c in $CONCS; do
          n=$((n + 1)); dir="raw/$rep/$tag/$stack/$wname/c$c"; mkdir -p "$OUT/$dir"
          start_temp=$(cool_down)
          others=$(gpu_others)
          python3 "$HERE/gpu_sampler.py" "$([ "$VENDOR" = NVIDIA ] && echo "nvidia:$UUID" || echo "$gpu")" "$OUT/$dir/gpu.csv" & sp=$!
          [ "$TRACE" = 1 ] && trace_start "$dir"
          ct run --rm --network host -v "$OUT:/out" --entrypoint /out/aiperf-venv/bin/aiperf "$first" profile \
            --model "$model" --url "http://127.0.0.1:$PORT" --endpoint-type chat --streaming \
            --concurrency "$c" --benchmark-duration "$DUR" --benchmark-grace-period 60 \
            --warmup-request-count $(( c > 4 ? c : 4 )) \
            --isl "$isl" --isl-stddev 0 --osl "$osl" --osl-stddev 0 --extra-inputs ignore_eos:true \
            --random-seed 42 --artifact-dir "/out/$dir" > "$OUT/$dir/console.txt" 2>&1
          rc=$?
          kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
          [ "$TRACE" = 1 ] && trace_stop "$dir"
          others=$(xargs -n1 <<< "$others $(gpu_others)" | sort -u | xargs)
          python3 "$HERE/collect.py" "$OUT/$dir" "$rep" "$model" "$stack" "$wname" "$isl" "$osl" "$c" "$rc" "$start_temp" "$others" >> "$OUT/results.jsonl"
          printf '   [%d/%d] %-8s c=%-3s %s\n' "$n" "$total" "$wname" "$c" "$(tail -1 "$OUT/results.jsonl" | python3 "$HERE/collect.py" --line)"
          [ -z "$others" ] || die "another program used this GPU during the point ($others): the point counts as failed and the run stops; results so far in $OUT (oif bench report $OUT)"
        done
      done
      ct logs oifb-srv > "$log" 2>&1
      stop_server
      run_s=$(( $(date +%s) - t_case ))
      echo "{\"type\":\"runtime\",\"rep\":$rep,\"model\":\"$model\",\"stack\":\"$stack\",\"run_s\":$run_s}" >> "$OUT/results.jsonl"
      echo "   $model on $stack: $((run_s / 60)) min $((run_s % 60)) s"
    done
  done
done
trap - EXIT
say "report"
python3 "$HERE/report.py" "$OUT" && echo "   $OUT/report.html"
if [ "$TRACE" = 1 ]; then python3 "$HERE/attrib.py" "$OUT"; fi
