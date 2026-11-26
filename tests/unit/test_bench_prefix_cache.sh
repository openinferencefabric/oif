#!/bin/bash
# B-3a calibration: AIPerf reuses 100 synthetic prompts (--num-dataset-entries defaults to 100), so with vLLM's prefix
# cache on, 99% of the 1K-prompt tokens came from the cache and the "prefill" points measured cache hits. The B-3a
# profiles turn the cache off (BENCH_PREFIX_CACHE=off), every point records the share of prompt tokens the cache
# served, and the report lists the points above 1%. In the same calibration a container that never started left an
# empty server log: the error of the container start now goes into that log.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# collect.py: prefix_hit_pct from the profiling-phase counters in AIPerf's server_metrics_export.csv
P=$SANDBOX/point; mkdir -p "$P"
# the real layout (AIPerf 0.13.0): one section per metric type, each with its own header; counters in "total"
metrics() {  # hits queries
  cat > "$P/server_metrics_export.csv" <<EOF
# AIPerf Server Metrics Export (CSV)
# aiperf_version: 0.13.0
#
Endpoint,Type,Metric,Unit,avg,min,max,std,p1,p5,p10,p25,p50,p75,p90,p95,p99,engine,model_name,reason,sleep_state,Description
127.0.0.1:8000,gauge,vllm:kv_cache_usage_perc,,0.5000,0.1000,0.9000,,,,,,,,,,,,m/x,,,"KV cache usage."

Endpoint,Type,Metric,Unit,total,rate,rate_avg,rate_min,rate_max,rate_std,engine,finished_reason,model_name,reason,source,generation,handler,method,status,Description
127.0.0.1:8000,counter,vllm:external_prefix_cache_hits,,0.0000,0.0000,,,,,0,,m/x,,,,,,,"External hits"
127.0.0.1:8000,counter,vllm:prefix_cache_hits,,$1,4483.8938,,,,,0,,m/x,,,,,,,"Prefix cache hits, in tokens."
127.0.0.1:8000,counter,vllm:prefix_cache_queries,,$2,4518.9242,,,,,0,,m/x,,,,,,,"Prefix cache queries, in tokens."

Endpoint,Type,Metric,Unit,count,count_rate,sum,sum_rate,avg,p1_estimate,p5_estimate,p10_estimate,p25_estimate,p50_estimate,p75_estimate,p90_estimate,p95_estimate,p99_estimate,engine,model_name,handler,Description
127.0.0.1:8000,histogram,vllm:time_to_first_token_seconds,,300,5.0,15.0,0.25,0.05,,,,,,,,,,,m/x,,"TTFT."

Endpoint,Metric,Key,Value,Description
127.0.0.1:8000,vllm:cache_config_info,enable_prefix_caching,False,Information of the LLMEngine CacheConfig
EOF
}
metrics 278528.0000 280704.0000
hit() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("prefix_hit_pct"))' "$1"; }
row=$(python3 "$ROOT/bench/collect.py" "$P" 1 m/x vllm p1k 1024 16 8 0 40)
eq "$(hit "$row")" "99.2" "share of prompt tokens served by the prefix cache:"
grep -q "cache hit 99.2%" <<< "$(python3 "$ROOT/bench/collect.py" --line <<< "$row")" || fail "the console line shows the cache hit share"
metrics 0.0000 0.0000
row=$(python3 "$ROOT/bench/collect.py" "$P" 1 m/x vllm p1k 1024 16 8 0 40)
eq "$(hit "$row")" "0.0" "cache off (vLLM counts no queries): 0%, not unknown:"
rm "$P/server_metrics_export.csv"
row=$(python3 "$ROOT/bench/collect.py" "$P" 1 m/x vllm p1k 1024 16 8 0 40)
eq "$(hit "$row")" "None" "no server metrics (Dynamo's frontend only): no share:"

# report.py: points above 1% are listed in the run quality
D=$SANDBOX/bench; mkdir -p "$D"
cat > "$D/env.json" <<'EOF'
{"gpu": "Test GPU", "repeats": 1, "max_start_temp_c": 60, "power_cap_w": 241, "profile": "prefill", "aiperf": "0.13.0",
 "workloads": ["p1k:1024:16"], "concurrency": [1, 8], "models": ["m/x"], "duration_s": 60, "images": []}
EOF
python3 - "$D/results.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    for c, h in ((1, 0.4), (8, 99.2)):
        f.write(json.dumps({"type": "point", "rep": 1, "model": "m/x", "stack": "vllm", "workload": "p1k", "isl": 1024, "osl": 16,
                            "concurrency": c, "rc": 0, "export": True, "out_tok_s": 100.0, "requests": 300, "errors": 0,
                            "osl_avg": 16.0, "ttft_p50_ms": 50.0, "itl_p50_ms": 5.0, "prefix_hit_pct": h}) + "\n")
PY
python3 "$ROOT/bench/report.py" "$D" >/dev/null
H=$(sed -e 's/<[^>]*>//g' "$D/report.html")
grep -q "prefix cache served more than 1% of the prompt tokens: 1 — x vllm p1k c=8" <<< "$H" || fail "cache-hit points listed in the run quality"
grep -q "prefix_hit_pct" "$D/summary.csv" || fail "summary.csv has the cache hit share"

# oif-bench.sh: BENCH_PREFIX_CACHE=off turns the cache off in vLLM (and Dynamo's vLLM worker) and SGLang
grep -q 'BENCH_PREFIX_CACHE:-on' "$ROOT/bench/oif-bench.sh" || fail "prefix cache on unless the profile turns it off"
grep -q 'VLLM_ARGS+=" --no-enable-prefix-caching"' "$ROOT/bench/oif-bench.sh" || fail "vLLM cache off"
grep -q 'SGLANG_ARGS+=" --disable-radix-cache"' "$ROOT/bench/oif-bench.sh" || fail "SGLang cache off"
# the error of a container that does not start goes into the server log (B-3a: an empty log hid a CDI failure)
grep -q 'start_server "$stack" "$model" 2> "$log"' "$ROOT/bench/oif-bench.sh" || fail "container start errors go to the server log"
grep -q 'ct logs oifb-srv >> "$log" 2>&1; echo "   not ready' "$ROOT/bench/oif-bench.sh" || fail "server output appended, start error kept"
finish
