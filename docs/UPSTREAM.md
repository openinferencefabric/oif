# Changes to offer upstream

Every change oif makes to the code of other projects, and every upstream problem it works around, prepared for the
maintainers: what is wrong, what oif changed, how it was tested, and what to submit. oif applies its patches at install
time to the pinned releases; nothing here is a fork.

| Project | Repository | Release oif patches |
| --- | --- | --- |
| Run:ai (open source) | <https://github.com/dsx-ai-factory/run-ai> | 3.0.20 (`RUNAI_VERSION`) |
| KAI Scheduler | <https://github.com/kai-scheduler/KAI-Scheduler> | v0.18.3 (`KAI_VERSION`; the version Run:ai 3.0.20 deploys through KRM) |

Status: **ready** = the patch can be proposed as it is (tests included); **rework** = the idea is right but the patch is
oif-specific and needs a general form; **issue** = no oif patch, oif works around it, report it.

## Summary

| # | Project | Change | Kind | Status |
| --- | --- | --- | --- | --- |
| R1 | Run:ai cluster-sync | Count AMD GPUs in the node inventory | patch 0001 | ready |
| R2 | Run:ai frontend | AMD logo for workloads on ROCm images | patch 0002 | ready |
| R3 | Run:ai go-operator | Report GPU fractions unavailable when the fractioning daemons have no node | patch 0003 | ready |
| R4 | Run:ai frontend | New cluster page: say how clusters are added in this installation | patch 0004 | rework |
| R5 | Run:ai go-operator | `cluster-redis` follows `global.replicaCount` into unreplicated copies | issue (oif sets `cluster-redis.replicas: 1`) | issue + small PR |
| R6 | Run:ai API | Department list omits `defaultNodePools` | issue | issue |
| R7 | Run:ai | New projects' default node pools are `default` only, a pool without GPUs | issue (oif sets the order per department) | issue |
| R8 | Run:ai cluster-sync | AMD GPU nodes reported "GPU fractions not supported" once KAI supports them | follow-up to K1 to K4 | after K1 to K4 |
| R9 | Run:ai | ROCm workload templates (whole and half AMD GPU) | template JSON | offer as samples |
| R10 | Run:ai workspaces | Parallel requests during a workspace login fail with `invalid_grant` | issue | issue |
| K1 | KAI common | Helper: is a node an AMD GPU node, which resource holds its GPU | patch 0001 | ready (rename) |
| K2 | KAI scheduler | Skip the NvFractions readiness check on AMD GPU nodes | patch 0002 | ready |
| K3 | KAI binder | Reserve an `amd.com/gpu` on AMD nodes; name the shared GPU for the device injector | patch 0003 | rework (annotation names) |
| K3b | KAI binder | The reservation pod's resource config is changed in place on every call | part of patch 0003 | ready as its own PR |
| K4 | KAI resource-reservation | Find the reserved AMD GPU without NVML | patch 0004 | ready |
| K5 | KAI admission | `runtimeClassName: nvidia` set on every fraction pod, whatever the vendor | issue (oif maps the name to runc on AMD nodes) | issue + PR |
| K6 | KAI / AMD | Device injector for AMD fractions (oif-amd-share NRI plugin) and the PyTorch memory cap | new component | propose as a design |
| A1 | AMD metrics exporter | Phantom UMC ECC errors on Radeon PRO W7900 with kernel 7.0 | issue (oif raises the threshold) | issue |

## Run:ai

### R1. cluster-sync: count AMD GPUs in the node inventory (ready)

