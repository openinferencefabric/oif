"""Per-request time to first token of each point (B-3a step 0): ttft_hist.py RUN_DIR [FILTER ...]

Reads RUN_DIR/raw/<rep>/<model>/<stack>/<workload>/c<N>/**/profile_export.jsonl (AIPerf's per-request records; the
profiling phase only, failed requests left out) and prints per point: percentiles, a histogram, the bimodality
coefficient (above 0.555 suggests two peaks), and the share of requests that start in waves. A wave is a run of
requests whose starts are less than 2 ms apart with at least max(4, N/4) members: in a closed loop at fixed output
length, requests can finish together and restart together, so TTFT depends on a request's place in its wave rather
than on the server alone. FILTER keeps the points whose path (model/stack/workload/cN) contains every word."""
import glob, json, os, statistics, sys

GAP_MS = 2.0
run, words = sys.argv[1], sys.argv[2:]


def pct(xs, q):
    return xs[min(len(xs) - 1, int(q / 100 * len(xs)))]


def bimodality(xs):
    n, m, sd = len(xs), statistics.mean(xs), statistics.pstdev(xs)
    if n < 4 or sd == 0:
        return 0.0
    skew = sum(((x - m) / sd) ** 3 for x in xs) / n
    kurt = sum(((x - m) / sd) ** 4 for x in xs) / n - 3
    return (skew ** 2 + 1) / (kurt + 3 * (n - 1) ** 2 / ((n - 2) * (n - 3)))


for f in sorted(glob.glob(f"{run}/raw/*/*/*/*/c*/**/profile_export.jsonl", recursive=True)):
    rel = os.path.relpath(f, f"{run}/raw").replace(os.sep, "/").split("/")
    rep, point, conc = rel[0], "/".join(rel[1:5]), int(rel[4][1:])
    if not all(w in point for w in words):
        continue
    reqs = []
    for line in open(f):
        r = json.loads(line)
        md, ttft = r.get("metadata", {}), (r.get("metrics", {}).get("time_to_first_token") or {}).get("value")
        if md.get("benchmark_phase", "profiling") == "profiling" and not r.get("error") and ttft is not None:
            reqs.append((md["request_start_ns"] / 1e6, ttft))
    if len(reqs) < 4:
        print(f"== {point} rep {rep}: {len(reqs)} requests, too few")
        continue
    reqs.sort()
    groups, cur = [], [reqs[0]]
    for prev, r in zip(reqs, reqs[1:]):
        if r[0] - prev[0] < GAP_MS:
            cur.append(r)
        else:
            groups.append(cur); cur = [r]
    groups.append(cur)
    in_waves = sum(len(g) for g in groups if len(g) >= max(4, conc // 4))
    t = sorted(x for _, x in reqs)
    bc = bimodality(t)
    print(f"== {point} rep {rep}")
    print(f"   requests {len(t)}  p10 {pct(t, 10):.1f}  p50 {pct(t, 50):.1f}  p90 {pct(t, 90):.1f}  p99 {pct(t, 99):.1f} ms")
    print(f"   bimodality {bc:.2f} (bimodal {'yes' if bc > 0.555 else 'no'})  in waves {100 * in_waves // len(t)}%"
          f"  largest wave {max(len(g) for g in groups)}")
    lo, hi = t[0], t[-1]
    width = (hi - lo) / 10 or 1
    counts = [0] * 10
    for x in t:
        counts[min(9, int((x - lo) / width))] += 1
    for i, c in enumerate(counts):
        print(f"   {lo + i * width:8.1f} ms  {'#' * round(50 * c / max(counts)):<50} {c}")
