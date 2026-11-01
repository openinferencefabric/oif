# Presentations

Living documentation decks for major features and tasks in Open Inference Fabric.

Each completed (or substantial) T-xxx task gets a presentation that explains the workflow, architecture decisions, and how it was verified. These decks are updated as the modules evolve.

## Product-level

| Deck | Description |
|------|-------------|
| [Product Strategy](OIF-Product-Strategy.md) | Positioning, market, uniqueness, roadmap and success metrics |
| [PRD](../docs/PRD.md) | Formal Product Requirements Document (v0.1) |

## Feature / Task decks

| Deck | Task | Status | Description |
|------|------|--------|-------------|
| [T-003 Continuous Integration](T003-Continuous-Integration.md) | T-003 | Done | Four parallel CI jobs on every push/PR: shellcheck/yamllint/unit tests, oif-amd-share Go tests, patch applicability against pinned upstream, full-history gitleaks (guide 15) |
| [T-108 GPU Fractions on NVIDIA](T108-GPU-Fractions-NVIDIA.md) | T-108 | Done | NVIDIA driver 615-server, in-place upgrade, fractiond/mpsd, two 0.5-GPU workloads sharing an A6000 (24 570 MiB each) |
| [T-119 KVM Hybrid GPU Lab](T119-KVM-Hybrid-GPU-Lab.md) | T-119 | Done | Repeatable KVM lab (hybrid-gpu-lab): 3 control-plane + 2 GPU workers with PCI passthrough |
| [T-120 Node List & Cluster Key](T120-Node-List-Cluster-Key.md) | T-120 | Done | Node list (`OIF_NODES`), cluster SSH key, per-node stage runner with reboot resume |
| [T-121 HA Kubernetes](T121-HA-Kubernetes-Workflow.md) | T-121 | Done | Highly available control plane with kube-vip, multi-node joins, Calico & MetalLB |
| [T-122 GPUs on Their Nodes](T122-GPUs-On-Their-Nodes.md) | T-122 | Done | Per-node GPU inventory, vendor drivers/firmware, conditional GPU Operators, correct resource placement |
| [T-123 Run:ai Node Pools](T123-Runai-Node-Pools.md) | T-123 | Done | Per-vendor Run:ai node pools (`nvidia`/`amd`) from oif labels, pool quotas, patched images on every node (27 checks PASS) |
| [T-124 Platform HA](T124-Platform-HA.md) | T-124 | Done | Platform high availability: redundant copies on control-plane nodes, CloudNativePG, conntrack reaper, 20 s detection (≤90 s user outage) |
| [T-125 One Job, One Vendor](T125-One-Job-One-Vendor.md) | T-125 | Done | Department default node pools (nvidia, amd, default), KAI PodGroup stays in one pool, ValidatingAdmissionPolicy refuses mixed-vendor pods (31 checks PASS) |
| [T-126 GPU Fractions on AMD](T126-GPU-Fractions-AMD.md) | T-126 | Done | Patched KAI + oif-amd-share NRI plugin: two 0.5-GPU ROCm workloads share a W7900 (soft isolation, ~18–22.5 GiB each); third waits on AMD quota; NVIDIA fractions unchanged |
| [T-127 AMD Fractions Usable from the UI](T127-AMD-Fractions-UX.md) | T-127 | Done | Automatic PyTorch memory cap on AMD fractions, half-GPU ROCm templates (pool amd), New cluster page points to oif install, guide 14; cluster-redis kept single |
| [T-128 Hardening after the External Review](T128-Hardening-AMD-Fractions.md) | T-128 | Done | Plugin GPU discovery, annotation policy, measured soft isolation, whole/half mutual exclusion, image-copy hygiene, clean AMD_FRACTIONS on/off, redis restart safety (17/17 + option suites) |

## Conventions

- **Primary format**: Markdown (renders natively on GitHub, easy to keep in sync with code).
- PPTX / PDF versions may be attached in Releases or generated on request.
- Filenames follow `Txxx-Short-Name.md` for task decks; product-level decks use descriptive names.
- Every deck links back to the relevant section of `TASKS.md`, `docs/DECISIONS.md` (ADRs), and the key source files.

## How these stay current

An automation watches the repository. When significant development lands (especially updates to `TASKS.md` or the installer modules), the corresponding presentation is regenerated or updated and committed here.

---

*Maintained as part of the open-inference-fabric documentation set.*
