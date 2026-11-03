# Lab acceptance tests

One script per task that needs real machines. Each prints `PASS` or `FAIL` per check and exits non-zero on any failure; a task is marked done in [TASKS.md](../../TASKS.md) only when its script passes. They run on the multi-node cluster built from the [hybrid-gpu-lab](https://github.com/manmohanbrahma/hybrid-gpu-lab) VMs (or any cluster with the same roles).

| Script | Task | Run on | After |
| --- | --- | --- | --- |
| `t120-nodes.sh [--reboot NODE]` | T-120 node list, cluster key, node runner | the first node, with sudo | `sudo ./oif install --until nodes` (or a full install) |
| `t121-cluster.sh [--failover]` | T-121 highly available Kubernetes across the nodes | the first node, with sudo | `sudo ./oif install --until k8s-verify` (or later) |
| `t122-gpus.sh` | T-122 GPUs on their nodes, both operators | the first node, with sudo | `sudo ./oif install --until amd-gpu-verify` (or later) |
| `t123-runai.sh` | T-123 Run:ai node pools per vendor, per-pool quotas, patched images on every node | the first node, with sudo | a full `sudo ./oif install` |
| `t128-hardening.sh [OPTION]` (`--image-copy`, `--expect-off` or `--redis-restart`) | T-128 hardening: AMD sharing guard, plugin, memory isolation, whole and half GPU, image copy, fractions off | the first node, with sudo | a full `sudo ./oif install` (`--expect-off`: after `AMD_FRACTIONS=none` in `.env` and `sudo ./oif install --reconfigure`) |
| `t129-vendor-pool.sh` | T-129 one GPU vendor per workload: webhook pins, vendor-less fraction refused | the first node, with sudo | a full `sudo ./oif install` with both GPU vendors |
| `t137-scheduling.sh` | T-137 Scheduling dashboard on several node pools | the first node, with sudo | a full `sudo ./oif install` with both GPU vendors |
| `t139-vram-cap.sh [--expect-off]` | T-139 hard VRAM cap for AMD fractions (fractiond, dmem) | the first node, with sudo | a full `sudo ./oif install` (`--expect-off`: after `AMD_VRAM_CAP=none` in `.env` and `sudo ./oif install --reconfigure`) |

| `t201-dynamo.sh [OPTION]` (`--platform` or `--expect-off`) | T-201 Dynamo platform in oif install; a Dynamo deployment under Run:ai | the first node, with sudo | a full `sudo ./oif install` (`--expect-off`: after `DYNAMO=none` in `.env` and `sudo ./oif install --reconfigure`) |

What each checks:

- **t120-nodes.sh**: several nodes in the settings and this host first; the cluster key exists and is root-only; for every other node: reachable with the cluster key alone (no agent) and sudo without a password, recorded for uninstall, oif copied, every node stage done, only the node settings sent (no passwords or tokens), its own change record; on NVIDIA nodes the driver loaded and nouveau blocked. `--reboot NODE` reboots that node the way the node runner does and requires it back within 15 minutes.

- **t121-cluster.sh**: every node Ready, the control-plane count, no node tainted against workloads, one etcd member and API server per control-plane node, no join tokens or uploaded certificates left, kubeconfig on the API endpoint; with a shared address: the API answers there and one kube-vip runs per control-plane node. `--failover` takes kube-vip off the node holding the address, requires another node to take it with the API still answering, then restores it.

- **t122-gpus.sh**: the cluster's GPU inventory (at least one per vendor); per GPU: its driver, `nvidia-smi` or `/dev/kfd`, and the node offering it; the cluster offers exactly as many `nvidia.com/gpu` and `amd.com/gpu` as there are GPUs and nodes without GPUs offer none; both operators ready; one test pod per vendor lands on that vendor's node and gets only its GPU; both exporters report.

- **t123-runai.sh**: GPU nodes labelled `oif.ai/gpu-vendor` and no other node; Run:ai pools `nvidia` and `amd` Ready with each vendor's GPUs; the three patched images on every node and in use; with project team-c (quota 1 per pool): a pod per pool runs on that vendor's node, a second NVIDIA pod waits on quota, an NVIDIA GPU asked for in pool `amd` is never placed.

- **t128-hardening.sh**: the plugin lists its AMD GPU at start; the half-GPU templates are offered; memory isolation measured (a half-GPU pod holding 20 GiB next to one that lifts PyTorch's cap: stopped at its share where the T-139 VRAM cap is on, more than its share where it is off); only KAI's binder may add, change or remove `oif.ai/amd-gpu*` annotations; a whole AMD GPU and a half never share the one GPU. `--image-copy`: another image under the patched UI's tag on a node is replaced and the UI restarted by install, and a second install restarts nothing. `--expect-off`: KAI's stock images, no plugin, no policy, no half-GPU templates. `--redis-restart`: restarts cluster-redis for the workspace-login check.

- **t129-vendor-pool.sh**: webhook ready and failing open, policy bound; an `nvidia.com/gpu` pod pinned to pool nvidia (label and node selector) and running on the NVIDIA node; with team-c's NVIDIA quota full a second one waits instead of moving to the AMD GPU (UI-10b); a fraction without a vendor allowed on both pools refused with the T-129 message, the same fraction in pool amd accepted, an `amd.com/gpu` pod pinned to amd; a GPU-less pod of a Deployment labelled pool nvidia pinned to nvidia.

- **t137-scheduling.sh**: team-c's quota summed over its pools (2: 1 nvidia, 1 amd); only projects counted; with a whole NVIDIA GPU and an AMD half running, 1.5 allocated (1 in nvidia, 0.5 in amd); Grafana serves the dashboard with the per-pool table and the caps panel's explanation.

- **t139-vram-cap.sh**: the AMD node labelled `oif.ai/amd-vram-cap=dmem`; fractiond ready there, registered with containerd's NRI and on the AMD backend; each half-GPU pod's cgroup capped at half the VRAM (`dmem.max`); a pod that lifts PyTorch's cap stopped at its share while its neighbour still allocates inside its own; fractiond logged both caps. `--expect-off`: no fractiond, no node label, a new fraction pod uncapped and able to take more than its share.

- **t201-dynamo.sh**: the Helm release at the pinned version, the six Dynamo CRDs, the operator available, no Grove or bundled KAI running, oif's values in use; then, with team-c's NVIDIA quota free, the S-4 deployment applied with kubectl: Run:ai lists it as a DynamoGraphDeployment in team-c, its worker and frontend run in pool nvidia under a KAI pod group, a chat completion comes back through the frontend, and a second deployment waits with an over-quota reason. Both deployments are deleted at the end. `--platform`: the platform checks only. `--expect-off`: no release, CRDs or namespace.

Unit tests that need no machines are in `tests/unit` (`tests/run.sh`); the read-only clean-host check after an uninstall is `tests/host/verify-clean.sh`.
