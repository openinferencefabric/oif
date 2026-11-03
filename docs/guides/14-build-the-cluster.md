# Guide 14: How oif builds the cluster, from bare machines to Run:ai

Steps T-101 to T-126. This guide follows one `sudo ./oif install` from start to end on a multi-node cluster: what runs on which machine, in what order, and why. The commands are in guides 1 to 13; guide 10 is the multi-node walkthrough with its output.

**oif builds the Run:ai cluster itself.** Run:ai's **Resources > Clusters > New cluster** page installs NVIDIA's stock `runai-cluster` chart, which has no AMD support and none of oif's patches. oif does not use it: the Run:ai control plane and its one cluster, `oif`, are installed together on the same Kubernetes by `oif install`. oif's build of the Run:ai UI says so on that page (T-127).

## The machines

| Role | How many | What runs there |
| --- | --- | --- |
| Control-plane node | 1 or 3 (3 for high availability) | Kubernetes control plane; the platform: Run:ai control plane and cluster services, its database, Prometheus, Grafana, the ingress. The first one also runs oif. |
| GPU worker | any | GPUs of one vendor each: NVIDIA or AMD. Workloads only. |

Every machine: Ubuntu 26.04 server, a user with sudo, reachable over SSH with your key from the first node, on one network. Two free addresses for the Kubernetes API (`OIF_API_VIP`, with 3 control-plane nodes) and a range for load balancers (`METALLB_RANGE`, the Run:ai address is its first). On the lab, hybrid-gpu-lab creates these five machines as VMs (`sudo ./lab create`).

```text
                       your workstation (ssh -A, browser over SOCKS)
                                    |
   +--------------------------- one network ----------------------------+
   |  cp1 (runs oif)        cp2               cp3                       |
   |  control plane         control plane     control plane             |
   |  platform copy         platform copy     platform copy             |
   |                                                                    |
   |  API address (kube-vip)        Run:ai / Grafana address (MetalLB)  |
   |                                                                    |
   |  gpu-nvidia: NVIDIA GPU(s)            gpu-amd: AMD GPU(s)          |
   |  Run:ai node pool nvidia              Run:ai node pool amd         |
   +--------------------------------------------------------------------+
```

## What you do

1. On the first control-plane node, with your SSH agent forwarded: `git clone` oif, `cp .env.example .env`.
2. In `.env`: `OIF_NODES` (every node as `address:role`, this node first), `OIF_API_VIP`, `METALLB_RANGE`, the Run:ai administrator e-mail and password, the Grafana password. Everything else has a default.
3. `sudo -E ./oif install`. It asks before it reboots anything, then runs in the background (`sudo tail -f /var/log/oif-install.log`, `sudo ./oif status`).

That is all. The rest of this guide is what oif then does.

## What oif does, in order

Each line is a stage (`sudo ./oif status` lists them). A stage that finished is skipped on the next run unless its pinned version or code changed, so `oif install` is also the upgrade command.

### 1. The first node prepares itself

| Stage | What it does |
| --- | --- |
| preflight | checks the host (OS, CPU threads, memory, free disk, GPUs and their drivers) without changing it; makes the data folder |
| host-packages, kernel | base packages; kernel modules and settings Kubernetes needs; swap off |
| storage-host | iSCSI for Longhorn on a control-plane node of an HA platform |
| containerd | the container runtime, data in the data folder |
| nvidia-driver, amd-firmware, amd-runtime, gpu-isolation | only where the GPUs are: the NVIDIA driver (615, for fractions), AMD firmware, the runtime name AMD GPU fractions need, display GPUs kept away from Kubernetes |
| reboot, host-verify | one reboot if a driver needs it (asked first), then a check that it took effect |
| k8s-packages, conntrack-reaper | kubeadm, kubelet, kubectl; a helper that drops connections to pods on a node that went down |

### 2. The other nodes, one after another

| Stage | What it does |
| --- | --- |
| nodes | over SSH, the stages of part 1 on every other node in `OIF_NODES`. A GPU node that needs a reboot for its driver is rebooted by oif, which waits for it and carries on. Each node keeps its own record of what it changed, for uninstall. |

### 3. Kubernetes across all nodes

