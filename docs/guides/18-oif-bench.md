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
| `sglang` | `BENCH_SGLANG_IMAGE`: OIF's SGLang build for RDNA3 (S-5, [below](#the-sglang-image-s-5)) | `sglang.launch_server`, Triton attention |
| `dynamo-sglang` | empty until T-212 | skipped |

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

## Where the first-token time goes (B-1b)

> Status: done in the lab on the W7900 (Qwen3-0.6B): run 1 (timings) 2026-11-20, 120 points, 0 errors; run 2
> (`--trace`) 2026-11-21, 40 points, 0 errors, no other process on the GPU. Evidence: `docs/evidence/B-1b/`.

Run 1, TTFT p50 in ms, median of 3 repeats:

| Point | `vllm` | `vllm-api4` | `vllm-rs` | `dynamo-vllm` |
| --- | ---: | ---: | ---: | ---: |
| chat c=1 | 31.8 | 31.3 | 23.6 | 28.6 |
| chat c=16 | 78.7 | 54.2 | 41.2 | 45.1 |
| chat c=32 | 92.9 | 71.2 | 60.6 | 57.6 |
| chat c=64 | 121.3 | 81.6 | 103.5 | 72.3 |
| short c=32 | 75.9 | 55.1 | 41.5 | 50.7 |
| short c=64 | 98.4 | 58.5 | 63.7 | 62.7 |

Inter-token latency is equal on all four stacks and throughput within 2 to 5%. vLLM's own switches (more API server
processes, the Rust frontend) close most of Dynamo's lead.

