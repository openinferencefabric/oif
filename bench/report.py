"""oif bench report: DIR/results.jsonl + DIR/env.json -> DIR/report.html (self-contained) and DIR/summary.csv.

report.py DIR
Repeats are combined by the median. A Dynamo-vs-engine difference is called "within noise" when it is smaller than
twice the larger run-to-run spread (coefficient of variation) of the two stacks at that point (needs 2+ repeats)."""
import csv, html, json, os, statistics, sys
from collections import defaultdict

D = sys.argv[1]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
env = json.load(open(os.path.join(D, "env.json")))
rows = [json.loads(l) for l in open(os.path.join(D, "results.jsonl")) if l.strip()]
points = [r for r in rows if r.get("type") == "point"]
starts = [r for r in rows if r.get("type") == "startup"]
runtimes = [r for r in rows if r.get("type") == "runtime"]
STACK_ORDER = ["vllm", "dynamo-vllm", "sglang", "dynamo-sglang"]
PAIRS = [("vllm", "dynamo-vllm"), ("sglang", "dynamo-sglang")]
METRICS = ["out_tok_s", "prefill_tok_s", "req_s", "tok_s_per_user", "ttft_p50_ms", "ttft_p99_ms", "itl_p50_ms", "itl_p99_ms",
           "e2e_p50_ms", "e2e_p99_ms", "gpu_busy_avg", "power_avg_w", "tok_per_joule", "vram_max_mib",
           "junction_max_c", "sclk_avg_mhz", "osl_avg", "errors"]

# ---------------------------------------------------------------- aggregate repeats (median), keep spread
groups = defaultdict(list)
for p in points:
    groups[(p["model"], p["stack"], p["workload"], p["concurrency"])].append(p)
agg = []
for (model, stack, wl, c), ps in sorted(groups.items(), key=lambda kv: (kv[0][0], STACK_ORDER.index(kv[0][1]) if kv[0][1] in STACK_ORDER else 9, kv[0][2], kv[0][3])):
    a = {"model": model, "stack": stack, "workload": wl, "concurrency": c, "isl": ps[0]["isl"], "osl": ps[0]["osl"],
         "repeats": len(ps), "failed": sum(1 for p in ps if p.get("rc") or not p.get("export"))}
    for k in METRICS:
        vals = [p[k] for p in ps if isinstance(p.get(k), (int, float))]
        a[k] = round(statistics.median(vals), 2) if vals else None
    tp = [p["out_tok_s"] for p in ps if p.get("out_tok_s")]
    a["cv_pct"] = round(100 * statistics.stdev(tp) / statistics.mean(tp), 2) if len(tp) > 1 else None
    a["osl_ok"] = a["osl_avg"] is None or abs(a["osl_avg"] - a["osl"]) <= 0.02 * a["osl"]
    agg.append(a)
by = {(a["model"], a["stack"], a["workload"], a["concurrency"]): a for a in agg}
models = list(dict.fromkeys(a["model"] for a in agg)) or env.get("models", [])
stacks = [s for s in STACK_ORDER if any(a["stack"] == s for a in agg)]
workloads = list(dict.fromkeys(w.split(":")[0] for w in env.get("workloads", []))) or sorted({a["workload"] for a in agg})


def pct(a, b):
    return None if a in (None, 0) or b is None else round(100 * (b - a) / a, 1)


# ---------------------------------------------------------------- Dynamo vs engine at every point
over = []
for eng, dyn in PAIRS:
    for (model, stack, wl, c), a in by.items():
        if stack != eng or (model, dyn, wl, c) not in by:
            continue
        b = by[(model, dyn, wl, c)]
        noise = max(a["cv_pct"] or 0, b["cv_pct"] or 0)
        d_tp = pct(a["out_tok_s"], b["out_tok_s"])
        over.append({"pair": f"{dyn} vs {eng}", "model": model, "workload": wl, "concurrency": c,
                     "tp_engine": a["out_tok_s"], "tp_dynamo": b["out_tok_s"], "d_tp_pct": d_tp,
                     "d_ttft_p50_ms": None if a["ttft_p50_ms"] is None or b["ttft_p50_ms"] is None else round(b["ttft_p50_ms"] - a["ttft_p50_ms"], 1),
                     "d_ttft_p50_pct": pct(a["ttft_p50_ms"], b["ttft_p50_ms"]), "d_ttft_p99_pct": pct(a["ttft_p99_ms"], b["ttft_p99_ms"]),
                     "d_itl_p50_pct": pct(a["itl_p50_ms"], b["itl_p50_ms"]), "d_e2e_p99_pct": pct(a["e2e_p99_ms"], b["e2e_p99_ms"]),
                     "noise_pct": noise if (a["cv_pct"] is not None and b["cv_pct"] is not None) else None,
                     "within_noise": (d_tp is not None and a["cv_pct"] is not None and b["cv_pct"] is not None and abs(d_tp) <= 2 * noise)})


