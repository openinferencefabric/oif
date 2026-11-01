# T-125 — One Job, One Vendor

**Status:** Done (2026-11-01)  
**Repo:** [manmohanbrahma/open-inference-fabric](https://github.com/manmohanbrahma/open-inference-fabric)  
**Related:** ADR-032 · `installer/stages/60-runai.sh` (stage `one-vendor`) · `installer/tools/runai_api.py` · `platform/kubernetes/one-gpu-vendor.yaml` · `tests/lab/t123-runai.sh` · Guide 12

---

## 1. What T-125 delivers

| Capability | Description |
|------------|-------------|
| **Default node-pool order** | Every Run:ai department gets default node pools `nvidia, amd, default` (or the vendors present). Workloads submitted without an explicit pool land where a matching GPU exists. |
| **Single-vendor PodGroups** | KAI keeps a multi-pod workload in one PodGroup bound to one pool, so a job never spreads across NVIDIA and AMD nodes. |
| **Admission refusal** | ValidatingAdmissionPolicy `oif-one-gpu-vendor` refuses any pod that requests both `nvidia.com/gpu` and `amd.com/gpu` at creation time. |

On a single-node mixed-vendor cluster the stage is a no-op (no per-vendor pools).

---

## 2. Architecture

```
Run:ai department defaultNodePools
          │
          ▼
  nvidia → amd → default     ← projects without own order inherit this
          │
          ▼
Workload submitted with no pool
          │
          ▼
KAI places whole PodGroup into first matching pool
          │
          ▼
ValidatingAdmissionPolicy (CEL)
  refuses pods that request both vendors
```

- Department defaults are set via the Run:ai REST API (`pool-order` command).
- The admission policy is pure Kubernetes CEL (no webhook, no extra image).
- On multi-node hybrid clusters the GPU pools already exist from T-123.

---

## 3. Workflow steps

Admin re-runs `sudo ./oif install` on the first control-plane node (only the new stage executes on an already-installed cluster):

| Step | Action |
|------|--------|
| **one-vendor** | Read each department (list endpoint omits `defaultNodePools`), PUT the GPU-first order. Apply ValidatingAdmissionPolicy + Binding. |
| **Verification** | `tests/lab/t123-runai.sh` asserts department order, a 2-pod Job without a pool runs both pods on the NVIDIA node as one PodGroup in pool `nvidia`, and a both-vendor pod is Forbidden. |

### Design notes (ADR-032)

- One job, one vendor: a pod that needs both GPUs can never be placed on a production-style cluster (one vendor per server).
- Department-level default avoids forcing every project to reconfigure.
- Projects that set their own order still win (explicit is stronger than inherited).

---

## 4. Key source files

| Path | Role |
|------|------|
| `installer/stages/60-runai.sh` | Stage `one-vendor`: calls `runai_api.py pool-order` and applies the policy |
| `installer/tools/runai_api.py` | `pool-order` / `departments` commands; reads full department objects |
| `platform/kubernetes/one-gpu-vendor.yaml` | ValidatingAdmissionPolicy (CEL) + Binding |
| `tests/lab/t123-runai.sh` | Extended with T-125 checks (31 total) |
| `tests/lab/t125-job.yaml` / `t125-both-vendors.yaml` | Test fixtures |
| `docs/guides/12-one-job-one-vendor.md` | User-facing guide |
| `docs/evidence/T-125/` | Lab evidence (2026-11-01) |

---

## 5. Verification

**Lab result (2026-11-01, 5-node hybrid-gpu-lab):**

- Stage `one-vendor` ran cleanly on the installed cluster.
- `tests/lab/t123-runai.sh`: 31/31 PASS
  - Every department's default pools = `nvidia,amd,default`
  - 2-pod half-GPU Job (no pool) → both pods on `gpu-nvidia`, one PodGroup in pool `nvidia`
  - Pod requesting both vendors → Forbidden by `oif-one-gpu-vendor`
- Run:ai UI training (no pool selected, 0.5 GPU) landed in pool `nvidia` on `gpu-nvidia`.

Evidence: `docs/evidence/T-125/one-vendor.txt`.

---

## 6. Summary

| | |
|---|---|
| **Outcome** | Workloads without a pool land on a GPU node; multi-pod jobs stay in one pool; mixed-vendor pods are refused at admission. |
| **Mechanism** | Department defaultNodePools + KAI PodGroup affinity + pure CEL ValidatingAdmissionPolicy. |
| **Safety** | Explicit project order still wins; uninstall removes the policy with the cluster. |
| **Proof** | `tests/lab/t123-runai.sh` 31 checks + UI confirmation on the lab. |
| **Next** | S-7 AMD GPU fractions (go/no-go). |

---

*Generated for the open-inference-fabric presentations set. Keep in sync with TASKS.md and the installer modules.*
