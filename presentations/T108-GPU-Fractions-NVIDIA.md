# T-108 — GPU Fractions on NVIDIA (ADR-032)

**Status:** Done (tested 2026-11-01 on the lab)  
**Repo:** [openinferencefabric/oif](https://github.com/openinferencefabric/oif)  
**Related:** ADR-032 · `installer/stages/30-gpu-host.sh` (nvidia-driver) · `installer/stages/60-runai.sh` (runai-fractions) · `docs/guides/11-gpu-fractions.md` · `docs/evidence/T-108/`

---

## 1. What T-108 delivers

| Capability | Description |
|------------|-------------|
| **Driver branch 615-server** | NVIDIA driver from the Ubuntu archive (open modules, prebuilt for the running kernel). Minimum for Run:ai 3.0 GPU fractions. An installed node on an older branch (e.g. 595) is upgraded in place with one reboot. |
| **Fractioning daemons** | `fractiond` (NRI plugin injecting per-container GPU memory limits) and `mpsd` run on r615 nodes. Cluster status moves from "Missing prerequisites" to Connected. |
| **Half-GPU sharing** | Two 0.5-GPU workloads from the Run:ai UI share one A6000. Each container sees and is limited to 24,570 MiB (`NVIDIA_GPU_MEMORY_LIMIT`). A third waits on project quota. |
| **In-place upgrade** | `oif install` on a running cluster upgrades only the NVIDIA node and the `runai-fractions` stage; other nodes are unchanged. |

AMD fractions remain a spike (S-7). Projects currently inherit only the `default` node pool (no GPU); T-125 will set `nvidia`, `amd`, `default`.

---

## 2. Architecture

```
NVIDIA node (gpu-nvidia)
┌──────────────────────────────────────┐
│ Host driver 615.71.09 (open modules)   │
│ nouveau blacklisted                   │
├──────────────────────────────────────┤
│ GPU Operator (toolkit + device plugin) │
├──────────────────────────────────────┤
│ fractiond (NRI) + mpsd                │  ← only on nodes with driver ≥ 615
│ GpuFractioningConfig (no blocking sel) │
└──────────────────────────────────────┘
         │
         ▼
Two 0.5-GPU pods bound to the same GPU UUID
Each sees memory.total = 24570 MiB
Third pod queues (quota or pool)
```

- **Driver stage** (`stage_nvidia_driver`): installs `nvidia-headless-no-dkms-<branch>-open` and matching kernel modules. On upgrade it purges the previous branch's packages and forces one reboot. Never downgrades a newer driver.
- **Fractions stage** (`stage_runai_fractions`): if the oldest NVIDIA driver on any node is < 615, it adds a nodeSelector that no node matches so the daemons stay off. Otherwise it clears the selector so fractiond/mpsd schedule onto NVIDIA nodes.
- **Memory enforcement**: the driver honours `NVIDIA_GPU_MEMORY_LIMIT` injected by fractiond. Quotas count the fractional GPU requests.

---

## 3. Workflow (in-place upgrade on a running cluster)

Admin runs `sudo ./oif install` on the first control-plane node.

| Step | Action |
|------|--------|
| **01 Nodes stage** | Only the NVIDIA node re-runs `nvidia-driver`. Detects loaded 595, installs 615 packages, removes old packages, writes nouveau blacklist (once), updates initramfs, asks for reboot. |
| **02 Reboot** | Node reboots (~2 min on the lab). GPU workloads on that node stop and restart after. |
| **03 host-verify** | Confirms driver 615.71.09 and A6000 visible. |
| **04 runai-fractions** | Recreates `GpuFractioningConfig` without the blocking selector. fractiond and mpsd become Ready. |
| **05 Cluster status** | Run:ai UI shows the cluster Connected (no longer Missing prerequisites). |

On a fresh install the same stages run as part of the normal node and Run:ai sequence.

---

## 4. Lab verification (2026-11-01)

From `docs/evidence/T-108/` and guide 11:

- Driver upgrade: 595.91.07 → 615.71.09, one reboot, fractiond/mpsd Ready.
- Two UI training workloads with **GPU fractioning = 50 %** run on the same A6000.
- Each pod: `gpu-fraction: 0.5`, `NVIDIA_GPU_MEMORY_LIMIT=24570`, `nvidia-smi` reports 24570 MiB total.
- Same GPU UUID in `NVIDIA_VISIBLE_DEVICES` for both pods.
- Third 0.5-GPU pod Pending (quota or pool).
- Unit tests 11/11, shellcheck clean.

---

## 5. Key source files

| Path | Role |
|------|------|
| `installer/stages/30-gpu-host.sh` | `stage_nvidia_driver`, upgrade path, reboot logic, host-verify |
| `installer/stages/60-runai.sh` | `stage_runai_fractions`, `fractioning_selector`, `GpuFractioningConfig` handling |
| `versions.env` | `NVIDIA_DRIVER_BRANCH=615-server` |
| `docs/guides/11-gpu-fractions.md` | Operator guide with screenshots and checks |
| `docs/evidence/T-108/` | Raw lab output (upgrade log + fractions proof) |
| `docs/DECISIONS.md` → ADR-032 | Decision for fractions on NVIDIA (AMD later) |

---

## 6. Summary

| | |
|---|---|
| **Outcome** | A6000 shared by two 0.5-GPU workloads; each limited to half the memory; third waits on quota |
| **Mechanism** | Driver ≥ 615 + fractiond NRI plugin + mpsd; in-place upgrade with one reboot |
| **Safety** | Older branch packages purged; no downgrade; uninstall returns to OS default (no NVIDIA driver) |
| **Proof** | Lab evidence + guide 11; cluster Connected; pods see 24 570 MiB |
| **Next** | T-125 (project default pools `nvidia,amd,default`); S-7 AMD fractions spike |

---

*Generated for the open-inference-fabric presentations set. Keep in sync with TASKS.md and the installer modules.*
