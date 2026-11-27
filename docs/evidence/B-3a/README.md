# B-3a evidence: prefill and decode, separated

## 00: per-request TTFT of the B-1b and B-2 chat points (step 0, 2026-11-26)

`00-ttft-hist-chat.txt`: `bench/ttft_hist.py` on the existing timing runs (no new GPU time), Qwen3-0.6B, chat 512/256,
plain vLLM and Dynamo at 16, 32 and 64 users, 3 repeats each: B-2 on the RTX A6000 (`b2-time-06b`), then B-1b on the
W7900 (`b1b-time-06b`). "In waves" is the share of requests that start less than 2 ms after the previous one in a
run of at least max(4, users/4): the closed loop (a new request as soon as one ends, every answer exactly 256 tokens)
lets requests finish together and restart together.

TTFT p50 per repeat (ms) and the share of requests in waves:

| GPU | Users | vLLM p50 | vLLM in waves | Dynamo p50 | Dynamo in waves |
| --- | --- | --- | --- | --- | --- |
| A6000 | 16 | 73.1, 72.3, 71.2 | 88-90% | 38.4, 37.4, 31.0 | 82-87% |
| A6000 | 32 | 89.8, 93.1, 81.0 | 52-82% | 35.2, 36.4, 37.4 | 22-38% |
| A6000 | 64 | 65.0, 80.1, 62.7 | 5-13% | 57.5, 54.2, 53.2 | 15-27% |
| W7900 | 16 | 78.1, 79.5, 78.7 | 87-88% | 45.1, 44.8, 45.2 | 88-91% |
| W7900 | 32 | 92.9, 88.4, 96.5 | 53-60% | 57.6, 63.2, 55.1 | 61-75% |
| W7900 | 64 | 121.3, 122.7, 75.8 | 13-35% | 82.4, 72.3, 66.2 | 32-47% |

Findings:

- **At 16 users the comparison is stable.** Both stacks run in the same regime (almost every request starts in a
  wave), and the p50 moves by at most 7 ms between repeats. Dynamo's lead (A6000 about 35 ms, W7900 about 34 ms) is
  the robust number.
- **At 64 users the TTFT p50 depends on the regime a repeat falls into.** Plain vLLM on the W7900 measured 121, 123
  and 76 ms in its three repeats; the published 121 ms is their median, so "121 to 72 ms, -40%" rests on a spread of
  almost half its own value. On the A6000 the c=64 repeats are bimodal per request (bimodality 0.56-0.67) and
  mostly out of waves, which is why plain vLLM's p50 there falls below its c=32 value.
- **The report never checked TTFT for noise.** `bench/report.py` takes the run-to-run spread from output throughput
  only (0.1-0.6% at these points), so TTFT differences were labelled real against a throughput spread. The B-3a
  report gives every metric its own spread and verdict.
- **Bursts favour Dynamo's frontend.** Requests that start together reach vLLM's single API process together, and
  their first tokens queue in its output path. Real traffic is not phase-locked; B-4a (Poisson arrivals) measures
  the gap without the closed loop's bursts.
- Request counts per point are whole multiples of the user count (for example 1280 = 20 x 64 on the A6000, 1088 =
  17 x 64 on the W7900): with equal request lengths every user completes the same number of requests in the 60 s.

## 01: calibration, vllm only, 1 repeat (2026-11-26)

`oif bench --profile prefill|decode|prefill-8b|decode-8b --stacks vllm --repeats 1` on each GPU, to fix the point
durations before the full runs. Three findings changed the profiles before any result is used:

- **The prefill points measured the prefix cache.** AIPerf builds 100 prompts per point and reuses them
  (`--num-dataset-entries` defaults to 100 in 0.13.0); vLLM keeps its prefix cache on by default. Share of prompt
  tokens served from the cache (`vllm:prefix_cache_hits` / `vllm:prefix_cache_queries` over the profiling phase):

  | W7900 points | Cache hits |
  | --- | --- |
  | prefill p1k, Qwen3-0.6B, 8-64 users; Qwen3-8B, 2-8 users | 99.2% |
  | prefill p1k, 1 user (about 100 requests: the first pass) | 4.9% (8B), 83.2% (0.6B, 595 requests) |
  | prefill p4k and p8k (100 prompts no longer fit the cache) | 0-24% |
  | decode (128-token prompts) | 0-94% |

  So the 8B p1k TTFT fell from 244 ms at 1 user to 69 ms at 2 users. The B-3a profiles now turn the cache off
  (`BENCH_PREFIX_CACHE=off`), every point records `prefix_hit_pct`, and the report lists points above 1%.
- **The published chat points ran on a warm cache too.** In B-1b (W7900) and B-2 (A6000), 512/256, about 98% of the
  prompt tokens at 8 users or more came from the cache (1 user: 0%), on plain vLLM and on Dynamo's vLLM worker alike
  (worker counters before and after the B-1b trace point at 64 users: 98.5% and 98.4%). The comparison is fair, but
  the TTFT measured there holds almost no prefill: it is frontend, queue and scheduling time.
- **4096-token answers do not end inside a point.** At 25-40 ms per token they take 100-165 s; AIPerf cancels what is
  not done 60 s after the 60 s point, and every request of d4k at 0.6B and 64 users and at 8B and 8, 16 and 32 users
  was cancelled (0 records). The decode profiles now use 256, 1K and 2K answers in 120 s points.

All W7900 points that produced records had 0 errors. The A6000 started no server: the CDI spec in `/var/run/cdi`
(dated 2026-11-21, ahead of `/etc/cdi`) mounted the socket of `nvidia-persistenced`, which had not run since the GPU
came back from the VM; the container failed to start and its error went nowhere, so the server log was empty. The
owner started `nvidia-persistenced` and refreshed the spec; the bench now writes a failed container start into the
server log.

## 02: second calibration, prefix cache off (2026-11-27)

Same command as 01 with the fixed profiles, both GPUs: 96 points, 0 errors, prefix cache 0.0% on every point, every
2K-token answer ended (OSL 2005-2037 of 2048: the tokenizer round trip, not cut answers). Run time per profile at one
repeat of one stack, seconds (A6000 / W7900): prefill 2966 / 1661, decode 3022 / 2439, prefill-8b 1841 / 1615,
decode-8b 3312 / 3075; together about 5.5 h per stack and repeat on both GPUs.

- **Prefill saturates early.** Qwen3-0.6B reaches its prompt rate by 8 users at 4K and 8K prompts (W7900 about 15-18K and
  12.5K tokens/s, A6000 about 43K and 34K) and by 32 users at 1K; above that TTFT is queue: 5.3 s (p4k) and 38 s (p8k)
  at 64 users on the W7900. Qwen3-8B saturates at 2 users for 4K and 8K prompts.
- **With the cache off the first token is real prefill.** W7900 p1k at 1 user: 36 ms (0.6B), 244 ms (8B), against 22 ms
  and 69 ms (2 users) with the warm cache in 01.
- **Qwen3-8B decode: TTFT grows with the users at about one decode step per user** (W7900 d256: 53, 269, 504, 703 ms at
  1, 8, 16, 32 users for a 128-token prompt). Closed-loop waves make every user's next request arrive together; the
  trace pass (queue against prefill) shows where the time goes.