def med(vals):
    vals = [v for v in vals if v is not None]
    return round(statistics.median(vals), 1) if vals else None


headline = []
for eng, dyn in PAIRS:
    for model in models:
        o = [x for x in over if x["pair"] == f"{dyn} vs {eng}" and x["model"] == model]
        if not o:
            continue
        headline.append({"pair": f"{dyn} vs {eng}", "model": model, "points": len(o),
                         "d_tp_pct": med([x["d_tp_pct"] for x in o]), "d_ttft_ms": med([x["d_ttft_p50_ms"] for x in o]),
                         "d_itl_pct": med([x["d_itl_p50_pct"] for x in o]),
                         "worst_tp_pct": min((x["d_tp_pct"] for x in o if x["d_tp_pct"] is not None), default=None),
                         "within_noise": sum(1 for x in o if x["within_noise"])})

# ---------------------------------------------------------------- CSV
with open(os.path.join(D, "summary.csv"), "w", newline="") as f:
    cols = ["model", "stack", "workload", "isl", "osl", "concurrency", "repeats", "failed", "cv_pct", "osl_ok"] + METRICS
    w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore"); w.writeheader(); w.writerows(agg)

# ---------------------------------------------------------------- startup, quality of the run
start_rows = []
for model in models:
    for s in stacks:
        st = [x for x in starts if x["model"] == model and x["stack"] == s]
        ok = [x["ready_s"] for x in st if x.get("ready_s") is not None]
        vr = [x["vram_bytes"] / 2**30 for x in st if x.get("vram_bytes")]
        rt = [x["run_s"] / 60 for x in runtimes if x["model"] == model and x["stack"] == s]
        start_rows.append([model, s, f"{len(ok)}/{len(st)}", med(ok), round(statistics.median(vr), 1) if vr else None,
                           med(rt), round(sum(rt), 1) if rt else None])
failed = [a for a in agg if a["failed"] or (a["errors"] or 0) > 0]
osl_bad = [a for a in agg if not a["osl_ok"]]

# ---------------------------------------------------------------- HTML
def mark(theme):
    p = os.path.join(ROOT, "brand", f"oif-mark-{theme}.svg")
    s = open(p).read() if os.path.exists(p) else ""
    return s.replace('width="264" height="200"', 'width="66" height="50"')


def table(head, body, cls=""):
    th = "".join(f"<th>{html.escape(str(h))}</th>" for h in head)
    tr = "".join("<tr>" + "".join(f"<td>{'—' if v is None else html.escape(str(v))}</td>" for v in r) + "</tr>" for r in body)
    return f'<div class="tw"><table class="{cls}"><thead><tr>{th}</tr></thead><tbody>{tr}</tbody></table></div>'


def sgn(v, unit="%"):
    return "—" if v is None else f"{'+' if v > 0 else ''}{v}{unit}"


img_rows = [[i.get("stack"), i.get("image", "").split("@")[0], (i.get("digest") or "").split("@")[-1][:19],
             ", ".join(f"{k} {v}" for k, v in (i.get("inside") or {}).items())] for i in env.get("images", [])]
tiles = "".join(
    f'<div class="tile"><div class="tl">{html.escape(h["pair"])}<br><b>{html.escape(h["model"])}</b></div>'
    f'<div class="tv">{sgn(h["d_tp_pct"])}</div><div class="tl">median output-throughput difference over {h["points"]} points'
    f' (worst {sgn(h["worst_tp_pct"])})</div><div class="ts">TTFT p50 {sgn(h["d_ttft_ms"], " ms")} · TPOT p50 {sgn(h["d_itl_pct"])}'
    f'{" · " + str(h["within_noise"]) + " points within noise" if env.get("repeats", 1) > 1 else ""}</div></div>'
    for h in headline) or '<p class="muted">No Dynamo/engine pair has results yet.</p>'
