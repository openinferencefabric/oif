#!/bin/bash
# B-1b: in the first --trace run another program (a GEMM benchmark) opened the same GPU while oif bench was running:
# every later point was slowed or failed, and the run went on for 10 hours. The start-up check (fuser on the render
# node) had passed. Now every point checks for processes outside the server that hold the GPU open, records them on
# the point (gpu_others), the report counts that point as failed, and the run stops. In the same run a py-spy hung on
# the engine core past its --duration and held the run for 4 hours: py-spy now runs under timeout.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# collect.py: the 11th argument (other processes on the GPU) is recorded on the point; absent when empty
P=$SANDBOX/point; mkdir -p "$P"
row=$(python3 "$ROOT/bench/collect.py" "$P" 1 m/x vllm chat 512 256 8 0 40 "4242=python3")
eq "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("gpu_others"))' "$row")" "4242=python3" "gpu_others on the point:"
row=$(python3 "$ROOT/bench/collect.py" "$P" 1 m/x vllm chat 512 256 8 0 40 "")
eq "$(python3 -c 'import json,sys; print("gpu_others" in json.loads(sys.argv[1]))' "$row")" "False" "no gpu_others when the GPU was ours alone:"

# report.py: a point that shared the GPU counts as failed
D=$SANDBOX/bench; mkdir -p "$D"
cat > "$D/env.json" <<'EOF'
{"gpu": "Test GPU", "repeats": 1, "max_start_temp_c": 60, "power_cap_w": 241, "profile": "quick", "aiperf": "0.13.0",
 "workloads": ["chat:512:256"], "concurrency": [8], "models": ["m/x"], "duration_s": 60, "images": []}
EOF
python3 - "$D/results.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    for s, others in (("vllm", None), ("dynamo-vllm", "4242=python3")):
        p = {"type": "point", "rep": 1, "model": "m/x", "stack": s, "workload": "chat", "isl": 512, "osl": 256,
             "concurrency": 8, "rc": 0, "export": True, "out_tok_s": 100.0, "requests": 300, "errors": 0, "osl_avg": 256.0,
             "ttft_p50_ms": 50.0, "itl_p50_ms": 5.0, "junction_max_c": 80.0, "power_avg_w": 230.0}
        if others:
            p["gpu_others"] = others
        f.write(json.dumps(p) + "\n")
PY
python3 "$ROOT/bench/report.py" "$D" >/dev/null
failed() { python3 -c 'import csv,sys; print([r["failed"] for r in csv.DictReader(open(sys.argv[1])) if r["stack"]==sys.argv[2]][0])' "$D/summary.csv" "$1"; }
eq "$(failed dynamo-vllm)" "1" "a point that shared the GPU counts as failed:"
eq "$(failed vllm)" "0" "a point with the GPU to itself is not failed:"

# oif-bench.sh: py-spy runs under timeout (a hung py-spy cannot hold the run), every point checks for other processes
grep -q -- '--entrypoint timeout "$first" -k 10 "$((DUR + 30))" /out/tools-venv/bin/py-spy record' "$ROOT/bench/oif-bench.sh" \
  || fail "py-spy under timeout in trace_start"
grep -q 'proc_sampler.py" --others' "$ROOT/bench/oif-bench.sh" || fail "oif-bench.sh checks the GPU for other processes at every point"
grep -q -- '--others .*"$DEVNODE" "$\$"' "$ROOT/bench/oif-bench.sh" || fail "oif-bench.sh leaves its own processes (telemetry) out of the check"

# proc_sampler.py --others: processes holding the device open, outside the server's process tree (Linux /proc)
if [ "$(uname -s)" = Linux ]; then
  DEV=$SANDBOX/renderD999; : > "$DEV"
  bash -c "bash -c 'exec 3<\"$DEV\"; sleep 30' & wait" & server=$!   # the server's tree: a child holds the device
  bash -c "exec 3<\"$DEV\"; sleep 30" & other=$!                       # another program holds it too
  # oif bench's own telemetry holds the device too on NVIDIA (gpu_sampler's nvidia-smi, B-2): a second root
  bash -c "bash -c 'exec 3<\"$DEV\"; sleep 30' & wait" & bench=$!
  sleep 0.5
  inner=$(pgrep -P "$server"); mine=$(pgrep -P "$bench")
  out=$(python3 "$ROOT/bench/proc_sampler.py" --others "$server" "$DEV" "$bench")
  grep -q "^$other=" <<< "$(tr ' ' '\n' <<< "$out")" || fail "the other program is listed: '$out'"
  grep -q "^$inner=" <<< "$(tr ' ' '\n' <<< "$out")" && fail "the server's own process is not listed: '$out'"
  grep -q "^$mine=" <<< "$(tr ' ' '\n' <<< "$out")" && fail "oif bench's own telemetry is not listed: '$out'"
  kill "$other" 2>/dev/null; pkill -P "$server" 2>/dev/null; pkill -P "$bench" 2>/dev/null; kill "$server" "$bench" 2>/dev/null; wait 2>/dev/null
  eq "$(python3 "$ROOT/bench/proc_sampler.py" --others "$$" "$DEV")" "" "nothing listed once the GPU is free:"
fi
finish