Run 2 splits the mean time to first token (ms; vLLM's own histograms, see the columns below):

| Point | Stack | client | core (queue + prefill) | out path | api layer | API process CPU |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| chat c=16 | `vllm` | 79.4 | 27.6 | **38.7** | 13.1 | 41% |
| | `vllm-api4` | 54.9 | 28.0 | 21.3 | 5.5 | |
| | `vllm-rs` | 43.2 | 26.0 | 16.5 | 0.7 | |
| | `dynamo-vllm` | 47.3 | 26.4 | 11.5 | 9.4 | 40% (frontend) |
| chat c=64 | `vllm` | 104.3 | 39.1 | **50.6** | 14.5 | 54% |
| | `dynamo-vllm` | 81.4 | 48.2 | 17.2 | 16.0 | 67% (frontend) |
| short c=64 | `vllm` | 98.3 | 32.2 | **49.9** | 16.2 | 65% |
| | `dynamo-vllm` | 67.9 | 30.2 | 19.7 | 18.0 | 98% (frontend) |

- The engine core is not the difference: queue + prefill is about the same on every stack.
- The difference is the **output path**: from the engine core's first token to the response, through ZMQ and the
  output processor in vLLM's API process. Plain vLLM spends 2 to 3 times as long there. Dynamo's HTTP layer is not
  faster than vLLM's (16 against 14.5 ms at chat c=64); its worker runs the output processing in a process of its own,
  away from the one serving HTTP.
- vLLM's API process is not saturated (40 to 65% of one core), so the cost is contention inside that one process, not
  a lack of CPU; py-spy puts most of its samples in thread-pool workers. Lock contention (the GIL) between those threads
  and the event loop is the working explanation, not a measured one.
- `vllm-rs` at chat c=64 is the exception: its engine core time jumps to 77 ms, as if the Rust frontend hands requests
  over in bursts. Open.
- `attrib.py` cannot tell the API servers of `vllm-api4` and `vllm-rs` from the engine core (all are `multiprocessing`
  children with the same command line), so their CPU column stays empty; the time split comes from vLLM's metrics and
  is complete.

Whether CUDA shows the same gap is B-2.

Two fixes came out of the first `--trace` run:

- **Another program on the GPU.** The start-up check found the GPU free, but a different benchmark opened it hours
  later and every point after that was slowed or failed. Now every point checks for processes outside the server that
  hold the GPU's render node open (`proc_sampler.py --others`); such a point is recorded with `gpu_others`, counts as
  failed in the report (and is left out of the medians), and the run stops with the process list.
- **py-spy hanging.** One py-spy kept unwinding the engine core for 4 hours past `--duration` and held the run. py-spy
  now runs under `timeout` (`--duration` + 30 s); a killed one leaves no profile for that process, and its log has no
  "Wrote" line.

B-1 measured Dynamo's first token up to 40% sooner than vLLM's own server (Qwen3-0.6B, chat, 64 users) with the same
engine and the same throughput. Two explanations are tested:

1. **The text layer around the engine.** vLLM's API server is one Python process that parses requests, renders the
   chat template, tokenizes, detokenizes and streams for every user; Dynamo does that in a multithreaded Rust frontend.
   vLLM 0.33.0 has its own Rust frontend (`vllm-rs`, experimental, off by default) and can run several API server
   processes.
2. **Something that differs between vLLM's ROCm and CUDA builds.** The request path has no CUDA/ROCm branch in vLLM
   0.33.0's source, but the images differ (torch build, libraries, what is compiled in), and a cost in the API process
   on ROCm would show only at run time. The same run on NVIDIA (B-2) answers it.

Stacks, all on `BENCH_VLLM_IMAGE` except Dynamo:

| Stack | What changes against `vllm` |
| --- | --- |
| `vllm-api4` | four Python API server processes instead of one |
| `vllm-rs` | vLLM's own Rust frontend (`VLLM_USE_RUST_FRONTEND=1`); skipped with a message when the image has no `vllm-rs` binary |
| `dynamo-vllm` | Dynamo's Rust frontend and the `dynamo.vllm` worker |

Run the `attrib` profile twice, one model per run (Qwen3-0.6B, then optionally Qwen3-8B), on the same node as B-1:

```bash
# 1. timings: 3 repeats, no profiler (about 40 min per stack for 0.6B)
sudo ./oif bench --gpu 1 --profile attrib --models Qwen/Qwen3-0.6B \
  --stacks "vllm vllm-api4 vllm-rs dynamo-vllm" --out /var/tmp/oif-bench/b1b-time-06b
# 2. where the time goes: one repeat with --trace
sudo ./oif bench --gpu 1 --profile attrib --models Qwen/Qwen3-0.6B --repeats 1 --trace \
  --stacks "vllm vllm-api4 vllm-rs dynamo-vllm" --out /var/tmp/oif-bench/b1b-trace-06b
```

`--trace` adds, per point: `procs.csv` (CPU of every process of the server, every second), `pyspy-<pid>.json` (py-spy
`--nonblocking` at 100 Hz on every Python process, from 10 s in for the benchmark duration; open in speedscope.app) and
`metrics-<port>-{before,after}.txt` (the server's `/metrics`; port 8081 is a Dynamo worker's). py-spy is pinned as
`PYSPY_VERSION` and runs from a short-lived `--pid host --privileged` container. At the end `bench/attrib.py` writes
`attrib.csv`, `attrib-profiles.txt` and prints, per point, the time to first token split into:

| Column | Meaning |
| --- | --- |
| client | AIPerf's mean TTFT, what a user sees |
| engine | `vllm:time_to_first_token_seconds`: from the request reaching vLLM's engine client (template rendered, prompt tokenized) to its first token leaving the output processor |
| core | queue + prefill in the engine core |
| out path | engine - core: ZMQ and the output processor, which shares the API process's event loop |
| api layer | client - engine: HTTP, chat template, tokenizing, the first SSE chunk |
| api CPU / busiest | CPU of the API layer (100 = one core) and of its busiest process |

Reading it: if `core` is the same on every stack and `api layer` + `out path` carry the difference, the gap is the
text layer. An API process near 100% (one core) at 8 to 64 users means it is the queue. `vllm-rs` or `vllm-api4`
closing the gap shows vLLM's own fix. Means include AIPerf's warm-up requests (at most 64 of several thousand per
point). Traced points are slower than untraced ones; take the timings from run 1.

## The same benchmark on NVIDIA (B-2)

> Status: done in the lab on the RTX A6000 (Qwen3-0.6B), 2026-11-22: timings 120 points and `--trace` 40 points,
> 0 failed, 0 request errors, no other process on the GPU. Evidence: `docs/evidence/B-2/`.

B-1b leaves one question open: does vLLM's own server trail Dynamo on CUDA as it does on ROCm? B-2 runs the same
profile and stacks on an NVIDIA GPU of the same node (lab: RTX A6000 next to the W7900, same host CPUs), with the same
vLLM release (`vllm/vllm-openai:v0.33.0`, `BENCH_VLLM_CUDA_IMAGE`) and Dynamo built from the same fork commit as the ROCm
image with upstream's own CUDA recipe (`DYNAMO_CUDA_IMAGE`). Compare the gaps within each GPU (plain vLLM against
`vllm-api4`, `vllm-rs` and Dynamo), not the GPUs' absolute numbers. Run it after the W7900 runs, never at the same time.

**Result: the gap is not ROCm's.** TTFT p50 in ms, median of 3 repeats, both GPUs:

