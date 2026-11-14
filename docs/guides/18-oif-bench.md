# 18. Benchmark Dynamo against its engine: `oif bench`

> Status: done (B-1). Tested on the lab's W7900 on 2026-11-13/14: quick run, then the full run, one model at a time.
> Output and numbers: [docs/evidence/B-1](../evidence/B-1/01-run.txt).

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

## Steps

1. Get oif on the node (the images are public, no registry login needed):

   ```bash
   git clone https://github.com/openinferencefabric/oif && cd oif
   ```

2. See which GPUs the node has and which can be used (AMD on amdgpu today; NVIDIA with B-2; a GPU below
   `BENCH_MIN_VRAM_GIB`, default 16 GiB, or with a monitor connected, is not offered):

   ```bash
   ./oif bench gpus
   ```

   ```text
      #  GPU                                PCI            memory  driver    usable
      1  Radeon Pro W7900                   0000:03:00.0   45 GiB  amdgpu    yes
   ```

3. A quick run first (about 30–40 minutes with the image pulls; two workloads, concurrency 1, 8 and 32, 30 s each). It
   lists the GPUs, asks which one to use, then asks for the models (Hugging Face ids; Enter keeps Qwen/Qwen3-0.6B and
   Qwen/Qwen3-8B):

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

4. The full run (the comparable result: four workloads, concurrency 1 to 64, 60 s per point, 3 repeats). On the W7900
   it took about 7.5 hours for Qwen3-8B and 6 hours for Qwen3-0.6B. Run each model as its own detached unit, so a
   dropped SSH session does not stop it and a failure costs one model, not both:

   ```bash
   cd ~/oif
   sudo systemd-run --unit oif-bench-8b --collect -p WorkingDirectory=$HOME/oif      ./oif bench --profile full --gpu 1 --models Qwen/Qwen3-8B --out /var/tmp/oif-bench/full-8b
   sudo journalctl -fu oif-bench-8b --since now      # Ctrl-C stops watching, not the run
   ```

   A detached run cannot ask, so give `--gpu` (number or PCI address from `oif bench gpus`) and `--models`. Start the
   next model only when the first has finished: **one `oif bench` at a time per GPU.** Two runs share the server
   container name and port, and the second removes the first one's server (this cost 6 points of the B-1 run).

   ```bash
   systemctl is-active oif-bench-8b                  # inactive: finished; then start the next model the same way
   ```

5. One report for both models:

   ```bash
   sudo mkdir /var/tmp/oif-bench/full
   cat /var/tmp/oif-bench/full-*/results.jsonl | sudo tee /var/tmp/oif-bench/full/results.jsonl >/dev/null
   sudo cp /var/tmp/oif-bench/full-8b/env.json /var/tmp/oif-bench/full/
   sudo ./oif bench report /var/tmp/oif-bench/full
   ```

Each model's run time per stack is printed and shown in the report.

Options: `--stacks "vllm dynamo-vllm"`, `--models "Qwen/Qwen3-8B"`, `--repeats N`, `--out DIR`, `--profile quick|full`
(bench/profiles). `HF_TOKEN` in the environment for gated models.

## Read the report

- **Headline:** per model, Dynamo's median difference from the engine in output throughput, TTFT and TPOT. A throughput
  difference is "within noise" when it is inside twice the run-to-run spread; "real, below 2%" when it is beyond the
  noise but small (the spread is often 0.1-0.3%, so 0.4% can be measurable and still not matter); points beyond 2% are
  named.
- **few requests:** a point where a stack completed fewer than 10 requests (8B decode at concurrency 1 and 2 completes
  3 to 6 in 60 s). Its p99 latencies rest on a handful of requests.
- **GPU hotspot:** each point starts below 60 °C, but the GPU runs much hotter during it (up to 104 °C on the W7900,
  at its 241 W power cap from concurrency 1). Both stacks see the same conditions; absolute numbers depend on cooling.

What B-1 found on the W7900 ([evidence](../evidence/B-1/01-run.txt)): Dynamo's throughput equals vLLM's (8B: 0.0%
median, no point beyond 2%; 0.6B: +0.5% median, -3.2% to +2.8%), TPOT is equal, and TTFT is lower with Dynamo at
moderate concurrency on 0.6B (10-40%), probably because Dynamo's frontend tokenizes in Rust while vLLM's API server is
one Python process (not yet confirmed). Dynamo's cost shows only with many short requests on the small model: at about
50 requests/s, throughput -2 to -3% and TTFT p99 137 to 304 ms. Dynamo's own gains need more than one GPU and are not
part of this test.

## Check it worked

- `/var/tmp/oif-bench/<date>/report.html` opens (copy it off the node), the run-quality section shows 0 failed points,
  0 points with a short output length and 0 points with fewer repeats than the profile.
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
| `pull ... failed` for ghcr.io, `invalid username/password` | A stale login is sent with the request: `sudo podman logout ghcr.io` and run again (the OIF images are public). |
| `GPU N cannot be used` | `./oif bench gpus` gives the reason (driver, memory, a monitor connected). |
| `not ready` and the server log | The log is in `<out>/logs/server-*.log`; a model too large for the GPU at `--max-model-len 8192` fails here. |
| Output length short in the run-quality section | The stack ignored `ignore_eos`; throughput at those points is not comparable. |
| `Connect call failed ('127.0.0.1', 8000)` in the middle of a run | Another `oif bench` started and removed this run's server. Stop both (`sudo systemctl stop <units>`), drop the failed points (`rc` not 0) from `results.jsonl`, rebuild the report, then run one at a time. |
| `Failed to start transient service unit: ... already loaded` | A unit of that name is still running or stopping: `systemctl list-units --all 'oif-bench*'`. |
| `journalctl` shows nothing | Use `sudo journalctl`: the oif user is not in the `adm` group. |
