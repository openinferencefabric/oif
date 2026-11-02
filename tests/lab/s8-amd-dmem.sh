#!/bin/bash
# S-8 spike: can a fractional AMD GPU get a hard, kernel-enforced VRAM cap (the dmem cgroup controller, Linux 6.14+),
# what does ROCm report inside that cap, and how do CU masks and per-process compute accounting behave?
# Evidence for ROCm tickets 1-3 (docs/evidence/S-8/). Runs on a GPU host as root, without Kubernetes:
#   sudo tests/lab/s8-amd-dmem.sh <PCI address>             the AMD GPU to test, already on amdgpu (never the W6400)
#   sudo tests/lab/s8-amd-dmem.sh --clean <PCI address>     also remove the cached ROCm image
# Changes, all undone at the end: +dmem in the root cgroup's subtree_control (only if it was off), cgroup
# /sys/fs/cgroup/oif-s8. The ROCm image stays in $WORK/podman for a rerun (--clean removes it). No driver is rebound.
set -uo pipefail
WORK=${WORK:-/var/tmp/oif-s8}   # set WORK= to a large disk: the ROCm image (about 3 GB) is kept there
IMAGE=${IMAGE:-docker.io/rocm/dev-ubuntu-24.04:7.2.4}
CG=/sys/fs/cgroup/oif-s8
# cgroupfs manager: each container's cgroup is created under the test cgroup that carries the dmem limit
# (--cgroup-parent; dmem limits apply to the whole subtree). --cgroups=disabled is not used: ROCm sees no GPU with it.
P=(podman --root "$WORK/podman" --runroot /run/oif-s8-podman --cgroup-manager=cgroupfs)
OUT=$WORK/s8-results.txt
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 2; }
CLEAN=no; [ "${1:-}" = --clean ] && { CLEAN=yes; shift; }
mkdir -p "$WORK"; : > "$OUT"
say() { echo "$*" | tee -a "$OUT"; }
die() { say "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------- the GPU and the kernel
BDF=${1:-}   # given explicitly: this test never picks a GPU by itself
[ -n "$BDF" ] || die "give the PCI address of the AMD GPU to test (lspci -d 1002: shows it); it must already be on amdgpu"
[ -e "/sys/bus/pci/devices/$BDF" ] || die "no PCI device $BDF"
[ "$(cat "/sys/bus/pci/devices/$BDF/device")" != 0x7422 ] || die "$BDF is the Radeon PRO W6400: excluded from this test (owner's decision)"
[ "$(basename "$(readlink "/sys/bus/pci/devices/$BDF/driver")")" = amdgpu ] || die "$BDF is not on amdgpu (no driver is rebound by this test)"
grep -qw dmem /sys/fs/cgroup/cgroup.controllers || die "kernel $(uname -r) has no dmem cgroup controller (6.14+)"
REGION=$(awk -v b="$BDF" '$1 ~ b {print $1; exit}' /sys/fs/cgroup/dmem.capacity)
[ -n "$REGION" ] || die "$BDF has no dmem region (dmem.capacity: $(cat /sys/fs/cgroup/dmem.capacity))"
VRAM=$(awk -v r="$REGION" '$1 == r {print $2}' /sys/fs/cgroup/dmem.capacity)
RENDER=$(basename "$(ls -d /sys/bus/pci/devices/"$BDF"/drm/renderD* | head -1)")
GFX=""; GPUID=""
for n in /sys/class/kfd/kfd/topology/nodes/*; do
  [ "$(awk '/^domain/{d=$2} /^location_id/{l=$2} END{printf "%04x:%02x:%02x.%x", d, l/256, (l%256)/8, l%8}' "$n/properties")" = "$BDF" ] || continue
  GFX=$(awk '/^gfx_target_version/{print $2}' "$n/properties"); GPUID=$(cat "$n/gpu_id"); NODE=$n; done
[ -n "$GFX" ] || die "$BDF not found in the KFD topology"
ARCH=$(printf 'gfx%d%d%x' $((GFX / 10000)) $((GFX / 100 % 100)) $((GFX % 100)))
OVR=(); RUNARCH=$ARCH
if [[ $ARCH =~ ^gfx103[1-9a-f]$ ]]; then OVR=(-e HSA_OVERRIDE_GFX_VERSION=10.3.0); RUNARCH=gfx1030; fi   # RDNA2 parts ROCm builds as gfx1030
say "S-8 $(date '+%F %T')  kernel $(uname -r)  GPU $BDF $(lspci -s "$BDF" | cut -d' ' -f2- | cut -c1-60)"
say "  dmem region $REGION, VRAM $((VRAM >> 20)) MiB, $RENDER, $ARCH (code built for $RUNARCH), KFD gpu_id $GPUID, image $IMAGE"

# ---------------------------------------------------------------- cgroups: the root enables dmem for its children
ADDED=no
if ! grep -qw dmem /sys/fs/cgroup/cgroup.subtree_control; then echo +dmem > /sys/fs/cgroup/cgroup.subtree_control || die "cannot enable dmem"; ADDED=yes; fi
cleanup() {
  find "$CG" -name cgroup.procs -exec cat {} + 2>/dev/null | xargs -r kill -9 2>/dev/null; sleep 1
  find "$CG" -mindepth 1 -depth -type d -exec rmdir {} \; 2>/dev/null
  rmdir "$CG" 2>/dev/null
  [ $ADDED = yes ] && echo -dmem > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null
  [ $CLEAN = yes ] && "${P[@]}" rmi -a -f >/dev/null 2>&1
  say "cleanup: cgroup removed$([ $ADDED = yes ] && echo ', dmem off again in the root cgroup')"
}
trap cleanup EXIT
mkdir -p "$CG"; echo +dmem > "$CG/cgroup.subtree_control" || die "cannot enable dmem in $CG"
for g in free capped neighbour cu; do mkdir -p "$CG/$g"; echo +dmem > "$CG/$g/cgroup.subtree_control"; done

# ---------------------------------------------------------------- the image and the probes
"${P[@]}" image exists "$IMAGE" || { say "pulling $IMAGE (once)"; "${P[@]}" pull -q "$IMAGE" >/dev/null || die "pull failed"; }
say "  ROCm $("${P[@]}" run --rm "$IMAGE" cat /opt/rocm/.info/version 2>/dev/null)"
cat > "$WORK/mem.py" <<'PY'
# hipMemGetInfo, then hipMalloc + hipMemset in steps until the target or the first failure; then hold the memory
import ctypes, sys, time
hip = ctypes.CDLL("/opt/rocm/lib/libamdhip64.so")
hip.hipGetErrorName.restype = ctypes.c_char_p
def info(tag):
    f, t = ctypes.c_size_t(), ctypes.c_size_t()
    r = hip.hipMemGetInfo(ctypes.byref(f), ctypes.byref(t))
    print(f"  {tag}: hipMemGetInfo rc={r} free={f.value >> 20} MiB total={t.value >> 20} MiB", flush=True)
step, target, hold = int(sys.argv[1]) << 20, int(sys.argv[2]) << 20, float(sys.argv[3])
info("start"); got, ptrs = 0, []
while got + step <= target:
    p = ctypes.c_void_p(); r = hip.hipMalloc(ctypes.byref(p), ctypes.c_size_t(step))
    if r == 0:
        r = hip.hipMemset(p, 1, ctypes.c_size_t(step)) or hip.hipDeviceSynchronize()
    if r != 0:
        print(f"  hipMalloc/hipMemset failed after {got >> 20} MiB: {r} {hip.hipGetErrorName(r).decode()}", flush=True); break
    ptrs.append(p); got += step
print(f"  allocated {got >> 20} MiB of {target >> 20} MiB asked", flush=True)
info("holding"); print("  HOLDING", flush=True); time.sleep(hold)
PY
cat > "$WORK/busy.cpp" <<'CPP'
// keeps every CU it may use busy for N seconds (argv[1]); prints nothing
#include <hip/hip_runtime.h>
#include <chrono>
#include <cstdlib>
__global__ void spin(float *o, long n) { float x = threadIdx.x; for (long i = 0; i < n; i++) x = x * 1.000001f + 0.5f; o[blockIdx.x * blockDim.x + threadIdx.x] = x; }
int main(int c, char **v) {
  double secs = c > 1 ? atof(v[1]) : 15; float *o; hipMalloc(&o, 4096 * 256 * sizeof(float));
  auto t0 = std::chrono::steady_clock::now();
  while (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() < secs) { spin<<<4096, 256>>>(o, 200000); hipDeviceSynchronize(); }
  return 0;
}
CPP
DEV=(--device /dev/kfd --device "/dev/dri/$RENDER" -v "$WORK:/s8" "${OVR[@]}")
in_cg() {   # cgroup cmd...: a container whose cgroup is created under that test cgroup
  local g=$1; shift; "${P[@]}" run --rm --cgroup-parent="/oif-s8/$g" "${DEV[@]}" "$IMAGE" "$@"; }
dmem_now() { awk -v r="$REGION" '$1 == r {print int($2 / 1048576)}' "$CG/$1/dmem.current"; }
hold_and_read() {   # cgroup log: wait for HOLDING, then read dmem.current of that cgroup
  for _ in $(seq 120); do grep -q HOLDING "$2" 2>/dev/null && break; sleep 1; done; say "  dmem.current of $1: $(dmem_now "$1") MiB"; }

STEP=256
CAP=$(( (VRAM >> 20) / 4 / STEP * STEP ))
WANT=$(( (VRAM >> 20) * 3 / 4 / STEP * STEP ))

say; say "A. no cap: allocate $WANT MiB (3/4 of VRAM)"
in_cg free python3 /s8/mem.py $STEP $WANT 5 > "$WORK/a.log" 2>&1 & hold_and_read free "$WORK/a.log"; wait; sed 's/^/ /' "$WORK/a.log" | grep -v HOLDING | tee -a "$OUT"

say; say "B. dmem.max $CAP MiB (1/4 of VRAM): ask for $WANT MiB"
echo "$REGION $((CAP << 20))" > "$CG/capped/dmem.max" || die "cannot set dmem.max"
say "  dmem.max: $(cat "$CG/capped/dmem.max")"
in_cg capped python3 /s8/mem.py $STEP $WANT 15 > "$WORK/b.log" 2>&1 & hold_and_read capped "$WORK/b.log"
say; say "C. a neighbour without a cap allocates the rest while B holds its share"
in_cg neighbour python3 /s8/mem.py $STEP $(( (VRAM >> 20) - CAP - 512 )) 3 > "$WORK/c.log" 2>&1; wait
sed 's/^/ /' "$WORK/b.log" | grep -v HOLDING | sed 's/^/ B/' | tee -a "$OUT"; sed 's/^/ /' "$WORK/c.log" | grep -v HOLDING | sed 's/^/ C/' | tee -a "$OUT"
[ -f "$CG/capped/dmem.events" ] && say "  dmem.events of capped: $(tr '\n' ' ' < "$CG/capped/dmem.events")"

say; say "D. CU mask: compile a busy kernel for $RUNARCH, run it without and with HSA_CU_MASK, sample KFD cu_occupancy"
"${P[@]}" run --rm "${DEV[@]}" "$IMAGE" /opt/rocm/bin/hipcc --offload-arch="$RUNARCH" -O2 -o /s8/busy /s8/busy.cpp > "$WORK/d-build.log" 2>&1 || { say "  build failed:"; tail -5 "$WORK/d-build.log" | tee -a "$OUT"; exit 1; }
CUS=$(awk '/^simd_count/{s=$2} /^simd_per_cu/{p=$2} END{if (p) print s / p}' "$NODE/properties")
say "  the GPU has ${CUS:-?} CUs"
for mask in "" "0:0-3"; do
  extra=(); [ -n "$mask" ] && extra=(-e "HSA_CU_MASK=$mask")
  "${P[@]}" run --rm --cgroup-parent=/oif-s8/cu "${DEV[@]}" "${extra[@]}" "$IMAGE" /s8/busy 12 > "$WORK/d.log" 2>&1 &
  sleep 6; samples=""; pid=""
  for p in $(find "$CG/cu" -name cgroup.procs -exec cat {} +); do [ -d "/sys/class/kfd/kfd/proc/$p" ] && pid=$p; done
  for _ in 1 2 3 4 5; do samples="$samples $(cat /sys/class/kfd/kfd/proc/"$pid"/stats_*/cu_occupancy 2>/dev/null | head -1)"; sleep 0.5; done
  say "  HSA_CU_MASK=${mask:-<unset>}: KFD process $pid, cu_occupancy samples:$samples"
  say "    files the kernel offers for this process: $(ls /sys/class/kfd/kfd/proc/"$pid"/ /sys/class/kfd/kfd/proc/"$pid"/stats_* 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
  say "    fdinfo engine lines: $(for f in /proc/"$pid"/fdinfo/*; do grep -h '^drm-engine\|^drm-cycles\|^drm-memory' "$f" 2>/dev/null; done | sort -u | tr '\n' ';' | cut -c1-300)"
  say "    host busy %: $(cat /sys/bus/pci/devices/"$BDF"/gpu_busy_percent 2>/dev/null)"
  wait
done
say; say "Results: $OUT (logs a.log b.log c.log d.log in $WORK)"
