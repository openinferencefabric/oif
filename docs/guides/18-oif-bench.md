# 18. Benchmark Dynamo against its engine: `oif bench`

> Status: built (B-1); the report is tested on synthetic data. The first lab run on the W7900 is pending; this guide is
> updated with its real output.

## What you get

`sudo ./oif bench` on a GPU node runs the same model on the plain engine (vLLM's own server) and on Dynamo built on top
of that engine, one after the other on the same GPU, with AIPerf. The result is one HTML report: output throughput,
prompt processing rate, time to first token, time per output token, speed per user, end-to-end latency, GPU power and
tokens per joule by concurrency, and Dynamo's difference from the engine at every point with a "within noise" verdict.
Method and metric definitions: [docs/BENCHMARK.md](../BENCHMARK.md).

| Stack | Image (versions.env) | Server |
| --- | --- | --- |
| `vllm` | `BENCH_VLLM_IMAGE`: vllm/vllm-openai-rocm v0.33.0 | `vllm serve` |
| `dynamo-vllm` | `DYNAMO_ROCM_IMAGE`: OIF's Dynamo ROCm build, FROM the image above (T-211) | `dynamo.frontend` + `dynamo.vllm`, aggregated |
| `sglang`, `dynamo-sglang` | empty until S-5 (SGLang on gfx1100) and T-212 | skipped |

## Before you start

- A node with the AMD Radeon PRO W7900 and the amdgpu driver (in the lab: VM `gpu-amd`). The W6400 is never used.
- Nothing else using the GPU. On a cluster node stop the kubelet for the run (`sudo systemctl stop kubelet`); start it
  again afterwards.
- Docker or Podman (`sudo apt-get install -y podman psmisc`), internet access for images and models, 60 GB free under
  `/var/tmp`.
- While the OIF packages on ghcr.io are private: a GitHub token with `read:packages`.

## Steps

1. Get oif on the node and log in to ghcr.io:

   ```bash
   git clone https://github.com/openinferencefabric/oif && cd oif
   read -rsp "GHCR token: " T; echo "$T" | sudo podman login ghcr.io -u <github-user> --password-stdin; unset T
   ```

2. A quick run first (about 30–40 minutes with the image pulls; two workloads, concurrency 1, 8 and 32, 30 s each):

   ```bash
   sudo ./oif bench --profile quick
   ```

   You should see the GPU found, both images pulled, the versions inside each image, both models downloaded, then per
   stack `ready in N s` and one line per point:

   ```text
   == repeat 1  Qwen/Qwen3-0.6B  vllm
      ready in 95s, VRAM 44012 MiB
      [1/24] chat     c=1   rc=0  ... tok/s  TTFT p50 ... ms  TPOT p50 ... ms  errors 0  OSL 256.0  GPU ..% .. W
   ```

3. The full run (the comparable result: four workloads, concurrency 1 to 64, 60 s per point, 3 repeats; about 7–8 hours),
   detached so a dropped SSH session does not stop it:

   ```bash
   sudo nohup setsid ./oif bench > ~/oif-bench-full.log 2>&1 &
   tail -f ~/oif-bench-full.log
   ```

Options: `--stacks "vllm dynamo-vllm"`, `--models "Qwen/Qwen3-8B"`, `--repeats N`, `--out DIR`, `--profile quick|full`
(bench/profiles). `HF_TOKEN` in the environment for gated models.

## Check it worked

- `/var/tmp/oif-bench/<date>/report.html` opens (copy it off the node), the run-quality section shows 0 failed points
  and 0 points with a short output length.
- `./oif bench report /var/tmp/oif-bench/<date>` rebuilds the report from `results.jsonl`.

## What changed on the host

- Container images (vLLM ROCm and OIF's Dynamo ROCm, about 20 GB with shared layers) and models under
  `/var/tmp/oif-bench/hf`; results under `/var/tmp/oif-bench/<date>`. Remove them with `sudo podman rmi <image>` and
  `sudo rm -rf /var/tmp/oif-bench`.
- Podman, if you installed it for the run. `oif bench` changes nothing else on the node; it is not part of
  `oif install`, so `oif uninstall` does not track it.
- The kubelet, if you stopped it: `sudo systemctl start kubelet`.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `something already uses the GPU (/dev/kfd)` | Stop the kubelet or the container holding the GPU; `sudo fuser -v /dev/kfd` names it. |
| `pull ... failed` for ghcr.io | Log in to ghcr.io (step 1) while the package is private. |
| `not ready` and the server log | The log is in `<out>/logs/server-*.log`; a model too large for the GPU at `--max-model-len 8192` fails here. |
| Output length short in the run-quality section | The stack ignored `ignore_eos`; throughput at those points is not comparable. |
