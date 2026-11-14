# oif bench: method

How `oif bench` measures LLM serving, so that every number in a report can be compared with the number beside it.
The rules come from ADR-006 (AIPerf), ADR-009 (one GPU under load, temperature guard), ADR-012 (fair comparison) and
ADR-033 (hardware configurations, workload catalogue, quality; proposed). Status per part is at the end.

## Principles

- **Comparable hardware.** Every model runs on comparable GPU configurations, chosen explicitly: a configuration is a set
  of GPUs on one node (vendor, model, count, device IDs), for example one NVIDIA RTX A6000 against one AMD Radeon PRO
  W7900 (both 48 GB) in the lab. The suite discovers the GPUs on each node and benchmarks only the configurations named;
  it never mixes vendors in one server.
- **Enough switches.** Model, precision, serving stack, engine arguments, hardware configuration, workloads, concurrency
  levels, requests per level and repeats are all selectable, so a comparison changes one thing at a time.
- **Fresh server per case.** For each model, precision, serving stack and hardware configuration a fresh server is
  started; then each workload runs at each concurrency level from one shared load client.
- **Same work for everyone.** Same prompts (fixed seed), exact output lengths (`ignore_eos`), same engine version and
  arguments within a comparison, one configuration under load at a time, GPUs below a start temperature (ADR-009).
- **Only common ground.** Only workloads and quality benchmarks that every compared model and configuration can run are
  included (context length, memory, modality); the report names what was left out and why.
- **Quality separately.** Output quality is measured in its own runs, not inferred from performance runs.
- **Everything recorded.** Image digests, versions inside each image, engine arguments, driver, power cap, clocks,
  start temperature and the exact load-client command go into every report.

## Metrics

