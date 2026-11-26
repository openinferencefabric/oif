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
