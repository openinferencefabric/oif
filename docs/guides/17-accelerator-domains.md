# Guide 17: Accelerator domains

Step T-130 (ADR-019, amendment 2026-11-05). Tested on the lab cluster (guide 10) on 2026-11-05 with
`tests/lab/t130-topology-labels.sh` (12/12, docs/evidence/T-130/); packing (T-132) tested on 2026-11-06 with
`tests/lab/t132-runai-topology.sh` (8/8) and `S9_TOPOLOGY=oif-accelerator tests/lab/s9-fake-topology.sh` (14/14),
docs/evidence/T-132/.

## What you get

A multi-GPU job runs fastest when all its GPUs share one scale-up fabric: NVLink on an NVIDIA HGX server or an NVL72
rack, xGMI (Infinity Fabric) on an AMD Instinct server, UALink on an AMD Helios rack. oif calls such a group an
**accelerator domain** and writes it on every GPU node as labels:

| Label | Meaning | Example values |
| --- | --- | --- |
| `oif.ai/accelerator-domain` | the GPUs a job can use over one scale-up fabric | `gpu-amd` (the node), `xgmi-0x5f1b...`, `nvl-<clique>`, `helios-r1` |
| `oif.ai/accelerator-fabric` | the fabric | `nvlink`, `xgmi`, `ualoe`, `pcie` |
| `oif.ai/scaleout-zone` | the scale-out network group | `default`, or the node's `topology.kubernetes.io/zone` |

KAI Scheduler reads these labels through a `Topology` (step T-132) and keeps a job's GPUs inside one domain; spike S-9
showed it does so on NVIDIA and AMD (docs/evidence/S-9/). Nodes without GPUs get no labels.

## How the domain is found

Agent `oif-topology` (images/oif-topology, a DaemonSet on every real node) looks at its own node every minute:

