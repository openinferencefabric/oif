#!/bin/bash
# oif bench: Dynamo against the plain engine it is built on, on the GPU of this node, with AIPerf (ADR-006).
#
#   sudo ./oif bench [run] [options]   benchmark on this GPU node (plain containers, no Kubernetes in the request path)
#        --profile full|quick          bench/profiles/*.env (default full: 4 workloads x 7 concurrencies x 3 repeats)
#        --stacks "vllm dynamo-vllm sglang dynamo-sglang"   default: every stack with an image in versions.env
#        --models "Qwen/Qwen3-0.6B Qwen/Qwen3-8B"           Hugging Face ids (HF_TOKEN in the environment if gated)
#        --repeats N                   override the profile's repeats (order of the stacks flips every repeat)
#        --out DIR                     default /var/tmp/oif-bench/<date>
#   ./oif bench report DIR             rebuild DIR/report.html from DIR/results.jsonl
#
#   stack            image (versions.env)        server
#   vllm             BENCH_VLLM_IMAGE            vllm serve
#   dynamo-vllm      DYNAMO_ROCM_IMAGE           dynamo.frontend + dynamo.vllm worker (aggregated), FROM BENCH_VLLM_IMAGE
#   sglang           BENCH_SGLANG_IMAGE          sglang.launch_server (S-5)
#   dynamo-sglang    DYNAMO_SGLANG_ROCM_IMAGE    dynamo.frontend + dynamo.sglang worker (aggregated, T-212)
# Each Dynamo image is built FROM its engine image, so engine, torch and ROCm match; the difference measured is
# Dynamo's frontend, request plane and worker wrapper. Same engine arguments within a pair, same AIPerf prompts
# (fixed seed), exact output lengths (ignore_eos), GPU below BENCH_MAX_START_TEMP_C before every point (ADR-009).
# AMD: the Radeon PRO W7900 (gfx1100); the W6400 is never used.
set -uo pipefail
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd); ROOT=$(dirname "$HERE")
# shellcheck source=../versions.env
. "$ROOT/versions.env"

say() { echo "== $*"; }
die() { echo "oif bench: $*" >&2; exit 1; }
usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; }

cmd=run; case ${1:-} in run) shift ;; report) cmd=report; shift ;; help|-h|--help) usage; exit 0 ;; esac
if [ $cmd = report ]; then [ -d "${1:-}" ] || die "report needs a result directory"; exec python3 "$HERE/report.py" "$1"; fi

MODELS="Qwen/Qwen3-0.6B Qwen/Qwen3-8B"; STACKS="vllm dynamo-vllm sglang dynamo-sglang"; PROFILE=full; REPEATS=""
OUT=/var/tmp/oif-bench/$(date +%Y%m%d-%H%M)
HF_HOME_HOST=${HF_HOME_HOST:-/var/tmp/oif-bench/hf}
PORT=8000; CTX=8192; MAXT=${BENCH_MAX_START_TEMP_C:-60}
VLLM_ARGS="--max-model-len $CTX --gpu-memory-utilization 0.90 --max-num-seqs 256 --seed 0"
# SGLang on gfx1100: no aiter (Instinct-only), Triton attention (S-5 settles the exact flags).
SGLANG_ARGS="--context-length $CTX --mem-fraction-static 0.85 --max-running-requests 256 --random-seed 0 --attention-backend triton --sampling-backend pytorch"

while [ $# -gt 0 ]; do case $1 in
  --profile) PROFILE=$2; shift 2 ;; --models) MODELS=$2; shift 2 ;; --stacks) STACKS=$2; shift 2 ;;
  --repeats) REPEATS=$2; shift 2 ;; --out) OUT=$2; shift 2 ;;
  *) die "unknown option $1 (oif bench help)" ;; esac; done
