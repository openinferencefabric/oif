# Install and deployment guides

One guide per step of the plan in [TASKS.md](../../TASKS.md). Each guide is written when its step is built and tested on the reference host, and updated whenever the step changes. Follow them in order.

| # | Guide | Step | Status |
| --- | --- | --- | --- |
| 1 | [Prepare the host and run the check](01-prepare-host.md) | T-101 | Tested |
| 2 | [Host preparation: NVIDIA driver, kernel settings, container runtime, GPU isolation](02-host-preparation.md) | T-102 | Tested |
| 3 | [Kubernetes, storage and load balancer](03-kubernetes.md) | T-103 | Tested |
| 4 | [NVIDIA GPU Operator](04-nvidia-gpu-operator.md) | T-104 | Tested |
| 5 | [Run:ai open source](05-runai.md) (published with screenshots: [Installation Guide](https://manmohanbrahma.github.io/ai/runai/install-guide/), [Deployment Guide](https://manmohanbrahma.github.io/ai/runai/deployment-guide/)) | T-105 | Tested |
| 6 | [AMD GPU Operator and Run:ai quotas on AMD GPUs](06-amd-gpu-operator.md) | T-111, S-2, T-113 | Tested |
| 7 | [Observability for NVIDIA and AMD GPUs](07-observability.md): recording rules, Fleet and Scheduling dashboards, Grafana | T-106, T-112, T-114 | Tested |
| 8 | [Run:ai patches and ROCm templates for AMD GPUs](08-runai-patches.md): Run:ai counts both vendors, AMD logo, node ready without fractions | T-115 | Tested |
| 9 | [Uninstall and reinstall](09-uninstall.md) | T-107 | Tested |
| 10 | [Multi-node hybrid cluster](10-multi-node.md): NVIDIA and AMD GPUs on separate nodes, HA control plane and platform, Run:ai node pools per vendor, a control-plane node powered off (published in [Run:ai with NVIDIA and AMD GPUs](https://manmohanbrahma.github.io/ai/runai-nvidia-amd/)) | T-120 – T-124 | Tested (lab) |
| 11 | [GPU fractions on NVIDIA GPUs](11-gpu-fractions.md): driver 615, fractioning daemons, half-GPU workloads from the Run:ai UI, quota on fractions | T-108 | Tested (lab) |
| 12 | [One job, one vendor](12-one-job-one-vendor.md): workloads without a node pool land on a GPU pool, a job stays in one pool, a pod asking for both vendors is refused | T-125 | Tested (lab) |
| 13 | [GPU fractions on AMD GPUs](13-amd-gpu-fractions.md): patched KAI and the oif-amd-share NRI plugin, half-GPU ROCm workloads from the Run:ai UI, soft memory isolation | T-126 – T-128 | Tested (lab) |
| 14 | [How oif builds the cluster](14-build-the-cluster.md): from bare machines to Run:ai, stage by stage across all nodes; why Run:ai's New cluster page is not used | T-101 – T-127 | Reference |
| 15 | [Continuous integration](15-ci.md): shellcheck, yamllint, unit tests, Go tests, patch check and secret scan on every push; run them locally | T-003 | Tested (CI) |
| 16 | [Dynamo under Run:ai](16-dynamo-under-runai.md): Dynamo 1.6.1 with Grove and its own KAI off, a DynamoGraphDeployment submitted through the Run:ai UI, the worker on the project's NVIDIA quota, chat through the frontend, a deployment over quota waits; installed by `oif install`; the AMD image built from oif's Dynamo fork (T-211) | S-4, T-201, T-211 | Tested (lab: NVIDIA); AMD image: build script ready, not built yet |
| 17 | [Accelerator domains](17-accelerator-domains.md): GPU nodes labelled with their scale-up domain (NVLink clique or NVSwitch, AMD xGMI hive, PCIe), fabric and scale-out zone by agent oif-topology; annotations for rack-scale domains; the agent limited to its own node and labels | T-130 – T-132 | Tested (lab: T-130 12/12, T-131 12/12, T-132 8/8) |
| 18 | [Benchmark Dynamo against its engine: `oif bench`](18-oif-bench.md): vLLM and OIF's Dynamo ROCm build on the W7900, same engine underneath, AIPerf sweep with temperature guard, HTML report with Dynamo's difference per point; SGLang after S-5 | B-1 | Report tested (synthetic); lab run pending |
| 19 | [Run a job without naming a GPU vendor: AIJob](19-aijob.md): AIJob (oif.ai/v1alpha1) picks NVIDIA or AMD from the AcceleratorDomain view (preferVendor is soft), creates a Job in that vendor's node pool under the project's quota; one vendor per job, optional one domain; status shows vendor, domains, nodes; project defaults (PlacementPolicy); figures in Grafana; where cross-vendor jobs are refused | T-133 – T-136 | Tested (lab: T-133 17/17, T-134 10/10, T-135 13/13) |

Multi-node (P1.3) workflow decks live under [presentations/](../../presentations/) (T-120–T-122). Full multi-node install guides come with T-124.

Project 2 (Dynamo serving and benchmarks) and 3 (unified API and gateway) add their guides here as they are built. Benchmark method: [docs/BENCHMARK.md](../BENCHMARK.md).

## How each guide is laid out

1. **What you get**: the result of the step.
2. **Before you start**: what must already be done.
3. **Steps**: numbered commands to copy, each followed by the output you should see.
4. **Check it worked**: commands that prove the result.
5. **What changed on the host**: every change, and how uninstall reverses it.
6. **Troubleshooting**: known problems and fixes.

Addresses, host names and secrets in examples are placeholders such as `<host-ip>`.
