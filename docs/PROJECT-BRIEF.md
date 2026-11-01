# Open Inference Fabric: project brief

One page for partners, sponsors and new contributors. Updated 2026-11-02.

## What it is

Open Inference Fabric (OIF) is an open-source project that turns bare-metal servers with NVIDIA and AMD GPUs into one
platform for running AI models: from an empty server to an inference endpoint, with every step tested and documented.

One installer, `oif install`, sets up:

| Layer | Built on |
| --- | --- |
| Kubernetes | Upstream kubeadm Kubernetes 1.35, hardened, with an HA control plane |
| GPUs | NVIDIA GPU Operator and AMD GPU Operator, side by side in one cluster |
| Orchestration | Open-source NVIDIA Run:ai 3.0 and the KAI Scheduler (CNCF Sandbox): projects, quotas, node pools, fractional GPUs |
| Serving | NVIDIA Dynamo with vLLM (in progress) |
| Benchmarks and telemetry | AIPerf, Prometheus and Grafana dashboards for both GPU vendors |

Every change it makes to a host is recorded and undone by `oif uninstall`.

- **Licence:** Apache-2.0
- **Repository:** <https://github.com/openinferencefabric/oif>
- **Started:** October 2026, after NVIDIA open-sourced Run:ai

## Why it matters

Running your own inference still means assembling many tools by hand, and most open tooling assumes one GPU vendor.
OIF gives teams a tested, vendor-neutral path on hardware they already own, including on-premises and air-gapped sites.
It also feeds what it learns back to the upstream projects, so the whole ecosystem gains.

## What it provides to the community

- **Guides:** 15 install and deployment guides, one per step, each written from a real run on the project's lab:
  NVIDIA RTX A6000 and AMD Radeon Pro W7900 nodes with a three-node control plane.
- **AMD support for Run:ai:**
  - AMD GPUs in Run:ai's node inventory;
  - per-vendor node pools and quotas, so a CUDA job never lands on an AMD GPU;
  - fractional AMD GPUs, with two workloads sharing one GPU under Run:ai's quotas.
- **Upstream contributions:**
  - 4 pull requests to Run:ai and the KAI Scheduler: [run-ai#3948](https://github.com/dsx-ai-factory/run-ai/pull/3948),
    [#3949](https://github.com/dsx-ai-factory/run-ai/pull/3949), [#3950](https://github.com/dsx-ai-factory/run-ai/pull/3950)
    and [KAI#2557](https://github.com/kai-scheduler/KAI-Scheduler/pull/2557);
  - 12 issues with lab evidence; the full list is in [UPSTREAM.md](UPSTREAM.md).
- **Reusable pieces:**
  - Grafana dashboards that show NVIDIA and AMD GPUs side by side;
  - lab test scripts and their recorded evidence;
  - 23 architecture decision records explaining each choice.
- **Engineering practice:** CI runs on every change (unit tests, patch checks, Go builds, secret scanning), versions are
  pinned, and no secrets or lab addresses appear in the repository.

## How it is run

- Run on a non-profit, volunteer basis. There is no company, no paid product and no revenue.
- Open governance from the start:
  - contributions under the Developer Certificate of Origin;
  - a Contributor Covenant code of conduct;
  - private vulnerability reporting.
- Maintainer: Manmohan Brahma ([LinkedIn](https://www.linkedin.com/in/manmohan-brahma-69683731/)).

## What support would change

| Need | What it enables |
| --- | --- |
| Website and documentation hosting | A searchable, versioned documentation site with preview builds for every pull request |
| Object storage | Offline install bundles for air-gapped GPU sites, patched images, and published benchmark results |
| Secure access | Contributors without GPU hardware can run the lab tests on the project's NVIDIA and AMD machines |
| GPU time | Continuous tests on more GPU models, especially AMD Instinct and newer NVIDIA generations |

## Roadmap

1. **Now:**
   - Dynamo serving under Run:ai quotas;
   - hardening of the fractional AMD GPU support.
2. **Next:**
   - Dynamo serving on AMD GPUs (ROCm);
   - side-by-side benchmarks of the same models on both vendors.
3. **Later:**
   - a unified inference API with self-service scheduling;
   - hard memory isolation on AMD Instinct GPUs (hardware partitions).
