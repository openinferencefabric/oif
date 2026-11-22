#!/bin/bash
# B-1b: oif bench --trace splits the time to first token (bench/attrib.py) and samples the server's CPU per process
# (bench/proc_sampler.py). Synthetic run: vLLM's own server against Dynamo at one point, with known histogram deltas,
# process CPU and a py-spy profile.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
D=$SANDBOX/attrib
V=$D/raw/1/m_x/vllm/chat/c64; Y=$D/raw/1/m_x/dynamo-vllm/chat/c64; mkdir -p "$V" "$Y"
cat > "$D/results.jsonl" <<'EOF'
{"type": "startup", "rep": 1, "model": "m/x", "stack": "vllm", "ready_s": 100}
{"type": "point", "rep": 1, "model": "m/x", "stack": "vllm", "workload": "chat", "concurrency": 64, "out_tok_s": 4383.0, "ttft_avg_ms": 136.0, "ttft_p50_ms": 136.4}
{"type": "point", "rep": 1, "model": "m/x", "stack": "dynamo-vllm", "workload": "chat", "concurrency": 64, "out_tok_s": 4400.0, "ttft_avg_ms": 82.0, "ttft_p50_ms": 81.5}
{"type": "point", "rep": 1, "model": "m/x", "stack": "vllm", "workload": "chat", "concurrency": 1, "out_tok_s": 234.0, "ttft_avg_ms": 33.0}
EOF
# vLLM: 500 requests in the point; TTFT 100 ms, queue 10 ms, prefill 20 ms on average (two label sets are summed)
cat > "$V/metrics-8000-before.txt" <<'EOF'
# HELP vllm:time_to_first_token_seconds Histogram of time to first token in seconds.
vllm:time_to_first_token_seconds_sum{engine="0",model_name="m/x"} 10.0
vllm:time_to_first_token_seconds_count{engine="0",model_name="m/x"} 100
vllm:request_queue_time_seconds_sum{engine="0",model_name="m/x"} 1.0
vllm:request_queue_time_seconds_count{engine="0",model_name="m/x"} 100
vllm:request_prefill_time_seconds_sum{engine="0",model_name="m/x"} 2.0
vllm:request_prefill_time_seconds_count{engine="0",model_name="m/x"} 100
EOF
cat > "$V/metrics-8000-after.txt" <<'EOF'
vllm:time_to_first_token_seconds_sum{engine="0",model_name="m/x"} 35.0
vllm:time_to_first_token_seconds_count{engine="0",model_name="m/x"} 350
vllm:time_to_first_token_seconds_sum{engine="1",model_name="m/x"} 25.0
vllm:time_to_first_token_seconds_count{engine="1",model_name="m/x"} 250
vllm:time_to_first_token_seconds_bucket{engine="0",le="0.1"} 999
vllm:request_queue_time_seconds_sum{engine="0",model_name="m/x"} 6.0
vllm:request_queue_time_seconds_count{engine="0",model_name="m/x"} 600
vllm:request_prefill_time_seconds_sum{engine="0",model_name="m/x"} 12.0
vllm:request_prefill_time_seconds_count{engine="0",model_name="m/x"} 600
EOF
# Dynamo: the engine's metrics come from the worker (8081), the frontend's from 8000
printf 'vllm:time_to_first_token_seconds_sum 0\nvllm:time_to_first_token_seconds_count 0\n' > "$Y/metrics-8081-before.txt"
printf 'vllm:time_to_first_token_seconds_sum 40\nvllm:time_to_first_token_seconds_count 500\n' > "$Y/metrics-8081-after.txt"
printf 'dynamo_frontend_time_to_first_token_seconds_sum 0\ndynamo_frontend_time_to_first_token_seconds_count 0\n' > "$Y/metrics-8000-before.txt"
printf 'dynamo_frontend_time_to_first_token_seconds_sum 41\ndynamo_frontend_time_to_first_token_seconds_count 500\n' > "$Y/metrics-8000-after.txt"
# CPU: the idle sample (t=0) is outside the busy window; the API server holds one core
cat > "$V/procs.csv" <<'EOF'
t,pid,name,cpu_pct,threads,rss_mib
0.0,10,/usr/bin/python3 /usr/local/bin/vllm serve m/x --host 127.0.0.1,1.0,30,900
0.0,11,VLLM::EngineCore,1.0,40,4000
1.0,10,/usr/bin/python3 /usr/local/bin/vllm serve m/x --host 127.0.0.1,99.0,30,900
1.0,11,VLLM::EngineCore,80.0,40,4000
2.0,10,/usr/bin/python3 /usr/local/bin/vllm serve m/x --host 127.0.0.1,101.0,30,900
2.0,11,VLLM::EngineCore,80.0,40,4000
EOF
# py-spy (speedscope): 4 samples; 2 in tokenizing, 1 in detokenizing, 1 in the HTTP layer; all under asyncio
cat > "$V/pyspy-10.json" <<'EOF'
{"shared": {"frames": [{"name": "run_forever", "file": "/usr/lib/python3.12/asyncio/base_events.py"},
                       {"name": "create_chat_completion", "file": "/vllm/entrypoints/openai/serving.py"},
                       {"name": "encode", "file": "/site-packages/transformers/tokenization_utils_fast.py"},
                       {"name": "step", "file": "/vllm/v1/engine/detokenizer.py"},
                       {"name": "__call__", "file": "/site-packages/starlette/routing.py"}]},
 "profiles": [{"type": "sampled", "samples": [[0, 1, 2], [0, 1, 2], [0, 3], [0, 4]], "weights": [1, 1, 1, 1]}]}