| Stage | What it does |
| --- | --- |
| kubernetes | `kubeadm init` on the first node, the API behind `OIF_API_VIP` (kube-vip moves it to a surviving control-plane node) |
| k8s-join, k8s-tokens | the other control-plane nodes and the workers join; join tokens removed afterwards |
| calico | the pod network |
| system-nodes | the control-plane nodes are labelled to carry the platform; GPU workers carry only workloads |
| storage, longhorn | storage for the platform: Longhorn with a copy of every volume on each control-plane node (one node: local disks) |
| metallb, k8s-verify | load-balancer addresses from `METALLB_RANGE`; a smoke test on every node |

### 4. The GPUs

| Stage | What it does |
| --- | --- |
| gpu-operator, gpu-verify | NVIDIA GPU Operator on the NVIDIA nodes (device plugin, container toolkit, DCGM metrics); a CUDA pod proves it |
| amd-gpu-operator, amd-gpu-verify | AMD GPU Operator on the AMD nodes (device plugin, node labeller, metrics exporter); a ROCm pod proves it |

### 5. The platform Run:ai needs

| Stage | What it does |
| --- | --- |
| platform-db | PostgreSQL, highly available (CloudNativePG, one instance per control-plane node), for Run:ai and Grafana |
| prometheus | Prometheus and Grafana |
| ingress, pki, runai-dns | the ingress controller on the Run:ai address; a private CA and the Run:ai certificate; the cluster's DNS answers the Run:ai domain |

### 6. Run:ai: control plane and cluster together

| Stage | What it does |
| --- | --- |
| runai | Run:ai's own installer, from the pinned open-source release, installs the **control plane and the cluster `oif` on this same Kubernetes**, connected to each other (Run:ai's "Same as control plane"). No New cluster wizard, no Helm command, no bootstrap token to handle. |
| runai-ha | two copies of every Run:ai service, spread over the control-plane nodes |
| runai-fractions | GPU fractions on NVIDIA nodes with driver 615 |
| runai-verify | the cluster reports Connected; Run:ai sees every node and GPU |
| runai-pools, one-vendor | a node pool per GPU vendor (`nvidia`, `amd`, and `default` for the control-plane nodes); workloads without a pool try the GPU pools first; a pod may not ask for both vendors |
| runai-admin | your administrator account from `.env` |
| runai-patches | oif's patches to Run:ai, built from source: AMD GPUs counted, the AMD logo for ROCm workloads, the New cluster page note |
| runai-quota, amd-quota, vendor-quota | test projects `team-a`, `team-b`, `team-c` prove that quotas hold for both vendors |
| runai-amd-templates | workload templates for AMD GPUs: whole GPU and half GPU (ROCm PyTorch, Jupyter) |
| amd-fractions | GPU fractions on AMD: KAI Scheduler rebuilt with oif's patches, the oif-amd-share plugin, a policy that guards it |

### 7. Observability

| Stage | What it does |
| --- | --- |
| observability, observability-verify | one set of GPU metrics for both vendors (`oif:gpu_*`), the Fleet and Scheduling dashboards in Grafana, checked with live data |

### 8. Serving

| Stage | What it does |
| --- | --- |
| dynamo | NVIDIA Dynamo's operator and CRDs (guide 16), with Grove and Dynamo's own KAI off so Run:ai's KAI schedules its pods; only when the cluster has an NVIDIA GPU; `DYNAMO=none` removes it |

## When it has finished

```bash
sudo ./oif status                 # every stage [x], every node reachable
sudo tests/lab/t123-runai.sh      # node pools, patches, placement per vendor, one job one vendor
```

Then open `https://runai.<first MetalLB address with dashes>.sslip.io` (trust `~/oif-ca.crt` from the first node) and log in with the administrator from `.env`. **Resources > Clusters** shows one cluster, `oif`, Connected; **Resources > Nodes** shows every node in its pool.

## Adding a node later

Add it to `OIF_NODES` and run `sudo ./oif install --reconfigure`. The node stages and the joins are written to skip what is done and handle the new node; this path has not been tested on the lab yet. A second Run:ai cluster on another Kubernetes is not something oif builds.

## Removing everything

`sudo ./oif uninstall` on the first node returns every node to its state before oif (guide 9): Kubernetes, Run:ai, drivers and every recorded file are removed, each node by its own record.
