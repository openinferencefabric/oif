"""Where the time to first token goes (B-1b): attrib.py DIR   (a run made with oif bench --trace)

For every traced point (DIR/raw/<rep>/<model>/<stack>/<workload>/c<N>/) it reads:
  metrics-<port>-{before,after}.txt   Prometheus text from the server: the mean of a histogram over the point is
                                      (sum after - sum before) / (count after - count before); warm-up requests count
  procs.csv                           proc_sampler.py: CPU per process of the server
  pyspy-<pid>.json                    py-spy speedscope profile of each Python process
and writes DIR/attrib.csv (one row per point) and DIR/attrib-profiles.txt (where each process spends its samples).

  client TTFT     AIPerf, what a user sees (results.jsonl)
  engine TTFT     vllm:time_to_first_token_seconds: from the request reaching vLLM's engine client (after the API
                  layer rendered the chat template and tokenized) to the first token leaving the output processor
  frontend TTFT   dynamo_frontend_time_to_first_token_seconds (Dynamo stacks only)
  queue, prefill  vllm:request_queue_time_seconds, vllm:request_prefill_time_seconds (engine core)
Derived, per point:
  core            queue + prefill: the engine core alone
  output path     engine TTFT - core: ZMQ from the engine core and the output processor in the API process, which
                  shares that process's event loop with everything else the API layer does
  api layer       client TTFT - engine TTFT: HTTP, chat template, tokenizing, the first SSE chunk, loopback network"""
import csv, glob, json, os, re, statistics, sys
from collections import Counter, defaultdict

HIST = {"engine_ttft_ms": "vllm:time_to_first_token_seconds", "queue_ms": "vllm:request_queue_time_seconds",
        "prefill_ms": "vllm:request_prefill_time_seconds", "frontend_ttft_ms": "dynamo_frontend_time_to_first_token_seconds"}
# Inclusive buckets: a sample counts in every bucket one of its frames matches (first match on detokenize before tokenize)
BUCKETS = [("detokenize", r"detokeniz|DecodeStream|convert_ids_to|incremental"),
           ("chat template", r"apply_chat_template|render_chat|jinja"),
           ("tokenize", r"tokeniz|encode"),
           ("http + sse", r"starlette|uvicorn|fastapi|h11|httptools|StreamingResponse|sse"),
           ("json + pydantic", r"json|pydantic|model_dump|serializ"),
           ("zmq + msgpack", r"zmq|msgspec|msgpack|core_client"),
           ("engine step", r"scheduler|schedule\b|execute_model|model_runner|sampler"),
           ("asyncio", r"asyncio|base_events|uvloop")]


def prom(path):
    """{metric_sum: v, metric_count: v} summed over label sets"""
    out = defaultdict(float)
    try:
        for line in open(path):
            m = re.match(r"([a-zA-Z_:]+?)_(sum|count)(\{[^}]*\})?\s+([0-9.eE+-]+)", line)
            if m:
                out[f"{m.group(1)}_{m.group(2)}"] += float(m.group(4))
    except FileNotFoundError:
        pass
    return out


def hist_means(d):
    before, after = defaultdict(float), defaultdict(float)
    for f in glob.glob(f"{d}/metrics-*-before.txt"):
        for k, v in prom(f).items():
            before[k] += v
    for f in glob.glob(f"{d}/metrics-*-after.txt"):
        for k, v in prom(f).items():
            after[k] += v
    row = {}
    for col, name in HIST.items():
        n = after[f"{name}_count"] - before[f"{name}_count"]
        row[col] = round(1000 * (after[f"{name}_sum"] - before[f"{name}_sum"]) / n, 2) if n > 0 else None
    return row


def role(name):
    for r, pat in (("engine core", r"EngineCore"), ("dynamo frontend", r"dynamo\.frontend"), ("dynamo worker", r"dynamo\.vllm"),
                   ("vllm-rs", r"vllm-rs"), ("api server", r"APIServer|vllm serve|vllm\.entrypoints")):
        if re.search(pat, name):
            return r
    return "other"


def cpu(d):
    """mean CPU per role while the server is busy (samples where the whole tree uses at least 20% of its peak)"""
    try:
        rows = list(csv.DictReader(open(f"{d}/procs.csv")))
    except FileNotFoundError:
        return {}
    total = defaultdict(float)
    for r in rows:
        total[r["t"]] += float(r["cpu_pct"])
    if not total:
        return {}
    busy = {t for t, v in total.items() if v >= 0.2 * max(total.values())}
    per = defaultdict(lambda: defaultdict(float))  # role -> t -> cpu
    top = defaultdict(lambda: defaultdict(float))  # role -> pid -> sum
    for r in rows:
        if r["t"] in busy:
            per[role(r["name"])][r["t"]] += float(r["cpu_pct"])
            top[role(r["name"])][r["pid"]] += float(r["cpu_pct"])
    out = {}
    for rl, ts in per.items():
        out[f"cpu {rl}"] = round(sum(ts.values()) / len(busy), 1)
        out[f"cpu {rl} busiest process"] = round(max(top[rl].values()) / len(busy), 1)
    return out


