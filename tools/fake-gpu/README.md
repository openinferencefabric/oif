# Fake AMD GPU nodes for KWOK

`fake_gpu_nodes.py` writes Kubernetes Node objects that look like nodes running the
[AMD GPU Operator](https://github.com/ROCm/gpu-operator), for [KWOK](https://kwok.sigs.k8s.io/) to keep Ready.
Schedulers (KAI Scheduler, the default scheduler, Run:ai) place pods on them as on real nodes, so multi-GPU placement,
partitioning and topology logic can be tested on any cluster, without the hardware. OIF uses it for P1.4 (spike S-9);
it does not depend on the rest of OIF. Python 3.9+, standard library only.

```bash
python3 tools/fake-gpu/fake_gpu_nodes.py --list
python3 tools/fake-gpu/fake_gpu_nodes.py --profile mi300x --count 4 | kubectl apply -f -
python3 tools/fake-gpu/fake_gpu_nodes.py --profile mi355x --partition cpx_nps2 --naming mixed | kubectl apply -f -
python3 tools/fake-gpu/fake_gpu_nodes.py --profile mi455x --racks 2 | kubectl apply -f -
kubectl delete node -l oif.ai/fake-gpu-profile            # remove them
```

KWOK must be running and manage nodes annotated `kwok.x-k8s.io/node=fake` (its default). The nodes carry the taint
`kwok.x-k8s.io/node=fake:NoSchedule`; test pods tolerate it, nothing else lands there.

## What is modelled

| Profile | GPUs per node | Memory | Scale-up fabric | Accelerator domain |
| --- | --- | --- | --- | --- |
| `mi300x`, `mi325x` | 8 (universal baseboard) | 192 / 256 GB | xGMI: each GPU linked to its 7 peers | the server |
| `mi350x`, `mi355x` | 8 | 288 GB | xGMI, 7 links of 144 GB/s per GPU | the server |
| `mi350p` | up to 8 PCIe cards per server | 144 GB | none: PCIe only (no Infinity Fabric between cards) | the server |
| `mi455x` | 4 per compute tray, 18 trays per Helios rack | 432 GB | UALink over Ethernet, 72 GPUs | the rack |
| `w7900` | 1 (PCIe card) | 45 GB | none | the server |

- **Labels as the node labeller writes them** (ROCm/k8s-device-plugin `cmd/k8s-node-labeller`): for each property every
  GPU of the node shares, `amd.com/gpu.<name>=<value>`, `beta.amd.com/gpu.<name>=<value>` and
  `beta.amd.com/gpu.<name>.<value>=<count>`; for family, device id (`amdgpu.ids`), product name, VRAM, CU and SIMD
  counts; plus `amd.com/gpu.compute-memory-partition` and the partitioning-supported labels on Instinct GPUs.
- **Resources as the device plugin names them** (`--naming`, its `resource_naming_strategy`): `single`
  (`amd.com/gpu`), `mixed` (`amd.com/cpx_nps4`) and `product` (`amd.com/gpu-mi300x-spx-nps1`).
- **Partitions** (`--partition`): SPX, DPX, QPX and CPX (1, 2, 4 and 8 devices per GPU) with NPS1, NPS2 or NPS4, only in
  the combinations AMD documents (MI300X: NPS2 with DPX, NPS4 with QPX or CPX; DPX + NPS2 not on MI325X; MI350X and
  MI355X, two I/O dies: NPS1 or NPS2, NPS2 with DPX, QPX or CPX). The MI350P (4 XCDs)
  has SPX, DPX and CPX of 4 partitions (36 GB, 32 CUs each); its NPS modes are not published, so NPS1 only. A partition's
  VRAM and CU labels are the GPU's divided by the partitions, as the labeller reports them (ROCm/gpu-operator#555).
- **Topology** (OIF's own labels; the AMD GPU Operator publishes no xGMI or UALink domain yet):
  `oif.ai/accelerator-domain` (the GPUs a job can use over the scale-up fabric), `oif.ai/accelerator-fabric`
  (`xgmi`, `ualoe`, `pcie`) and `oif.ai/scaleout-zone`, for KAI Scheduler's `Topology` levels.

**Assumed, not yet published:** MI455X's device id and product name are not in `amdgpu.ids`, so its nodes carry no
device-id or product labels and use `amd.com/gpu` (annotation `oif.ai/fake-gpu-assumed`). Fake nodes have no device
plugin, partition manager or GPUs: they test placement, not performance or device injection.

Tests: `tests/unit/test_fake_gpu.sh` (labels, resource names, partition rules, Helios racks).
