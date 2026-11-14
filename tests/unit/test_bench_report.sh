#!/bin/bash
# oif bench report (bench/report.py) on synthetic results: the throughput verdict (within noise, real but below 2%,
# real), points with few requests, points with fewer repeats than the profile, and the GPU hotspot line.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
D=$SANDBOX/bench; mkdir -p "$D"
cat > "$D/env.json" <<'EOF'
{"gpu": "Test GPU", "repeats": 3, "max_start_temp_c": 60, "power_cap_w": 241, "profile": "full", "aiperf": "0.13.0",
 "workloads": ["chat:512:256"], "concurrency": [1, 8, 64], "models": ["m/x"], "duration_s": 60, "images": []}
EOF
python3 - "$D/results.jsonl" <<'PY'
import json, sys
# (concurrency, stack): (throughput per repeat, requests); dynamo-vllm at c=64 lost its third repeat
cases = {(1, "vllm"): ([100.0, 100.1, 99.9], 5), (1, "dynamo-vllm"): ([100.5, 100.6, 100.4], 5),        # +0.5%, spread 0.1%
         (8, "vllm"): ([100.0, 100.0, 100.2], 300), (8, "dynamo-vllm"): ([95.0, 95.1, 94.9], 300),       # -5%
         (64, "vllm"): ([100.0, 110.0, 90.0], 900), (64, "dynamo-vllm"): ([105.0, 105.0], 900)}        # +5%, spread 10%
with open(sys.argv[1], "w") as f:
    for (c, s), (tps, n) in cases.items():
        for rep, tp in enumerate(tps, 1):
            f.write(json.dumps({"type": "point", "rep": rep, "model": "m/x", "stack": s, "workload": "chat", "isl": 512, "osl": 256,
                                "concurrency": c, "rc": 0, "export": True, "out_tok_s": tp, "requests": n, "errors": 0, "osl_avg": 256.0,
                                "ttft_p50_ms": 50.0, "itl_p50_ms": 5.0, "junction_max_c": 80.0 + c / 8, "power_avg_w": 230.0}) + "\n")
PY
out=$(python3 "$ROOT/bench/report.py" "$D")
eq "$out" "report: 17 points, 6 medians, 3 Dynamo/engine comparisons" "report summary line:"
H=$(sed -e 's/<[^>]*>//g' "$D/report.html")
grep -q "1 within noise · 1 real but below 2% · 1 beyond 2% (chat c=8 -5.0%)" <<< "$H" || fail "headline verdict counts and the point beyond 2%"
grep -q "real, below 2% (noise 0.1%) · few requests" <<< "$H" || fail "c=1: +0.5% beyond its 0.1% noise is 'real, below 2%', and has few requests"
grep -q "fewer than 10 requests: 2 — x vllm chat c=1; x dynamo-vllm chat c=1" <<< "$H" || fail "few-requests list in the run quality"
grep -q "fewer repeats than the profile's 3: 1 — x dynamo-vllm chat c=64" <<< "$H" || fail "lost repeat listed in the run quality"
grep -q "GPU hotspot up to 88 °C under load (each point starts below 60 °C), power up to 230 W of a 241 W cap" <<< "$H" || fail "hotspot line"
eq "$(head -1 "$D/summary.csv" | tr -d '\r' | tr ',' '\n' | tail -1)" "requests" "summary.csv has the request count:"
finish