def profile(path):
    """(total samples, {bucket: share}, [(self share, frame)])"""
    try:
        sp = json.load(open(path))
    except Exception:
        return 0, {}, []
    frames = sp["shared"]["frames"]
    label = [f'{f.get("name", "?")} ({os.path.basename(f.get("file", "") or "")})' for f in frames]
    full = [f'{f.get("name", "")} {f.get("file", "") or ""}' for f in frames]  # buckets match the whole path
    hit = [[b for b, pat in BUCKETS if re.search(pat, x, re.I)] for x in full]
    total, buckets, selfs = 0, Counter(), Counter()
    for p in sp["profiles"]:
        for stack, w in zip(p["samples"], p.get("weights") or [1] * len(p["samples"])):
            if not stack:
                continue
            total += w
            for b in {b for i in stack for b in hit[i][:1]}:
                buckets[b] += w
            selfs[label[stack[-1]]] += w
    if not total:
        return 0, {}, []
    return total, {b: round(100 * v / total, 1) for b, v in buckets.items()}, [(round(100 * v / total, 1), f) for f, v in selfs.most_common(12)]


out = sys.argv[1]
points = [json.loads(l) for l in open(f"{out}/results.jsonl") if '"type": "point"' in l or '"type":"point"' in l]
rows, notes = [], []
for p in points:
    d = f'{out}/raw/{p["rep"]}/{p["model"].replace("/", "_")}/{p["stack"]}/{p["workload"]}/c{p["concurrency"]}'
    if not glob.glob(f"{d}/metrics-*") and not os.path.exists(f"{d}/procs.csv"):
        continue  # not traced
    row = {k: p.get(k) for k in ("rep", "model", "stack", "workload", "concurrency", "out_tok_s", "ttft_avg_ms", "ttft_p50_ms")}
    row.update(hist_means(d))
    if row["ttft_avg_ms"] is not None and row["engine_ttft_ms"] is not None:
        row["api_layer_ms"] = round(row["ttft_avg_ms"] - row["engine_ttft_ms"], 2)
    if row["queue_ms"] is not None and row["prefill_ms"] is not None:
        row["core_ms"] = round(row["queue_ms"] + row["prefill_ms"], 2)
        if row["engine_ttft_ms"] is not None:
            row["output_path_ms"] = round(row["engine_ttft_ms"] - row["core_ms"], 2)
    row.update(cpu(d))
    rows.append(row)
    for f in sorted(glob.glob(f"{d}/pyspy-*.json")):
        n, b, top = profile(f)
        if n:
            title = f'{p["model"]} {p["stack"]} {p["workload"]} c={p["concurrency"]} rep {p["rep"]} {os.path.basename(f)[:-5]}: {n} samples'
            notes.append(title + "\n  inclusive: " + ", ".join(f"{k} {v}%" for k, v in sorted(b.items(), key=lambda x: -x[1]))
                         + "\n" + "\n".join(f"  {s:5.1f}%  {fr}" for s, fr in top))
if not rows:
    sys.exit(f"attrib: no traced points in {out} (run oif bench with --trace)")
cols = list(dict.fromkeys(k for r in rows for k in r))
with open(f"{out}/attrib.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=cols)
    w.writeheader()
    w.writerows(rows)
open(f"{out}/attrib-profiles.txt", "w").write("\n\n".join(notes) + "\n")
# console: median over repeats per stack, workload and concurrency
g = defaultdict(list)
for r in rows:
    g[(r["model"], r["workload"], r["concurrency"], r["stack"])].append(r)
med = lambda rs, k: statistics.median([r[k] for r in rs if r.get(k) is not None]) if any(r.get(k) is not None for r in rs) else None
fmt = lambda v: "-" if v is None else f"{v:.1f}"
print(f'{"model":<16}{"wl":<7}{"c":>4}  {"stack":<12}{"client":>8}{"engine":>8}{"core":>7}{"out path":>9}{"api layer":>10}{"api CPU":>9}{"busiest":>9}')
for (m, wl, c, s), rs in sorted(g.items()):
    print(f'{m.split("/")[-1]:<16}{wl:<7}{c:>4}  {s:<12}{fmt(med(rs, "ttft_avg_ms")):>8}{fmt(med(rs, "engine_ttft_ms")):>8}'
          f'{fmt(med(rs, "core_ms")):>7}{fmt(med(rs, "output_path_ms")):>9}{fmt(med(rs, "api_layer_ms")):>10}'
          f'{fmt(med(rs, "cpu api server") or med(rs, "cpu dynamo frontend") or med(rs, "cpu vllm-rs")):>9}'
          f'{fmt(med(rs, "cpu api server busiest process")):>9}')
print(f"attrib: {len(rows)} traced points -> {out}/attrib.csv, {out}/attrib-profiles.txt")