| Point | W7900 `vllm` | W7900 `dynamo-vllm` | A6000 `vllm` | A6000 `dynamo-vllm` | A6000 `vllm-api4` | A6000 `vllm-rs` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| chat c=8 | 55.2 | 35.7 | 45.7 | 27.0 | 31.8 | 21.1 |
| chat c=16 | 78.7 | 45.1 | 72.3 | 37.4 | 42.8 | 28.2 |
| chat c=32 | 92.9 | 57.6 | 89.8 | 36.4 | 57.6 | 38.2 |
| short c=16 | 57.5 | 36.5 | 47.8 | 21.7 | 29.5 | 18.7 |
| short c=32 | 75.9 | 50.7 | 59.5 | 24.6 | 45.9 | 25.0 |

- On CUDA plain vLLM trails Dynamo as much as on ROCm or more (chat c=32: +147% on the A6000, +61% on the W7900), and
  vLLM's own `--api-server-count 4` and Rust frontend close the gap there too.
- The trace pass shows the same place: the output path costs plain vLLM 37 ms at chat c=16 on the A6000 and 39 ms on
  the W7900, Dynamo 11 ms on both. The same milliseconds on two GPUs and two GPU software stacks, on the same host CPU,
  put it in vLLM's API process, which is the same Python code for CUDA and ROCm.