| Node | Domain | Fabric |
| --- | --- | --- |
| NVIDIA with GPU feature discovery's `nvidia.com/gpu.clique` (GB200/GB300 NVL72) | `nvl-<clique>`: every tray of the NVLink domain | `nvlink` |
| NVIDIA with several GPUs and an NVSwitch on the PCI bus (HGX, DGX) | the node | `nvlink` |
| AMD whose GPUs are in one xGMI hive (driver sysfs `xgmi_hive_info/xgmi_hive_id`: MI300X, MI325X, MI350X, MI355X servers) | `xgmi-<hive id>` | `xgmi` |
| AMD with GPUs in several hives (GPUs split between VMs) | the node | `xgmi` |
| anything else (PCIe cards: the lab's A6000 and W7900, MI350P servers), or GPUs of both vendors | the node | `pcie` |

It reads sysfs read-only and counts GPUs from the node's allocatable resources (`nvidia.com/gpu`, `amd.com/*` in any of
AMD's resource naming strategies).

## Domains no driver reports: annotations

AMD publishes no label or sysfs entry for a Helios rack's UALink domain yet (oif asked AMD: ROCm/gpu-operator#679). Name
it with node annotations, the same keys as the labels; they win over detection:

```bash
for t in $(seq -w 1 18); do
  kubectl annotate node helios-r1-t$t oif.ai/accelerator-domain=helios-r1 oif.ai/accelerator-fabric=ualoe --overwrite
done
kubectl annotate node gpu-07 oif.ai/scaleout-zone=spine-2 --overwrite      # a scale-out group
```

The agent picks them up within a minute; removing an annotation restores the detected value. An annotation that is not a
valid label value is ignored (the agent logs it).

## What the agent may do

It needs to patch nodes, which Kubernetes RBAC cannot narrow to one node or to some labels, so policy
`oif-topology-own-node` (a ValidatingAdmissionPolicy) allows its service account to change **only the node it runs on**
(the node name in its token) and **only its three labels**: no other label, no taint, no annotation. Simulated (KWOK)
nodes are skipped: whoever creates them sets their labels (tools/fake-gpu).

## Install, check, remove

`oif install` runs stage `topology` after `vendor-pool` when the cluster has GPUs: it builds the agent (as it builds
oif-vendor-pool, in a Kubernetes Job from the pinned Go image), copies it to every node, applies
platform/kubernetes/topology.yaml and waits until every GPU node has a domain:

```text
    gpu-amd: domain gpu-amd, fabric pcie, zone default
    gpu-nvidia: domain gpu-nvidia, fabric pcie, zone default
  ok  GPU nodes labelled with their accelerator domain (agent oif-topology; a node annotation with the same key overrides)
```

Check by hand:

```bash
kubectl get nodes -L oif.ai/accelerator-domain,oif.ai/accelerator-fabric,oif.ai/scaleout-zone
kubectl -n oif-topology logs ds/oif-topology          # the decision and why, per node
sudo tests/lab/t130-topology-labels.sh               # labels, override, and the policy (as the agent)
```

Without GPUs the stage removes the agent, the policy and the labels. `oif uninstall` removes them with the cluster.

## Packing workloads by domain (T-132)

Stage `runai-topology` (after `topology`) creates Run:ai **network topology** `oif-accelerator` with the levels
`oif.ai/scaleout-zone` > `oif.ai/accelerator-domain` > `kubernetes.io/hostname` and links it to the GPU node pools
(`nvidia` and `amd`; `default` on one node). Run:ai's agent writes it into the cluster as KAI `Topology`
`oif-accelerator`; it shows in the Run:ai UI under the node pools.

- **Every workload** submitted through Run:ai (UI, API, CLI) into those pools gets `kai.scheduler/topology:
  oif-accelerator` and `kai.scheduler/topology-preferred-placement: kubernetes.io/hostname` from Run:ai itself: KAI puts
  its pods on as few hosts as it can, then inside one domain, then one zone. Preferred means it still runs when no
  single host or domain has room.
- **A workload that must stay in one domain** (tensor parallelism over NVLink or xGMI) adds **two** annotations:
  `kai.scheduler/topology: oif-accelerator` and `kai.scheduler/topology-required-placement: oif.ai/accelerator-domain`
  (in the form under the workload's annotations; in the API as `spec.annotations: [{"name": "kai.scheduler/topology",
  "value": "oif-accelerator"}, {"name": "kai.scheduler/topology-required-placement", "value":
  "oif.ai/accelerator-domain"}]`; on a Job or other object as metadata annotations). Both are needed: Run:ai adds its
  topology only to workloads that carry no `kai.scheduler/` annotation of their own, and KAI **silently ignores** a
  required level without a topology (lab, T-132: such a pod ran unconstrained). The workload then waits until one
  domain has room for all of it, and KAI's reason says so ("requirement oif.ai/accelerator-domain couldn't be
  satisfied"). Run:ai's preferred placement is not added in that case; add
  `kai.scheduler/topology-preferred-placement: kubernetes.io/hostname` too if you want it.
- **KAI v0.18.3 bug, fixed by oif:** when every node of the pool sits inside one domain below the required level (a
  one-node pool, or a pool inside one NVL72 rack with a required zone), stock KAI never places the workload ("node-group(s)
  didn't have enough resources: GPUs ... pods", T-132 lab). oif's KAI patch 0007 fixes it (upstream K10,
  docs/UPSTREAM.md). The patched KAI runs on every cluster with an AMD GPU (stage `amd-fractions`, T-141), unless
  `AMD_FRACTIONS=none`. **An NVIDIA-only cluster keeps KAI's stock images** (owner decision, ADR-032 amendment
  2026-11-14): there a required level works only when the pool's nodes span several of its domains. In a pool inside one
  domain, leave the required annotation out: every placement already lands in that domain. oif's AIJob (T-133) does
  this itself; the fix reaches stock KAI with upstream PR KAI#2594, and patch 0007 is dropped when Run:ai ships it.
- **A plain Kubernetes Job** is one gang only when it says so: add `kai.scheduler/batch-min-member: "<pods>"`, or KAI
  places it one pod at a time and picks the domain for the first pod (spike S-9). Run:ai's distributed workloads are
  gangs already.

Making "required" a project's default is T-134 (PlacementPolicy); asking for it in vendor-neutral terms is T-133.

```bash
sudo tests/lab/t132-runai-topology.sh                            # topology, pools, what KAI gets for Run:ai workloads
sudo S9_TOPOLOGY=oif-accelerator tests/lab/s9-fake-topology.sh   # packing on fake 8-GPU servers and Helios racks
```
