# Tasks

Work through tasks in order: understand, plan, implement, test, review, commit, update docs. Each step ends with a working vertical slice.

Status: `[ ]` open, `[~]` in progress, `[x]` done, `[-]` dropped.

The work is split into three projects (ADR-010). Each builds on the one before, and each step inside a project is a checkpoint the owner signs off before the next starts.

## Phase 0: Repository

- [x] T-001 Research, PRD, architecture, design, rules, decisions, test plan, security, tasks
- [x] T-002 Public GitHub repository, licence, README; push
- [x] T-003 CI (guide 15): `.github/workflows/ci.yml` on every push and pull request, four jobs: `tests/run.sh` (shellcheck incl. build scripts, yamllint, Python syntax, unit tests with promtool, new dashboard `oif:*` and Markdown link tests), the oif-amd-share Go tests in `GO_BUILD_IMAGE`, `tests/check-patches.sh` (all Run:ai and KAI patches apply to the pinned source), gitleaks over the full history; tools pinned in versions.env, actions by commit. Passed 2026-11-01: first run green on all four jobs. Found on the way: the join templates were invalid YAML as written (`[${JOIN_CA_HASH}]`, now quoted); gitleaks flags the unit tests' fake kubeadm token and key (allowed by exact value); a failed promtool download silently skipped the rule tests (now fails in CI)

## Project 1: Orchestration platform

### P1.1 Run:ai on NVIDIA, default stack

Slice: a clean host becomes a Kubernetes cluster where Run:ai schedules work on the A6000.

- [x] T-101 `oif` skeleton: verbs, logging, prompts, state, manifest helpers, `versions.env`
- [x] T-102 Host preparation: packages, swap, sysctls, containerd, NVIDIA driver from the Ubuntu archive, vfio isolation of the W6400
- [x] T-103 kubeadm 1.35 single node, Calico, control-plane taint removed; local-path storage; MetalLB
- [x] T-104 NVIDIA GPU Operator, default settings (toolkit, device plugin, GFD, DCGM exporter)
- [x] T-105 Run:ai open source, default install (control plane, cluster, KAI Scheduler); spike S-3 first decides the install method
- [x] T-106 kube-prometheus-stack; DCGM and Run:ai metrics scraped; Fleet and Scheduling dashboards (both vendors, guide 7; Grafana on grafana.<runai-domain>)
- [x] T-107 `oif uninstall`, `status`, `plan`, `check` for everything above. Passed 2026-10-25: uninstall, clean check, reinstall from the GitHub tarball; a second uninstall needed two re-run fixes (12775ca, edec89e) and then left the host clean (tests/host/verify-clean.sh). Guide 9 written
- [x] T-108 GPU fractions on NVIDIA (ADR-032, guide 11): host driver branch 615-server (Ubuntu 26.04 archive, open modules, prebuilt for the running kernel); an installed node on an older branch is upgraded in place with one reboot; stage runai-fractions then lets the fractioning daemons onto r615 nodes. Passed 2026-11-01 on the lab: `oif install` on the running cluster upgraded gpu-nvidia 595.91.07 -> 615.71.09 with one reboot (2 min), fractiond and mpsd Ready, cluster Connected (no longer Missing prerequisites); two 0.5-GPU trainings from the Run:ai UI share the A6000, each container sees 24,570 MiB (NVIDIA_GPU_MEMORY_LIMIT), a third waits on quota; unit tests 11/11, shellcheck clean. Found on the way: the leftover-package loop failing on a removed package (ebe5615); projects inherit default node pools `default` only, so UI workloads land in a pool without GPUs (T-125; team-c set by hand to nvidia, amd, default)
- Checkpoint: project `team-a` with a quota of 1 NVIDIA GPU; a GPU pod runs, a second waits on quota; the dashboards show it; uninstall returns the host to the OS default.

### P1.2 Add AMD GPUs

Slice: the same cluster also schedules the W7900, with AMD telemetry next to NVIDIA's.

