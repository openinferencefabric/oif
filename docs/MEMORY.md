# Memory

Current state of the project. Update after every task.

## Status (2026-10-28)

- Phase 0: research and project documents written (T-001). Repository public (T-002); moved to github.com/openinferencefabric/oif on 2026-11-02.
- **P1.1** (single-node NVIDIA stack) done through T-107: host prep, kubeadm, NVIDIA GPU Operator, Run:ai 3.0.20, observability, uninstall/reinstall verified on the reference host.
- **P1.2** (AMD on the same node) done through T-115: AMD GPU Operator v1.5.1, dual-vendor recording rules and dashboards, per-vendor ResourceQuota (ADR-015), Run:ai patches so AMD GPUs appear in inventory and UI (ADR-016).
- **P1.3** multi-node hybrid cluster on [hybrid-gpu-lab](https://github.com/manmohanbrahma/hybrid-gpu-lab) (cp1–3, gpu-amd W7900, gpu-nvidia A6000):
  - [x] T-119 lab VMs with GPU passthrough
  - [x] T-120 node list, cluster SSH key, per-node runner (`tests/lab/t120-nodes.sh`, 66 checks with reboot path)
  - [x] T-121 HA Kubernetes with kube-vip on `OIF_API_VIP` (`tests/lab/t121-cluster.sh --failover`, 14 checks)
  - [x] T-122 GPUs on their nodes (`tests/lab/t122-gpus.sh`, 20 checks)
  - [x] T-123 Run:ai node pools `nvidia` / `amd` (`tests/lab/t123-runai.sh`, 27 checks; regression T-120/T-121/T-122 pass). Guide 10. Presentation updated.
  - [ ] T-124 demonstration and multi-node guides (stop cp1, workloads in both pools, dashboards, uninstall across nodes, lab recreate)
- **P1.4 Topology & Intent** defined (ADR-019 accepted, ADR-020 testing strategy):
  - Design: `docs/design/Vendor-Agnostic-Job-Model.md` (includes supported/unsupported placement contract)
  - Lab acceptance: `docs/design/P1.4-Lab-Acceptance-Checks.md` (bounded by current lab hardware)
  - Tasks T-130 – T-136 in TASKS.md (not started)
- Product docs: PRD v0.1, Product Strategy presentation, AMD pitch deck (artifact), SDLC.md
- Presentations for T-119–T-123 and product strategy under `presentations/`
- Guide 9 (uninstall) and Guide 10 (multi-node hybrid cluster) written; guides 1–8 remain single-node focused until T-124 hardens the multi-node path

## Plan

Three projects (ADR-010): Project 1 orchestration (Run:ai on NVIDIA, then AMD, then multi-node HA, then topology & intent), Project 2 Dynamo serving and fair benchmark, Project 3 AI gateway and self-service API (ADR-018 proposed).

Process: [docs/SDLC.md](SDLC.md).

## Current task

T-120 – T-123 done and tested on hybrid-gpu-lab (guide 10; lab scripts t120–t123 pass). Next implementation work: **T-124** (demonstration: stop cp1, workloads in both pools, dashboards, uninstall across nodes, `lab recreate`, install again).

Still open from earlier slices: T-116 KAI vendor-aware placement on mixed nodes. T-003 CI done (guide 15): every push runs the static checks, Go tests, patch check and secret scan; keep it green before merging.

P1.4 (T-130+) is defined and ready to start after P1.3 checkpoint (or in parallel for design-only work). Cross-vendor distributed model-parallel execution remains unsupported by default until an engine and configuration are explicitly validated.

## Multi-agent note

- **Claude Code**: implementation (installer, stages, tests, guides from real runs).
- **Grok**: architecture, ADRs, PRD, design docs, presentations, acceptance criteria, SDLC alignment.
- Shared contract: TASKS.md + ADRs + RULES.md + SDLC.md. Claim tasks with `[~]` and agent name.

## Notes

- Multi-node design is ADR-017: one entry point on the first control-plane node; same stages and own change record on every node; cluster key only after initial install; uninstall walks every node.
- Single-node remains the default when `OIF_NODES` is empty.
- Vendor-agnostic job surface and AcceleratorDomain: ADR-019; testing environments ADR-020.
- Lab acceptance scripts: `tests/lab/t120-nodes.sh`, `t121-cluster.sh`, `t122-gpus.sh`, `t123-runai.sh`, `t124-ha.sh` with `t124-probe.py` run outside the cluster (inside, kube-proxy answers the ingress address itself).
- Platform HA is ADR-022 with its amendments: copies on different control-plane nodes, CloudNativePG database (always `clusters.postgresql.cnpg.io`: Run:ai has its own `cluster` CRD), `oif-conntrack-reaper` host service, MetalLB only on control-plane nodes, 20 s node detection, `wal_keep_size` 4GB.
- Long lab tests: run them detached (`systemd-run` on the node, `setsid nohup` on the host); a dropped laptop link lost run 5 and run 6 of T-124. Host clean check: `tests/host/verify-clean.sh`.
- The reference host has no `curl` or `git` out of the box; oif uses Python and `wget`.
- Every step ships with a guide in `docs/guides/` (owner's rule, 2026-10-24).

## Known issues and risks

- Dynamo has no official ROCm support (ADR-002); decided by S-1.
- SGLang ROCm builds target Instinct GPUs; serving on the W7900 (gfx1100) is unproven (S-5).
- Run:ai GPU quotas count both vendors as one; per-vendor caps on a mixed node use ResourceQuota (ADR-015). On multi-node with one vendor per server, real node pools replace that (T-123).
- The KAI scheduler can bind an NVIDIA pod when only the AMD GPU is free on a mixed node; T-116.
- GPU fractions (T-108, ADR-032): NVIDIA driver branch 615-server makes Run:ai's fractioning daemons run (NRI memory limits enforced by the driver, MPS); a node below r615 keeps them off and Run:ai shows Missing prerequisites. AMD: done in T-126 (guide 13; soft isolation): KAI v0.18.3 fractions are NVIDIA-only (scheduler readiness check, binder, reservation pod on nvidia.com/gpu + NVML); a CDI pod annotation is not injected by containerd; the W7900 shares evenly between capped pods, an uncapped pod starves the others.
- Run:ai projects without their own `defaultNodePools` inherit their department's; Run:ai's own default is `default` only, a pool without GPUs. Stage one-vendor (T-125) sets `nvidia, amd, default` on every department. `GET /api/v1/org-unit/departments` leaves out `defaultNodePools` and `description`: read `/departments/<id>`. PUT takes the GET body without the read-only fields (no `name`).
- AMD GPU fractions (T-126): oif rebuilds KAI v0.18.3 (patches/kai/) and runs the oif-amd-share NRI plugin; only KAI's binder may set oif.ai/amd-gpu* (policy). KAI's admission gives every fraction pod runtimeClassName nvidia, so AMD-only nodes map that runtime to runc (node stage amd-runtime). RunaiConfig takes KAI image overrides (spec.binder.image, spec.binder.resourceReservation.image, spec.runai-scheduler.image). In the UI form, keep only pool amd or a fraction runs on NVIDIA first. KAI patches must be rebased when Run:ai bumps KAI (KRM).
- T-127: half-GPU AMD templates (pool amd) and the automatic PyTorch cap (PYTORCH_ALLOC_CONF=per_process_memory_fraction from the plugin); vLLM needs --gpu-memory-utilization below the share. A rebuilt patched image keeps its tag: oif restarts its deployment and copies it to a node unless the content (digest) matches. cluster-redis must stay single on the HA platform (workspace login sessions). The workstation <-> lab link is ~115 KB/s: a fresh browser needs ~80 s for the Run:ai UI; do not advise Ctrl+F5.
- T-128: AMD fraction memory isolation is soft in practice too: a pod that calls set_per_process_memory_fraction(1.0) takes more than its share (23 of 22.5 GiB next to a 20 GiB neighbour). An empty value in .env never overrides a saved setting (env_load), so switching a none back on needs an explicit value (AMD_FRACTIONS=all, RUNAI_PATCHES=all). Lab tests change settings with .env + install --reconfigure; `VAR=x sudo ./oif install` changes nothing.
- One job, one vendor (T-125): KAI binds a workload's PodGroup to one node pool; ValidatingAdmissionPolicy `oif-one-gpu-vendor` refuses a pod asking for both vendors. Run:ai distributed workloads (PyTorch, MPI) need the Kubeflow training operator, which oif does not install.
- Dynamo (S-4, guide 16): 1.6.1 runs under Run:ai 3.0.20 with the chart's defaults (Grove and its bundled KAI off); Run:ai lists a DynamoGraphDeployment as a workload and KAI applies the project quota. A DGD is non-preemptible: it never borrows over quota. Pool labels: set `runai/node-pool` in every component's `podTemplate.metadata.labels`; the DGD-level label does not reach the pods and the GPU-less frontend otherwise falls through to another pool (T-129). T-201: stage `dynamo` (installer/stages/85-dynamo.sh) installs it as release dynamo-platform in dynamo-system (takes over a hand install), only with an NVIDIA GPU; `DYNAMO=none` removes release, CRDs and namespace (and every DGD); uninstall removes it with the cluster. `runai_api.py workloads` lists workloads as Run:ai shows them.
- Kernel 7.0 inbox amdgpu reports phantom UMC ECC errors on the W7900; the AMD metrics exporter needs a raised threshold.
- Both GPUs throttle when loaded together on the reference chassis (ADR-009).
- Multi-GPU same-vendor domains (NVLink / Infinity Fabric packing of gpuCount > 1) and Instinct-class hardware are not available on the current hybrid-gpu-lab (1 GPU per vendor worker). Acceptance claims for those cases must be deferred or bounded until suitable hardware exists.
- Hard VRAM cap for AMD fractions (S-8, T-139): kai-scheduler/gpu-fractioning's `fractiond` with an AMD backend (fork `openinferencefabric/gpu-fractioning`, `--gpu-vendor=amd`) writes `dmem.max` on the pod cgroup from the binder's annotations; lab PASS 2026-11-03 (0.25 pod stopped at 11,264 of 11,516 MiB, 0.5 neighbour unaffected). The kubelet already enables `dmem` down kubepods.slice on kernel 7.0. The kubelet pulls images one at a time: a 20 GB pull blocks every other pod on the node; the lab test uses `manmohanbrahma/oif-vram-probe` (122 MB, HSA).
- T-139 (done 2026-11-03, t139 10/10, t128 18/18): OIF installs the hard VRAM cap: stage amd-fractions builds fractiond from the fork (GPU_FRACTIONING_REF, codeload tarball with checksum; `GOWORK=off`, the root module builds fractiond with its ./pkg replace), labels nodes `oif.ai/amd-vram-cap=dmem` after checking `dmem.capacity` over SSH, DaemonSet oif-fractiond (privileged, host /sys read-only, host cgroup tree read-write, plugin index 20). A unit-test kubectl stub must read stdin on `apply -f -`, or render gets a broken pipe and the stage dies with "rejected".
- T-129 (done 2026-11-03, t129 10/10, t123 31/31): Run:ai writes a workload's node pools as OR'd node-affinity terms (`oif.ai/gpu-vendor In [nvidia]`, `In [amd]`; pool default = `runai/node-pool DoesNotExist`), and the UI's whole GPU as `nvidia.com/gpu`; KAI counts AMD and NVIDIA GPUs alike, so a vendor-specific pod can be placed in the other vendor's pool. Webhook oif-vendor-pool (stdlib Go, no client-go; service account token against the API server) pins pods; policy oif-vendor-agnostic-gpu refuses vendor-less fractions allowed on both. Kubernetes 1.35 here has no MutatingAdmissionPolicy API. Project namespaces carry label `runai/queue`. Since T-129 a fraction submitted without choosing a pool is refused; T-125's lab Job names pool nvidia on the Job.
- T-137 (done 2026-11-03, 7/7): Run:ai exports one queue per project and node pool (`runai_*_per_queue{project, nodepool}`; department queues have no project and -1 = no quota). oif:project_gpu_* are sums over oif:project_pool_gpu_* (max per pool, -1 as 0). Grafana cannot hide a panel by its data: an empty panel gets a noValue explanation instead.
- T-138 (done 2026-11-04, 8/8): Run:ai's Overview and Analytics read every metric number from the control plane's Thanos (remote write from Prometheus runai/runai to https://<domain>/api/v1/receive); only node and GPU device counts come from its database. Thanos receive with more than one copy needs the Bitnami chart's `receive.service.additionalHeadless: true` or the hashring is 127.0.0.1 alone. A StatefulSet's serviceName cannot change: re-create it with `--cascade=orphan`, then wait on its revision status, not `kubectl rollout status` (returns at once on a new object). `runai_api.py telemetry TYPE` reads what the Overview shows.
- T-140 (done 2026-11-04, 13/13): Run:ai 3.0.20's workload forms share `hybrid-compute-resource-section` (UI patch 0005 adds the vendor choice there); "GPU devices" is always `nvidia.com/gpu`, a whole AMD GPU is the extended resource `amd.com/gpu`, and a form "whole GPU" has no `gpuRequestType` while a compute preset stores it as portion 1. KAI's scheduler reads GPU memory only from `nvidia.com/gpu.memory` (oif's KAI patch 0005 adds AMD's `beta.amd.com/gpu.vram.<size>`); never put `nvidia.com/gpu.memory` on an AMD node (Run:ai's status-updater adds both, KAI's pod-group controller refuses both). Run:ai's frontend image has no shell: check the UI over HTTPS. Workload REST: POST /api/v1/workloads/trainings with spec.compute and spec.nodePools; compute presets: /api/v1/asset/compute (name and description only, no labels).
- S-9 (done 2026-11-05, 14/14): KAI v0.18.3's topology scheduling keeps a gang in one domain (Topology levels of node labels, annotations `kai.scheduler/topology`, `kai.scheduler/topology-required-placement`; `kai.scheduler/batch-min-member` makes a Job one gang, the Job grouper's default is 1 pod and then the domain is chosen for one pod). KWOK v0.8.0's `stage-fast.yaml` has a `pod-complete` Stage that finishes Job pods at once: delete it, or fake pods free their GPUs (that was the first run's "over-commit"). Fake AMD nodes: tools/fake-gpu (labeller labels, naming strategies, SPX/DPX/QPX/CPX x NPS; MI350P SPX/DPX/CPX of 4; RDNA 2 SIMDs per CU, CDNA 4).
- T-130 (done 2026-11-05, 12/12): domain = node label (ADR-019 amendment). Agent oif-topology labels its own node; ServiceAccount tokens carry `authentication.kubernetes.io/node-name` in userInfo.extra (Kubernetes 1.35), which policy oif-topology-own-node checks. NVSwitch = NVIDIA PCI device of class 0x0680; AMD xGMI hive in `/sys/class/drm/card*/device/xgmi_hive_info/xgmi_hive_id` (0 or missing: none). KAI ignores nodes missing a Topology level's label, so every GPU node gets all three labels.
- T-132 (done 2026-11-06, t132 8/8, S-9 on oif-accelerator 14/14): A workload with any kai.scheduler/ annotation of its own gets no topology from Run:ai, and KAI ignores a required level when the pod group has no topology name (getJobTopology: "" = no constraint), so "require one domain" = kai.scheduler/topology AND the required level (lab: required alone ran unconstrained). Run:ai 3.0.20 network topologies (`/api/v1/network-topologies`, levels top first, no update: delete and recreate) become KAI Topologies of the same name (Run:ai agent); a node pool's `networkTopologyId` (PATCH `/api/v1/node-pools/{id}`; a PATCH without the field clears it) makes Run:ai add `kai.scheduler/topology` and `topology-preferred-placement=<lowest level>` to every workload submitted into the pool. KAI Topologies created in the cluster are synced up with source "Cluster". KAI v0.18.3 (and main 4261bdf) topology bug: lowestCommonDomainID walks down while all the job's nodes agree and stops only at the preferred level, so in a pool whose nodes share one domain below the required level (one-node pool) the required level's domains get no free resources computed and the job waits ("not enough resources: GPUs, pods"); oif KAI patch 0007 stops at the required level too. The patched KAI is built only by stage amd-fractions (AMD-only nodes), T-141.