[ -f "$HERE/profiles/$PROFILE.env" ] || die "no profile $PROFILE in bench/profiles"
# shellcheck source=/dev/null
. "$HERE/profiles/$PROFILE.env"
WORKLOADS=$BENCH_WORKLOADS; CONCS=$BENCH_CONCURRENCY; DUR=$BENCH_DURATION_S; REPEATS=${REPEATS:-$BENCH_REPEATS}
[ "$(id -u)" = 0 ] || die "run with sudo"

image_of() { case $1 in
  vllm) echo "${BENCH_VLLM_IMAGE:-}" ;; dynamo-vllm) echo "${DYNAMO_ROCM_IMAGE:-}" ;;
  sglang) echo "${BENCH_SGLANG_IMAGE:-}" ;; dynamo-sglang) echo "${DYNAMO_SGLANG_ROCM_IMAGE:-}" ;;
  *) die "unknown stack $1" ;; esac; }
use=""; for s in $STACKS; do
  if [ -n "$(image_of "$s")" ]; then use="$use $s"; else echo "   skip $s: no image pinned in versions.env yet"; fi
done
STACKS=${use# }; [ -n "$STACKS" ] || die "no stack to run"

# ---------------------------------------------------------------- preflight
CT=$(command -v docker || command -v podman) || die "no docker or podman: sudo apt-get install -y podman"
say "oif bench, profile $PROFILE ($REPEATS repeat(s)), stacks: $STACKS, runtime $CT"
gpu=""; for d in /sys/class/drm/card*/device; do
  [ "$(cat "$d/vendor" 2>/dev/null)" = 0x1002 ] || continue
  case $(cat "$d/device") in 0x7448) gpu=$d ;; 0x7422) echo "   W6400 present: never used by oif bench" ;; esac
done
[ -n "$gpu" ] || die "no Radeon PRO W7900 (1002:7448) with the amdgpu driver on this node"
hw=$(ls -d "$gpu"/hwmon/hwmon* 2>/dev/null | head -1)
say "GPU: Radeon PRO W7900 at $(basename "$(readlink -f "$gpu")")"
command -v fuser >/dev/null || die "fuser missing (apt-get install -y psmisc)"
if fuser /dev/kfd >/dev/null 2>&1; then
  die "something already uses the GPU (/dev/kfd, pids$(fuser /dev/kfd 2>/dev/null)): stop it first (e.g. systemctl stop kubelet)"
fi
mkdir -p "$OUT"/{raw,logs} "$HF_HOME_HOST"
free_gb=$(df -BG --output=avail "$(dirname "$OUT")" | tail -1 | tr -dc 0-9)
[ "$free_gb" -ge 60 ] || die "need 60 GB free next to $OUT, have ${free_gb} GB"

say "pull images"
for s in $STACKS; do
  $CT pull -q "$(image_of "$s")" >/dev/null || die "pull $(image_of "$s") failed (a private GHCR package needs: $CT login ghcr.io)"
  echo "   $s"
done
GPU_FLAGS=(--device /dev/kfd --device /dev/dri --group-add video --ipc host --shm-size 16g
           --security-opt seccomp=unconfined --network host)
getent group render >/dev/null && GPU_FLAGS+=(--group-add "$(getent group render | cut -d: -f3)")
HF_FLAGS=(-v "$HF_HOME_HOST:/hf" -e HF_HOME=/hf)
[ -n "${HF_TOKEN:-}" ] && HF_FLAGS+=(-e HF_TOKEN)

