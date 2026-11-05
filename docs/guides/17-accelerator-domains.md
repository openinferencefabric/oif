# Guide 17: Accelerator domains

Step T-130 (ADR-019, amendment 2026-11-05). Built and unit-tested on 2026-11-05; lab check `tests/lab/t130-topology-labels.sh`
pending its first run.

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
