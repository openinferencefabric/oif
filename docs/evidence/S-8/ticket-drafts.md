# S-8 ROCm ticket drafts (not filed)

Drafts for ROCm, to be completed with the S-8 results (`tests/lab/s8-amd-dmem.sh`, output in `s8-results.txt`) and
filed only after the owner's "approve post". `ROCm/ROCm` was archived in October 2026: runtime issues go to
`ROCm/rocm-systems` (projects clr, rocr-runtime, amdsmi); amdgpu/amdkfd kernel bugs to
gitlab.freedesktop.org/drm/amd. No duplicates found on 2026-11-03 (searched: dmem, cgroup VRAM limit, hipMemGetInfo
container, HSA_CU_MASK, cu_occupancy, per-process utilization; nearest: rocm-systems#12503).

Filled from the S-8 run on the Radeon PRO W7900 (2026-11-03, `findings.md`). Ticket 2 has no measured number: gfx1100
offers no per-process counter to show the mask's effect (rerun D with a self-timing kernel if the maintainers ask).

---

## Ticket 1 - rocm-systems (clr, rocr-runtime)

**Title:** hipMemGetInfo and the HSA memory pool size ignore the cgroup `dmem.max` VRAM limit

**Problem.** Since Linux 6.14 the `dmem` cgroup controller can cap a cgroup's VRAM, and amdgpu registers its VRAM as a
dmem region (`drm/<pci>/vram`). Kubernetes GPU sharing can use this to give each container a hard share of one GPU.
Inside such a container ROCm still reports the whole GPU, so frameworks size themselves for memory they cannot get:

- `hipMemGetInfo` returns total 46064 MiB and free 45986 MiB while `dmem.max` is 11264 MiB;
- allocation stops at 11008 MiB with `hipErrorOutOfMemory` (the kernel cap works; `dmem.current` 11148 MiB);
- while the capped process holds its share, `hipMemGetInfo` reports the device's free memory (34832 MiB), not the
  216 MiB left in its cgroup;
- vLLM (`--gpu-memory-utilization`) and PyTorch's caching allocator take `total`/`free` at face value, so a workload
  given a quarter of a GPU plans for all of it and fails at the cap instead of fitting into it.

**Expected.** Like the NVIDIA stack with a per-container memory limit (`cudaMemGetInfo` reports the limit), ROCm reports
the VRAM a process may use: `total = min(VRAM, dmem.max of its cgroup and every ancestor)`, `free = total - dmem.current`
(bounded by the device's free VRAM). The same for `hsa_amd_memory_pool_get_info(HSA_AMD_MEMORY_POOL_INFO_SIZE)` and
`hipDeviceProp_t.totalGlobalMem`, so allocators built on HSA agree with HIP.

**Notes.** The limit is read from `/sys/fs/cgroup/<own cgroup>/dmem.max` up to the root, matching the region of the
device by PCI address. No new API; with no cgroup limit nothing changes. Reproduction: `s8-amd-dmem.sh` step B
(podman 5, ROCm 7.2.4 in `rocm/dev-ubuntu-24.04:7.2.4`, kernel 7.0.0-38, Radeon PRO W7900 gfx1100 46 GiB).

**Use case.** Open Inference Fabric runs Run:ai/KAI with fractional AMD GPUs (two pods on one Radeon PRO W7900).
Today each workload must cap itself (PyTorch memory fraction); a kernel cap is enforceable, but only useful once the
runtime reports it.

---

## Ticket 2 - rocm-systems (rocr-runtime) + amdkfd

**Title:** A compute-unit mask that the node sets and the workload cannot lift (for sharing one GPU between containers)

**Problem.** Sharing a GPU between containers needs a compute share as well as a memory share. `HSA_CU_MASK` limits the
CUs of every queue a process creates (ROCm documentation), but the process sets it itself: a workload that unsets the variable, or creates queues through KFD
directly, uses every CU. HAMi enforces it with an LD_AUDIT library for the same reason, which a process can also bypass.

**Expected.** A mask set outside the workload and enforced by the kernel: KFD intersects every queue's CU mask with a
per-process maximum. The maximum comes from a privileged source the workload cannot change, for example:

- a per-cgroup value (an interface of the dmem or misc controller, or a KFD sysfs file keyed by cgroup) read when the
  process opens `/dev/kfd`; or
- a sysfs file under `/sys/class/kfd/kfd/proc/<pid>/` that a privileged agent writes, applied to existing and new queues.

ROCr then reports the CU count of the mask (`hipDeviceProp_t.multiProcessorCount`, `HSA_AMD_AGENT_INFO_COMPUTE_UNIT_COUNT`)
so libraries size their grids for it.

**Use case.** The equivalent of NVIDIA MPS SM sharing (`CUDA_MPS_ACTIVE_THREAD_PERCENTAGE`, which the MPS server
enforces) for Kubernetes GPU fractions on Radeon PRO and Instinct GPUs that are not partitioned.

---

## Ticket 3 - rocm-systems (amdsmi) + amdkfd

**Title:** Per-process compute busy time for KFD queues (per-container GPU utilization)

**Problem.** A shared GPU needs utilization per container (billing, quotas, "is my fraction busy"). For ROCm compute
work the kernel offers:

- `gpu_busy_percent`: the whole device;
- `/sys/class/kfd/kfd/proc/<pid>/stats_<gpuid>/`: only `evicted_ms` on a Radeon PRO W7900 (gfx1100); `cu_occupancy`,
  an instantaneous sample where it exists, is not offered;
- DRM fdinfo of a ROCm process running a busy kernel: `drm-memory-cpu/gtt/vram` only, no `drm-engine-*` line
  (ROCm 7.2.4, kernel 7.0.0-38).

So `amd-smi process` and exporters cannot say how much of the GPU's time a process used. HAMi documents the same gap
("the kernel does not account compute time per process").

**Expected.** amdkfd accumulates the time a process's compute queues were active per GPU, exposes it as a monotonic
counter (for example `stats_<gpuid>/busy_ns`, or `drm-engine-compute` in the fdinfo of `/dev/kfd`), and amdsmi
returns it in the process list (`amdsmi_get_gpu_process_list`), like `drm-engine-gfx` for graphics.

**Related:** rocm-systems#12503 (cu_occupancy reported invalid when a GPU lacks the file).
