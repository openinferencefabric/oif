# Guide 12: One job, one vendor

Step T-125 (ADR-032). Tested on the lab cluster (guide 10) on 2026-11-01.

## What you get

On a cluster whose GPU servers each have one vendor (guide 10: pools `nvidia` and `amd`):

- A workload submitted **without choosing a node pool** lands where a GPU exists. oif sets every Run:ai department's default node pools to the GPU pools first, then `default` (`nvidia, amd, default` on the lab); projects without their own order inherit it. Before, they inherited `default` only, which has no GPU, and a UI workload waited there forever.
- A **multi-pod workload runs in one pool**: KAI schedules all pods of a workload as one PodGroup, bound to one node pool, so a job never spreads over the NVIDIA and the AMD node.
- A **pod asking for NVIDIA and AMD GPUs at once is refused** when it is created (a Kubernetes ValidatingAdmissionPolicy, `oif-one-gpu-vendor`), instead of waiting for a node that cannot exist.

On a single node with both vendors (guides 1 to 9) the stage changes nothing: there is no per-vendor pool.

## Before you start

- A multi-node cluster installed with oif (guide 10), with the Run:ai node pools per vendor (T-123).
- Kubernetes 1.30 or later (ValidatingAdmissionPolicy is GA; the lab runs 1.35).

## Steps

1. Get the oif version with T-125 and run the install again on the first node:

   ```bash
   cd ~/open-inference-fabric && git pull
   sudo ./oif install
   ```

   On a new cluster this is part of the normal install. On an installed one only the new stage runs:

   ```text
   == stage: one-vendor
       department default default node pools nvidia,amd,default
     [ok] workloads without node pools try: nvidia, amd, default
   validatingadmissionpolicy.admissionregistration.k8s.io/oif-one-gpu-vendor created
   validatingadmissionpolicybinding.admissionregistration.k8s.io/oif-one-gpu-vendor created
     [ok] a pod asking for NVIDIA and AMD GPUs at once is refused (ValidatingAdmissionPolicy oif-one-gpu-vendor)
   == install finished
   ```

   The order lists only the vendors the cluster has: a cluster with NVIDIA nodes only gets `nvidia, default`.

2. In the Run:ai UI, submit a workload without touching the node pools: **Workload manager > Workloads > New workload > Training**, a project, **Start from scratch**, an image and, for example, GPU devices `1` with **GPU fractioning** at 50 % (guide 11). Open **Nodes**: the order is already `nvidia`, `amd`, `default`.

   ![The training form: 0.50 GPUs requested; the Nodes section lists nvidia, amd, default without any pool picked.](img/12-form.png)

## Check it worked

The workload runs in pool `nvidia`:

![Workloads: ui-t125-auto running in project team-c, node pool nvidia, 0.5 GPU requested and allocated.](img/12-workloads.png)

On the first node, the lab test runs a 2-pod half-GPU Job without a node pool, then tries a pod with both vendors:

```bash
sudo tests/lab/t123-runai.sh
```

```text
T-125 one job, one vendor
        default nvidia,amd,default
  PASS  every department's default node pools are nvidia,amd,default
        job pods running on: gpu-nvidia gpu-nvidia
  PASS  a 2-pod Job without a node pool runs both pods on the NVIDIA node (gpu-nvidia)
  PASS  the Job is one PodGroup in pool nvidia
        both vendors: Error from server (Forbidden): ... ValidatingAdmissionPolicy 'oif-one-gpu-vendor' ...
  PASS  a pod asking for NVIDIA and AMD GPUs is refused

T-123: PASS (31 checks)
```

By hand:

```bash
kubectl get validatingadmissionpolicy oif-one-gpu-vendor
kubectl -n runai-<project> get podgroups -L runai/node-pool
```

Full output: `docs/evidence/T-125/`.

## What changed on the host

Nothing on the hosts; two cluster changes:

| Change | Reversed by uninstall |
| --- | --- |
| Run:ai departments' default node pools (`nvidia, amd, default`) | goes with Run:ai |
| ValidatingAdmissionPolicy and binding `oif-one-gpu-vendor` | goes with the cluster (`kubeadm reset`) |

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| A workload without a pool still waits in `default` (`No node in the default node-pool has GPU resources`) | Its project has its own order, which wins over the department's: set the GPU pools first on the project (`PUT /api/v1/org-unit/projects/<id>` with `"defaultNodePools": ["nvidia", "amd", "default"]` and the project's `resources`, no `name`), or pick the pool in the form's **Nodes** section. A workload submitted before T-125 keeps the order it was created with: submit it again. |
| `pods "..." is forbidden: ValidatingAdmissionPolicy 'oif-one-gpu-vendor'` | Expected: one pod asked for `nvidia.com/gpu` and `amd.com/gpu`. Split it into one workload per vendor. |
| A distributed (PyTorch, MPI) workload: `distributed framework PyTorch is not available` | Run:ai's distributed workloads need the Kubeflow training operator, which oif does not install. A multi-pod Kubernetes Job with `schedulerName: runai-scheduler` works and stays in one pool. |
