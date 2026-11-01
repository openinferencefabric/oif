# T-128 — Hardening after the External Review (AMD GPU Fractions)

**Status:** Done (tested 2026-11-01 on the lab)  
**Repo:** [manmohanbrahma/open-inference-fabric](https://github.com/manmohanbrahma/open-inference-fabric)  
**Related:** ADR-032 · T-126 · T-127 · S-7 · `images/oif-amd-share/` · Guide 13 · `tests/lab/t128-hardening.sh` · `docs/evidence/T-128/`

---

## 1. What T-128 delivers

| Capability | Description |
|------------|-------------|
| **Plugin startup GPU discovery** | `oif-amd-share` lists every AMD GPU it can see at start (PCI addresses). Only `cardN`/`renderDN` DRM entries count; missing `/dev/kfd`, stale render nodes, GPUs without DRM devices, or extra DRM entries are handled cleanly. |
| **Annotation policy enforcement** | ValidatingAdmissionPolicy `oif-amd-share-annotations` allows only KAI's binder to add, change or remove `oif.ai/amd-gpu*` annotations. Hand-set or forged annotations are refused. |
| **Soft memory isolation measurement** | A half-GPU pod that keeps the PyTorch cap holds 20 GiB of its 22.5 GiB share; a second half that calls `torch.cuda.set_per_process_memory_fraction(1.0)` takes 23 GiB (more than its share, limited by free memory). Documented as soft isolation. |
| **Whole + half GPU mutual exclusion** | On a single AMD GPU a whole-GPU pod waits while a half is running (and vice versa) via Run:ai quota; they never share the device. |
| **Image copy hygiene** | A node that receives a replaced image under the same tag restarts the affected component; a second install does nothing. Image copies compare content (digest), not only name. |
| **AMD_FRACTIONS lifecycle** | `AMD_FRACTIONS=none` restores stock KAI, removes the plugin namespace and half-GPU templates, and waits until the namespace is gone. An empty value keeps a saved `none`; use `all` to turn fractions back on. |
| **cluster-redis restart safety** | Restarting the single `cluster-redis` with an open Jupyter workspace keeps the login session. |

Builds on T-126/T-127. Memory isolation remains soft for non-PyTorch processes; share an AMD GPU only between trusted workloads.

---

## 2. Architecture

```
AMD GPU node (gpu-amd, pool amd)
┌─────────────────────────────────────────────┐
│ Host amdgpu + ROCm device plugin                         │
├─────────────────────────────────────────────┤
│ oif-amd-share NRI plugin (DaemonSet)                    │  ← logs "AMD GPUs on this node: 0000:03:00.0" at start
│   → injects /dev/kfd + DRM nodes                          │
│   → OIF_GPU_MEMORY_FRACTION + PYTORCH_ALLOC_CONF         │
├─────────────────────────────────────────────┤
│ ValidatingAdmissionPolicy oif-amd-share-annotations     │  ← only binder SA may touch oif.ai/amd-gpu*
│ Patched KAI binder (reserves amd.com/gpu, writes annot.) │
└─────────────────────────────────────────────┘
         │
         ▼
Half-GPU pod (0.5) + whole-GPU pod (1)
Never both Running: second waits on team-c-amd quota
Soft isolation: PyTorch capped; non-compliant process can over-allocate free memory
```

- **Plugin**: lists GPUs at start; refuses containers whose named GPU it cannot find.
- **Policy**: binder-only mutation of the share annotations.
- **Image hygiene**: `runai_patch_spread` restarts the deployment when a node had to load a different digest under the same tag.
- **Lifecycle**: `AMD_FRACTIONS=none` waits for the plugin namespace to disappear and removes half-GPU templates; `all` turns them back on.

---

## 3. Workflow steps

On an installed multi-node cluster with AMD fractions already on:

| Step | Action |
|------|--------|
| **Plugin hardening** | Rebuild/redeploy `oif-amd-share` with improved GPU discovery and failure paths. |
| **Policy check** | Confirm ValidatingAdmissionPolicy exists and binds only the binder service account. |
| **Lab verification** | `sudo tests/lab/t128-hardening.sh` (17 checks) or with `--image-copy`, `--expect-off`, `--redis-restart`. |
| **Fractions off/on** | Set `AMD_FRACTIONS=none` in `.env`, `sudo ./oif install --reconfigure`; later `AMD_FRACTIONS=all`. |
| **Image copy test** | Intentionally replace a UI image digest on a node; reinstall restores it and restarts the component once. |

### Design notes

- Soft isolation is intentional and documented (guide 13). A non-compliant pod can consume free memory beyond its share.
- Whole and half GPU requests are mutually exclusive on one physical GPU via existing Run:ai quota accounting.
- Empty `AMD_FRACTIONS=` preserves a previously saved `none`; explicit `all` is required to re-enable.

---

## 4. Key source files

| Path | Role |
|------|------|
| `images/oif-amd-share/` | NRI plugin: GPU discovery at start, device injection, PyTorch cap, failure paths |
| `installer/stages/` (amd-fractions, runai-patches, runai-ha) | Build/load/switch, image copy by digest + restart, template removal, redis single |
| `tests/lab/t128-hardening.sh` | Lab acceptance: policy, plugin log, soft memory, whole/half mutual exclusion, image-copy, expect-off, redis-restart |
| `docs/guides/13-amd-gpu-fractions.md` | Updated troubleshooting and soft-isolation notes |
| `docs/evidence/T-128/` | Lab outputs (17/17, image-copy 7/7, fractions-off, redis-restart) |

---

## 5. Verification

**Lab results (2026-11-01, hybrid-gpu-lab, owner-run):**

- `sudo tests/lab/t128-hardening.sh` → **17/17 PASS**
  - Plugin lists `0000:03:00.0` at start.
  - Only the binder may add/change/remove `oif.ai/amd-gpu*`.
  - Half holds 20 GiB; greedy pod that lifts the cap takes 23 GiB (> 22.5 GiB share).
  - Whole GPU waits while half runs (and reverse); both eventually run when the other is gone.
- `--image-copy` → **7/7**: replaced image restored, UI restarted; second install restarts nothing.
- `--expect-off` (after `AMD_FRACTIONS=none` + `--reconfigure`) → **9/9**: stock KAI images, plugin namespace gone, half-GPU templates removed, whole-GPU templates remain.
- `--redis-restart` → **1/1**: cluster-redis back; open Jupyter workspace stays logged in.

Found and fixed on the way:

- `AMD_FRACTIONS=none` did not wait for the plugin namespace to disappear.
- Empty `AMD_FRACTIONS=` kept a saved `none` (must use `all`).

---

## 6. Summary

| | |
|---|---|
| **Outcome** | AMD fractions hardened: plugin discovery, annotation policy, measured soft isolation, whole/half mutual exclusion, image-copy hygiene, clean fractions on/off, redis restart safety |
| **Mechanism** | NRI plugin improvements + ValidatingAdmissionPolicy + installer lifecycle + lab suite `t128-hardening.sh` |
| **Safety** | Soft isolation explicitly measured and documented; only trusted workloads should share an AMD GPU |
| **Proof** | Lab evidence in `docs/evidence/T-128/`; 17/17 + option suites green |
| **Next** | Project 1.4 Topology & Intent (T-130+); optional hard isolation later if required |

---

*Generated for the open-inference-fabric presentations set. Keep in sync with TASKS.md and the installer modules.*
