# B-1b evidence: where Dynamo's first-token gain comes from (W7900)

Radeon Pro W7900 (gfx1100) on the lab node, Qwen3-0.6B, profile `attrib` (chat 512/256 and short 128/128, 1 to 64
users, 60 s per point), stacks `vllm`, `vllm-api4`, `vllm-rs`, `dynamo-vllm`. Images and versions per stack in
`*/images.jsonl` and `*/env.json`; method in guide 18, "Where the first-token time goes (B-1b)".

| Directory | Run | Code | Points |
| --- | --- | --- | --- |
| `time/` | timings, 3 repeats, 2026-11-20 | 68f8b27 | 120, 0 failed, 0 request errors |
| `trace/` | `--trace`, 1 repeat, 2026-11-21 | 43eb4fb | 40, 0 failed, 0 request errors, no other process on the GPU |

Files: `results.jsonl` (one line per point), `summary.csv` (medians), `report.html` (`oif bench report`),
`attrib.csv` (time to first token split per point, CPU per process role), `attrib-profiles.txt` (py-spy samples by
bucket and top functions per process). The raw per-request data, CPU samples and speedscope profiles stay on the node.

Two earlier trace runs were discarded and not kept here: one shared the GPU with another program for 10 hours (the
reason for the per-point check), one started on code from before that check. In the kept trace run py-spy on the
engine core was stopped by its timeout at some points, so those points have no engine-core profile; the time split
does not depend on it.