- Throughput and inter-token latency are equal between vLLM and Dynamo on both GPUs (within 1 to 2%).
- Open: at 64 users plain vLLM on the A6000 is faster than at 32 (short c=64: 34 ms, below Dynamo's 39 ms), which the
  W7900 does not show. A guess, not checked: the faster GPU finishes the fixed-length requests in step, so new ones
  arrive in waves and are prefilled together.

**1. Host: NVIDIA Container Toolkit and the CDI spec** (once; the NVIDIA driver is installed). oif bench hands the GPU
to the container as a CDI device (`--device nvidia.com/gpu=<UUID>`); Docker 28 and later and Podman read CDI specs
from `/etc/cdi`.

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update
. versions.env; V=${NVIDIA_CTK_VERSION}-1
sudo apt-get install -y nvidia-container-toolkit=$V nvidia-container-toolkit-base=$V \
  libnvidia-container-tools=$V libnvidia-container1=$V
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
nvidia-ctk cdi list                      # nvidia.com/gpu=0, =GPU-<uuid>, =all
./oif bench gpus                         # the NVIDIA GPU now says "yes"
```

If `docker info` does not list `/etc/cdi` under "CDI spec directories", enable CDI:
`sudo nvidia-ctk runtime configure --runtime=docker --cdi.enabled && sudo systemctl restart docker`.
Remove it again with `sudo apt-get purge nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools
libnvidia-container1` and `sudo rm /etc/cdi/nvidia.yaml /etc/apt/sources.list.d/nvidia-container-toolkit.list
/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg`.

**2. The Dynamo image for CUDA** (once; 1 to 2 hours of CPU, about 150 GB free, no GPU). Not while a benchmark runs on
the same node: the build loads every core and would slow the frontends being measured.

```bash
tmux new -s dyncuda 'images/dynamo-vllm-rocm/build.sh --device cuda --ref d893564741 --push'
```

It prints `DYNAMO_CUDA_IMAGE=...@sha256:...`; pin that in `versions.env`. The smoke test checks a CUDA torch and that
Dynamo's worker and frontend import. Upstream's CUDA recipe pins transformers to 5.19.0 (vLLM's image ships 5.20.2);
`oif bench` prints both versions per stack, and the difference is kept as upstream ships it.

**3. The runs**, the same two passes as on the W7900 with the NVIDIA GPU's number or PCI address:

```bash
sudo ./oif bench --gpu 82:00.0 --profile attrib --models Qwen/Qwen3-0.6B \
  --stacks "vllm vllm-api4 vllm-rs dynamo-vllm" --out /var/tmp/oif-bench/b2-time-06b
sudo ./oif bench --gpu 82:00.0 --profile attrib --models Qwen/Qwen3-0.6B --repeats 1 --trace \
  --stacks "vllm vllm-api4 vllm-rs dynamo-vllm" --out /var/tmp/oif-bench/b2-trace-06b
```

On NVIDIA the telemetry comes from `nvidia-smi` (`gpu.csv`: busy, memory, power, GPU temperature as `edge_c`, SM clock;
no hotspot sensor), the start temperature (ADR-009) is the GPU temperature, and the "anyone else on the GPU" checks use
the GPU's `/dev/nvidiaN`. The SGLang stacks have no NVIDIA image here and are skipped with a message.

## Check it worked

- `/var/tmp/oif-bench/<date>/report.html` opens (copy it off the node), the run-quality section shows 0 failed points,
  0 points with a short output length and 0 points with fewer repeats than the profile.
- `./oif bench report /var/tmp/oif-bench/<date>` rebuilds the report from `results.jsonl`.

## The SGLang image (S-5)

SGLang publishes ROCm images for Instinct GPUs only (gfx942, gfx950, gfx1250). oif builds the line AMD's daily RDNA CI
runs green on: SGLang's `amd_march` branch at one commit with six RDNA pull requests on top, `sgl-kernel` compiled for
gfx1100, no aiter (it has no RDNA kernels), on `rocm/pytorch` with torch 2.10 and ROCm 7.2.4. Every input is pinned in
`versions.env` (`SGLANG_ROCM_*`). SGLang then serves with Triton attention (`--attention-backend triton`) and
`SGLANG_USE_AITER=0`; `oif bench` passes both.

Build it on a Linux machine with Docker or Podman and about 100 GB free (about 15 minutes on the lab node, no GPU
needed), inside `tmux`; `--push` needs a GHCR login as in guide 16:

```bash
images/sglang-rocm/build.sh            # build and smoke-test (ROCm torch, no aiter, sglang and sgl_kernel import)
images/sglang-rocm/build.sh --push     # prints BENCH_SGLANG_IMAGE=<image>@<digest> to pin in versions.env
```

The tag is `<commit>-<gpu target>-prs<hash of the pinned PRs>`. Check it on the GPU before a benchmark: serve Qwen3-8B
and run SGLang's GSM8K test (100 questions, about 30 s):

```bash
sudo podman run -d --name s5 --device /dev/kfd --device /dev/dri --group-add video --ipc host \
  --security-opt seccomp=unconfined --network host -v /var/tmp/oif-bench/hf:/hf -e HF_HOME=/hf -e SGLANG_USE_AITER=0 \
  "$IMG" python3 -m sglang.launch_server --model-path Qwen/Qwen3-8B --host 127.0.0.1 --port 30000 --attention-backend triton
sudo podman logs -f s5                 # wait for "The server is fired up", then Ctrl-C
sudo podman exec s5 python3 -m sglang.test.few_shot_gsm8k --num-questions 100 --port 30000
sudo podman rm -f s5
```

On the W7900 (2026-11-16, [evidence](../evidence/S-5/01-build-serve-gsm8k.txt)): GSM8K 92% on 100 questions (AMD's CI:
96%, inside the noise of 100 questions), 25.6 tokens/s for one request. A quick `oif bench` with vllm and sglang ran both
models with 0 errors ([evidence](../evidence/S-5/02-quick-bench.txt)). SGLang is 21-42% below vLLM there, but the two
images are on different ROCm releases (vLLM's on ROCm 10.0, AMD's RDNA SGLang line on 7.2.4), so read that as two
stacks, not two engines; each Dynamo image is built FROM its engine's, so the Dynamo comparisons are unaffected. Harmless in the log: `amdsmi` not installed,
"aiter is AMD specific", "Python TreeCore" (torch 2.10 is outside the range of SGLang's Rust radix tree, so its Python
one is used).

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
| A point with thousands of errors, the server log ends in `shutdown triggered`, the bench gone | The shell that ran it closed (SSH dropped); the bench's cleanup removed the server mid-point. Run it detached: `sudo systemd-run --unit=oif-bench --collect -p WorkingDirectory=$PWD $PWD/oif bench ...` and follow it with `sudo journalctl -fu oif-bench`. |
| `manifest unknown` when pulling an image pinned by digest | The digest is not the registry's: after `podman push`, `podman image inspect` shows the local manifest's digest. Pin the one the registry reports for the tag (`podman pull <image:tag>` then `podman image inspect --format '{{.Digest}}'`). |
| Output length short in the run-quality section | The stack ignored `ignore_eos`; throughput at those points is not comparable. |
| `another oif bench is running on this node (PID N)` | One `oif bench` per node (B-1a; ADR-009: one GPU under load at a time). Wait for that run, or stop it: `systemctl list-units --all 'oif-bench*'` names its unit. The lock is `/run/lock/oif-bench.lock` and frees itself when the run ends. |
| `Connect call failed ('127.0.0.1', 8000)` in the middle of a run | Before B-1a a second `oif bench` could start and remove this run's server; now it is refused. With an older checkout: stop both (`sudo systemctl stop <units>`), drop the failed points (`rc` not 0) from `results.jsonl`, rebuild the report, then run one at a time. |
| `Failed to start transient service unit: ... already loaded` | A unit of that name is still running or stopping: `systemctl list-units --all 'oif-bench*'`. |
| `journalctl` shows nothing | Use `sudo journalctl`: the oif user is not in the `adm` group. |