| Metric | Definition | Better |
| --- | --- | --- |
| Output throughput | Generated tokens per second, all concurrent users combined | higher |
| Prompt processing rate | Input tokens processed per second, all users combined (prefill rate) | higher |
| Time to first token (TTFT) | From sending a request to receiving its first generated token: queueing plus prefill | lower |
| Time per output token (TPOT) | Average gap between generated tokens after the first, per request (AIPerf's inter-token latency) | lower |
| Speed per user | Tokens per second one user sees while generating: 1000 ÷ TPOT in ms | higher |
| End-to-end latency (E2E) | From sending a request to receiving its last token | lower |
| Concurrency | Requests the client keeps in flight; a new one starts as soon as one finishes | – |
| Traffic-mix knee | Highest Poisson arrival rate at which every workload keeps 95% of its requests within the latency targets | higher |
| MTP acceptance length | Average tokens accepted per decoding step with multi-token prediction (1 means no gain) | higher |
| Power | Sum of the board power of the GPUs the server uses, sampled every second while they are busy | lower |
| Tokens per joule | Output throughput ÷ power | higher |

Percentiles are p50, p90 and p99 for TTFT, TPOT and E2E. Repeats are combined by the median, and a difference between
two stacks is called "within noise" when it is smaller than twice the larger run-to-run spread (coefficient of
variation) of the two. A difference beyond the noise but below 2% is reported as "real, below 2%": with spreads of
0.1-0.3% (B-1) a few tenths of a percent are measurable without mattering. A point where a stack completed fewer than
10 requests is marked, because its p99 rests on a handful of requests.

## Workloads

| Workload | Input tokens (ISL) | Output tokens (OSL) | Concurrency levels | Requests per level | Represents |
| --- | --- | --- | --- | --- | --- |
| Prefill | 131,072 | 1 | 1, 2, 4, 8 | 4, 8, 16, 32 | pure prompt processing, one output token |
| Decode | 128 | 16,384 | 1, 8, 32, 128, 256 | 3, 16, 64, 256, 512 | short prompt, very long answer: pure generation speed |
| Agentic coding | 32,768 | 1,024 | 1, 8, 32, 64 | 8, 32, 128, 256 | long tool/coding context; about 90% of each prompt is a shared prefix the cache can reuse |
| Long-document QA | 102,400 | 512 | 1, 4, 16 | 3, 8, 32 | a 100K-token document and a short answer |
| Reasoning | 2,048 | 16,384 | 1, 8, 32, 128 | 3, 16, 64, 256 | short question, long chain of thought |
| Long generation | 8,192 | 65,536 | 1, 8, 32 | 2, 8, 32 | medium prompt, 64K-token output (vendor reference shape) |
| Chat | 1,024 | 512 | 1, 8, 32, 128, 256 | 8, 32, 128, 512, 1024 | interactive chat turns |

A workload runs on a configuration only if the model's context length and the GPUs' memory hold it at its highest
concurrency; otherwise it is dropped for every compared configuration (common ground). On 48 GB GPUs with
small models the long-context rows (Prefill, Long-document QA, Long generation) usually drop out. The traffic mix
offers these workloads together as Poisson arrivals at rising rates to find the knee.

Today's profiles (B-1) are shorter shapes for one 48 GB GPU and a fixed duration per point: `full` = chat 512/256,
prefill 2048/128, decode 128/1024, short 128/128 at concurrency 1–64, 60 s per point, 3 repeats; `quick` = chat and
decode at 1, 8, 32, 30 s, 1 repeat.

## Quality benchmarks

Every model at 16, 8 and 4-bit where the hardware supports the format.

| Benchmark | What it tests | Size | Scoring | Judge |
| --- | --- | --- | --- | --- |
| GPQA Diamond | Graduate-level science reasoning (biology, chemistry, physics), questions written to be hard to look up | 198 four-option multiple-choice questions | Accuracy; repeated runs with answer order shuffled, mean ± 95% confidence interval | None (exact answer match) |
| SciCode | Writing scientific code: each research problem split into sub-steps implemented as Python functions | 80 main problems, 338 sub-problems | Generated code runs against the reference tests in an isolated sandbox; sub-problem and main-problem pass rates | None (tests) |
| AA-LCR v1.1 | Long-context reasoning across several real documents, about 100K tokens of input per question | 100 questions; dataset pinned to the v1.1 release commit | Answer judged correct or incorrect against the reference | Local judge model on the same system (Artificial Analysis uses a hosted judge, so scores are comparable but not identical) |
| IFBench | Following precise, verifiable output constraints that are uncommon in training data | About 300 prompts with out-of-distribution constraints | Strict prompt-level accuracy: every constraint in a prompt must be met | None (rule-based checkers) |
| Terminal-Bench 2.1 | Completing real tasks in a Linux terminal as an agent: building, debugging, configuring systems | Containerised tasks with automated checks | Share of tasks passed, mean of 3 trials | None (task tests) |
| DeepSWE v1.1 | Software engineering on real repositories: reading code, editing it and making the tests pass | Repository issues with hidden tests | Share of issues resolved | None (tests) |
| NL2Repo | Building a whole repository from a natural-language specification | Specification-to-repository tasks | Share of the target project's test suite that passes | None (tests) |
| Agents' Last Exam | Hard multi-step agentic tasks that need planning and tool use | Agentic task set | Task success rate | The benchmark's own checker |
| AutomationBench | Automating business workflows across simulated applications through tool calls | Workflow tasks with defined end states | Share of workflows that reach the correct end state | None (state checks) |

Common settings: every benchmark runs through the model's OpenAI-compatible endpoint on the same engine version and
hardware configuration as the performance runs, reasoning on, with each vendor's recommended sampling (for example
temperature 1.0, top-p 0.95) and a large output budget. Agentic benchmarks run their tools in isolated containers. A
benchmark that only some of the compared models can take (for example image input) is dropped so every score compares
all of them.

## Status

| Part | Task | Status |
| --- | --- | --- |
| Dynamo against its plain engine on one GPU (vLLM; SGLang after S-5/T-212), metrics above except knee and MTP, B-1 profiles, report | B-1 | Built; report tested on synthetic data; lab run on the W7900 next |
| Hardware configurations: discover GPUs per node, select configurations (`--gpus`), run on each node one at a time, merge into one report | B-2 | Planned |
| Workload catalogue above with requests per level, common-ground filter, precisions (16/8/4-bit) | B-3 | Planned |
| Traffic-mix knee (Poisson) and MTP acceptance length | B-4 | Planned |
| Quality benchmarks above | B-5 | Planned |
| Through Kubernetes: the same runs as Run:ai workloads on the platform, results as Grafana annotations | B-6 | Planned |
