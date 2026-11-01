# T-126 — GPU Fractions on AMD (ADR-032)

**Status:** Done (tested 2026-11-01 on the lab)  
**Repo:** [manmohanbrahma/open-inference-fabric](https://github.com/manmohanbrahma/open-inference-fabric)  
**Related:** ADR-032 · S-7 · `installer/stages/75-amd-fractions.sh` · `images/oif-amd-share/` · `platform/gpu-amd/amd-share.yaml` · Guide 13 · `docs/evidence/T-126/`

---

## 1. What T-126 delivers

| Capability | Description |
|------------|-------------|
| **Patched KAI v0.18.3** | Four patches: AMD GPU node helper; scheduler skips the NVIDIA-only NvFractions readiness check on AMD GPU nodes; binder reserves `amd.com/gpu` and names the GPU in `oif.ai/amd-gpu*` annotations; resource-reservation reports the AMD GPU's PCI address. |
| **oif-amd-share NRI plugin** | On AMD-only GPU nodes, gives a fraction pod `/dev/kfd` and the GPU's DRM nodes when containerd creates the container, plus `OIF_GPU_MEMORY_FRACTION`. Pods request no `amd.com/gpu` themselves. |
| **Annotation policy** | ValidatingAdmissionPolicy `oif-amd-share-annotations` allows only KAI's binder to set the `oif.ai/amd-gpu*` annotations (prevents bypassing quotas). |
| **AMD runtime class** | Node stage `amd-runtime` maps the `nvidia` runtime class to `runc` on AMD-only nodes (KAI admission sets `runtimeClassName: nvidia` on every fraction pod before placement). |
| **Soft memory isolation** | Two 0.5-GPU ROCm workloads share a W7900 (each holds ~18–22.5 GiB, ~24 TFLOPS). A third waits on the project's AMD quota. NVIDIA fractions are unchanged. Isolation is soft (workload must honour the fraction env var; no hard driver limit). |
| **Opt-out** | `AMD_FRACTIONS=none` restores stock KAI images and removes the plugin. |

Requires AMD-only GPU nodes (multi-node, T-123). On mixed or NVIDIA-only clusters the stage is a no-op.

---

## 2. Architecture

```
AMD-only GPU node (gpu-amd, pool amd)
┌───────────────────────────────────────────┐
│ Host amdgpu driver + ROCm device plugin          │
├───────────────────────────────────────────┤
│ oif-amd-share NRI plugin (DaemonSet)             │  ← reads oif.ai/amd-gpu annotation
│   → injects /dev/kfd + DRM nodes + OIF_GPU_* env  │
├───────────────────────────────────────────┤
│ Patched KAI scheduler + binder + reservation     │
│   → reserves amd.com/gpu, sets annotations       │
│ ValidatingAdmissionPolicy (binder only)          │
└───────────────────────────────────────────┘
         │
         ▼
Two 0.5-GPU ROCm pods share the same W7900
Each sees OIF_GPU_MEMORY_FRACTION=0.5, holds ~18–22.5 GiB
Third 0.5-GPU pod Pending (AMD quota)
NVIDIA fractions (A6000) unchanged
```

- **Build**: stage `amd-fractions` builds patched KAI images (`oif.local/kai-scheduler/*:v0.18.3-oif-<rev>`) and the plugin image once, loads them on every node, and points `RunaiConfig` at them.
- **Placement**: KAI places the whole PodGroup into the AMD pool; binder writes the PCI address annotation; plugin injects devices only for annotated containers that do not already have `/dev/kfd`.
- **Isolation**: soft. Workloads are expected to respect `OIF_GPU_MEMORY_FRACTION` (e.g. via PyTorch memory caps). An uncapped pod can starve others (documented in S-7).

---

## 3. Workflow steps

Admin runs `sudo ./oif install` on the first control-plane node (stage runs only when AMD-only nodes exist).

| Step | Action |
|------|--------|
| **amd-fractions** | Build (or reuse) patched KAI + plugin images; load on every node; patch `RunaiConfig`; roll out scheduler/binder; deploy DaemonSet + ValidatingAdmissionPolicy. |
| **amd-runtime** (node stage) | On AMD-only nodes, add a containerd drop-in so runtime class `nvidia` maps to `runc`. |
| **Verification** | Plugin-alone test: two unprivileged pods share the W7900. Scheduler test: two 0.5 pods run, third queues on quota; hand-set annotation refused. UI: two half-GPU ROCm trainings in pool `amd`. |

### Design notes (ADR-032 / S-7)

- KAI v0.18.3 is NVIDIA-only end-to-end (scheduler readiness, binder plugins, reservation requesting `nvidia.com/gpu`). Patches make the fraction path vendor-aware without changing the NVIDIA path.
- CDI annotations are not injected by kubelet, so an NRI plugin is required to grant the devices.
- Memory isolation remains soft; hard limits would need driver or ROCm changes outside the scope of T-126.

---

## 4. Key source files

| Path | Role |
|------|------|
| `installer/stages/75-amd-fractions.sh` | Stage `amd-fractions`: build, load, switch images, deploy plugin + policy; `AMD_FRACTIONS=none` restores stock |
| `patches/kai/<version>/*.patch` | Four KAI patches (AMD helper, scheduler skip, binder annotations, reservation PCI) |
| `images/oif-amd-share/` | NRI plugin (Go): injects `/dev/kfd` + DRM nodes + env from `oif.ai/amd-gpu*` annotations |
| `platform/gpu-amd/amd-share.yaml` | DaemonSet (nodeSelector `oif.ai/gpu-vendor=amd`) + ValidatingAdmissionPolicy |
| `platform/gpu-amd/amd-fractions-build-job.yaml` | One-shot build Job (source tarball + patches + Go build) |
| `docs/guides/13-gpu-fractions-amd.md` | Operator guide |
| `docs/evidence/T-126/` | Lab evidence (plugin alone, scheduler, UI) |
| `docs/DECISIONS.md` → ADR-032 | Decision for soft AMD fractions |

---

## 5. Verification

**Lab results (2026-11-01, hybrid-gpu-lab, owner-run):**

- **Plugin alone** (`docs/evidence/T-126/01-nri-plugin.txt`): two unprivileged pods (no `amd.com/gpu`) share the W7900; each holds 18 GiB, 25.5 TFLOPS; a pod naming a missing PCI address is refused; control pod without annotation sees no GPU. Unit tests pass.
- **Through scheduler** (`02-runai-scheduler.txt`): two 0.5-GPU pods on `gpu-amd` (18 GiB / 24.2 TFLOPS each); third Pending (`NonPreemptibleOverQuota` on team-c AMD quota); NVIDIA 0.5 pods unchanged (24 570 MiB); hand-set annotation Forbidden by the policy; reservation pods request the correct vendor resource.
- **Run:ai UI** (`03-runai-ui.txt`): two half-GPU ROCm trainings in pool `amd` (0.5 GPU, 22.5 GB each, AMD logo); both see the same PCI address and `OIF_GPU_MEMORY_FRACTION=0.5`.

Found and fixed: KAI admission sets `runtimeClassName: nvidia` on every fraction pod (fixed by `amd-runtime` drop-in). Memory isolation is soft (documented). Not tested: GiB-based fractions on AMD; more than one AMD GPU per node.

---

## 6. Summary

| | |
|---|---|
| **Outcome** | Two 0.5-GPU ROCm workloads share one W7900; third waits on AMD quota; NVIDIA fractions unchanged |
| **Mechanism** | Patched KAI (annotations + amd.com/gpu reservation) + oif-amd-share NRI plugin + admission policy + runtime-class mapping |
| **Safety** | Only binder may set annotations; soft isolation documented; `AMD_FRACTIONS=none` restores stock KAI |
| **Proof** | Lab evidence in `docs/evidence/T-126/`; UI confirmation; unit tests on the plugin |
| **Next** | Project 1.4 Topology & Intent (T-130+); hard isolation if required later |

---

*Generated for the open-inference-fabric presentations set. Keep in sync with TASKS.md and the installer modules.*
