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