- **Patch:** `patches/runai/3.0.20/0001-cluster-sync-count-amd-gpus-on-mixed-nodes.patch` (85 lines added, 8 removed; `cluster-sync/pkg/handlers/parsers/node_parser.go`, tests in `parsers_test.go`).
- **Problem:** Run:ai schedules `amd.com/gpu`, but its node inventory reads only NVIDIA's labels. A node with an AMD GPU shows no GPU type, the Overview shows fewer GPU devices than the cluster has, and a node with both vendors counts only the NVIDIA GPUs.
- **Change:** read the AMD GPU Operator's labels (`amd.com/gpu.product-name`, `beta.amd.com/gpu.product-name.*`, `amd.com/gpu.vram`) as well as NVIDIA's; on a node with both vendors the type becomes `NVIDIA type + AMD type` and the count is the sum. GPU memory stays NVIDIA's on a mixed node.
- **Tests:** unit tests in the patch; lab: Overview 2/2 GPU devices, node type `NVIDIA-RTX-A6000 + AMD-Radeon-Pro-W7900` (oif guide 8).
- **Suggested PR:** "cluster-sync: count AMD GPUs (amd.com/gpu) in the node inventory".

### R2. frontend: AMD logo for ROCm images (ready)

- **Patch:** `0002-frontend-amd-logo-for-rocm-images.patch` (31+, 3-; `common/icon.util/icon.util.ts`, `icons.constant.ts`, `assets/icons/svg/amd.svg`, tests in `icon.util.test.ts`).
- **Problem:** workloads on AMD GPUs get the generic icon, while NVIDIA images get theirs.
- **Change:** an image whose path has a `rocm/` segment (`rocm/pytorch`, `docker.io/rocm/...`) gets the AMD icon.
- **Tests:** vitest, 53 tests in the icon suite pass; lab screenshots of the Workloads page.
- **Note for the maintainers:** check the AMD logo's use is acceptable to you, or replace it with a neutral "ROCm" icon.

### R3. go-operator: fractions unavailable when the daemons have no node (ready)

- **Patch:** `0003-go-operator-fractions-unavailable-without-target-nodes.patch` (50+; `pkg/controller-utils/gpu_fractioning_checker.go` and its test).
- **Problem:** when GPU fractioning cannot run anywhere (both daemons report `NoTargetNodes`, e.g. every NVIDIA driver older than r615), the operator reported fractions **available**, so every GPU node counted as not ready: Overview "Ready 0/1 nodes".
- **Change:** `NoTargetNodes` from both daemons means fractions are unavailable; nodes stay Ready, and the cluster shows "Missing prerequisites" as intended.
- **Tests:** unit tests; lab before and after (oif guide 8).

### R4. frontend: New cluster page in an installation that builds its own cluster (rework)

- **Patch:** `0004-frontend-new-cluster-points-to-oif.patch` (39+, 2-; `views/cluster/cluster-new.vue`). It replaces the wizard with a note pointing to `oif install`, so nobody installs NVIDIA's stock cluster chart (no AMD support) or registers a cluster and its bootstrap token by mistake.
- **Not for upstream as it is:** it names oif. **Proposal:** a control-plane setting (for example `tenant.clusterCreation: disabled` plus a message or URL) that hides the wizard and shows the installation's own instructions; useful to anyone who installs Run:ai with their own tooling.

### R5. cluster-redis follows `global.replicaCount` (issue + small PR)

- **Problem:** setting `RunaiConfig spec.global.replicaCount: 2` for high availability also gives `cluster-redis` two copies. They do not replicate, and the workspace login proxy (oauth2-proxy, `--session-store-type=redis`) stores a session in one copy and later reads the other: "session does not exist", the login starts again, and Jupyter and every other workspace URL never loads (78 HTTP 500 and 95 redirects for one page load in the lab).
- **oif workaround:** `RunaiConfig spec.cluster-redis.replicas: 1` (stage `runai-ha`, commit fc6e57e).
- **Suggested fix:** `cluster-redis` ignores `global.replicaCount` (it is a cache without replication), or runs as a replicated set when more than one copy is asked for. Evidence: `docs/evidence/T-127/lab-test-3.txt`.

### R6. API: the department list omits `defaultNodePools` (issue)