over_body = [[o["pair"], o["model"], o["workload"], o["concurrency"], o["tp_engine"], o["tp_dynamo"], sgn(o["d_tp_pct"]),
              sgn(o["d_ttft_p50_ms"], " ms"), sgn(o["d_ttft_p99_pct"]), sgn(o["d_itl_p50_pct"]), sgn(o["d_e2e_p99_pct"]),
              "—" if o["noise_pct"] is None else ("within noise" if o["within_noise"] else f"real (noise {o['noise_pct']}%)")]
             for o in over]
skipped = [s for s in STACK_ORDER if s not in stacks]
data = {"agg": agg, "models": models, "stacks": stacks, "workloads": workloads, "conc": env.get("concurrency", [])}

page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>oif bench {html.escape(env.get("gpu", "GPU"))}</title>
<style>
:root{{--page:#f9f9f7;--surface:#fcfcfb;--ink:#0b0b0b;--ink2:#52514e;--muted:#898781;--grid:#e1e0d9;--axis:#c3c2b7;--ring:rgba(11,11,11,.10);
--s1:#2a78d6;--s2:#eb6834;--s3:#1baf7a;--s4:#eda100;--teal:#0E7C86}}
@media (prefers-color-scheme:dark){{:root:not([data-theme=light]){{--page:#0d0d0d;--surface:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;--grid:#2c2c2a;--axis:#383835;--ring:rgba(255,255,255,.10);
--s1:#3987e5;--s2:#d95926;--s3:#199e70;--s4:#c98500}}}}
:root[data-theme=dark]{{--page:#0d0d0d;--surface:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;--grid:#2c2c2a;--axis:#383835;--ring:rgba(255,255,255,.10);
--s1:#3987e5;--s2:#d95926;--s3:#199e70;--s4:#c98500}}
*{{box-sizing:border-box}} body{{margin:0;background:var(--page);color:var(--ink);font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}}
main{{max-width:1180px;margin:0 auto;padding:24px 16px 64px}} h1{{font-size:26px;margin:0}} h2{{font-size:19px;margin:36px 0 8px}} h3{{font-size:16px;margin:20px 0 6px}}
.muted{{color:var(--ink2)}} header{{display:flex;gap:14px;align-items:center}} .mk-d{{display:none}}
@media (prefers-color-scheme:dark){{:root:not([data-theme=light]) .mk-l{{display:none}} :root:not([data-theme=light]) .mk-d{{display:inline}}}}
:root[data-theme=dark] .mk-l{{display:none}} :root[data-theme=dark] .mk-d{{display:inline}}
.card{{background:var(--surface);border:1px solid var(--ring);border-radius:12px;padding:16px;margin:12px 0}}
.tiles{{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px}} .tile{{background:var(--surface);border:1px solid var(--ring);border-radius:12px;padding:14px}}
.tv{{font-size:30px;font-weight:600;margin:4px 0}} .tl{{color:var(--ink2);font-size:13px}} .ts{{font-size:13px;margin-top:6px}}
.tw{{overflow-x:auto}} table{{border-collapse:collapse;width:100%;font-size:13px;font-variant-numeric:tabular-nums}} th,td{{text-align:left;padding:5px 8px;border-bottom:1px solid var(--grid);white-space:nowrap}} th{{color:var(--ink2);font-weight:600}}
.ctl{{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:8px 0}} select,button{{font:inherit;color:var(--ink);background:var(--surface);border:1px solid var(--axis);border-radius:8px;padding:5px 10px}}
.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:12px}} .panel{{background:var(--surface);border:1px solid var(--ring);border-radius:12px;padding:10px 10px 4px;position:relative}}
.panel h4{{margin:0 0 2px;font-size:14px}} .panel .sub{{color:var(--ink2);font-size:12px}} svg text{{fill:var(--muted);font-size:11px}}
.legend{{display:flex;flex-wrap:wrap;gap:14px;font-size:13px;color:var(--ink2)}} .legend span{{display:inline-flex;align-items:center;gap:6px}}
.tip{{position:absolute;pointer-events:none;background:var(--surface);border:1px solid var(--axis);border-radius:8px;padding:6px 8px;font-size:12px;display:none;z-index:2;box-shadow:0 2px 8px rgba(0,0,0,.15)}}
details summary{{cursor:pointer;color:var(--ink2)}} code{{font-size:12px}} ul{{padding-left:20px}}
</style></head><body><main>
<header><span class="mk-l">{mark("light")}</span><span class="mk-d">{mark("dark")}</span>
<div><h1>Dynamo vs plain engine on the {html.escape(env.get("gpu", "GPU"))}</h1>
<div class="muted">open inference fabric · oif bench, profile {html.escape(str(env.get("profile")))} · {env.get("repeats")} repeat(s) · AIPerf {html.escape(str(env.get("aiperf")))}</div></div>
<button id="theme" style="margin-left:auto" aria-label="Switch light or dark">Light / dark</button></header>

<h2>What this measures</h2>
<p>The Dynamo image is built <b>FROM</b> the plain engine image, so the engine, PyTorch and ROCm are the same files. Both get the same engine
arguments, the same AIPerf prompts (fixed seed) and exact output lengths (<code>ignore_eos</code>), one at a time on one GPU that starts
each point below {env.get("max_start_temp_c")} °C. What differs is Dynamo's frontend, request plane and worker wrapper. A small negative
number is the price of that layer; Dynamo's gains (KV-aware routing across workers, disaggregation, planner) need more than one GPU and are not
part of this test.</p>
{"<p class='muted'>Not in this run: " + ", ".join(skipped) + " (no image pinned yet; SGLang needs spike S-5 on gfx1100 first).</p>" if skipped else ""}

<h2>Headline: Dynamo vs engine</h2><div class="tiles">{tiles}</div>
<p class="muted">Positive throughput means Dynamo served more output tokens per second; positive TTFT/TPOT means Dynamo was slower.
Medians over every workload and concurrency point.</p>

<h2>Curves</h2>
<p class="muted">Metric definitions: docs/BENCHMARK.md in the oif repository. TPOT is the average gap between generated tokens after the first; speed per user is 1000 ÷ TPOT.</p>
<div class="ctl"><label>Model <select id="model"></select></label><label>Metric <select id="metric"></select></label></div>
<div class="legend" id="legend"></div>
<div class="grid" id="charts"></div>
<details class="card"><summary>Table view of the curves</summary><div id="ctable"></div></details>

<h2>Dynamo vs engine at every point</h2>
<div class="card">{table(["pair", "model", "workload", "conc", "engine tok/s", "Dynamo tok/s", "Δ throughput", "Δ TTFT p50", "Δ TTFT p99", "Δ TPOT p50", "Δ E2E p99", "verdict"], over_body)}</div>

<h2>Start-up, memory and run time</h2>
<div class="card">{table(["model", "stack", "started", "seconds to first answer (median)", "VRAM after start (GiB)", "run time per repeat (min, median)", "run time, all repeats (min)"], start_rows)}</div>

<h2>Run quality</h2>
<ul><li>Points with failed runs or request errors: <b>{len(failed)}</b>{(" — " + "; ".join(f"{a['model']} {a['stack']} {a['workload']} c={a['concurrency']} ({a['errors']} errors)" for a in failed[:12])) if failed else ""}</li>
<li>Points where the mean output length missed the requested length by more than 2%: <b>{len(osl_bad)}</b>{" (ignore_eos not honoured there; throughput is not comparable)" if osl_bad else " (every request produced the requested tokens)"}</li>
<li>Run-to-run spread of output throughput: {("median CV " + str(med([a["cv_pct"] for a in agg])) + "%") if env.get("repeats", 1) > 1 else "one repeat only: no spread, so no noise verdict (the full profile runs 3)"}</li></ul>

<h2>Environment</h2>
<div class="card">{table(["stack", "image", "digest", "inside"], img_rows)}
<p>GPU {html.escape(env.get("gpu", ""))}, {round(env.get("vram_total_bytes", 0) / 2**30)} GiB, power cap {env.get("power_cap_w")} W · amdgpu {html.escape(str(env.get("amdgpu")))} · kernel {html.escape(env.get("kernel", ""))} · {env.get("cpus")} CPUs</p>
<p>vLLM arguments: <code>{html.escape(env.get("vllm_args", ""))}</code><br>SGLang arguments: <code>{html.escape(env.get("sglang_args", ""))}</code><br>
Workloads (name:input:output tokens): <code>{html.escape(" ".join(env.get("workloads", [])))}</code> · concurrency {html.escape(" ".join(map(str, env.get("concurrency", []))))} · {env.get("duration_s")} s per point, warm-up max(c, 4) requests</p>
<p class="muted">Raw AIPerf exports, GPU samples (0.5 s) and server logs are in the result directory; <code>summary.csv</code> has every median shown here.</p></div>
</main>
<script>
const DATA={json.dumps(data)};
const COL={{"vllm":"var(--s1)","dynamo-vllm":"var(--s2)","sglang":"var(--s3)","dynamo-sglang":"var(--s4)"}};
const DASH=s=>s.startsWith("dynamo")?"6 4":"";
const MET={{out_tok_s:["Output tokens/s","",1],prefill_tok_s:["Prompt processing rate (input tokens/s)","",1],tok_s_per_user:["Speed per user (tokens/s)","",1],req_s:["Requests/s","",1],
ttft_p50_ms:["TTFT p50","ms",0],ttft_p99_ms:["TTFT p99","ms",0],itl_p50_ms:["TPOT p50","ms",0],itl_p99_ms:["TPOT p99","ms",0],
e2e_p50_ms:["End-to-end latency p50","ms",0],e2e_p99_ms:["End-to-end latency p99","ms",0],power_avg_w:["GPU power","W",0],
tok_per_joule:["Output tokens per joule","",1],gpu_busy_avg:["GPU busy","%",0]}};
const $=id=>document.getElementById(id);
try{{const t=localStorage.getItem("oif-theme");if(t)document.documentElement.dataset.theme=t;}}catch(e){{}}
$("theme").onclick=()=>{{const dark=document.documentElement.dataset.theme==="dark"||(!document.documentElement.dataset.theme&&matchMedia("(prefers-color-scheme: dark)").matches);
document.documentElement.dataset.theme=dark?"light":"dark";try{{localStorage.setItem("oif-theme",document.documentElement.dataset.theme)}}catch(e){{}}}};
DATA.models.forEach(m=>$("model").add(new Option(m,m)));Object.entries(MET).forEach(([k,v])=>$("metric").add(new Option(v[0]+(v[1]?" ("+v[1]+")":""),k)));
$("legend").innerHTML=DATA.stacks.map(s=>`<span><svg width="26" height="10"><line x1="1" y1="5" x2="25" y2="5" stroke="${{COL[s]}}" stroke-width="2" stroke-dasharray="${{DASH(s)}}"/></svg>${{s}}</span>`).join("");
function fmt(v){{return v==null?"—":(Math.abs(v)>=100?Math.round(v).toLocaleString():(+v).toFixed(1))}}
function draw(){{const m=$("model").value,k=$("metric").value,[label,unit]=MET[k];const C=DATA.conc;let out="",rows=[];
for(const w of DATA.workloads){{const pts=DATA.agg.filter(a=>a.model===m&&a.workload===w);if(!pts.length)continue;
const W=340,H=210,L=46,R=10,T=10,B=28;const vals=pts.map(p=>p[k]).filter(v=>v!=null);const ymax=Math.max(...vals,0)*1.1||1;
const x=i=>L+(C.length>1?i*(W-L-R)/(C.length-1):0),y=v=>T+(H-T-B)*(1-v/ymax);let g="";
for(let i=0;i<=4;i++){{const v=ymax*i/4;g+=`<line x1="${{L}}" x2="${{W-R}}" y1="${{y(v)}}" y2="${{y(v)}}" stroke="var(--grid)" stroke-width="1"/><text x="${{L-6}}" y="${{y(v)+4}}" text-anchor="end">${{fmt(v)}}</text>`}}
C.forEach((c,i)=>g+=`<text x="${{x(i)}}" y="${{H-10}}" text-anchor="middle">${{c}}</text>`);
let lines="";for(const s of DATA.stacks){{const ps=C.map((c,i)=>{{const p=pts.find(p=>p.stack===s&&p.concurrency===c);return p&&p[k]!=null?[x(i),y(p[k])]:null}}).filter(Boolean);
if(!ps.length)continue;lines+=`<polyline fill="none" stroke="${{COL[s]}}" stroke-width="2" stroke-dasharray="${{DASH(s)}}" points="${{ps.map(p=>p.join(",")).join(" ")}}"/>`+
ps.map(p=>`<circle cx="${{p[0]}}" cy="${{p[1]}}" r="3.5" fill="${{COL[s]}}" stroke="var(--surface)" stroke-width="2"/>`).join("")}}
const ex=pts[0];out+=`<div class="panel" data-w="${{w}}"><h4>${{w}}</h4><div class="sub">${{ex.isl}} in / ${{ex.osl}} out tokens · ${{label}}${{unit?" ("+unit+")":""}} by concurrency</div>
<svg viewBox="0 0 ${{W}} ${{H}}" width="100%" role="img" aria-label="${{label}} for ${{w}}">${{g}}<line x1="${{L}}" x2="${{W-R}}" y1="${{y(0)}}" y2="${{y(0)}}" stroke="var(--axis)"/>${{lines}}
<line class="cross" x1="0" x2="0" y1="${{T}}" y2="${{H-B}}" stroke="var(--axis)" visibility="hidden"/><rect x="${{L}}" y="0" width="${{W-L-R}}" height="${{H}}" fill="transparent" class="hit"/></svg><div class="tip"></div></div>`;
C.forEach(c=>{{const r=[w,c];DATA.stacks.forEach(s=>{{const p=pts.find(p=>p.stack===s&&p.concurrency===c);r.push(p?fmt(p[k]):"—")}});rows.push(r)}})}}
$("charts").innerHTML=out||"<p class='muted'>No results for this model.</p>";
$("ctable").innerHTML=`<div class="tw"><table><thead><tr><th>workload</th><th>concurrency</th>${{DATA.stacks.map(s=>`<th>${{s}}</th>`).join("")}}</tr></thead><tbody>${{rows.map(r=>"<tr>"+r.map(v=>`<td>${{v}}</td>`).join("")+"</tr>").join("")}}</tbody></table></div>`;
document.querySelectorAll(".panel").forEach(pn=>{{const svg=pn.querySelector("svg"),tip=pn.querySelector(".tip"),cross=pn.querySelector(".cross"),w=pn.dataset.w;
const pick=e=>{{const r=svg.getBoundingClientRect(),vx=(e.clientX-r.left)*340/r.width;const i=Math.max(0,Math.min(C.length-1,Math.round((vx-46)/((340-56)/Math.max(1,C.length-1)))));return i}};
svg.addEventListener("mousemove",e=>{{const i=pick(e),c=C[i],xx=46+(C.length>1?i*(340-56)/(C.length-1):0);cross.setAttribute("x1",xx);cross.setAttribute("x2",xx);cross.setAttribute("visibility","visible");
tip.innerHTML=`<b>concurrency ${{c}}</b><br>`+DATA.stacks.map(s=>{{const p=DATA.agg.find(p=>p.model===m&&p.workload===w&&p.stack===s&&p.concurrency===c);return `<span style="color:${{COL[s]}}">■</span> ${{s}}: ${{p?fmt(p[k]):"—"}} ${{unit}}`}}).join("<br>");
tip.style.display="block";const pr=pn.getBoundingClientRect();tip.style.left=Math.min(e.clientX-pr.left+12,pr.width-170)+"px";tip.style.top=(e.clientY-pr.top+12)+"px"}});
svg.addEventListener("mouseleave",()=>{{tip.style.display="none";cross.setAttribute("visibility","hidden")}})}})}}
$("model").onchange=draw;$("metric").onchange=draw;draw();
</script></body></html>"""
open(os.path.join(D, "report.html"), "w").write(page)
print(f"report: {len(points)} points, {len(agg)} medians, {len(over)} Dynamo/engine comparisons")
