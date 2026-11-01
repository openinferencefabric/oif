# Guide 13: GPU fractions on AMD GPUs

Step T-126 (ADR-032, spike S-7). Tested on the lab cluster (guide 10) on 2026-11-01.

## What you get

- A workload asks for part of an AMD GPU exactly as for an NVIDIA one: in the Run:ai UI **GPU fractioning**, % of the device, or the `gpu-fraction` annotation. Two half-GPU workloads share one Radeon PRO W7900, each sees the GPU (45 GiB) and gets half of its compute (24.2 TFLOPS each, fp16).
- Run:ai counts the fractions: the Workloads page shows 0.5 GPU and 22.5 GB each in pool `amd`; with 1 AMD GPU of quota, two halves run and a third waits (`team-c-amd quota is 1 GPUs, while 1 GPUs are already allocated`).
- NVIDIA fractions (guide 11) and whole GPUs of both vendors work as before.

**Memory isolation is soft.** No AMD driver limits a process's GPU memory and the W7900 cannot be partitioned, so `amd-smi` in a pod always shows the whole GPU (46,064 MB), where `nvidia-smi` in an NVIDIA half shows 24,570 MiB. oif keeps the share in two ways (T-127):

- **PyTorch is capped automatically.** The plugin sets PyTorch's allocator to the pod's share (`PYTORCH_ALLOC_CONF=per_process_memory_fraction:0.5`, also the HIP and CUDA names, added to the image's own allocator settings). PyTorch, and what runs on it such as vLLM, refuses to allocate past the share. vLLM's default `--gpu-memory-utilization 0.9` then fails on half a GPU instead of taking the neighbour's memory: set it below the share (for example `0.45`).
- **Everything else gets the share** in `OIF_GPU_MEMORY_FRACTION` (for example `0.5`) and must keep to it. A process outside PyTorch that ignores it can take the memory its neighbour needs (S-7: a pod without a cap took 40.5 GiB and the second one failed with out-of-memory).

NVIDIA fractions are hard limits, enforced by the driver.

How it works:

| Piece | What it does |
| --- | --- |
| KAI Scheduler v0.18.3, rebuilt with oif's patches (`patches/kai/`) | the scheduler skips NVIDIA's readiness check on AMD GPU nodes; the binder reserves the GPU with a reservation pod that holds an `amd.com/gpu`, and writes the GPU's PCI address into the pod (`oif.ai/amd-gpu`) |
| oif-amd-share, an NRI plugin (`images/oif-amd-share/`), on every AMD GPU node | when containerd creates the pod's container, gives it `/dev/kfd` and that GPU's `/dev/dri` nodes, and sets `OIF_GPU_MEMORY_FRACTION` |
| ValidatingAdmissionPolicy `oif-amd-share-annotations` | only KAI's binder may set the `oif.ai/amd-gpu` annotations, so no one gets a GPU outside Run:ai's quotas |
| containerd on AMD-only GPU nodes | runtime class `nvidia` runs `runc` there: KAI's admission gives every fraction pod that class before a node is chosen |

## Before you start

- A multi-node cluster installed with oif (guide 10): AMD GPUs on nodes of their own, Run:ai node pool `amd` (T-123). On a single node with both vendors, AMD GPUs stay whole.
- GPU fractions on NVIDIA working or not needed (guide 11).
- Internet access for the build: the KAI source (pinned checksum), Go modules and the base images.

## Steps

1. Get the oif version with T-126 and run the install again on the first node:

   ```bash
   cd ~/open-inference-fabric && git pull
   sudo ./oif install
   ```

   On an installed cluster, the node stage `amd-runtime` changes the AMD node only, then stage `amd-fractions` builds and switches on the patched KAI (10 to 30 minutes for the build):

   ```text
   [192.168.120.21]   [ok] runtime class nvidia runs runc on this AMD GPU node (GPU fractions)
   == stage: amd-fractions
       == patch 0001-common-amd-gpu-node.patch ... 0004-resourcereservation-amd-gpu-device.patch
       ok  .../pkg/binder/plugins/nvfractions   ok  .../pkg/scheduler/plugins/gpusharingnodevalidation   ...
       == image oif.local/kai-scheduler/scheduler:v0.18.3-oif-216ce155df72 from ghcr.io/kai-scheduler/kai-scheduler/scheduler:v0.18.3
     [ok] patched image oif.local/kai-scheduler/binder:v0.18.3-oif-216ce155df72 on every node (4 loaded now)
     [ok] KAI scheduler and binder patched for AMD GPU fractions (v0.18.3-oif-216ce155df72)
     [ok] AMD GPUs on gpu-amd can be shared: Run:ai GPU fractions in pool amd; memory isolation is soft
   == install finished
   ```

2. In the Run:ai UI the quickest way is a template (T-127): **Workload manager > Workloads > New workload > Training**, a project with AMD quota, template **pytorch-rocm-half-gpu**, a name, **Create training**. It has the ROCm image, half a GPU and pool `amd` already set, and its log shows the GPU, its share and five minutes of compute. For Jupyter: **New workload > Workspace**, template **jupyter-lab-rocm-half-gpu**.

   Or from scratch: **Start from scratch**, a name, then:
   - **Environment**: a ROCm image, for example `docker.io/rocm/pytorch:rocm10.1.0_ubuntu24.04_py3.12_pytorch_release_2.14.0`, and its command;
   - **Compute resources**: GPU devices `1`, **GPU fractioning** on, GPU memory **% of device** `50`;
   - **Nodes**: keep only `amd` (the **X** on the `nvidia` and `default` rows). The form starts with the project's order (`nvidia`, `amd`, `default`, guide 12), and a fraction placed first on `nvidia` runs on the NVIDIA GPU.

   ![The training form: ROCm PyTorch image, GPU fractioning on at 50 % of the device, 0.50 GPUs, node pool amd only.](img/13-form.png)

3. Submit a second one the same way.

## Check it worked

![Workloads: ui-amd-a and ui-amd-b, AMD logo, running in pool amd with 0.5 GPU each.](img/13-workloads.png)

![Projects: team-c has 1.00 GPU allocated, the two halves of the W7900.](img/13-projects.png)

On the first node:

```bash
kubectl -n oif-system get pods -o wide                      # oif-amd-share on every AMD GPU node
kubectl -n runai-reservation get pods -o wide               # one reservation pod per shared GPU (amd.com/gpu: 1)
kubectl -n runai-<project> get pods -o wide
kubectl -n runai-<project> exec <pod> -- python3 -c "import os,torch; print(os.environ['OIF_GPU_MEMORY_FRACTION'], torch.cuda.get_device_name(0))"
```

```text
oif-amd-share-7qk5w   1/1   Running   gpu-amd
gpu-reservation-3117eb96bc13da22   1/1   Running   gpu-amd
ui-amd-a-f9s86   1/1   Running   gpu-amd
ui-amd-b-55jwg   1/1   Running   gpu-amd
0.5 AMD Radeon Pro W7900
```

### Inside a workload (a notebook from **jupyter-lab-rocm-half-gpu**)

Run:ai's allocation record stays on the pod object; inside the container the share shows as oif's variables and the
PyTorch cap:

```python
import os, torch
for k in ("RUNAI_PROJECT", "RUNAI_JOB_NAME", "OIF_GPU_PCI", "OIF_GPU_MEMORY_FRACTION", "PYTORCH_ALLOC_CONF"):
    print(f"{k:25} {os.environ.get(k)}")
free, total = torch.cuda.mem_get_info()
share = float(os.environ["OIF_GPU_MEMORY_FRACTION"])
print(f"GPU memory {total/2**30:.1f} GiB, this pod's share {share} = {share*total/2**30:.1f} GiB")
for gib in (20, 25):
    try:
        x = torch.empty(int(gib * 2**30) // 2, dtype=torch.float16, device="cuda"); print(f"{gib} GiB: allocated"); del x
    except torch.OutOfMemoryError:
        print(f"{gib} GiB: refused (over the share)")
```

```text
RUNAI_PROJECT             team-c
RUNAI_JOB_NAME            test
OIF_GPU_PCI               0000:03:00.0
OIF_GPU_MEMORY_FRACTION   0.5
PYTORCH_ALLOC_CONF        per_process_memory_fraction:0.5
GPU memory 45.0 GiB, this pod's share 0.5 = 22.5 GiB
20 GiB: allocated
25 GiB: refused (over the share)
```

`amd-smi` in the pod shows the whole card (46,064 MB, 96 compute units; PyTorch counts 48, the work-group processors of two CUs each): there is no partition. Compute is time-sliced: a half alone on the GPU runs at full speed (49.8 TFLOPS fp16), two busy halves get about 24 each. Run:ai's record, from the first node:

```bash
kubectl -n runai-<project> get pod -l workloadName=<name> -o jsonpath='{.items[0].metadata.annotations}' | tr ',' '
' | grep -E 'runai-allocated|gpu-fraction|oif.ai'
```

```text
"gpu-fraction":"0.5"
"oif.ai/amd-gpu":"0000:03:00.0"
"runai-allocated-gpu-memory":"22500"
"runai-allocated-gpus":"0.5"
```

The lab test `tests/lab/t126-amd-fractions.yaml` runs two halves and a third on pool `amd` and two halves on `nvidia` without the UI. Full output: `docs/evidence/T-126/`.

## What changed on the host

| Change | Reversed by uninstall |
| --- | --- |
| On AMD-only GPU nodes: `/etc/containerd/conf.d/90-oif-amd-fractions.toml` (runtime `nvidia` = runc), containerd restarted once | the file (and the folder, if oif created it) is removed |
| Four images in containerd on every node: `oif.local/kai-scheduler/{scheduler,binder,resourcereservation}`, `oif.local/oif/oif-amd-share` | go with containerd's data |
| Cluster: RunaiConfig points KAI at the patched images; namespace `oif-system` (plugin DaemonSet); policy `oif-amd-share-annotations` | go with Run:ai and the cluster; `AMD_FRACTIONS=none` in `.env` (`sudo ./oif install --reconfigure`) puts KAI's stock images back and removes the plugin; `AMD_FRACTIONS=all` (an empty value keeps the saved `none`) turns them on again |

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| A fraction meant for AMD runs on the NVIDIA GPU | The workload's pools list `nvidia` first: keep only `amd` in the form's **Nodes** section. |
| Pod on gpu-amd stuck in ContainerCreating: `no runtime for "nvidia" is configured` | The node stage `amd-runtime` has not run there: `sudo ./oif install` again. |
| Pod on gpu-amd runs but `torch.cuda.is_available()` is False | oif-amd-share was not running when the container was created: `kubectl -n oif-system get pods`; delete the pod so it starts again. The plugin log names every pod it gives a GPU. |
| `forbidden: ValidatingAdmissionPolicy 'oif-amd-share-annotations'` | Expected for anyone but KAI's binder: ask for a fraction (`gpu-fraction`) instead of setting `oif.ai/amd-gpu`. |
| A pod fails with out-of-memory although the GPU is half free | Its neighbour does not keep to its share: set the framework's memory limit from `OIF_GPU_MEMORY_FRACTION` in both. |
| A fraction asks for GPU memory in GiB instead of % of the device | Not tested on AMD: use % of the device. |
| A workspace URL (Jupyter) stays blank; its proxy logs `session does not exist` | Before T-127, the HA platform ran two unreplicated copies of `cluster-redis`, where workspace logins are kept: `sudo ./oif install` (runai-ha keeps one copy), then open the link in a new private window. |
