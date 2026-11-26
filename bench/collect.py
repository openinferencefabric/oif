"""One benchmark point -> one JSON line.

collect.py DIR REP MODEL STACK WORKLOAD ISL OSL CONC RC START_TEMP_C [GPU_OTHERS]
                                                           reads DIR/**/profile_export_aiperf.json and DIR/gpu.csv;
                                                           GPU_OTHERS: pid=name of other processes on the GPU
collect.py --line                                          reads a result line on stdin, prints a one-line summary"""
import csv, glob, json, statistics, sys

if sys.argv[1] == "--line":
    d = json.loads(sys.stdin.read())
    print("rc=%s  %s tok/s  TTFT p50 %s ms  TPOT p50 %s ms  errors %s  OSL %s  GPU %s%% %s W  cache hit %s%%" % (
        d.get("rc"), d.get("out_tok_s"), d.get("ttft_p50_ms"), d.get("itl_p50_ms"), d.get("errors"),
        d.get("osl_avg"), d.get("gpu_busy_avg"), d.get("power_avg_w"), d.get("prefix_hit_pct")))
    sys.exit(0)

dirp, rep, model, stack, wl, isl, osl, conc, rc, t0 = sys.argv[1:11]
row = {"type": "point", "rep": int(rep), "model": model, "stack": stack, "workload": wl,
       "isl": int(isl), "osl": int(osl), "concurrency": int(conc), "rc": int(rc), "start_temp_c": int(t0)}
if len(sys.argv) > 11 and sys.argv[11].strip():
    row["gpu_others"] = sys.argv[11].strip()  # another program used the GPU during the point: not a valid measurement

f = (glob.glob(f"{dirp}/**/profile_export_aiperf.json", recursive=True) or [None])[0]
d = json.load(open(f)) if f else {}


def m(key, stat="avg"):
    v = d.get(key)
    if isinstance(v, dict):
        return v.get(stat)
    return v


for name, key in (("ttft", "time_to_first_token"), ("itl", "inter_token_latency"), ("e2e", "request_latency")):
    for s in ("avg", "p50", "p90", "p99"):
        v = m(key, s)
        row[f"{name}_{s}_ms"] = round(v, 2) if isinstance(v, (int, float)) else None
row["out_tok_s"] = round(m("output_token_throughput") or 0, 1) or None
row["tok_s_per_user"] = round(m("output_token_throughput_per_user") or 0, 1) or None
row["req_s"] = round(m("request_throughput") or 0, 3) or None
row["requests"] = m("request_count")
row["errors"] = m("error_request_count") or 0
row["error_kinds"] = len(d.get("error_summary") or [])
row["osl_avg"] = round(m("output_sequence_length") or 0, 1) or None
row["isl_avg"] = round(m("input_sequence_length") or 0, 1) or None
row["prefill_tok_s"] = round(row["isl_avg"] * row["req_s"], 1) if row["isl_avg"] and row["req_s"] else None  # prompt processing rate
row["export"] = bool(d)

# share of prompt tokens the engine's prefix cache served (B-3a: AIPerf recycles 100 prompts, so a warm cache skips
# prefill); vLLM counters over the profiling phase. Dynamo's timing runs scrape only its frontend: no share there.
sm = (glob.glob(f"{dirp}/**/server_metrics_export.csv", recursive=True) or [None])[0]
row["prefix_hit_pct"] = None
try:  # one section per metric type, each with its own header line; counters carry their delta in "total"
    cnt, head = {}, None
    for r in csv.reader(l for l in open(sm) if not l.startswith("#")) if sm else []:
        if not r:
            continue
        if r[0] == "Endpoint":
            head = r
        elif head and "total" in head and r[head.index("Type")] == "counter":
            cnt[r[head.index("Metric")]] = float(r[head.index("total")] or 0)
    if "vllm:prefix_cache_queries" in cnt:  # cache off: vLLM counts no queries, so 0%
        q = cnt["vllm:prefix_cache_queries"]
        row["prefix_hit_pct"] = round(100 * cnt.get("vllm:prefix_cache_hits", 0) / q, 1) if q else 0.0
except Exception as e:  # the cache share must never cost the point its line
    row["metrics_error"] = str(e)[:120]

try:  # GPU telemetry: keep the samples while the GPU is working (the window AIPerf measured)
    rows = [r for r in csv.DictReader(open(f"{dirp}/gpu.csv"))]
    busy = [r for r in rows if r["busy"] and float(r["busy"]) > 5] or rows
    num = lambda k, rs: [float(r[k]) for r in rs if r[k] not in ("", None)]
    row["gpu_busy_avg"] = round(statistics.mean(num("busy", busy)), 1) if num("busy", busy) else None
    row["power_avg_w"] = round(statistics.mean(num("power_w", busy)), 1) if num("power_w", busy) else None
    row["vram_max_mib"] = max(num("vram_mib", rows)) if num("vram_mib", rows) else None
    row["junction_max_c"] = max(num("junction_c", rows)) if num("junction_c", rows) else None
    row["sclk_avg_mhz"] = round(statistics.mean(num("sclk_mhz", busy))) if num("sclk_mhz", busy) else None
    if row["power_avg_w"] and row["out_tok_s"]:
        row["tok_per_joule"] = round(row["out_tok_s"] / row["power_avg_w"], 2)
except Exception as e:
    row["gpu_error"] = str(e)[:120]
print(json.dumps(row))
