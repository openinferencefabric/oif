#!/bin/bash
# B-4a: the closed loop (a new request as soon as one ends) lets requests finish together and start together, and the
# TTFT p50 of both stacks depends on those waves (B-3a evidence 00 and 03). A profile with BENCH_ARRIVAL=poisson runs
# open loop: its levels are requests per second with Poisson arrivals (AIPerf --request-rate, --arrival-pattern
# poisson), no concurrency cap. The point directories keep the c<level> name so ttft_hist.py and attrib.py read them.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
B=$ROOT/bench/oif-bench.sh

grep -q 'ARRIVAL=${BENCH_ARRIVAL:-closed}' "$B" || fail "closed loop unless the profile says poisson"
grep -q 'closed|poisson) ;; \*) die' "$B" || fail "an unknown arrival pattern stops the run"
grep -q 'load=(--request-rate "$c" --arrival-pattern poisson)' "$B" || fail "poisson: request rate, Poisson arrivals"
grep -q 'load=(--concurrency "$c")' "$B" || fail "closed: concurrency"
grep -q '"${load\[@\]}" --benchmark-duration' "$B" || fail "AIPerf gets the load of the profile"
grep -q -- '--concurrency "$c" --benchmark-duration' "$B" && fail "no fixed --concurrency left in the AIPerf call"
grep -q '"arrival": "$ARRIVAL"' "$B" || fail "env.json records the arrival pattern"

# the B-4a profile: open loop, cache off like B-3a, levels that are request rates
(
  # shellcheck source=/dev/null
  . "$ROOT/bench/profiles/poisson.env"
  [ "$BENCH_ARRIVAL" = poisson ] || { echo "      FAIL: poisson.env is not open loop"; exit 1; }
  [ "$BENCH_PREFIX_CACHE" = off ] || { echo "      FAIL: poisson.env keeps the prefix cache"; exit 1; }
) || FAILS=$((FAILS + 1))

# report.py names the load by what it is
D=$SANDBOX/bench; mkdir -p "$D"
cat > "$D/env.json" <<'EOF'
{"gpu": "Test GPU", "repeats": 1, "max_start_temp_c": 60, "power_cap_w": 241, "profile": "poisson", "aiperf": "0.13.0",
 "arrival": "poisson", "workloads": ["d256:128:256"], "concurrency": [4, 8], "models": ["m/x"], "duration_s": 120, "images": []}
EOF
python3 - "$D/results.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    for c in (4, 8):
        f.write(json.dumps({"type": "point", "rep": 1, "model": "m/x", "stack": "vllm", "workload": "d256", "isl": 128, "osl": 256,
                            "concurrency": c, "rc": 0, "export": True, "out_tok_s": 100.0, "requests": 480, "errors": 0,
                            "osl_avg": 256.0, "ttft_p50_ms": 20.0, "itl_p50_ms": 4.0, "prefix_hit_pct": 0.0}) + "\n")
PY
python3 "$ROOT/bench/report.py" "$D" >/dev/null
H=$(sed -e 's/<[^>]*>//g' "$D/report.html")
grep -q "requests per second (Poisson arrivals) 4 8" <<< "$H" || fail "the environment line names the load as a Poisson request rate"
finish