- [x] S-2 **KAI quotas for `amd.com/gpu`.** Passed 2026-10-25 (stage amd-quota): a pod requesting `amd.com/gpu` waits in team-b (quota 0, `NonPreemptibleOverQuota`) on a free GPU and runs in team-a (quota 1). A project's GPU quota is one count across vendors; the per-vendor 1+1 check moves to T-113.
- [x] T-111 AMD GPU Operator v1.5.1 (in-kernel driver, device plugin, node labeller, ECC threshold for kernel 7.0); guide 6
- [x] T-112 `oif:gpu_*` recording rules for both vendors with `promtool` unit tests (pinned Prometheus 3.15.0); also oif:node_*, per-vendor allocatable/requested/caps and Run:ai project series
- [x] T-113 Per-vendor GPU quotas (ADR-015: a single node cannot be split into node pools, so a Kubernetes ResourceQuota caps each vendor inside one Run:ai project): project team-c, quota 2 = 1 NVIDIA + 1 AMD; one pod per vendor runs, a third GPU pod is refused. Passed 2026-10-25 (stage vendor-quota)
- [x] T-114 Fleet dashboard shows both vendors on the same panels (tested 2026-10-25)
- [x] T-115 Run:ai counts and shows AMD GPUs (ADR-016, guide 8): oif patch set for Run:ai 3.0.20 built on the cluster (cluster-sync counts AMD GPUs on mixed nodes, web UI AMD logo for ROCm images, operator reports fractions unavailable when no node runs them); ROCm templates pytorch-rocm-1-gpu and jupyter-lab-rocm-1-gpu; the same PyTorch check printed the W7900 and the A6000. Passed 2026-10-25: Overview 1/1 nodes, 2/2 GPU devices
- [ ] T-116 KAI scheduler patch: vendor-aware placement on a node with both vendors (an NVIDIA pod must not be bound when only the AMD GPU is free)
- Checkpoint: one project with quota 1+1; both GPUs allocatable; a third GPU pod waits on quota; uninstall still clean.

### P1.3 Multi-node hybrid cluster