EOF
out=$(python3 "$ROOT/bench/attrib.py" "$D")
grep -q "attrib: 2 traced points" <<< "$out" || fail "two traced points (the untraced c=1 point is left out): $out"
col() { python3 -c 'import csv,sys; r=[x for x in csv.DictReader(open(sys.argv[1])) if x["stack"]==sys.argv[2]][0]; print(r.get(sys.argv[3]) or "")' "$D/attrib.csv" "$1" "$2"; }
eq "$(col vllm engine_ttft_ms)" "100.0" "engine TTFT = sum delta / count delta over both label sets:"
eq "$(col vllm core_ms)" "30.0" "core = queue 10 + prefill 20:"
eq "$(col vllm output_path_ms)" "70.0" "output path = engine 100 - core 30:"
eq "$(col vllm api_layer_ms)" "36.0" "api layer = client 136 - engine 100:"
eq "$(col vllm "cpu api server")" "100.0" "API server CPU over the busy window only:"
eq "$(col vllm "cpu engine core")" "80.0" "engine core CPU:"
eq "$(col dynamo-vllm engine_ttft_ms)" "80.0" "Dynamo: engine TTFT from the worker's metrics:"
eq "$(col dynamo-vllm frontend_ttft_ms)" "82.0" "Dynamo: frontend TTFT:"
P=$(cat "$D/attrib-profiles.txt")
grep -q "inclusive: asyncio 100.0%, tokenize 50.0%, detokenize 25.0%, http + sse 25.0%" <<< "$P" || fail "profile buckets: $P"
grep -q "50.0%  encode (tokenization_utils_fast.py)" <<< "$P" || fail "self time by function: $P"

# proc_sampler on a live process tree (Linux /proc): a busy child shows up with its CPU, and as a Python process
if [ "$(uname -s)" = Linux ]; then
  bash -c 'python3 -c "while True: pass" & wait' & parent=$!
  sleep 0.5
  pyp=$(python3 "$ROOT/bench/proc_sampler.py" --python "$parent")
  [ -n "$pyp" ] || fail "proc_sampler --python finds the busy python child of $parent"
  python3 "$ROOT/bench/proc_sampler.py" "$parent" "$SANDBOX/procs.csv" & sp=$!
  sleep 3.5; kill "$sp"; wait "$sp" 2>/dev/null
  pkill -P "$parent" 2>/dev/null; kill "$parent" 2>/dev/null; wait "$parent" 2>/dev/null
  busy=$(python3 -c 'import csv,sys; print(max(float(r["cpu_pct"]) for r in csv.DictReader(open(sys.argv[1])) if "while True" in r["name"]))' "$SANDBOX/procs.csv" 2>/dev/null)
  python3 -c "import sys; sys.exit(0 if float('${busy:-0}') > 50 else 1)" || fail "busy child sampled near one core, got ${busy:-nothing}"
fi
finish
