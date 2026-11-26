#!/bin/bash
# B-3a: every workload of every bench profile fits the server context that profile gives (BENCH_CTX, default 8192):
# input + output tokens + 64 for the chat template. A request longer than the context fails at the server, so a
# profile with 8K prompts must raise the context. oif-bench.sh sets the server context from the profile.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
for p in "$ROOT"/bench/profiles/*.env; do
  (
    unset BENCH_CTX
    # shellcheck source=/dev/null
    . "$p"
    ctx=${BENCH_CTX:-8192}
    for wl in $BENCH_WORKLOADS; do
      IFS=: read -r name isl osl <<< "$wl"
      [ $((isl + osl + 64)) -le "$ctx" ] || { echo "      FAIL: $(basename "$p") $name: $isl + $osl tokens + 64 > context $ctx"; exit 1; }
    done
    for v in BENCH_CONCURRENCY BENCH_DURATION_S BENCH_REPEATS; do
      [ -n "${!v}" ] || { echo "      FAIL: $(basename "$p") has no $v"; exit 1; }
    done
    # an answer must be able to end inside the point: the slowest decode seen (Qwen3-8B, 32 users, about 40 ms per
    # token on the W7900) with margin, 50 ms per token, within the point plus AIPerf's 60 s grace period. In the
    # calibration every 4096-token answer at 8B and 8 users or more, and at 0.6B and 64 users, was cancelled.
    for wl in $BENCH_WORKLOADS; do
      IFS=: read -r name _ osl <<< "$wl"
      [ $((osl * 50)) -le $(( (BENCH_DURATION_S + 60) * 1000 )) ] || { echo "      FAIL: $(basename "$p") $name: $osl tokens at 50 ms do not end in ${BENCH_DURATION_S} s + 60 s"; exit 1; }
    done
    # B-3a measures prefill and decode themselves: no prefix cache (AIPerf recycles its prompts)
    case $(basename "$p") in prefill*|decode*) [ "${BENCH_PREFIX_CACHE:-on}" = off ] || { echo "      FAIL: $(basename "$p") keeps the prefix cache on"; exit 1; } ;; esac
  ) || FAILS=$((FAILS + 1))
done
grep -q 'CTX=${BENCH_CTX:-8192}' "$ROOT/bench/oif-bench.sh" && pass || fail "oif-bench.sh takes the server context from the profile"
# the context is set after the profile is read, and the engine arguments use it
awk '/^\. "\$HERE\/profiles/ {p=NR} /^CTX=\$\{BENCH_CTX/ {c=NR} /^VLLM_ARGS=.*\$CTX/ {v=NR} END {exit !(p && c > p && v > c)}' \
  "$ROOT/bench/oif-bench.sh" && pass || fail "CTX after the profile is sourced, VLLM_ARGS after CTX"
finish