Slice: NVIDIA and AMD GPUs in separate nodes, as in production (one vendor per server), with a highly available control plane. Tested on the [hybrid-gpu-lab](https://github.com/manmohanbrahma/hybrid-gpu-lab) VMs: cp1-3 (control plane), gpu-amd (W7900), gpu-nvidia (A6000).

- [x] T-119 KVM lab (separate project hybrid-gpu-lab): 3 control-plane + 2 GPU worker VMs, GPUs passed through, create/destroy/recreate; both drivers initialise in the VMs and survive a recreate (2026-10-26)
- [x] T-120 Node list `OIF_NODES`, cluster SSH key created by oif on cp1 and installed once through the admin's forwarded agent, admin key on the control plane by choice, per-node runner (`oif _node`, node reboots driven by cp1), `install --until`. Passed 2026-10-26 on the lab: `tests/lab/t120-nodes.sh --reboot gpu-nvidia`, 63 checks (gpu-nvidia: NVIDIA 595 driver, reboot back in 27 s). Found and fixed on the way: agent keys masking the cluster key, ssh reading the node list, no keepalive after a node went down, the lab powering VMs off on reboot
- [x] T-121 HA Kubernetes: kube-vip v1.2.4 on `OIF_API_VIP`, `kubeadm init` on cp1, cp2/cp3 join as control planes, workers join (`oif _node-join`, tokens over SSH stdin, deleted after), Calico, MetalLB in the node subnet, no control-plane taint. Passed 2026-10-26 on the lab: `tests/lab/t121-cluster.sh --failover`, 14 checks (5 nodes Ready; API address moved from cp1 to cp2 with the API answering throughout)
- [x] T-122 GPUs on their nodes: cluster GPU inventory over the cluster key, NVIDIA driver with nouveau blocked on NVIDIA nodes, new node stage `amd-firmware` (`linux-firmware-amd-graphics`, amdgpu reload, else reboot), both GPU operators installed when any node has that vendor and checked on the node that has it; AMD operator stages before the platform. Passed 2026-10-26 on the lab: `tests/lab/t122-gpus.sh`, 20 checks. Found on the way: lsmod cut off by an early-exiting awk (pipefail), the AMD exporter Service answering only on AMD nodes (internalTrafficPolicy Local)
- [x] T-123 Run:ai on several nodes: stage `runai-pools` labels GPU nodes `oif.ai/gpu-vendor` and creates the Run:ai node pools `nvidia` and `amd`; project quotas per pool (per-vendor; a third pod queues), ADR-015's ResourceQuota kept for a single node; patch builds pinned to the first node, patched images loaded on every node; quota tests in the vendor's pool. Passed 2026-10-28 on the lab: `tests/lab/t123-runai.sh`, 27 checks; regression T-120 (66), T-121 --failover (14), T-122 (20) pass. Guide 10. Handoff (Grok): presentations/T123-Runai-Node-Pools.md can take these results; T-124 next
- [x] T-124 Demonstration and platform HA (ADR-022): install across five nodes, a control-plane node powered off with nobody acting, workloads in both pools, quotas, dashboards, uninstall across nodes and install again. Passed 2026-10-31 on a fresh install: `tests/lab/t124-ha.sh cp2` with cp2 holding the database primary and the ingress address, 23 checks; outside probe `tests/lab/t124-probe.py` on the lab host: UI 0 s, login with API call 67 s, Grafana 47 s (limit 90 s); regression T-120 (74), T-121 (11), T-122 (20), T-123 (27) pass. Uninstall across nodes clean (verify-clean on all five); no `lab recreate` was needed. Found and fixed on the way (ADR-022 amendments): Run:ai's `cluster` CRD hiding CloudNativePG's, database connections, singles users miss, connections stuck on the dead primary (`oif-conntrack-reaper`), the ingress address announced from a GPU worker, 20 s node detection, `wal_keep_size` after a 4.5 h outage. Guide 10 (HA section); published as /ai/runai-amd-ha/. Handoff (Grok): a T-124 presentation can take guide 10's results and ADR-022's amendment list; open follow-ups: automatic rebuild of a database copy, fencing (ADR-022 rejected list)
- [x] T-125 One job, one vendor (ADR-032, guide 12): stage one-vendor sets every Run:ai department's default node pools to the GPU pools first (`nvidia, amd, default`; projects without their own order inherit it) and adds ValidatingAdmissionPolicy `oif-one-gpu-vendor`, which refuses a pod asking for `nvidia.com/gpu` and `amd.com/gpu`; KAI keeps a multi-pod workload in one PodGroup, bound to one pool. Passed 2026-11-01 on the lab: only the new stage ran on the installed cluster; t123 31/31 (a 2-pod 0.5-GPU Job without a pool ran both pods on gpu-nvidia in one PodGroup in pool nvidia; the both-vendor pod refused); a UI training with no pool picked showed nvidia, amd, default and ran on gpu-nvidia. Found on the way: the department list API leaves out defaultNodePools (read each department, d4c696e); Run:ai distributed workloads need the Kubeflow training operator (not installed)
- [x] S-7 **AMD GPU fractions** (ADR-032): **go** (owner, 2026-11-01), soft memory isolation. KAI v0.18.3 is NVIDIA-only at every step (scheduler readiness check in NvFractions mode, binder plugins, reservation pod requesting nvidia.com/gpu and using NVML); a CDI pod annotation is not injected (kubelet passes no pod annotations to containers). On the W7900: two pods with PyTorch memory caps of 0.45 each held 18 GiB, GPU 100 % busy, 24.3 + 24.3 TFLOPS (one pod alone 55.3); a pod without the cap took 40.5 GiB and the second failed with OOM. Findings and patch plan: docs/evidence/S-7/findings.md
- [x] T-126 **GPU fractions on AMD** (ADR-032, S-7, guide 13): KAI v0.18.3 rebuilt with four patches (AMD GPU node helper; scheduler skips the NvFractions readiness check on AMD GPU nodes; binder reserves an amd.com/gpu and names the GPU in oif.ai/amd-gpu* annotations; resource-reservation reports the AMD GPU's PCI address) and the oif-amd-share NRI plugin (gives the pod /dev/kfd and the GPU's DRM nodes, OIF_GPU_MEMORY_FRACTION); policy oif-amd-share-annotations (binder only); node stage amd-runtime (runtime class nvidia = runc on AMD-only nodes); stage amd-fractions builds, loads and switches them on; AMD_FRACTIONS=none restores stock KAI. Passed 2026-11-01 on the lab (tests run by the owner): plugin alone, two unprivileged pods share the W7900 (25.5 TFLOPS each); through Run:ai's scheduler two 0.5 pods on gpu-amd (18 GiB held and 24.2 TFLOPS each), a third waits on team-c's AMD quota, NVIDIA fractions unchanged (24,570 MiB each), a hand-set annotation refused; from the Run:ai UI two half-GPU ROCm trainings in pool amd (0.5 GPU, 22.5 GB each, AMD logo). Found on the way: KAI's admission sets runtimeClassName nvidia on every fraction pod (fixed by amd-runtime); no go-operator patch needed (RunaiConfig takes KAI image overrides). Memory isolation is soft (documented). Not tested: fractions by GPU memory in GiB on AMD; more than one AMD GPU per node
- [x] T-127 **AMD GPU fractions, usable from the UI** (ADR-032; owner's review of T-126 on 2026-11-01: amd-smi shows the whole GPU, no logs, no obvious AMD fraction in the UI, the New cluster page is NVIDIA-only): (B) the plugin caps PyTorch to the pod's share (allocator per_process_memory_fraction, merged with the image's settings); (A) Run:ai templates for half an AMD GPU (ROCm PyTorch training, Jupyter) with pool amd preset; (C) the templates run a probe that logs the GPU, its share and a compute result; a Run:ai UI patch on New cluster pointing to oif install (no stock cluster registration from there); guide 14: how oif builds the cluster across all nodes. Passed 2026-11-01 on the lab (owner): New cluster page shows the oif note; a Jupyter workspace from jupyter-lab-rocm-half-gpu runs on the W7900 with PYTORCH_ALLOC_CONF=per_process_memory_fraction:0.5 (20 GiB allocated, 25 and 30 GiB refused: 22.49 GiB allowed), Run:ai records 0.5 GPU / 22,500 MB. Found and fixed on the way: a rebuilt patched image kept its tag (deployment not restarted; image copy compared names only, so two UI builds were served at once); runai-ha's global replicaCount gave cluster-redis two unreplicated copies, so workspace logins looped (ADR on HA amended: cluster-redis single)
- [x] T-128 **Hardening after the external review** (2026-11-01, guide 13): plugin failure paths and GPU discovery at start; a node that gets a replaced image restarts its component; half-GPU templates removed when fractions are off; lab checks for the annotation policy, the same-tag image copy, soft memory isolation with a non-compliant pod, a whole and a half AMD GPU on one node, AMD_FRACTIONS off and on, cluster-redis restart with an open workspace. Passed 2026-11-01 on the lab (owner): tests/lab/t128-hardening.sh 17/17 (plugin lists 0000:03:00.0 at start; only the binder may add, change or remove oif.ai/amd-gpu*; a whole AMD GPU waits while a half runs and the reverse; a pod lifting PyTorch's cap took 23 GiB of a 22.5 GiB share next to a 20 GiB neighbour), --image-copy 7/7 (UI image restored and restarted, a second install restarts nothing), --expect-off 9/9 and on again, --redis-restart 1/1 with the Jupyter workspace still logged in. Found and fixed on the way: AMD_FRACTIONS=none did not wait for the plugin's namespace to go; an empty AMD_FRACTIONS keeps a saved none (use all). Evidence docs/evidence/T-128/
- [ ] T-129 **Refuse a GPU pod that may run on either vendor** (ADR-032 amendment, owner decision 2026-11-01): UI test UI-10b placed a CUDA workspace from scratch on gpu-amd (pool amd) when team-c's NVIDIA quota was full, because the project's pool order (nvidia, amd, default; T-125) lets KAI fall back across vendors. An admission policy refuses a GPU pod whose allowed node pools include both `nvidia` and `amd`, with a message to choose one pool; the oif templates already choose one. Lab test: from-scratch workload with both pools refused with that message; with pool `nvidia` only it waits on quota instead of moving to `amd`
- [ ] T-137 **OIF Scheduling dashboard on several node pools**: `oif:project_gpu_deserved`, `_allocated` and `_pending` take `max` over a project's queues; with one queue per pool (team-c-nvidia, team-c-amd) they show one pool (quota 1 and allocated 1 where Run:ai has 2 and 1.5). Sum the per-pool queues; the "Per-vendor caps" panel (single-node ResourceQuota, ADR-015) is empty on multi-node: show it only when the quota exists
- [ ] T-138 **Run:ai Overview "Allocated GPU devices" stays 0** while whole and fractional GPUs are allocated (UI-11, both vendors): find the metric it reads and whether oif's setup or Run:ai is the cause; upstream issue if Run:ai
- Checkpoint: five Ready nodes; Run:ai shows two pools with one GPU each; a project with quota 1 per pool runs one workload per vendor and queues a third; uninstall leaves every node clean.

### P1.4 Topology & Intent (vendor-agnostic surface)

Slice: the platform discovers high-bandwidth domains and accepts jobs that do not name a vendor, while still preferring GPU Direct domains when available (ADR-019, docs/design/Vendor-Agnostic-Job-Model.md).

- [ ] T-130 Topology discovery: controller (or stage) that labels nodes with vendor, interconnect class and provisional domain membership from NFD + GPU operator labels; publishes `AcceleratorDomain` objects for single-node and multi-node same-vendor groups
- [ ] T-131 `AcceleratorDomain` CRD + status (capacity, allocatable, conditions); basic unit and lab tests on hybrid-gpu-lab
- [ ] T-132 Domain-aware packing: scheduler filter/score (or KAI integration) that prefers packing multi-GPU requests inside one domain; records chosen domain on the workload
- [ ] T-133 `AIJob` CRD (intent surface): model, precision, gpuCount, qos, optional placement preferences (`preferVendor`, `requireSameDomain`, `allowCrossVendor`); controller translates to existing Run:ai / Kubernetes objects so current resource names keep working
- [ ] T-134 PlacementPolicy defaults (namespace or cluster): allowCrossVendor, preferSameDomain, vendorPriority; applied when the AIJob omits fields
- [ ] T-135 Status and observability: AIJob status shows vendor, domain, crossVendor flag; extend `oif:*` with domain utilisation and cross-vendor placement counters; Grafana panel
- [ ] T-136 Guides and presentation: how to submit a vendor-agnostic job, how domains appear, how cross-vendor is requested or forbidden
- Checkpoint: a multi-GPU AIJob with `requireSameDomain: true` lands inside one domain; an AIJob with no vendor preference is placed according to policy; status and dashboards show the chosen vendor and domain; existing direct `nvidia.com/gpu` / `amd.com/gpu` jobs still work.

## Project 2: Serving and a fair benchmark

The goal is an apples-to-apples comparison: same model, same Dynamo version, same engine version and flags, same benchmark profile, one GPU under load at a time (ADR-011, ADR-012).

### P2.1 Dynamo on NVIDIA with the default engines

- [~] S-4 (Claude) **Dynamo under Run:ai's KAI.** Dynamo 1.6.1 (owner decision 2026-11-01; Run:ai 3.0's support matrix names 1.5.x, so this also tests compatibility): `dynamo-platform` chart with its defaults: Grove and its bundled KAI Scheduler off (Grove is for multi-node gangs; single-node pods then go to Run:ai's KAI like any project workload). Exit: an aggregated DynamoGraphDeployment (frontend + one vLLM worker, Qwen3-0.6B) submitted to team-c through Run:ai (YAML submission) shows in Run:ai's Workloads, its worker runs on gpu-nvidia in pool nvidia under team-c's quota, chat completion through the frontend works, and a second one over quota waits. Fail: the owner chooses Dynamo 1.5.x or Dynamo pods outside Run:ai's quotas
- [ ] T-201 Dynamo platform (operator, CRDs) pinned and installed; pods scheduled by KAI under the Run:ai project (spike S-4 first)
- [ ] T-202 Qwen3-0.6B on the A6000 with Dynamo's default vLLM image; chat completion through the Dynamo frontend
- [ ] T-203 Same model with Dynamo's default SGLang image
- [ ] T-204 Same model with Dynamo's default TensorRT-LLM image (NVIDIA-only reference; check Ampere support first)
- [ ] T-205 AIPerf runner as a Kubernetes Job; `oif bench` with profiles, temperature guard, Grafana annotations; JSON results
- [ ] T-206 Serving dashboard (request rate, TTFT, ITL, KV cache, queue) for Dynamo frontend and workers
- Checkpoint: a report for the A6000 with three engines.

### P2.2 Dynamo on AMD with equivalent engines

- [ ] S-1 **Dynamo on ROCm (W7900).** ROCm vLLM base plus the Dynamo runtime (no NIXL, no KVBM), aggregated, in podman. Exit: worker registers, chat completion works (streaming and not), 10 minutes of AIPerf at concurrency 8 without errors. Fail: owner chooses llm-d or plain vLLM ROCm.
- [ ] S-5 **SGLang ROCm on gfx1100.** SGLang's ROCm builds target Instinct GPUs; prove it serves on the W7900. Fail: the AMD SGLang column is marked "not supported" in reports.
- [ ] T-211 `images/dynamo-vllm-rocm`: the vLLM version that matches Dynamo's NVIDIA default as closely as ROCm allows
- [ ] T-212 `images/dynamo-sglang-rocm` (if S-5 passes)
- [ ] T-213 Qwen3-0.6B on the W7900 through the same Dynamo frontend, selected by model name
- [ ] T-214 Same `oif bench` profiles on the W7900
- Checkpoint: one report, A6000 vs W7900, per engine, with any version difference shown on the report.

### P2.3 Engine overlays: latest vLLM and SGLang on both vendors

- [ ] T-221 Overlay build: Dynamo runtime pinned, engine replaced by the latest vLLM or SGLang release; the same engine version for the CUDA and ROCm images (ADR-011)
- [ ] T-222 Compatibility check per overlay (worker registers, metrics exported, KV events if the engine supports them); results recorded in `docs/COMPATIBILITY.md`
- [ ] T-223 One serving profile file (`profiles/*.yaml`) applied to both vendors: dtype, max model length, max batch, prefix caching, chunked prefill, scheduler settings
- [ ] T-224 Benchmark matrix: {A6000, W7900} x {vLLM, SGLang} x {Dynamo default, latest overlay}; 3 repeats; HTML comparison report with versions, image digests, flags, power and clocks
- Checkpoint: a fair-comparison report the owner signs off for publication.

## Project 3: Unified API and AI gateway

One OpenAI-compatible API in front of every model on both vendors, with API keys, token budgets and usage per team, then a self-service API to deploy, serve and benchmark. Starts after P1.3 and P2.1 + S-1 (models served by Dynamo on NVIDIA and on AMD). Design: ADR-018 (proposed).

### P3.1 AI gateway

- [ ] S-6 **Gateway choice.** agentgateway (Linux Foundation, v1.x; the gateway Dynamo documents for GAIE routing) against Agent Router (formerly Envoy AI Gateway, v1.2; mature token rate limits and quotas), both through the Gateway API Inference Extension. Same test on the lab cluster: OpenAI chat and streaming to a Dynamo model on each vendor through an InferencePool with Dynamo's endpoint picker; per-key authentication; a per-key token budget that refuses the request over it; usage metrics in Prometheus; added latency at concurrency 8. Exit: the owner picks one (ADR-018 accepted).
- [ ] T-301 Gateway installed by an oif stage, pinned; its own MetalLB address and `api.<domain>` with the oif CA; Gateway API and GAIE CRDs pinned
- [ ] T-302 One route per model name; an InferencePool per model and vendor (Dynamo's EPP for Dynamo deployments); `/v1/models` lists what is served
- [ ] T-303 Vendor policy per model: pinned to a vendor, preferred with fail-over, or split by weight; a request header can ask for a vendor
- [ ] T-304 API keys per team, mapped to a Run:ai project; keys stored as Kubernetes secrets, created and revoked with `oif api-key`
- [ ] T-305 Token rate limits and budgets per key (input and output tokens), 429 with a clear message when exceeded
- [ ] T-306 Usage and cost dashboard: requests, tokens, errors and latency per key, model and vendor; `oif:` recording rules with promtool tests
- [ ] T-307 Guide and published pages; AIPerf through the gateway vs direct to the frontend (gateway overhead)
- Checkpoint: two teams with their own keys call the same model name; one is served by the A6000, one by the W7900 (or both with fail-over); a team over its token budget gets 429; Grafana shows tokens per team and vendor.

### P3.2 Self-service API

- [ ] T-311 API design (OpenAPI): environments (vendor, GPU, engine, profile), deployments, benchmark runs; authenticated with the P3.1 keys, scoped to the key's Run:ai project
- [ ] T-312 Deploy and remove a model: creates the Dynamo deployment in the project's namespace (scheduled by KAI under the project's quota), its InferencePool and route
- [ ] T-313 Benchmark runs through the API: AIPerf Job with a profile, results as JSON and in the report
- [ ] T-314 Small web UI on the API, or Run:ai workload templates where they are enough
- [ ] T-315 Placement policies: by vendor preference, free capacity, latency target or cost per token

### P3.3 Agents and tools (optional)

- [ ] T-321 MCP tool servers behind the same gateway, with the same keys (both gateway candidates support MCP)

## Release

- [ ] T-901 End-to-end test on the reference host from a clean OS (TEST_PLAN.md)
- [ ] T-902 Install and comparison guides with screenshots on the guides site
- [ ] T-903 Tag v0.1.0 after Project 1, v0.2.0 after Project 2
