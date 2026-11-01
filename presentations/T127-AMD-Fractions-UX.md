# T-127 — AMD GPU Fractions, Usable from the UI (ADR-032)

**Status:** Done (tested 2026-11-01 on the lab)  
**Repo:** [manmohanbrahma/open-inference-fabric](https://github.com/manmohanbrahma/open-inference-fabric)  
**Related:** ADR-032 · T-126 · S-7 · `images/oif-amd-share/` · `patches/runai/3.0.20/0004-frontend-new-cluster-points-to-oif.patch` · Guide 13 · Guide 14 · `docs/evidence/T-127/`

---

## 1. What T-127 delivers

| Capability | Description |
|------------|-------------|
| **Automatic PyTorch memory cap** | The oif-amd-share NRI plugin sets `PYTORCH_ALLOC_CONF=per_process_memory_fraction:<fraction>` (also the HIP and CUDA names), merged with any image settings. PyTorch (and frameworks built on it such as vLLM) refuse allocations past the pod's share. |
| **Half-GPU AMD templates** | Run:ai templates `pytorch-rocm-half-gpu` (training) and `jupyter-lab-rocm-half-gpu` (workspace) with pool `amd` preset, ROCm image, 0.5 GPU fraction, and a probe that logs the GPU, its share and a compute result. |
| **New cluster page note** | Frontend patch `0004-frontend-new-cluster-points-to-oif.patch`: **Resources > Clusters > New cluster** explains that clusters are added with `oif install` (guide 14) instead of NVIDIA's stock Helm command (no AMD support, bootstrap token). |
| **Guide 14** | End-to-end description of how one `sudo ./oif install` builds the multi-node cluster from bare machines to a working Run:ai platform. |
| **HA amendment** | `cluster-redis` kept single (its copies do not replicate; workspace login sessions were lost across copies). |

Builds on T-126's soft fractions. Memory isolation remains soft for non-PyTorch processes; `amd-smi` still shows the whole GPU.

---

## 2. Architecture

```
AMD-only GPU node (gpu-amd, pool amd)
┌─────────────────────────────────────────────┐
│ Host amdgpu driver + ROCm device plugin          │
├─────────────────────────────────────────────┤
│ oif-amd-share NRI plugin (DaemonSet)             │  ← reads oif.ai/amd-gpu* annotation
│   → injects /dev/kfd + DRM nodes                   │
│   → OIF_GPU_MEMORY_FRACTION=0.5                    │
│   → PYTORCH_ALLOC_CONF=per_process_memory_fraction:0.5│
├─────────────────────────────────────────────┤
│ Patched KAI (T-126) + Run:ai templates              │
│   pytorch-rocm-half-gpu / jupyter-lab-rocm-half-gpu│
│   (pool amd, 0.5 GPU, probe in log)                │
└─────────────────────────────────────────────┘
         │
         ▼
Jupyter / training pod from template
Sees share in env + automatic PyTorch cap (20 GiB ok, 25+ GiB refused)
Run:ai records 0.5 GPU / 22 500 MB
amd-smi still shows whole card (soft isolation)
```

- **Plugin change (B)**: on container create, the NRI plugin appends the per-process memory fraction to the three PyTorch allocator env vars, merging with any values already present in the image.
- **Templates (A/C)**: stage `runai-amd-templates` creates the half-GPU templates with pool `amd` and a command/probe that prints GPU identity, fraction, device files and a short compute result.
- **UI patch**: new frontend patch so the New cluster wizard points at `oif install` / guide 14 instead of generating a stock Helm command.
- **Image rebuild hygiene**: oif now restarts the deployment when a patched image digest changes (same tag) and copies images by content, not only by name.

---

## 3. Workflow steps

Admin runs `sudo ./oif install` (or the relevant stages after T-126 is already present).

| Step | Action |
|------|--------|
| **Plugin rebuild** | `amd-fractions` rebuilds the oif-amd-share image with the PyTorch cap logic and loads it. |
| **Templates** | `runai-amd-templates` creates `pytorch-rocm-half-gpu` and `jupyter-lab-rocm-half-gpu`. |
| **Frontend patch** | `runai-patches` builds and switches the UI image that includes patch 0004. |
| **HA fix** | `runai-ha` keeps `cluster-redis` at replica count 1. |
| **User path** | In the Run:ai UI: New workload → Training or Workspace → choose the half-GPU template → Create. Log shows the probe; notebook sees the automatic cap. |

### Design notes

- Soft isolation is unchanged for non-PyTorch processes; the automatic cap only covers the PyTorch allocator.
- vLLM's default `--gpu-memory-utilization 0.9` will fail on a half GPU; set it below the share (e.g. 0.45).
- New cluster registration is intentionally disabled in the UI; oif owns cluster construction (guide 14).

---

## 4. Key source files

| Path | Role |
|------|------|
| `images/oif-amd-share/` | NRI plugin: injects devices + `OIF_GPU_MEMORY_FRACTION` + PyTorch `per_process_memory_fraction` |
| `patches/runai/3.0.20/0004-frontend-new-cluster-points-to-oif.patch` | New cluster page note pointing to `oif install` / guide 14 |
| `installer/stages/` (runai-amd-templates, amd-fractions, runai-patches, runai-ha) | Template creation, plugin deploy, UI build, redis single |
| `docs/guides/13-amd-gpu-fractions.md` | Updated operator guide (templates + automatic cap) |
| `docs/guides/14-build-the-cluster.md` | End-to-end cluster build walkthrough |
| `docs/evidence/T-127/lab-test-3.txt` | Lab evidence (Jupyter workspace, cap behaviour, Run:ai record) |
| `docs/DECISIONS.md` → ADR-022 amendment | cluster-redis kept single |

---

## 5. Verification

**Lab results (2026-11-01, hybrid-gpu-lab, owner-run):**

- New cluster page shows the oif note (no stock Helm command).
- Jupyter workspace from `jupyter-lab-rocm-half-gpu` (team-c, pool amd) on the W7900:
  - `PYTORCH_ALLOC_CONF=per_process_memory_fraction:0.5`
  - 20 GiB allocated; 25 GiB and 30 GiB refused (22.49 GiB allowed)
  - Run:ai records `gpu-fraction 0.5`, `runai-allocated-gpu-memory 22500`
  - Probe log shows GPU PCI, share 0.5, device files, compute result
- `amd-smi` still reports the whole card (expected for soft isolation).

Found and fixed on the way:

- Rebuilt patched image kept its tag → deployment not restarted; image copy compared names only → two UI builds served at once (fixed by digest comparison + restart).
- `runai-ha` global `replicaCount=2` gave unreplicated `cluster-redis` copies → workspace logins looped (ADR-022 amended: cluster-redis single).

---

## 6. Summary

| | |
|---|---|
| **Outcome** | Half-GPU AMD workloads are one click from the Run:ai UI; PyTorch is automatically capped to the share; New cluster page points to oif |
| **Mechanism** | NRI plugin env injection + half-GPU templates (pool amd) + frontend patch 0004 + guide 14 |
| **Safety** | Soft isolation documented; only PyTorch is hard-capped by the allocator; templates preset the correct pool |
| **Proof** | Lab evidence in `docs/evidence/T-127/`; UI templates confirmed; Run:ai allocation record matches |
| **Next** | Project 1.4 Topology & Intent (T-130+); optional hard isolation later if required |

---

*Generated for the open-inference-fabric presentations set. Keep in sync with TASKS.md and the installer modules.*