- `GET /api/v1/org-unit/departments` returns departments without `defaultNodePools` and `description`; `GET /api/v1/org-unit/departments/{id}` returns them. A client that reads the list and writes back what it read clears the description. oif reads each department on its own (commit d4c696e).

### R7. Default node pool order for new projects (issue)

- A project without its own order inherits `default` only. In a cluster with a node pool per GPU vendor, `default` holds the CPU nodes, so a workload submitted from the UI without choosing a pool waits forever: "No node in the default node-pool has GPU resources".
- oif sets every department's order to the GPU pools first (`nvidia, amd, default`, stage `one-vendor`). **Suggestion:** a cluster-level default order, or GPU pools before pools without GPUs when no order is set.

### R8. AMD nodes and the GPU fractions status (after K1 to K4)

- cluster-sync marks a node that the GPU-fractioning operator does not cover as "GPU fractions are not supported on this node". With K1 to K4, AMD GPU nodes do support fractions through KAI; the status should say so (the node carries `amd.com/gpu`, and KAI's AMD fraction path is enabled).

### R9. ROCm workload templates (samples)

- `platform/runai/templates/`: `pytorch-rocm-1-gpu` and `jupyter-lab-rocm-1-gpu` (a whole AMD GPU through `extendedResources`), `pytorch-rocm-half-gpu` and `jupyter-lab-rocm-half-gpu` (`gpuPortionRequest 0.5`, node pool `amd`). Offer as sample templates for AMD users.

### R10. Workspace login with parallel requests (issue)

- On the first visit to a workspace URL, the browser asks for dozens of files at once before the session cookie exists; each request starts its own login and all but one fail with `invalid_grant "Code not valid"`. It recovers, but on a slow link the page stays blank for minutes. Likely an oauth2-proxy setting (for example skipping the login for static assets, or serving the app's index first).

## KAI Scheduler

Background: KAI's GPU sharing is written for NVIDIA at every step. On a node whose GPUs are AMD (`amd.com/gpu`), a GPU
fraction cannot be scheduled (NvFractions readiness check), cannot be reserved (the reservation pod asks for
`nvidia.com/gpu` and finds its GPU with NVML), and cannot be given to the pod (NVIDIA environment and CDI only). K1 to K4
make the path vendor-aware; K6 is the AMD device injector. Tested on a Radeon PRO W7900 with Run:ai 3.0.20: two
half-GPU workloads share the GPU (24.2 TFLOPS each), a third waits on quota, NVIDIA fractions unchanged
(`docs/evidence/T-126/`).

### K1. common: AMD GPU node helper (ready, rename)

- **Patch:** `patches/kai/v0.18.3/0001-common-amd-gpu-node.patch` (67+; `pkg/common/resources/oif_amd_gpu.go` and test).
- `IsAmdGpuNode(node)`: the node offers `amd.com/gpu` and no `nvidia.com/gpu`. `GpuResourceOfNode(node)`: the resource that holds a whole GPU there.
- **For upstream:** rename the file (`amd_gpu.go`) and the annotation constants (`kai.scheduler/amd-gpu...` instead of `oif.ai/amd-gpu...`).

### K2. scheduler: NvFractions readiness check on AMD GPU nodes (ready)

- **Patch:** `0002-scheduler-fractions-on-amd-gpu-nodes.patch` (28+; `pkg/scheduler/plugins/gpusharingnodevalidation/`).
- In `NvFractions` mode the scheduler refuses every shared-GPU pod on nodes without condition `gpu-fractioning.nvidia.com/Ready`: "node is not ready for fractional GPU scheduling". The operator never covers AMD nodes, so the check now applies to NVIDIA nodes only. Test: an AMD node passes without the condition, an NVIDIA node without it is still refused.

### K3. binder: AMD GPU nodes (rework: annotation names)

- **Patch:** `0003-binder-fractions-on-amd-gpu-nodes.patch` (133+, 6-; `pkg/binder/binding/resourcereservation/resource_reservation.go`, `pkg/binder/plugins/nvfractions/nv_fractions.go`, tests).
- The reservation pod holds the node's own GPU resource (`amd.com/gpu` on an AMD node). The nvfractions plugin, on an AMD node, writes the shared GPU's PCI address, the container and the share into pod annotations for the device injector (K6), instead of NVIDIA's visible-devices and memory annotations.
- **For upstream:** annotation names under KAI's domain; possibly a separate binder plugin (`amdfractions`) rather than a branch in `nvfractions`.

### K3b. binder: shared resource config changed in place (ready, separate PR)

- In `createGPUReservationPod` the stock code deletes `nvidia.com/gpu` from `rsc.podResources.Limits/Requests`, the service-wide configuration, on every call (`delete(rsc.podResources.Limits, ...)`). The patch copies the maps first. A test checks the configuration is unchanged after a call. Small, independent bug fix.

### K4. resource-reservation: find the AMD GPU (ready)

- **Patch:** `0004-resourcereservation-amd-gpu-device.patch` (83+; `pkg/resourcereservation/discovery/`).
- On an AMD node the reservation pod gets `/dev/kfd` and one render node from AMD's device plugin; it reports that GPU's PCI address (from `/sys/class/drm/<render node>/device`) instead of asking NVML. Tests with a fake `/dev` and `/sys`.

### K5. admission: runtime class on fraction pods (issue + PR)

- `runtimeenforcement` sets `runtimeClassName: <gpuFractionRuntimeClassName>` (default `nvidia`) on every pod that asks for a GPU fraction, at creation, before any node or vendor is chosen. A pod's runtime class cannot change later, so a fraction KAI places on an AMD node fails: "no runtime for nvidia is configured".
- **oif workaround:** on AMD-only nodes, containerd's runtime name `nvidia` runs runc (node stage `amd-runtime`).
- **Suggested fix:** set the runtime class only for pods that can land only on NVIDIA nodes (their node pool or selector), or let the runtime class be chosen per node pool.

### K6. Device injector for AMD fractions (design proposal)

- A pod with a GPU fraction asks for no `amd.com/gpu`, so AMD's device plugin gives it no device. oif's NRI plugin (`images/oif-amd-share/`, about 200 lines of Go with tests) gives the container `/dev/kfd` and the reserved GPU's DRM nodes when containerd creates it, from the binder's annotations; a ValidatingAdmissionPolicy lets only the binder set those annotations. It also sets `OIF_GPU_MEMORY_FRACTION` and PyTorch's allocator cap (`PYTORCH_ALLOC_CONF=per_process_memory_fraction:<share>`, merged with the image's own settings), so PyTorch and vLLM keep to their share.
- **Limits to state upstream:** memory isolation is soft (no AMD driver cap; the W7900 has no partitions); compute is time-sliced.
- **Where it could live:** KAI (next to NVIDIA's gpu-fractioning `fractiond`), AMD's GPU Operator, or the ROCm device plugin. Propose as a design discussion with the evidence.

## AMD

### A1. Metrics exporter: phantom UMC ECC errors (issue)

- With the kernel's `amdgpu` on kernel 7.0, the Radeon PRO W7900 reports UMC ECC errors that do not exist; the device metrics exporter then marks the GPU unhealthy. oif raises the exporter's UMC ECC threshold for W7900/W7800 cards (`AMD_WORKSTATION_IDS` in `installer/stages/70-gpu-amd.sh`). Report to ROCm/device-metrics-exporter with the kernel and card.

## How to submit

1. Open an issue per item in the project's repository, with the problem, the evidence file and the oif patch linked.
2. For **ready** items, a pull request against the project's main branch: rebase the patch from the pinned release, rename oif's names where noted, keep the tests.
3. K1 to K4 together, with K6 described in the issue, so the maintainers see the whole AMD fraction path.
