#!/bin/bash
# B-3a step 0: bench/ttft_hist.py shows the per-request TTFT distribution of a point and whether requests start in
# closed-loop waves. Synthetic run: a steady point (starts 20 ms apart, one TTFT peak) and a wave-locked point
# (4 waves of 50 requests that start together, half fast and half slow).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
D=$SANDBOX/hist
S=$D/raw/1/m_x/vllm/chat/c32/aiperf; W=$D/raw/1/m_x/vllm/chat/c64/aiperf; mkdir -p "$S" "$W"
python3 - "$S/profile_export.jsonl" "$W/profile_export.jsonl" <<'EOF'
import json, random, sys
random.seed(1)
rec = lambda start_ms, ttft, phase="profiling", err=None: json.dumps({
    "metadata": {"request_start_ns": int(start_ms * 1e6), "benchmark_phase": phase},
    "metrics": {"time_to_first_token": {"value": ttft, "unit": "ms"}}, "error": err})
with open(sys.argv[1], "w") as f:
    f.write(rec(0, 999, phase="warmup") + "\n")                       # warm-up: not counted
    f.write(rec(1, 999, err={"code": 500}) + "\n")                    # failed request: not counted
    for i in range(200):
        f.write(rec(10 + 20 * i, random.gauss(60, 3)) + "\n")
with open(sys.argv[2], "w") as f:
    for w in range(4):
        for i in range(50):
            f.write(rec(1000 * w + 0.01 * i, 30 + random.random() if i < 25 else 150 + random.random()) + "\n")
EOF
out=$(python3 "$ROOT/bench/ttft_hist.py" "$D")
steady=$(grep -A3 "c32" <<< "$out"); waves=$(grep -A3 "c64" <<< "$out")
eq "$(grep -c "requests 200" <<< "$steady")" 1 "steady point counts profiling requests without errors:"
grep -q "bimodal no" <<< "$steady" && pass || fail "steady point is not bimodal: $steady"
grep -q "in waves 0%" <<< "$steady" && pass || fail "steady point has no waves: $steady"
grep -q "bimodal yes" <<< "$waves" && pass || fail "wave point is bimodal: $waves"
grep -q "in waves 100%" <<< "$waves" && pass || fail "wave point starts in waves: $waves"
# a filter keeps only the matching points
eq "$(python3 "$ROOT/bench/ttft_hist.py" "$D" c64 | grep -c "^== ")" 1 "filter c64:"
finish
