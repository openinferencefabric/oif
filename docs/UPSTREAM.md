# Changes to offer upstream

Every change oif makes to the code of other projects, and every upstream problem it works around, prepared for the
maintainers: what is wrong, what oif changed, how it was tested, and what to submit. oif applies its patches at install
time to the pinned releases. The one fork is Dynamo (ADR-002 amendment 2026-11-06): its ROCm support changes how the
images are built, so it is developed on branch `rocm` of <https://github.com/openinferencefabric/dynamo>, pinned by commit,
with nothing oif-specific in it, and each change goes upstream (D-items).

Live status of every submitted thread (state, last activity, replies waiting on us): <https://openinferencefabric.github.io/upstream/>,
refreshed daily from GitHub. Add each new thread to that page's `upstream/contributions.json` when it is filed.

| Project | Repository | Release oif patches |
| --- | --- | --- |
| Run:ai (open source) | <https://github.com/dsx-ai-factory/run-ai> | 3.0.20 (`RUNAI_VERSION`) |
| KAI Scheduler | <https://github.com/kai-scheduler/KAI-Scheduler> | v0.18.3 (`KAI_VERSION`; the version Run:ai 3.0.20 deploys through KRM) |
| Dynamo | <https://github.com/ai-dynamo/dynamo> | 1.6.1 on NVIDIA (`DYNAMO_VERSION`); AMD images from the fork's branch `rocm` (`DYNAMO_ROCM_*`) |

Status: **ready** = the patch can be proposed as it is (tests included); **rework** = the idea is right but the patch is
oif-specific and needs a general form; **issue** = no oif patch, oif works around it, report it; **filed** = submitted,
with the thread linked (its live state is on the page above).

## Summary

