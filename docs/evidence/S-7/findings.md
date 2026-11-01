# S-7 AMD GPU fractions: findings (2026-11-01)

Run:ai 3.0.20, KAI Scheduler v0.18.3 (images ghcr.io/kai-scheduler/kai-scheduler/*:v0.18.3), gpu-fractioning v0.1.6,
kai-config global.gpuSharingMode=NvFractions, one SchedulingShard per node pool. Lab: gpu-amd, Radeon PRO W7900 45 GiB,
AMD GPU Operator v1.5.1, containerd 2.2.2 (enable_cdi=true, NRI on).

## Source (KAI v0.18.3, Run:ai 3.0.20)

Every step of KAI's fraction path assumes NVIDIA:
- scheduler: plugin gpusharingnodevalidation refuses shared-GPU pods on nodes without condition
  gpu-fractioning.nvidia.com/Ready when the mode is NvFractions (the message seen for pool amd in T-108).
  The mode is a scheduler flag (--gpu-sharing-mode); a SchedulingShard's args can override it per pool.
- binder: plugins gpusharing and nvfractions act on every shared-GPU bind, read label nvidia.com/gpu.memory and set
  NVIDIA_VISIBLE_DEVICES or NvFractions annotations. Plugins can be enabled per kai-config (binder.plugins).
- reservation pod: always requests nvidia.com/gpu (constants.NvidiaGpuResource; config can add resources, not remove
  that one); its image finds the GPU with NVML.
- AMD pieces already present: scheduler counts amd.com/gpu as GPUs (whole only); podgroupcontroller reads AMD VRAM
  from beta.amd.com/gpu.vram (gpu-amd carries beta.amd.com/gpu.vram=45G).
- Run:ai cluster-sync: "GPU fractions are not supported on this node" is node status only; the control plane accepted a
  fractional workload for pool amd in T-108, KAI refused it.
- KAI service images can be overridden in kai-config (service.image); kai-config is written by Run:ai's go-operator,
  which oif already rebuilds with patches (T-115).

## Lab

1. CDI pod annotation (cdi.k8s.io/s7: <W7900 CDI device>, spec in /etc/cdi): not injected; kubelet does not pass pod
   annotations to containers, so containerd only injects CDI devices from a device plugin or DRA.
   -> A fractional pod (no amd.com/gpu request) needs its own device injection: an NRI plugin, as NVIDIA's fractiond.
2. One pod (privileged, for device access in the test), PyTorch cap 0.45:
   visible True, W7900 45.0 GiB, held 18.0 GiB, over-cap allocation refused, 55.3 TFLOPS fp16 (8192^3 matmul, 60 s).
3. Two pods at once, cap 0.45 each: both held 18.0 GiB (host VRAM used 37.2 GiB), GPU busy 100 %,
   24.3 + 24.3 TFLOPS = 48.6 (88 % of one pod alone: time-sliced, even split).
4. Pod a without the convention (cap 0.95) took 40.5 GiB; pod b then failed: OutOfMemoryError (3.95 GiB free).
   -> Memory isolation on AMD is soft: no driver cap; each workload must limit itself.
Cleaned up: namespace oif-s7 deleted, /etc/cdi removed. ROCm PyTorch image left in gpu-amd's image cache.

## Verdict: go, with soft memory isolation (owner decided 2026-11-01: go, build T-126)

Works: two workloads share one W7900, time-sliced evenly, each within its own memory cap.
Does not exist: a hard per-pod memory limit (NVIDIA's fractiond + driver have one; AMD Radeon has none, no partitioning
on the W7900).

Patch plan (T-126, if go):
1. oif NRI plugin `oif-amd-share` (DaemonSet on AMD nodes): for a pod the binder marked, add /dev/kfd and the GPU's
   /dev/dri nodes plus device cgroup rules; set HIP_VISIBLE_DEVICES; set the memory cap hints (e.g.
   OIF_GPU_MEMORY_FRACTION, PYTORCH and vLLM defaults in the oif ROCm templates).
2. KAI patches, built from v0.18.3 source like the Run:ai patches:
   a. scheduler: the NvFractions readiness check applies to NVIDIA nodes only;
   b. binder: on a node with amd.com/gpu, the reservation pod requests amd.com/gpu and the fraction pod gets the oif
      annotation (GPU index, memory share from beta.amd.com/gpu.vram) instead of NVIDIA env/annotations;
   c. reservation pod: report the GPU without NVML on AMD nodes.
3. Run:ai go-operator patch: kai-config points binder/scheduler at the patched images.
4. Run:ai cluster-sync patch (optional): AMD nodes no longer say fractions unsupported.
5. Tests: two 0.5 workloads in pool amd from the Run:ai UI run together on the W7900, a third waits on quota,
   whole-GPU AMD workloads still work, NVIDIA fractions unchanged.
Risk: KAI patches must be rebased for every KRM/KAI upgrade (Run:ai bumps KAI with KRM); upstreaming them to
KAI-Scheduler removes that.

Alternatives: whole AMD GPUs only (no work; the demo shows fractions on NVIDIA only); DRA with a shared
ResourceClaim (Kubernetes-native sharing, but outside Run:ai's fraction accounting and UI).
