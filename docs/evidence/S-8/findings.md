# S-8 AMD GPU fractions with a kernel VRAM cap: findings (2026-11-03)

Question: can a fractional AMD GPU get a hard, kernel-enforced memory limit (Linux `dmem` cgroup controller) the way
NVIDIA's gpu-fractioning gets one from driver r615, and what is still missing in ROCm? Script
`tests/lab/s8-amd-dmem.sh`, output `s8-results-w7900.txt`.

Setup: lab host, Ubuntu 26.04, kernel 7.0.0-38, Radeon PRO W7900 (gfx1100, 46,064 MiB, amdgpu), ROCm 7.2.4 in
`rocm/dev-ubuntu-24.04:7.2.4` under podman 5 (cgroupfs manager, each container's cgroup created under a test cgroup).
The W6400 (host display) was not used; ROCm still creates an empty KFD context on every GPU of the host
(rocm-systems#14778). The W7900 was released from vfio-pci for this test (driverctl, one reboot).

## Results

| Step | What | Result |
|---|---|---|
| A | no cap, allocate 34,304 MiB | all allocated; `dmem.current` 34,532 MiB (the kernel accounts ROCm/KFD VRAM per cgroup) |
| B | `dmem.max` 11,264 MiB, ask for 34,304 MiB | stopped at 11,008 MiB with `hipErrorOutOfMemory`; `dmem.current` 11,148 MiB. **Hard cap works.** Inside the cap `hipMemGetInfo` reports total 46,064 / free 45,986 MiB at start and free 34,832 MiB (device-wide) while holding |
| C | uncapped neighbour while B holds its share | allocated 34,048 MiB; device free 638 MiB at the end. The cap does not affect neighbours |
| D | busy kernel without and with `HSA_CU_MASK=0:0-3` | per-process KFD sysfs: only `stats_<gpu>/evicted_ms` (no `cu_occupancy` on gfx1100); fdinfo of the process: `drm-memory-*` only, no `drm-engine-*`; `gpu_busy_percent` is device-wide. The mask's effect was not measured (no per-process counter to read) |

Also found: `podman run --cgroups=disabled` leaves ROCm with no device (`hipErrorNoDevice`) although `/dev/kfd` and the
render node are passed; with podman's own cgroup the same container sees the GPU (`s8-bisect.sh`, cases 1-4). The
`dmem` controller itself changes nothing for device discovery.

## Verdict

- **Memory:** a hard per-container VRAM limit on AMD needs no ROCm change: kernel 6.14+, `+dmem` enabled down the pod
  cgroup tree, `dmem.max` on the container's cgroup (OCI `linux.resources.unified`, settable by an NRI plugin at
  container creation, as NVIDIA's fractiond injects its limit). oif can replace the soft PyTorch cap (ADR-032) with it.
- **But** ROCm reports the whole GPU inside the cap, so engines that size themselves from `hipMemGetInfo` (vLLM
  `--gpu-memory-utilization`, PyTorch caching allocator) plan for 45 GiB and fail at 11 GiB. ROCm ticket 1.
- **Compute:** the only CU partitioning is `HSA_CU_MASK`, set by the process itself. ROCm ticket 2.
- **Metrics:** no per-process compute time for KFD queues on this GPU. ROCm ticket 3.
- ADR-032's rejection of HAMi ("no Radeon support") is out of date: HAMi's AMD sharing (docs of 2026-10-29) uses this
  same `dmem` cap plus an LD_AUDIT library and CU masks. It owns `amd.com/gpu` with its own device plugin, so it still
  does not fit next to Run:ai/KAI; the ADR needs its reason updated, not its decision.

## Next

1. oif task: set `dmem.max` from the oif-amd-share NRI plugin (and enable `+dmem` on the node's kubepods tree), keep
   the PyTorch/vLLM fraction as the in-process hint until ticket 1 is fixed; lab test with a pod that lifts its cap.
2. File ROCm tickets 1-3 (`ticket-drafts.md`) after the owner's approval.
3. Optional: rerun D with a kernel that reports its own throughput, to show the CU mask's effect in numbers.