say "versions inside each image"
: > "$OUT/images.jsonl"
for s in $STACKS; do
  img=$(image_of "$s")
  inside=$($CT run --rm --entrypoint python3 "$img" -c '
import importlib.metadata as m, json, torch
d = {"torch": torch.__version__, "hip": torch.version.hip}
for p in ("vllm", "sglang", "sgl-kernel", "ai-dynamo", "ai-dynamo-runtime", "triton"):
    try: d[p] = m.version(p)
    except Exception: pass
print(json.dumps(d))' 2>/dev/null) || inside=null
  digest=$($CT image inspect "$img" --format '{{index .RepoDigests 0}}' 2>/dev/null)
  echo "{\"stack\":\"$s\",\"image\":\"$img\",\"digest\":\"$digest\",\"inside\":${inside:-null}}" >> "$OUT/images.jsonl"
  echo "   $s: $inside"
done
rd() { cat "$1" 2>/dev/null || true; }
python3 - "$OUT/env.json" <<PY
import json, os, platform, sys
env = {"oif_version": "${OIF_VERSION:-}", "kernel": platform.release(), "cpus": os.cpu_count(),
       "amdgpu": "$(rd /sys/module/amdgpu/version)", "gpu": "Radeon PRO W7900 (gfx1100)",
       "vram_total_bytes": int("$(rd "$gpu/mem_info_vram_total")" or 0),
       "power_cap_w": round(int("$(rd "$hw/power1_cap")" or 0) / 1e6), "max_start_temp_c": $MAXT,
       "profile": "$PROFILE", "repeats": $REPEATS, "duration_s": $DUR, "aiperf": "$AIPERF_VERSION",
       "workloads": "$WORKLOADS".split(), "concurrency": [int(c) for c in "$CONCS".split()], "models": "$MODELS".split(),
       "vllm_args": "$VLLM_ARGS", "sglang_args": "$SGLANG_ARGS",
       "images": [json.loads(l) for l in open("$OUT/images.jsonl")]}
json.dump(env, open(sys.argv[1], "w"), indent=1)
PY

say "models into $HF_HOME_HOST"
first=$(image_of "${STACKS%% *}")
for m in $MODELS; do
  $CT run --rm "${HF_FLAGS[@]}" --entrypoint bash "$first" -c \
    "if command -v hf >/dev/null; then hf download $m >/dev/null; else huggingface-cli download $m >/dev/null; fi" \
    || die "download $m failed"
  echo "   $m"
done

say "AIPerf $AIPERF_VERSION (venv in $OUT)"
$CT run --rm -v "$OUT:/out" --entrypoint bash "$first" -c \
  "python3 -m venv /out/aiperf-venv && /out/aiperf-venv/bin/pip install -q aiperf==$AIPERF_VERSION" \
  > "$OUT/logs/aiperf-install.log" 2>&1 || die "aiperf install failed: $OUT/logs/aiperf-install.log"

# ---------------------------------------------------------------- server control
stop_server() { $CT rm -f oifb-srv >/dev/null 2>&1; for _ in $(seq 30); do fuser /dev/kfd >/dev/null 2>&1 || return 0; sleep 2; done; }
start_server() {  # stack model
  local s=$1 m=$2 img; img=$(image_of "$1")
  local dyn=(-e DYN_DISCOVERY_BACKEND=file -e DYN_FILE_KV=/tmp/dynamo_kv -e DYN_REQUEST_PLANE=tcp -e DYN_SYSTEM_PORT=8081)
  stop_server
  case $s in
    vllm)          $CT run -d --name oifb-srv "${GPU_FLAGS[@]}" "${HF_FLAGS[@]}" --entrypoint bash "$img" -c \
                     "exec vllm serve $m --host 0.0.0.0 --port $PORT $VLLM_ARGS" ;;
    dynamo-vllm)   $CT run -d --name oifb-srv "${GPU_FLAGS[@]}" "${HF_FLAGS[@]}" "${dyn[@]}" --entrypoint bash "$img" -c \
                     "python3 -m dynamo.frontend --http-port $PORT & exec python3 -m dynamo.vllm --model $m $VLLM_ARGS" ;;
    sglang)        $CT run -d --name oifb-srv "${GPU_FLAGS[@]}" "${HF_FLAGS[@]}" -e SGLANG_USE_AITER=0 --entrypoint bash "$img" -c \
                     "exec python3 -m sglang.launch_server --model-path $m --host 0.0.0.0 --port $PORT $SGLANG_ARGS" ;;
    dynamo-sglang) $CT run -d --name oifb-srv "${GPU_FLAGS[@]}" "${HF_FLAGS[@]}" "${dyn[@]}" -e SGLANG_USE_AITER=0 --entrypoint bash "$img" -c \
                     "python3 -m dynamo.frontend --http-port $PORT & exec python3 -m dynamo.sglang --model-path $m $SGLANG_ARGS" ;;
  esac >/dev/null
}
wait_ready() {  # model -> seconds until the first chat is answered; fails after 20 min or when the server exits
  local m=$1 t0; t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt 1200 ]; do
    [ -n "$($CT ps -q -f name=oifb-srv)" ] || return 1
    if curl -sf "http://127.0.0.1:$PORT/v1/models" 2>/dev/null | grep -q "\"$m\"" \
       && curl -sf "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
            -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" >/dev/null 2>&1; then
      echo $(( $(date +%s) - t0 )); return 0
    fi
    sleep 3
  done; return 1
}
junction() { local v; v=$(rd "$hw/temp2_input"); [ -n "$v" ] || v=$(rd "$hw/temp1_input"); echo $(( ${v:-0} / 1000 )); }
cool_down() {  # ADR-009: wait (up to 10 min) until the GPU is below MAXT; prints the start temperature
  local t0; t0=$(date +%s)
  while [ "$(junction)" -ge "$MAXT" ] && [ $(( $(date +%s) - t0 )) -lt 600 ]; do sleep 5; done
  junction
}

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
      start_server "$stack" "$model"
      if ! ready=$(wait_ready "$model"); then
        $CT logs oifb-srv > "$log" 2>&1; echo "   not ready; last lines of $log:"; tail -15 "$log" | sed 's/^/     /'
        echo "{\"type\":\"startup\",\"rep\":$rep,\"model\":\"$model\",\"stack\":\"$stack\",\"ready_s\":null}" >> "$OUT/results.jsonl"
        stop_server; continue
      fi
      vram=$(rd "$gpu/mem_info_vram_used")
      echo "   ready in ${ready}s, VRAM $(( ${vram:-0} / 1048576 )) MiB"
      echo "{\"type\":\"startup\",\"rep\":$rep,\"model\":\"$model\",\"stack\":\"$stack\",\"ready_s\":$ready,\"vram_bytes\":${vram:-0}}" >> "$OUT/results.jsonl"
      for wl in $WORKLOADS; do
        IFS=: read -r wname isl osl <<< "$wl"
        for c in $CONCS; do
          n=$((n + 1)); dir="raw/$rep/$tag/$stack/$wname/c$c"; mkdir -p "$OUT/$dir"
          start_temp=$(cool_down)
          python3 "$HERE/gpu_sampler.py" "$gpu" "$OUT/$dir/gpu.csv" & sp=$!
          $CT run --rm --network host -v "$OUT:/out" --entrypoint /out/aiperf-venv/bin/aiperf "$first" profile \
            --model "$model" --url "http://127.0.0.1:$PORT" --endpoint-type chat --streaming \
            --concurrency "$c" --benchmark-duration "$DUR" --benchmark-grace-period 60 \
            --warmup-request-count $(( c > 4 ? c : 4 )) \
            --isl "$isl" --isl-stddev 0 --osl "$osl" --osl-stddev 0 --extra-inputs ignore_eos:true \
            --random-seed 42 --artifact-dir "/out/$dir" > "$OUT/$dir/console.txt" 2>&1
          rc=$?
          kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
          python3 "$HERE/collect.py" "$OUT/$dir" "$rep" "$model" "$stack" "$wname" "$isl" "$osl" "$c" "$rc" "$start_temp" >> "$OUT/results.jsonl"
          printf '   [%d/%d] %-8s c=%-3s %s\n' "$n" "$total" "$wname" "$c" "$(tail -1 "$OUT/results.jsonl" | python3 "$HERE/collect.py" --line)"
        done
      done
      $CT logs oifb-srv > "$log" 2>&1
      stop_server
    done
  done
done
trap - EXIT
say "report"
python3 "$HERE/report.py" "$OUT" && echo "   $OUT/report.html"
