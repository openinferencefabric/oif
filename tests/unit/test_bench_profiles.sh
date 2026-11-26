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
  ) || FAILS=$((FAILS + 1))
done
grep -q 'CTX=${BENCH_CTX:-8192}' "$ROOT/bench/oif-bench.sh" && pass || fail "oif-bench.sh takes the server context from the profile"
# the context is set after the profile is read, and the engine arguments use it
awk '/^\. "\$HERE\/profiles/ {p=NR} /^CTX=\$\{BENCH_CTX/ {c=NR} /^VLLM_ARGS=.*\$CTX/ {v=NR} END {exit !(p && c > p && v > c)}' \
  "$ROOT/bench/oif-bench.sh" && pass || fail "CTX after the profile is sourced, VLLM_ARGS after CTX"
finish
