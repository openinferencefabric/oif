# B-2 evidence: the B-1b benchmark on NVIDIA (RTX A6000)

NVIDIA RTX A6000 on the same lab node as the W7900 of B-1b (same host CPUs), Qwen3-0.6B, profile `attrib`, stacks
`vllm`, `vllm-api4`, `vllm-rs` (vllm/vllm-openai v0.33.0) and `dynamo-vllm` (Dynamo built from fork commit
d893564741 with upstream's CUDA recipe on vllm/vllm-openai v0.33.0). Versions per stack in `*/images.jsonl`; method
and the comparison with the W7900 in guide 18, "The same benchmark on NVIDIA (B-2)".

| Directory | Run | Code | Points |
| --- | --- | --- | --- |
| `time/` | timings, 3 repeats, 2026-11-21/22 | dd02af2 | 120, 0 failed, 0 request errors |
| `trace/` | `--trace`, 1 repeat, 2026-11-22 | dd02af2 | 40, 0 failed, 0 request errors, no other process on the GPU |

Files as in `docs/evidence/B-1b`. The desktop login screen (GDM) was stopped for the runs: it had opened the A6000.
Earlier starts that stopped after point 1 (oif bench's own nvidia-smi, then `watch nvidia-smi`, counted as another
program) were discarded; the fixes are in dd02af2.
