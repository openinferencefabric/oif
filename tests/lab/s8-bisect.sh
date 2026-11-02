#!/bin/bash
# S-8 follow-up: why HIP saw no GPU in s8-amd-dmem.sh while plain podman did. hipGetDeviceCount on one AMD GPU (its
# render node only): (1) --cgroups=disabled in the caller's cgroup, (2) inside a new cgroup without the dmem controller,
# (3) inside a new cgroup with dmem on, (4) podman's own cgroup. Undoes its cgroup changes at the end.
#   sudo tests/lab/s8-bisect.sh <PCI address>        same WORK= as s8-amd-dmem.sh (reuses its image)
set -uo pipefail
BDF=${1:?give the PCI address of the AMD GPU}; WORK=${WORK:-/var/tmp/oif-s8}; CG=/sys/fs/cgroup/oif-s8b
IMAGE=docker.io/rocm/dev-ubuntu-24.04:7.2.4
P=(podman --root "$WORK/podman" --runroot /run/oif-s8-podman)
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 2; }
[ "$(basename "$(readlink /sys/bus/pci/devices/$BDF/driver)")" = amdgpu ] || { echo "$BDF is not on amdgpu"; exit 1; }
R=$(basename "$(ls -d /sys/bus/pci/devices/$BDF/drm/renderD* | head -1)")
PROBE='import ctypes;h=ctypes.CDLL("/opt/rocm/lib/libamdhip64.so");h.hipGetErrorName.restype=ctypes.c_char_p;n=ctypes.c_int();r=h.hipGetDeviceCount(ctypes.byref(n));print("   hipGetDeviceCount:",h.hipGetErrorName(r).decode(),"devices",n.value)'
run() { "${P[@]}" run --rm "$@" --device /dev/kfd --device "/dev/dri/$R" -e AMD_LOG_LEVEL=1 "$IMAGE" python3 -c "$PROBE" 2>&1 | tail -4; }
ADDED=no
cleanup() { for g in "$CG"/*/; do [ -d "$g" ] && rmdir "$g" 2>/dev/null; done; rmdir "$CG" 2>/dev/null
  [ $ADDED = yes ] && echo -dmem > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; echo "cleanup done"; }
trap cleanup EXIT

echo "1. --cgroups=disabled, caller's cgroup"; run --cgroups=disabled
mkdir -p "$CG/a"
echo "2. --cgroups=disabled, new cgroup, dmem off"
bash -c 'echo $$ > "$0/cgroup.procs" && exec "$@"' "$CG/a" "${P[@]}" run --rm --cgroups=disabled --device /dev/kfd --device "/dev/dri/$R" "$IMAGE" python3 -c "$PROBE" 2>&1 | tail -4
grep -qw dmem /sys/fs/cgroup/cgroup.subtree_control || { echo +dmem > /sys/fs/cgroup/cgroup.subtree_control; ADDED=yes; }
echo +dmem > "$CG/cgroup.subtree_control"; mkdir -p "$CG/b"
echo "3. --cgroups=disabled, new cgroup, dmem on (no limit): $(cat "$CG/b/dmem.max" | tr '\n' ' ')"
bash -c 'echo $$ > "$0/cgroup.procs" && exec "$@"' "$CG/b" "${P[@]}" run --rm --cgroups=disabled --device /dev/kfd --device "/dev/dri/$R" "$IMAGE" python3 -c "$PROBE" 2>&1 | tail -4
echo "   dmem.current after: $(tr '\n' ' ' < "$CG/b/dmem.current")"
echo "4. podman's own cgroup (no --cgroups=disabled), dmem on in the root"; run