| # | Project | Change | Kind | Status |
| --- | --- | --- | --- | --- |
| R1 | Run:ai cluster-sync | Count AMD GPUs in the node inventory | patch 0001 | closed as not planned 2026-11-08 (AMD not on the Run:ai roadmap): [run-ai#3939](https://github.com/dsx-ai-factory/run-ai/issues/3939), PR [run-ai#3950](https://github.com/dsx-ai-factory/run-ai/pull/3950); oif keeps patch 0001 and linked it on the issue for anyone who needs it (2026-11-18) |
| R2 | Run:ai frontend | AMD logo for workloads on ROCm images | patch 0002 | closed as a duplicate of [run-ai#6006](https://github.com/dsx-ai-factory/run-ai/issues/6006) (custom icon upload and image-to-icon mapping API) on 2026-11-26: [run-ai#3940](https://github.com/dsx-ai-factory/run-ai/issues/3940); our PR [run-ai#3948](https://github.com/dsx-ai-factory/run-ai/pull/3948) closed by us 2026-11-27 |
| R3 | Run:ai go-operator | Report GPU fractions unavailable when the fractioning daemons have no node | patch 0003 | filed: [run-ai#3941](https://github.com/dsx-ai-factory/run-ai/issues/3941), PR open [run-ai#3949](https://github.com/dsx-ai-factory/run-ai/pull/3949) ("being reviewed"); the required check needs `issue/approved` on #3941, asked 2026-11-11 |
| R4 | Run:ai frontend | New cluster page: say how clusters are added in this installation | patch 0004 | filed: [run-ai#3942](https://github.com/dsx-ai-factory/run-ai/issues/3942); the maintainer asked for our PR (2026-11-18). We corrected the token claim (the access-token `curl` shows only for cluster versions before 2.15) and proposed the general fix: Cancel on step 2 and a discard prompt for a never-connected cluster; PR once product agrees |
| R5 | Run:ai go-operator | `cluster-redis` follows `global.replicaCount` into unreplicated copies | issue (oif sets `cluster-redis.replicas: 1`) | fixed upstream: [run-ai#3943](https://github.com/dsx-ai-factory/run-ai/issues/3943) closed 2026-11-17, `cluster-redis` defaults to one replica ([run-ai#5301](https://github.com/dsx-ai-factory/run-ai/pull/5301) main, [#5329](https://github.com/dsx-ai-factory/run-ai/pull/5329) release-3.0); drop oif's `cluster-redis.replicas: 1` on a release that carries #5329 |
| R6 | Run:ai API | Department list omits `defaultNodePools` | issue | fixed upstream 2026-11-10: [run-ai#3944](https://github.com/dsx-ai-factory/run-ai/issues/3944); check on the next release |
| R7 | Run:ai | New projects' default node pools are `default` only, a pool without GPUs | issue (oif sets the order per department) | answered and closed 2026-11-26: [run-ai#3945](https://github.com/dsx-ai-factory/run-ai/issues/3945): a cluster-scope policy with `defaults.nodePools` covers it, no code change; oif to adopt it |
| R8 | Run:ai cluster-sync | AMD GPU nodes reported "GPU fractions not supported" once KAI supports them | follow-up to K1 to K4 | after K1 to K4 |
| R9 | Run:ai | ROCm workload templates (whole and half AMD GPU) | template JSON | closed 2026-11-26 with guidance: [run-ai#3946](https://github.com/dsx-ai-factory/run-ai/issues/3946): templates are generic (`extendedResources` with `amd.com/gpu`), created per cluster in the UI or API; templates stay in oif |
| R10 | Run:ai workspaces | Parallel requests during a workspace login fail with `invalid_grant` | issue | filed: [run-ai#3947](https://github.com/dsx-ai-factory/run-ai/issues/3947); not reproduced by Run:ai (2026-11-12); closed by us 2026-11-13 as not planned (seen only over a slow VPN path while cluster-redis had two copies, R5), no re-test |
| R11 | Run:ai metrics | AMD GPUs missing from Run:ai's GPU metrics: its AMD rules read `amd_gpu_*` names no current exporter emits; its Prometheus does not watch `kube-amd-gpu` | feature request (oif's own `oif:gpu_*` rules map the exporter) | reopened 2026-11-26: [run-ai#4274](https://github.com/dsx-ai-factory/run-ai/issues/4274); Run:ai proposes a ServiceMonitor plus a PrometheusRule (no Run:ai change) and asks us to test; acknowledged 2026-11-27, lab test when the owner schedules it |
| R12 | Run:ai | AMD GPU support as community-maintained (reconsider R1, R2, R9, R11), or a stop-gap fork under its own name | discussion | opened 2026-11-11: [run-ai discussion #5023](https://github.com/dsx-ai-factory/run-ai/discussions/5023); no replies. Decision 2026-11-13: no follow-up in the repo (the "not planned" answers stand); AMD stays as oif patches; any public case is made on our own channels, about single-vendor governance |
| K1 | KAI common | Helper: is a node an AMD GPU node, which resource holds its GPU | patch 0001 | proposed on [KAI-Scheduler#2556](https://github.com/kai-scheduler/KAI-Scheduler/issues/2556) (design questions first) |
| K2 | KAI scheduler | Skip the NvFractions readiness check on AMD GPU nodes | patch 0002 | proposed on [KAI-Scheduler#2556](https://github.com/kai-scheduler/KAI-Scheduler/issues/2556) |
| K3 | KAI binder | Reserve an `amd.com/gpu` on AMD nodes; name the shared GPU for the device injector | patch 0003 | proposed on [KAI-Scheduler#2556](https://github.com/kai-scheduler/KAI-Scheduler/issues/2556); rework (annotation names) |
| K3b | KAI binder | The reservation pod's resource config is changed in place on every call | part of patch 0003 | filed: [KAI-Scheduler#2554](https://github.com/kai-scheduler/KAI-Scheduler/issues/2554), PR [KAI-Scheduler#2557](https://github.com/kai-scheduler/KAI-Scheduler/pull/2557) **merged 2026-11-16**; bot backports open for v0.16, v0.18, v0.19 (#2698-#2700), v0.14 cherry-pick failed (manual only if asked). oif's patch 0003 can drop this part once oif pins a KAI release that carries it |
| K4 | KAI resource-reservation | Find the reserved AMD GPU without NVML | patch 0004 | proposed on [KAI-Scheduler#2556](https://github.com/kai-scheduler/KAI-Scheduler/issues/2556) |
| K8 | KAI scheduler | GPU-memory fractions on AMD nodes: the scheduler reads only `nvidia.com/gpu.memory`; read `beta.amd.com/gpu.vram.<size>` as the pod-group controller does | patch 0005 (T-140) | proposed on KAI#2556 |
| K9 | KAI scheduler | Node with GPUs of both vendors: `nvidia.com/gpu` and `amd.com/gpu` share one GPU slot, so a pod is placed where only the other vendor's GPU is free and the kubelet refuses it; check the vendor's own free GPUs in the node predicate | patch 0006 (T-116) | after the hardware test (T-901) |
| K10 | KAI scheduler | Topology: a required level above the lowest common domain of the job's nodes (a one-node pool, or a pool inside one domain) is never satisfied: `lowestCommonDomainID` stops only at the preferred level, and the required level's domains are checked with free resources computed for a lower subtree (0 GPUs, 0 pods); stop at the required level too | patch 0007 (T-132); reproduced on main 4261bdf | filed ([KAI#2593](https://github.com/kai-scheduler/KAI-Scheduler/issues/2593)), PR [KAI#2594](https://github.com/kai-scheduler/KAI-Scheduler/pull/2594) **merged 2026-11-16**; bot backports open for v0.12 to v0.19 (#2702-#2706). oif's patch 0007 can go once oif pins a KAI release that carries it |
| D1 | Dynamo container build | `--device rocm` for vLLM (and SGLang): Dynamo images on vllm/vllm-openai-rocm, the Intel XPU pattern; co-developing Andy Luo's (AMD) draft [dynamo#12537](https://github.com/ai-dynamo/dynamo/pull/12537), rebased onto main, vLLM 0.33.0 as on CUDA, `rixl` alias dropped (vLLM imports `nixl_rocm` since 0.26.1) | fork [openinferencefabric/dynamo](https://github.com/openinferencefabric/dynamo/tree/rocm) branch `rocm` (T-211) | upstream PR [dynamo#12537](https://github.com/ai-dynamo/dynamo/pull/12537) closed for inactivity 2026-11-11; asked to reopen (or a follow-up PR keeping Andy Luo's commits) |
| K5 | KAI admission | `runtimeClassName: nvidia` set on every fraction pod, whatever the vendor | issue (oif maps the name to runc on AMD nodes) | closed as not planned 2026-11-16 ([KAI-Scheduler#2555](https://github.com/kai-scheduler/KAI-Scheduler/issues/2555)): fractions are NVIDIA-only in KAI; workaround confirmed by the maintainer, a `runtimeClassName` naming a RuntimeClass with the `runc` handler; #1544 should remove the runtime class. oif's KAI patches linked on the issue (2026-11-18) |
| K6 | KAI / AMD | Device injector for AMD fractions (oif-amd-share NRI plugin) and the PyTorch memory cap | new component | design shared on [KAI-Scheduler#1544](https://github.com/kai-scheduler/KAI-Scheduler/issues/1544) |
| K7 | KAI gpu-fractioning | `fractiond --gpu-vendor=amd`: hard VRAM cap per pod with the Linux `dmem` cgroup | fork (merged to its main); installed by oif since T-139 | PR open ([gpu-fractioning#175](https://github.com/kai-scheduler/gpu-fractioning/pull/175)); second review 2026-11-26 (design accepted, 4 points, 1 blocking, unsigned commits block merge); fixed, rebased on main and every commit signed (fa42620), posted 2026-11-27; waiting on danbar2 |
| A1 | AMD metrics exporter | Phantom UMC ECC errors on Radeon PRO W7900 with kernel 7.0 | issue (oif raises the threshold) | issue |
| A2 | ROCm (clr, rocr-runtime) | `hipMemGetInfo` and the HSA pool size ignore the cgroup `dmem.max` VRAM limit (S-8) | issue (oif keeps the in-process fraction as the sizing hint) | filed: [rocm-systems#14860](https://github.com/ROCm/rocm-systems/issues/14860); AMD assessed it (harkgill-amd, `status: assessed`, 2026-11-18) and opened the fix [rocm-systems#16042](https://github.com/ROCm/rocm-systems/pull/16042) (ROCr clamps the pool size and free memory to `dmem.max`, tested on a W7900), waiting for review |
| A3 | ROCm (amdsmi, amdkfd) | No per-process compute busy time for KFD queues, so no per-pod GPU utilization (S-8) | issue | filed: [rocm-systems#14861](https://github.com/ROCm/rocm-systems/issues/14861) |
| A4 | ROCm (rocr-runtime, amdkfd) | CU mask only settable by the workload (`HSA_CU_MASK`), no node-enforced compute share (S-8) | issue | drafted, held for a measured run |
| A5 | ROCm device-metrics-exporter | GPU metrics carry a pod only for device-plugin or DRA allocations, one pod per GPU: GPU-sharing pods (KAI fractions) get no per-pod metrics | issue | filed ([device-metrics-exporter#722](https://github.com/ROCm/device-metrics-exporter/issues/722)); AMD triaged it 2026-11-04 (assigned to check whether it is officially supported); oif answered 2026-11-06 ([comment](https://github.com/ROCm/device-metrics-exporter/issues/722#issuecomment-6689065458)) |
| A6 | AMD GPU Operator (node labeller, DRA driver) | No topology labels: xGMI group (the driver has `xgmi_hive_info/xgmi_hive_id`), UALink domain for Helios, partition capabilities, DRA device attributes; MI455X missing from `amdgpu.ids` | issue (oif labels fake nodes `oif.ai/accelerator-domain`) | filed 2026-11-05: [ROCm/gpu-operator#679](https://github.com/ROCm/gpu-operator/issues/679) |
| X1 | KWOK (kubernetes-sigs) | Docs example for AMD Instinct GPU nodes next to the NVIDIA one, from oif's generator `tools/fake-gpu` | issue, then a docs PR (needs the CNCF CLA) | accepted by the maintainer 2026-11-06 ([kubernetes-sigs/kwok#1802](https://github.com/kubernetes-sigs/kwok/issues/1802)); docs PR [kwok#1808](https://github.com/kubernetes-sigs/kwok/pull/1808): changes requested 2026-11-16 (MI355 product name, drop `beta.amd.com`, no third-party link, menu; "wait for actual usage"), all addressed in 6c6ad3b4 (2026-11-18) with the usage case; checks pass, needs `/lgtm` and `/approve` |

Checked and not upstream: T-138, Run:ai Overview "Allocated GPU devices" at 0. oif's HA values gave Thanos receive three copies with `replicationFactor` 3 but not the chart's `receive.service.additionalHeadless`, so every remote write was refused; fixed in oif (guide 10). Run:ai's defaults (one receiver) are fine.

## Submitted (2026-11-01)

Opened by Manmohan Brahma; PR commits signed off (DCO). Run:ai merges a PR only after a maintainer approves its issue.

| # | Issue | Pull request |
| --- | --- | --- |
| R1 | [run-ai#3939](https://github.com/dsx-ai-factory/run-ai/issues/3939) | [run-ai#3950](https://github.com/dsx-ai-factory/run-ai/pull/3950) |
| R2 | [run-ai#3940](https://github.com/dsx-ai-factory/run-ai/issues/3940) | [run-ai#3948](https://github.com/dsx-ai-factory/run-ai/pull/3948) |
| R3 | [run-ai#3941](https://github.com/dsx-ai-factory/run-ai/issues/3941) | [run-ai#3949](https://github.com/dsx-ai-factory/run-ai/pull/3949) |
| R4 | [run-ai#3942](https://github.com/dsx-ai-factory/run-ai/issues/3942) (as a setting) | |
| R5 | [run-ai#3943](https://github.com/dsx-ai-factory/run-ai/issues/3943) | |
| R6 | [run-ai#3944](https://github.com/dsx-ai-factory/run-ai/issues/3944) | |
| R7 | [run-ai#3945](https://github.com/dsx-ai-factory/run-ai/issues/3945) | |
| R9 | [run-ai#3946](https://github.com/dsx-ai-factory/run-ai/issues/3946) | |
| R10 | [run-ai#3947](https://github.com/dsx-ai-factory/run-ai/issues/3947) | |
| K1–K4 | [KAI#2556](https://github.com/kai-scheduler/KAI-Scheduler/issues/2556) (design questions first) | |
| K3b | [KAI#2554](https://github.com/kai-scheduler/KAI-Scheduler/issues/2554) | [KAI#2557](https://github.com/kai-scheduler/KAI-Scheduler/pull/2557) |
| K5 | [KAI#2555](https://github.com/kai-scheduler/KAI-Scheduler/issues/2555) | |
| K6 | [comment on KAI#1544](https://github.com/kai-scheduler/KAI-Scheduler/issues/1544#issuecomment-6557664853) (NRI injection for fraction pods) | |
| A2 | [rocm-systems#14860](https://github.com/ROCm/rocm-systems/issues/14860) | |
| A3 | [rocm-systems#14861](https://github.com/ROCm/rocm-systems/issues/14861) | |

Held: R8 (until KAI answers #2556); A4 (needs a measured CU-mask run, docs/evidence/S-8/ticket-drafts.md); A1 (not reproduced on the current lab: the W7900 shows no UMC errors; report again with fresh evidence).

Follow-ups (2026-11-01): CodeRabbit's findings on #3950 (family count when the product count is unusable) and #3949 (malformed daemon conditions reported unavailable) fixed in e619499f and 6ddd263e, checked on Run:ai main 1fee5ece; T-128 evidence added to [run-ai#3943](https://github.com/dsx-ai-factory/run-ai/issues/3943#issuecomment-6560336091) (one cluster-redis copy survives a restart with a workspace logged in) and [KAI#2556](https://github.com/kai-scheduler/KAI-Scheduler/issues/2556#issuecomment-6560342620) (soft memory isolation measured: 23 GiB taken from a 22.5 GiB share).

## Submitted (2026-11-03)

| # | Thread | What |
| --- | --- | --- |
| K7 | [gpu-fractioning#173](https://github.com/kai-scheduler/gpu-fractioning/issues/173) | Feature request: `fractiond --gpu-vendor=amd`, a hard VRAM cap per pod with the dmem cgroup; offers a PR with signed-off commits once the approach and annotation names are agreed |
| K1–K4, K7 | [comment on KAI#2556](https://github.com/kai-scheduler/KAI-Scheduler/issues/2556#issuecomment-6598391590) | Corrects the 2026-11-01 measurement: isolation can be hard with dmem (0.25 pod stopped at 11,264 MiB by an 11,516 MiB cap; 0.5 neighbour 20,480 MiB); links #173 |
| K7 | [run-ai Discussion #4103](https://github.com/dsx-ai-factory/run-ai/discussions/4103) | For Run:ai's developers: the implementation, the lab result on Run:ai 3.0.20, and where it touches Run:ai (AMD nodes reported without fractions, #3941; templates #3946) |
| K7 | [gpu-fractioning#175](https://github.com/kai-scheduler/gpu-fractioning/pull/175) | PR `feat(fractiond): limit AMD GPU memory with the dmem cgroup`, reworked to the upstream contract: the existing `gpu-memory` annotations with PCI addresses in `gpus.devices`, `dmem.max`/`dmem.min` on the container through NRI (`AddLinuxUnified`), `docs/amd/README.md`; two DCO-signed commits on upstream main 5420a92 |
| K7 | [comment on gpu-fractioning#173](https://github.com/kai-scheduler/gpu-fractioning/issues/173#issuecomment-6613757949) | Links #175; asks about the annotation prefix on AMD nodes and whether to propose the KAI side (binder writes PCI addresses, KAI#2556) next |

Evidence: the lab test `test/amd/quick-dmem-cap.sh` and the vLLM benchmark `test/amd/bench-qwen3.sh` in
[openinferencefabric/gpu-fractioning](https://github.com/openinferencefabric/gpu-fractioning); report with raw results at
<https://manmohanbrahma.github.io/gpu-benchmark/amd-fraction-dmem-cap/> (a capped 0.5 pod within about 1% of the whole GPU
on time per token, latency and throughput, on the W7900 and on NVIDIA's gpu-fractioning with an A6000).

## Submitted (2026-11-04)

| # | Thread | What |
| --- | --- | --- |
| R11 | [run-ai#4274](https://github.com/dsx-ai-factory/run-ai/issues/4274) | Feature request: AMD GPU metrics from the AMD GPU Operator's Device Metrics Exporter. Name and label mapping (`gpu_total_vram`, `gpu_used_vram` MiB, `gpu_gfx_activity`; `hostname`, `card_model`, `gpu_id`), the scrape namespace, lab evidence and screenshots (Run:ai Nodes without the W7900's memory and free GPUs; OIF Fleet with it), OIF's rules offered as the basis of a PR. Framed as a feature: AMD is not a documented Run:ai configuration |
| A5 | [device-metrics-exporter#722](https://github.com/ROCm/device-metrics-exporter/issues/722) | Feature request: per-pod metrics for pods sharing a GPU without their own `amd.com/gpu` (KAI fractions): the exporter labels the GPU with KAI's reservation pod. Lab evidence from both cases; asks for process-based attribution and a pod UID label |
| K8 | [comment on KAI#2556](https://github.com/kai-scheduler/KAI-Scheduler/issues/2556#issuecomment-6639255329) | The scheduler cannot size GPU-memory fractions on AMD nodes; oif's KAI patch 0005 (one function, tests) and the T-140 lab evidence; warns against putting `nvidia.com/gpu.memory` on AMD nodes (Run:ai double-counts, the pod-group controller refuses) |

## Submitted (2026-11-06)

| # | Thread | What |
| --- | --- | --- |
| K10 | [KAI#2593](https://github.com/kai-scheduler/KAI-Scheduler/issues/2593), PR [KAI#2594](https://github.com/kai-scheduler/KAI-Scheduler/pull/2594) | Topology: a required level above the lowest common domain of the job's nodes (one-node pool) is never satisfied; fix stops `lowestCommonDomainID` at the required level, 5-case test (3 fail before), changelog fragment, DCO sign-off; checked on KAI main 4261bdf (topology plugin and scheduler actions tests). Same fix as oif KAI patch 0007 |
| A5 | [comment on device-metrics-exporter#722](https://github.com/ROCm/device-metrics-exporter/issues/722#issuecomment-6689065458) | Answer to AMD's triage: the KAI fraction setup (only the reservation pod holds `amd.com/gpu`), offer to test any build on the W7900 |

PRs were checked on the upstream `main` they target (Run:ai cfd9d8ac, KAI 4e6fcbd): build, vet, the service's tests, and lint with the project's own config and version. R1 for upstream parses the AMD count with `strconv.ParseInt(..., 32)` (gosec G109); oif's patch 0001 still uses `Atoi`.

## Submitted (2026-11-11)

Replies to the week's responses. Run:ai declined the AMD changes (AMD is not on its roadmap): R1, R2, R9, R11 and
PR #3950 closed as not planned; oif keeps them as patches. R2's PR #3948 and R3's PR #3949 are "being reviewed".

| # | Thread | What |
| --- | --- | --- |
| K3b | [reply on KAI#2557](https://github.com/kai-scheduler/KAI-Scheduler/pull/2557#discussion_r4541009238) | Review (gshaibi): strip the GPU resource once in `NewService` instead of on every bind; done (58019b53), changelog linked to #2554 |
| K10 | [reply on KAI#2594](https://github.com/kai-scheduler/KAI-Scheduler/pull/2594#discussion_r4541009713) | Review (blacksoxx, "would merge as is"): the test requires every idle node to be offered, counted as distinct nodes (a node is in both the host-level and the required-level subset); 534b1f8a |
| K7 | [review answer on gpu-fractioning#175](https://github.com/kai-scheduler/gpu-fractioning/pull/175#issuecomment-6802445636), [pushed](https://github.com/kai-scheduler/gpu-fractioning/pull/175#issuecomment-6803066882) | Maintainer review (danbar2) answered point by point and fixed (T-142); a reply on each of the 13 inline comments; asked where AMD metrics should go |
| R10 | [closing note on run-ai#3947](https://github.com/dsx-ai-factory/run-ai/issues/3947#issuecomment-6843447475) | No re-test: seen only over a slow VPN path while cluster-redis had two copies (#3943); closed as not planned |
| K5 | [correction on KAI#2555](https://github.com/kai-scheduler/KAI-Scheduler/issues/2555#issuecomment-6843448607) | Withdrew the webhook node check (cost on every pod creation); a RuntimeClass with the `runc` handler set by the platform already avoids the mutation; per-pod opt-out if code is wanted; #1544 the real fix |
| A2 | [follow-up on rocm-systems#14860](https://github.com/ROCm/rocm-systems/issues/14860#issuecomment-6843610810) | Untriaged after 11 days; new evidence: dmem caps are heading into Kubernetes (gpu-fractioning#175), so `hipMemGetInfo` ignoring them now matters in practice; asked for routing to clr/rocr-runtime |
| A5 | [ping on device-metrics-exporter#722](https://github.com/ROCm/device-metrics-exporter/issues/722#issuecomment-6843611398) | A week after our answer; offered to test on the KAI fractions setup. A3 and A6 not pinged (nothing new to add) |
| X1 | [PR kwok#1808](https://github.com/kubernetes-sigs/kwok/pull/1808) | Docs example `amd-gpu-nodes`: MI300X server, MI355X in CPX/NPS2, Helios tray, two pods; tested on kwokctl v0.8.0; generator linked at oif 24d3d6e. Preparing it fixed two generator errors: MI350X/MI355X memory modes are NPS1/NPS2 (#42), MI455X carries only published values (#43) |
| R10 | [reply on run-ai#3947](https://github.com/dsx-ai-factory/run-ai/issues/3947#issuecomment-6842107938) | SaraNachmias could not reproduce `invalid_grant` (a throttled first load got stuck until a refresh); answered that our callbacks may have come from R5 (#3943, two cluster-redis copies), promised a re-test with one copy, proxy logs and a stripped HAR, and to close in favour of #3943 if it does not reproduce |
| K5 | [reply on KAI#2555](https://github.com/kai-scheduler/KAI-Scheduler/issues/2555#issuecomment-6841915768) | Thezone-1 traced the bug to `runtimeenforcement.Mutate` and asked for a direction; as reporter we suggested skipping the mutation when no node matching the pod's required selector/affinity reports `nvidia.com/gpu` (today's behaviour when in doubt), redundant once #1544 lands; noted it matters mostly after #2556; offered a lab test |
| K7 | [lab result on gpu-fractioning#175](https://github.com/kai-scheduler/gpu-fractioning/pull/175#issuecomment-6841571283) | The review changes on the W7900 node (2026-11-13): 11/11, readiness, 4096 MiB `dmem.max` on create, no `dmem.min`, re-apply in place after fractiond was down, fail-closed with the clear error; suggested AMD metrics as a follow-up PR |
| D1 | [comment on dynamo#12537](https://github.com/ai-dynamo/dynamo/pull/12537#issuecomment-6802330157) | Andy Luo's ROCm PR was closed for inactivity; asked to reopen, with the fork's four commits explained, the W7900 benchmark against plain vLLM 0.33.0, and what is untested; offered a follow-up PR keeping his commits |
| X1 | [reply on kwok#1802](https://github.com/kubernetes-sigs/kwok/issues/1802#issuecomment-6802446459) | The maintainer accepted the AMD node example; PR to follow (MI300X, CPX MI355X, Helios tray) |
| R4 | [reply on run-ai#3942](https://github.com/dsx-ai-factory/run-ai/issues/3942#issuecomment-6802447469) | Reopened, "looking into it"; offered a PR that takes the bearer token out of the copied `curl` command |
| R6 | [reply on run-ai#3944](https://github.com/dsx-ai-factory/run-ai/issues/3944#issuecomment-6802448253) | Fixed upstream; will confirm on the next release |
| R1 | [reply on run-ai#3939](https://github.com/dsx-ai-factory/run-ai/issues/3939#issuecomment-6802449436) | Acknowledged the not-planned answers on #3939, #3940, #3946 and #4274 |
| R12 | [run-ai discussion #5023](https://github.com/dsx-ai-factory/run-ai/discussions/5023); reopen requests on [#3939](https://github.com/dsx-ai-factory/run-ai/issues/3939#issuecomment-6805462080), [#3940](https://github.com/dsx-ai-factory/run-ai/issues/3940#issuecomment-6805462515), [#3946](https://github.com/dsx-ai-factory/run-ai/issues/3946#issuecomment-6805462976), [#4274](https://github.com/dsx-ai-factory/run-ai/issues/4274#issuecomment-6805463604), [PR #3950](https://github.com/dsx-ai-factory/run-ai/pull/3950#issuecomment-6805464072) | Asks the maintainers (GOVERNANCE.md) to accept AMD support as community-maintained: outside the support matrix, OIF owns the tests and posts an AMD lab run per release, `amd` label and a named owner. Otherwise a stop-gap fork, under its own name per TRADEMARKS.md, kept in step with releases and offered back. We have no triage rights, so we asked for the threads to be reopened |
| R2 | [reply on run-ai#3948](https://github.com/dsx-ai-factory/run-ai/pull/3948#issuecomment-6805787888) | Maintainer: "reviewing it". The required check "PR links an approved issue" needs an open issue labelled `issue/approved`; #3940 is closed, so the PR waits on R12. Rebase offered (467 commits behind main) |
| R3 | [reply on run-ai#3949](https://github.com/dsx-ai-factory/run-ai/pull/3949#issuecomment-6805788429) | Maintainer: "reviewing it". Not AMD-specific; asked for `issue/approved` on #3941 so the required check passes; rebase and rerun before merge |

## Submitted (2026-11-16)

Status on 2026-11-16: KAI#2557 and #2594 are approved by gshaibi and noiyemini (2026-11-12) with green CI, but GitHub
shows both as blocked; gpu-fractioning#175 waits for danbar2's re-review; kwok#1808 passed every check after
`/ok-to-test` (wzshiming, 2026-11-13) and needs `/lgtm` and `/approve` (yibozhuang). R6 (run-ai#3944) was fixed
upstream on 2026-11-10; Run:ai 3.0.23 and later should carry it, oif pins 3.0.20 (confirm after the upgrade, then drop
the per-department GET in `installer/tools/runai_api.py`).

| # | Thread | What |
| --- | --- | --- |
| K3b | [ping on KAI#2557](https://github.com/kai-scheduler/KAI-Scheduler/pull/2557#issuecomment-6908218217) | Asked what is still needed to merge (approved, shown as blocked) |
| K10 | [ping on KAI#2594](https://github.com/kai-scheduler/KAI-Scheduler/pull/2594#issuecomment-6908218612) | Asked what is still needed to merge (approved, shown as blocked) |
| K7 | [ping on gpu-fractioning#175](https://github.com/kai-scheduler/gpu-fractioning/pull/175#issuecomment-6908219007) | Asked danbar2 for a re-review: every point addressed (261f6ce, 584b4b8), lab results posted |
| X1 | [ping on kwok#1808](https://github.com/kubernetes-sigs/kwok/pull/1808#issuecomment-6908219479) | Asked wzshiming for a review; all checks pass |

## Submitted (2026-11-18)

Status on 2026-11-18: KAI#2557 (K3b) and #2594 (K10) merged on 2026-11-16 with backports. run-ai#3943 (R5) fixed
upstream. AMD opened a ROCm fix for A2 ([rocm-systems#16042](https://github.com/ROCm/rocm-systems/pull/16042)). On every
thread closed as "AMD not planned", we added one note: oif maintains a parallel version, take the patches from oif
(owner's decision, 2026-11-18; the 2026-11-13 "no follow-up" decision on R12 still holds for asking to reopen). The owner
emailed AMD leadership the same day, asking AMD to share oif's AMD support within AMD and its user community, and to
comment on R12.

| # | Thread | What |
| --- | --- | --- |
| R1 | [note on run-ai#3939](https://github.com/dsx-ai-factory/run-ai/issues/3939#issuecomment-6988893237) | Parallel version in oif: patch 0001 and guide 8 |
| R2 | [note on run-ai#3940](https://github.com/dsx-ai-factory/run-ai/issues/3940#issuecomment-6988894096) | Parallel version in oif: patch 0002 and guide 8 |
| R9 | [note on run-ai#3946](https://github.com/dsx-ai-factory/run-ai/issues/3946#issuecomment-6988894745) | Parallel version in oif: `platform/runai/templates`, guides 8 and 13 |
| R11 | [note on run-ai#4274](https://github.com/dsx-ai-factory/run-ai/issues/4274#issuecomment-6988895403) | Parallel version in oif: `oif-gpu.rules.yaml` and its promtool tests |
| K5 | [note on KAI#2555](https://github.com/kai-scheduler/KAI-Scheduler/issues/2555#issuecomment-6988896165) | Parallel version in oif: `patches/kai/v0.18.3` and guide 13 |
| R5 | [thanks on run-ai#3943](https://github.com/dsx-ai-factory/run-ai/issues/3943#issuecomment-6988899608) | Thanks for #5301/#5329; oif drops its workaround on a release with the fix |
| X1 | [review answer on kwok#1808](https://github.com/kubernetes-sigs/kwok/pull/1808#issuecomment-6988941651) | All four review points fixed in 6c6ad3b4 (rebased on main); the usage case (KAI places pods on whole AMD GPUs today) |
| R4 | [reply on run-ai#3942](https://github.com/dsx-ai-factory/run-ai/issues/3942#issuecomment-6989463895) | Corrected the token claim; proposed Cancel on step 2 plus a discard prompt for never-connected clusters, PR on product agreement |

Still waiting on maintainers: K7 (gpu-fractioning#175), R3 (run-ai#3949, `issue/approved` on #3941), R2 PR (run-ai#3948,
blocked while #3940 is closed), R12 (discussion #5023) and K7's run-ai discussion #4103 (no replies), K1-K4 (KAI#2556),
K6 (KAI#1544), A3 (rocm-systems#14861), A5 (device-metrics-exporter#722), A6 (gpu-operator#679), R7 (run-ai#3945).

## Status check (2026-11-12)

Every thread linked here checked against GitHub on 2026-11-12. Changes since the last entries:

- **K3b** [KAI#2557](https://github.com/kai-scheduler/KAI-Scheduler/pull/2557): approved by gshaibi ("LGTM").
- **K10** [KAI#2594](https://github.com/kai-scheduler/KAI-Scheduler/pull/2594): approved by gshaibi and noiyemini. Both
  KAI PRs show `check-approvals` failed, but those runs finished before the approvals; E2E tests are running. No action
  from us unless a maintainer asks for a rebase.
- **R2, R3** [run-ai#3948](https://github.com/dsx-ai-factory/run-ai/pull/3948), [#3949](https://github.com/dsx-ai-factory/run-ai/pull/3949):
  the required check "PR links an approved issue" fails on both (the linked issue must be open and labelled
  `issue/approved`); replied 2026-11-11.
- **R5, R10** [run-ai#3943](https://github.com/dsx-ai-factory/run-ai/issues/3943), [#3947](https://github.com/dsx-ai-factory/run-ai/issues/3947):
  triaged and assigned (#3943 unassigned again 2026-11-11), no comment.
- **K7** [gpu-fractioning#173](https://github.com/kai-scheduler/gpu-fractioning/issues/173): danbar2 set the issue type
  and removed `priority/P2` (2026-11-10).
- No answer yet: R12 (discussion #5023) and the reopen requests on #3939, #3940, #3946, #4274, PR #3950; D1
  (dynamo#12537, still closed); K1-K4 (KAI#2556, last activity 2026-11-04); K5 (KAI#2555); A2, A3 (rocm-systems#14860,
  #14861); A6 (gpu-operator#679); A5 (device-metrics-exporter#722, since our answer 2026-11-06); X1 (kwok#1802, our
  docs PR is next).

## Submitted (2026-11-25)

Status on 2026-11-25 (all 31 threads re-read). Run:ai approved R3 (`issue/approved` on #3941) and reviewed #3949; Run:ai
accepted a narrowed R4 (Cancel button on step 2 only); KAI asked on K1-K4 whether DRA would be the better route.
Owner approved pushing and posting on 2026-11-25.

**Decision on K1-K4 (owner, 2026-11-25):** move AMD GPU sharing to DRA instead of the NRI and reservation-pod path in
KAI. Verified first: KAI counts DRA claims as whole devices (`countGPUDevicesFromClaim` ignores capacity); AMD's DRA
driver v1.0.1 shares MI300 partitions but not a whole GPU by memory (community proposal ROCm/k8s-gpu-dra-driver#127/#128
withdrawn for rework); consumable capacity (KEP-5075) is accounting only and alpha on Kubernetes 1.35. Next: dmem
enforcement in AMD's DRA driver, fractional DRA accounting in KAI (design issue if KAI agrees). Until then oif keeps
its KAI patches 0001-0005 for 1.35 clusters.

| # | Thread | What |
| --- | --- | --- |
| R3 | [run-ai#3949 comment](https://github.com/dsx-ai-factory/run-ai/pull/3949#issuecomment-7156530956) | All 4 review notes addressed (fail open, one `findCondition` helper, mixed-case test); rebased on main (47be392b); 64/64 specs, golangci-lint 0 issues |
| R3 | [run-ai#5996](https://github.com/dsx-ai-factory/run-ai/pull/5996) | New PR: backport to `release-3.0`, same checks |
| R4 | [run-ai#3942 comment](https://github.com/dsx-ai-factory/run-ai/issues/3942#issuecomment-7156534544) | Accepted the narrowed scope; asked about the landing page and a failed delete. Frontend PR to follow |
| K1-K4 | [KAI#2556 comment](https://github.com/kai-scheduler/KAI-Scheduler/issues/2556#issuecomment-7156540210) | Answer to "why not DRA?": agree; proposal above |
| K3b | [KAI#2765](https://github.com/kai-scheduler/KAI-Scheduler/pull/2765), [#2766](https://github.com/kai-scheduler/KAI-Scheduler/pull/2766), [note on #2557](https://github.com/kai-scheduler/KAI-Scheduler/pull/2557#issuecomment-7156534944) | Backports: v0.14 by hand (bot cherry-pick conflicted; new test fails without the fix), v0.16 with tests adapted (bot PR #2698 fails `go vet`) |
| A2 | [rocm-systems#14860 comment](https://github.com/ROCm/rocm-systems/issues/14860#issuecomment-7156535501) | Thanks for triage, offer to test |

Not done: re-requesting review on kwok#1808 (only collaborators can request reviewers; we already asked on 2026-11-18, so
no second comment yet).

## Submitted (2026-11-27)

Status on 2026-11-27 (all 34 threads re-read). Run:ai's camielRunai answered four of our feature requests on 2026-11-26
(R2 duplicate of #6006, R7 and R9 answered without code, R11 reopened with a workaround to test). danbar2 re-reviewed
K7 on 2026-11-26. Owner approved pushing and posting on 2026-11-27. Drafts and checks:
`upstream-replies/2026-11-27-replies.md` (local).

| # | Thread | What |
| --- | --- | --- |
| K7 | [gpu-fractioning#175 comment](https://github.com/kai-scheduler/gpu-fractioning/pull/175#issuecomment-7203131911) and 4 inline replies | All four review points fixed in fa42620: test race (cleanup stops the re-check and flushes; race x5 green), readiness re-check every 30 s while the node has no VRAM region, `dmem.capacity` read once per Synchronize, best-effort re-apply stated in docs, log and CHANGELOG. Branch rebased on upstream main (merge commit dropped), all 5 commits SSH-signed (GitHub: verified) and DCO-signed. Checked in `golang:1.27.3` on the lab host: gofmt, `go vet ./fractioning-manager/...`, `go test ./fractioning-manager/...`. Not re-run on the W7900 (lab VMs off). Asked danbar2 to approve the fork-PR CI run; the formal re-request returned 404 (collaborators only) |
| R11 | [run-ai#4274 comment](https://github.com/dsx-ai-factory/run-ai/issues/4274#issuecomment-7203137002) | Thanks for the workaround; will test on Run:ai 3.0.20 (A6000 + W7900) and report the Overview and Nodes pages before and after |
| R2 | [run-ai#3948 closed](https://github.com/dsx-ai-factory/run-ai/pull/3948#issuecomment-7203137581) | Closed our PR in favour of #6006 (icon upload and mapping API covers ROCm images) |

Not posted (no reply needed): R7 (#3945) and R9 (#3946), both closed with correct answers.

## Run:ai

### R1. cluster-sync: count AMD GPUs in the node inventory (ready)

- **Patch:** `patches/runai/3.0.20/0001-cluster-sync-count-amd-gpus-on-mixed-nodes.patch` (85 lines added, 8 removed; `cluster-sync/pkg/handlers/parsers/node_parser.go`, tests in `parsers_test.go`).
- **Problem:** Run:ai schedules `amd.com/gpu`, but its node inventory reads only NVIDIA's labels. A node with an AMD GPU shows no GPU type, the Overview shows fewer GPU devices than the cluster has, and a node with both vendors counts only the NVIDIA GPUs.
- **Change:** read the AMD GPU Operator's labels (`amd.com/gpu.product-name`, `beta.amd.com/gpu.product-name.*`, `amd.com/gpu.vram`) as well as NVIDIA's; on a node with both vendors the type becomes `NVIDIA type + AMD type` and the count is the sum. GPU memory stays NVIDIA's on a mixed node.
- **Tests:** unit tests in the patch; lab: Overview 2/2 GPU devices, node type `NVIDIA-RTX-A6000 + AMD-Radeon-Pro-W7900` (oif guide 8).
- **Suggested PR:** "cluster-sync: count AMD GPUs (amd.com/gpu) in the node inventory".

### R2. frontend: AMD logo for ROCm images (ready)

- **2026-11-26/27:** Run:ai closed #3940 as a duplicate of [#6006](https://github.com/dsx-ai-factory/run-ai/issues/6006) (API to upload custom icons and map them to images by exact match or regex). We closed PR #3948. Next: test #6006 with ROCm images when it ships; until then oif keeps patch 0002.

- **Patch:** `0002-frontend-amd-logo-for-rocm-images.patch` (31+, 3-; `common/icon.util/icon.util.ts`, `icons.constant.ts`, `assets/icons/svg/amd.svg`, tests in `icon.util.test.ts`).
- **Problem:** workloads on AMD GPUs get the generic icon, while NVIDIA images get theirs.
- **Change:** an image whose path has a `rocm/` segment (`rocm/pytorch`, `docker.io/rocm/...`) gets the AMD icon.
- **Tests:** vitest, 53 tests in the icon suite pass; lab screenshots of the Workloads page.
- **Note for the maintainers:** check the AMD logo's use is acceptable to you, or replace it with a neutral "ROCm" icon.

### R3. go-operator: fractions unavailable when the daemons have no node (ready)

- **Patch:** `0003-go-operator-fractions-unavailable-without-target-nodes.patch` (50+; `pkg/controller-utils/gpu_fractioning_checker.go` and its test).
- **Problem:** when GPU fractioning cannot run anywhere (both daemons report `NoTargetNodes`, e.g. every NVIDIA driver older than r615), the operator reported fractions **available**, so every GPU node counted as not ready: Overview "Ready 0/1 nodes".
- **Change:** `NoTargetNodes` from both daemons means fractions are unavailable; nodes stay Ready, and the cluster shows "Missing prerequisites" as intended.
- **Tests:** unit tests; lab before and after (oif guide 8).

### R4. frontend: New cluster page in an installation that builds its own cluster (rework)

- **Patch:** `0004-frontend-new-cluster-points-to-oif.patch` (39+, 2-; `views/cluster/cluster-new.vue`). It replaces the wizard with a note pointing to `oif install`, so nobody installs NVIDIA's stock cluster chart (no AMD support) or registers a cluster and its bootstrap token by mistake.
- **Not for upstream as it is:** it names oif. **Proposal:** a control-plane setting (for example `tenant.clusterCreation: disabled` plus a message or URL) that hides the wizard and shows the installation's own instructions; useful to anyone who installs Run:ai with their own tooling.

### R5. cluster-redis follows `global.replicaCount` (issue + small PR)

- **Problem:** setting `RunaiConfig spec.global.replicaCount: 2` for high availability also gives `cluster-redis` two copies. They do not replicate, and the workspace login proxy (oauth2-proxy, `--session-store-type=redis`) stores a session in one copy and later reads the other: "session does not exist", the login starts again, and Jupyter and every other workspace URL never loads (78 HTTP 500 and 95 redirects for one page load in the lab).
- **oif workaround:** `RunaiConfig spec.cluster-redis.replicas: 1` (stage `runai-ha`, commit fc6e57e).
- **Suggested fix:** `cluster-redis` ignores `global.replicaCount` (it is a cache without replication), or runs as a replicated set when more than one copy is asked for. Evidence: `docs/evidence/T-127/lab-test-3.txt`.

### R6. API: the department list omits `defaultNodePools` (issue)

- `GET /api/v1/org-unit/departments` returns departments without `defaultNodePools` and `description`; `GET /api/v1/org-unit/departments/{id}` returns them. A client that reads the list and writes back what it read clears the description. oif reads each department on its own (commit d4c696e).

### R7. Default node pool order for new projects (issue)

- A project without its own order inherits `default` only. In a cluster with a node pool per GPU vendor, `default` holds the CPU nodes, so a workload submitted from the UI without choosing a pool waits forever: "No node in the default node-pool has GPU resources".
- oif sets every department's order to the GPU pools first (`nvidia, amd, default`, stage `one-vendor`). **Suggestion:** a cluster-level default order, or GPU pools before pools without GPUs when no order is set.
- **Answered 2026-11-26 (closed):** a policy at cluster scope with `defaults: nodePools: [nvidia, amd, default]` applies to every department and project, including new ones; a narrower policy that sets `nodePools` wins. **Next (oif):** replace the per-department order in stage `one-vendor` with that cluster policy, and document it.

### R8. AMD nodes and the GPU fractions status (after K1 to K4)

- cluster-sync marks a node that the GPU-fractioning operator does not cover as "GPU fractions are not supported on this node". With K1 to K4, AMD GPU nodes do support fractions through KAI; the status should say so (the node carries `amd.com/gpu`, and KAI's AMD fraction path is enabled).

### R9. ROCm workload templates (samples)

- `platform/runai/templates/`: `pytorch-rocm-1-gpu` and `jupyter-lab-rocm-1-gpu` (a whole AMD GPU through `extendedResources`), `pytorch-rocm-half-gpu` and `jupyter-lab-rocm-half-gpu` (`gpuPortionRequest 0.5`, node pool `amd`). Offer as sample templates for AMD users.
- **2026-11-26 (closed):** Run:ai: templates are added per cluster; nothing in them is vendor-specific (`extendedResources` with `amd.com/gpu`), created in the UI or with `POST /api/v1/workload-templates/trainings|workspaces`. The templates stay in oif.

### R10. Workspace login with parallel requests (issue)

- On the first visit to a workspace URL, the browser asks for dozens of files at once before the session cookie exists; each request starts its own login and all but one fail with `invalid_grant "Code not valid"`. It recovers, but on a slow link the page stays blank for minutes. Likely an oauth2-proxy setting (for example skipping the login for static assets, or serving the app's index first).
- **2026-11-13:** Run:ai could not reproduce it. Our first sighting was in the T-127 week, possibly while cluster-redis still had two copies (R5). Re-test on one copy: a CPU Jupyter workspace, fresh incognito session over the slow link, DevTools HAR (cache off), `runai-oauth2-proxy-0` logs; strip cookies and codes from the HAR before sharing.


### R11. AMD GPU metrics from the Device Metrics Exporter (filed)

- **Found in T-138:** with the Thanos fix, Run:ai's metrics count one GPU on a cluster with two; the W7900 has no GPU memory and no fully free GPU device on the Nodes page.
- **Cause:** `rulegroups.go` maps `amd_gpu_memory_total`, `amd_gpu_memory_used`, `amd_gpu_use_percent` with labels `node_id`, `productname`, `gpu_id`, `pod`; the AMD GPU Operator's exporter (v1.5.1) emits `gpu_total_vram`, `gpu_used_vram` (MiB), `gpu_gfx_activity` with `hostname`, `card_model`, `gpu_id`. Run:ai's Prometheus selects ServiceMonitors only in `runai`, `monitoring`, `kube-system`, `openshift-monitoring`, `dgxc-system` and project namespaces; the exporter's is in `kube-amd-gpu`.
- **oif today:** its own rules (`platform/observability/rules/oif-gpu.rules.yaml`, `oif:gpu_*`) read the exporter for Grafana; Run:ai's Overview still leaves the AMD GPU out of its metric tiles.
- **Next:** if the maintainers agree, a PR adding the exporter as a second source in the AMD rules, with promtool tests.
- **2026-11-26 (reopened):** camielRunai proposed doing it with no Run:ai change: a ServiceMonitor in `runai` selecting the exporter in `kube-amd-gpu`, and a PrometheusRule recording `amd_gpu_memory_total|used` (`gpu_*_vram` x 1024²) and `amd_gpu_use_percent` (`gpu_gfx_activity`) with `hostname`→`node_id`, `card_model`→`productname`; asked us to test. Checked against the code: fits `amdMetricsRule`; Run:ai's Prometheus selects rules and ServiceMonitors in `runai` and its ClusterRole lists endpoints cluster-wide. To check in the lab: the `app: amd-device-metrics-exporter` selector must match the exporter **Service**; the scrape's `pod` label becomes `pod_uuid` (per-pod AMD metrics still won't join); partitioned GPUs are not in the UUID. Acknowledged 2026-11-27.
- **Next:** lab test when the owner schedules it (needs the Run:ai VMs; NAI's `hl-nkp` off, shared A6000); report before/after; if it works, offer a docs PR with the two manifests rather than the code change.
## KAI Scheduler

Background: KAI's GPU sharing is written for NVIDIA at every step. On a node whose GPUs are AMD (`amd.com/gpu`), a GPU
fraction cannot be scheduled (NvFractions readiness check), cannot be reserved (the reservation pod asks for
`nvidia.com/gpu` and finds its GPU with NVML), and cannot be given to the pod (NVIDIA environment and CDI only). K1 to K4
make the path vendor-aware; K6 is the AMD device injector. Tested on a Radeon PRO W7900 with Run:ai 3.0.20: two
half-GPU workloads share the GPU (24.2 TFLOPS each), a third waits on quota, NVIDIA fractions unchanged
(`docs/evidence/T-126/`).

### R12. AMD GPU support: community-maintained, or a fork (discussion open)

- **Where:** [run-ai discussion #5023](https://github.com/dsx-ai-factory/run-ai/discussions/5023) (Ideas), opened 2026-11-11 after R1, R2, R9, R11 and PR #3950 were closed as not planned.
- **Ask:** reconsider under GOVERNANCE.md (roadmap is NVIDIA's; decisions by lazy consensus); accept AMD support as community-maintained, outside the support matrix, with OIF owning tests, an AMD lab run per release, an `amd` label and a named owner; reopen the threads meanwhile (we have pull rights only).
- **Fallback:** a stop-gap fork of Run:ai with the AMD changes, kept in step with releases, under its own name (TRADEMARKS.md: no NVIDIA or Run:ai branding implying endorsement), every change offered back. Name not chosen yet.
- **Commitment:** an AMD lab run per Run:ai release while the discussion stands.

### K1. common: AMD GPU node helper (ready, rename)

- **Patch:** `patches/kai/v0.18.3/0001-common-amd-gpu-node.patch` (67+; `pkg/common/resources/oif_amd_gpu.go` and test).
- `IsAmdGpuNode(node)`: the node offers `amd.com/gpu` and no `nvidia.com/gpu`. `GpuResourceOfNode(node)`: the resource that holds a whole GPU there.
- **For upstream:** rename the file (`amd_gpu.go`) and the annotation constants (`kai.scheduler/amd-gpu...` instead of `oif.ai/amd-gpu...`).

### K2. scheduler: NvFractions readiness check on AMD GPU nodes (ready)

- **Patch:** `0002-scheduler-fractions-on-amd-gpu-nodes.patch` (28+; `pkg/scheduler/plugins/gpusharingnodevalidation/`).
- In `NvFractions` mode the scheduler refuses every shared-GPU pod on nodes without condition `gpu-fractioning.nvidia.com/Ready`: "node is not ready for fractional GPU scheduling". The operator never covers AMD nodes, so the check now applies to NVIDIA nodes only. Test: an AMD node passes without the condition, an NVIDIA node without it is still refused.

### K3. binder: AMD GPU nodes (rework: annotation names)

- **Patch:** `0003-binder-fractions-on-amd-gpu-nodes.patch` (133+, 6-; `pkg/binder/binding/resourcereservation/resource_reservation.go`, `pkg/binder/plugins/nvfractions/nv_fractions.go`, tests).
- The reservation pod holds the node's own GPU resource (`amd.com/gpu` on an AMD node). The nvfractions plugin, on an AMD node, writes the shared GPU's PCI address, the container and the share into pod annotations for the device injector (K6), instead of NVIDIA's visible-devices and memory annotations.
- **For upstream:** annotation names under KAI's domain; possibly a separate binder plugin (`amdfractions`) rather than a branch in `nvfractions`.

### K3b. binder: shared resource config changed in place (ready, separate PR)

- In `createGPUReservationPod` the stock code deletes `nvidia.com/gpu` from `rsc.podResources.Limits/Requests`, the service-wide configuration, on every call (`delete(rsc.podResources.Limits, ...)`). The patch copies the maps first. A test checks the configuration is unchanged after a call. Small, independent bug fix.

### K4. resource-reservation: find the AMD GPU (ready)

- **Patch:** `0004-resourcereservation-amd-gpu-device.patch` (83+; `pkg/resourcereservation/discovery/`).
- On an AMD node the reservation pod gets `/dev/kfd` and one render node from AMD's device plugin; it reports that GPU's PCI address (from `/sys/class/drm/<render node>/device`) instead of asking NVML. Tests with a fake `/dev` and `/sys`.

### K5. admission: runtime class on fraction pods (issue + PR)

- `runtimeenforcement` sets `runtimeClassName: <gpuFractionRuntimeClassName>` (default `nvidia`) on every pod that asks for a GPU fraction, at creation, before any node or vendor is chosen. A pod's runtime class cannot change later, so a fraction KAI places on an AMD node fails: "no runtime for nvidia is configured".
- **oif workaround:** on AMD-only nodes, containerd's runtime name `nvidia` runs runc (node stage `amd-runtime`).
- **Suggested fix:** set the runtime class only for pods that can land only on NVIDIA nodes (their node pool or selector), or let the runtime class be chosen per node pool.

### K6. Device injector for AMD fractions (design proposal)

- A pod with a GPU fraction asks for no `amd.com/gpu`, so AMD's device plugin gives it no device. oif's NRI plugin (`images/oif-amd-share/`, about 200 lines of Go with tests) gives the container `/dev/kfd` and the reserved GPU's DRM nodes when containerd creates it, from the binder's annotations; a ValidatingAdmissionPolicy lets only the binder set those annotations. It also sets `OIF_GPU_MEMORY_FRACTION` and PyTorch's allocator cap (`PYTORCH_ALLOC_CONF=per_process_memory_fraction:<share>`, merged with the image's own settings), so PyTorch and vLLM keep to their share.
- **Limits to state upstream:** memory isolation is soft (no AMD driver cap; the W7900 has no partitions); compute is time-sliced.
- **Where it could live:** KAI (next to NVIDIA's gpu-fractioning `fractiond`), AMD's GPU Operator, or the ROCm device plugin. Propose as a design discussion with the evidence.

### K7. fractiond: hard VRAM cap for AMD fractions (PR open)

- **Code:** branch `amd/dmem-cap` of <https://github.com/openinferencefabric/gpu-fractioning> (fork of `kai-scheduler/gpu-fractioning`): `fractioning-manager/fractiond/internal/amd/` with unit tests, `--gpu-vendor=amd`, `docs/amd/README.md`, lab test `test/amd/quick-dmem-cap.sh` and its 122 MB probe image (`test/amd/vram-probe/`).
- **Problem:** K6's memory isolation is soft: a pod that lifts PyTorch's cap takes its neighbours' memory (T-128). NVIDIA's `fractiond` has the driver enforce the limit; no AMD driver does.
- **Change:** on `CreateContainer`, `fractiond` reads the binder's `oif.ai/amd-gpu*` annotations, enables `dmem` down to the pod's parent cgroup where it is off, and writes `dmem.max = drm/<pci address>/vram <share × VRAM>` on the pod cgroup (S-8: Linux 6.14+, amdgpu). Refuses the container when the cap cannot be set, unless `--fail-open`. Retroactive enforcement stays NVIDIA-only.
- **Tests:** unit tests on fake cgroup and sysfs trees; lab 2026-11-03 (W7900, kernel 7.0, KAI places the pods): a 0.25 pod without the plugin took 30,720 MiB; with it, stopped at 11,264 MiB by a cap of 11,516 MiB while a 0.5 neighbour got 20,480 MiB.
- **Submitted:** issue #173, Run:ai Discussion #4103, then PR [#175](https://github.com/kai-scheduler/gpu-fractioning/pull/175) (2026-11-03) from branch `feat/fractiond-amd-dmem`. The PR reworks the backend to upstream's contract: no `oif.ai/*` annotations, the existing `<prefix><ctr>.gpu-memory.request|limit` and `.gpus.devices` (PCI addresses); `dmem.max`/`dmem.min` set on the container's cgroup by the runtime through NRI, so fractiond writes no host cgroup files. Lab on upstream main with that branch: PASS 6/6 (the 11,516 MiB container stopped at 11,264 MiB, neighbour got 20 GiB, pod cgroup uncapped).
- **Review (2026-11-11, T-142):** danbar2 checked the PR against the kernel, runc and containerd sources: the approach is right (dmem is the only upstream, kernel-enforced VRAM cap for amdgpu; Project-HAMi's AMD device plugin is adding the same), with fixes needed. Done in fork commits 261f6ce and 584b4b8: retroactive enforcement re-applies `dmem.max` in place on `Synchronize`; `dmem.min` dropped (inert); `dmem.capacity` read through a read-only host mount gates readiness and each container, so `--fail-open` applies; vendor flag normalised; overflow bound; Linux 6.15+ (amdgpu registers its region from 6.15); runc 1.2.0+ or crun for multi-GPU containers; GTT is not capped; Instinct partitions share one cap per card. Lab check `tests/lab/gf175-reapply.sh`: 11/11 on 2026-11-13 (docs/evidence/T-142), [posted](https://github.com/kai-scheduler/gpu-fractioning/pull/175#issuecomment-6841571283); AMD metrics suggested as a follow-up.
- **Second review (2026-11-26):** danbar2 re-reviewed at 7e7a98f: design accepted (verified containerd/CRI-O merge `Unified` on update, the already-capped check, CREATED containers); AMD metrics agreed as a follow-up. Four points: `TestSynchronizeAMDReapply` failed 5/5 (no flush before `t.TempDir()` cleanup, blocking); readiness never recovers when `amdgpu` binds after fractiond; `dmem.capacity` re-read per container in one Synchronize; best-effort re-apply not stated. Plus: 5 of 6 commits unsigned, which blocks merge. **Fixed 2026-11-27** in fa42620 (30 s readiness re-check, one read per Synchronize, docs/log/CHANGELOG wording, test cleanup, 3 new tests); branch rebased on upstream main with all commits SSH-signed (key `id_ed25519_github_signing`, now also configured in `~/gpu-fractioning`); [posted](https://github.com/kai-scheduler/gpu-fractioning/pull/175#issuecomment-7203131911).
- **Next:** danbar2's approval and the CI run (fork-PR workflows may need maintainer approval); after merge, a follow-up issue for AMD metrics (the metricsd mapping drops AMD devices: `gpudevices.FromContainer` filters on NVIDIA's major 195; needs a non-minor device identity in `store.GPUDevice`). Then the binder writing PCI addresses in `gpus.devices` so the PR works on a Run:ai cluster, now via the DRA direction (K1-K4, 2026-11-25). oif keeps the fork's pod-level cap (`oif.ai/*` annotations) until then.

## AMD

### A1. Metrics exporter: phantom UMC ECC errors (issue)

- With the kernel's `amdgpu` on kernel 7.0, the Radeon PRO W7900 reports UMC ECC errors that do not exist; the device metrics exporter then marks the GPU unhealthy. oif raises the exporter's UMC ECC threshold for W7900/W7800 cards (`AMD_WORKSTATION_IDS` in `installer/stages/70-gpu-amd.sh`). Report to ROCm/device-metrics-exporter with the kernel and card.

## How to submit

1. Open an issue per item in the project's repository, with the problem, the evidence file and the oif patch linked.
2. For **ready** items, a pull request against the project's main branch: rebase the patch from the pinned release, rename oif's names where noted, keep the tests.
3. K1 to K4 together, with K6 described in the issue, so the maintainers see the whole AMD fraction path.
4. Before submitting, check the patch still applies: CI runs `tests/check-patches.sh` on every push against the pinned release (Run:ai 3.0.20, KAI v0.18.3); for a newer upstream, change the version and checksum in `versions.env` and run it.

### A5. Device Metrics Exporter: per-pod metrics for GPU-sharing pods (filed)

- `pkg/exporter/scheduler/k8s.go` attributes a GPU to a pod from the kubelet's PodResources: an `amd.com/*` device-plugin allocation or a `gpu.amd.com` DRA claim, one pod per device (a later pod overwrites an earlier one). Pods sharing a GPU through KAI fractions ask for no `amd.com/gpu` (the reservation pod holds it), so their usage is reported against the reservation pod or no pod. Related: ROCm/device-metrics-exporter#665 (a shared DRA claim attributed to one pod).
- **Lab, 2026-11-04 (exporter v1.5.1):** with two 0.5 fraction pods on the W7900, every series carries `pod=gpu-reservation-...`, `namespace=runai-reservation`, `container=resource-reservation`; neither workload pod appears. A pod with `amd.com/gpu: 1` is labelled correctly. No pod UID label.
- **Filed:** [ROCm/device-metrics-exporter#722](https://github.com/ROCm/device-metrics-exporter/issues/722): attribution by the processes using the GPU (KFD process list, `dmem.current` per container) and an opt-in pod UID label.
- **Reply (2026-11-04):** an AMD collaborator thanked us and assigned an engineer to check whether this is something they officially support. Waiting for that answer.
