# oif bench

Benchmarks Dynamo against the plain engine its image is built on, on the GPU of the node it runs on, with AIPerf
(ADR-006), one GPU at a time below a start temperature (ADR-009), under the fair-comparison rules of ADR-012.

```bash
sudo ./oif bench --profile quick                 # about 25 min per stack and model: a check, not a result
sudo ./oif bench                                 # full profile: the comparable result (3 repeats)
sudo ./oif bench --stacks "vllm dynamo-vllm" --models "Qwen/Qwen3-8B"
./oif bench report /var/tmp/oif-bench/<run>      # rebuild the report
```

| File | Role |
| --- | --- |
| `oif-bench.sh` | preflight (GPU, nothing else on it, disk), image pulls, versions inside each image, model downloads, server start per stack, AIPerf per point |
| `profiles/*.env` | workloads (name:input:output tokens), concurrency levels, seconds per point, repeats |
| `gpu_sampler.py` | GPU busy, VRAM, power, temperatures and clock from amdgpu sysfs every 0.5 s |
| `collect.py` | one point: AIPerf export + GPU samples into one line of `results.jsonl` |
| `report.py` | medians over repeats, Dynamo-vs-engine difference with a noise verdict, `report.html`, `summary.csv` |

Images come from `versions.env` (`BENCH_*`, `DYNAMO_*ROCM_IMAGE`); a stack without an image is skipped. Before a run,
stop anything that holds the GPU on that node (`systemctl stop kubelet` on a cluster node) and log in to ghcr.io while
the OIF packages are private.
