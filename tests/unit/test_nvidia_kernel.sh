#!/bin/bash
# T-143: the NVIDIA driver after a kernel update. NV_CHECK on fake /sys, /boot and /lib/modules; the flavour's modules
# package; the driver stage's pin and paths (lab case of 2026-11-12, first install); the first node's check before a
# re-run; oif status; the GPU Operator toolkit restart. apt, dpkg, modprobe, kubectl and the nodes are stubbed.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
export NV_MODULE=$SANDBOX/sys/nvidia-version NV_BOOT=$SANDBOX/boot NV_MODULES=$SANDBOX/modules
for f in "$ROOT"/installer/stages/30-gpu-host.sh "$ROOT"/installer/stages/50-gpu-nvidia.sh; do
  # shellcheck source=/dev/null
  . "$f" || { echo "      FAIL: cannot load $f"; exit 1; }
done
NVIDIA_DRIVER_BRANCH=615-server; CALLS=$SANDBOX/calls
mkdir -p "$SANDBOX/sys"
kernel() {   # version [nvidia]: an installed kernel, with the NVIDIA modules when "nvidia" is given
  touch "$NV_BOOT/vmlinuz-$1"; mkdir -p "$NV_MODULES/$1/kernel"
  [ "${2:-}" = nvidia ] && { mkdir -p "$NV_MODULES/$1/kernel/nvidia-615srv-open"; touch "$NV_MODULES/$1/kernel/nvidia-615srv-open/nvidia.ko"; }
  return 0; }
reset() { rm -rf "$NV_BOOT" "$NV_MODULES" "$NV_MODULE"; mkdir -p "$NV_BOOT"; touch "$NV_BOOT/vmlinuz" "$NV_BOOT/vmlinuz.old"; : > "$CALLS"; }
check() { sh -c "$NV_CHECK"; }

# --- NV_CHECK and its reading
reset; kernel 7.0.0-38-generic nvidia; kernel 7.0.0-43-generic nvidia; echo 615.71.09 > "$NV_MODULE"
eq "$(check)" "615.71.09 7.0.0-43-generic yes" "driver loaded, newest kernel has its modules:"
eq "$(check | nv_problems)" "" "all well: no problem:"
reset; kernel 7.0.0-42-generic nvidia; kernel 7.0.0-43-generic; echo 615.71.09 > "$NV_MODULE"
eq "$(check | nv_problems)" "kernel 7.0.0-43-generic has no NVIDIA modules: the GPU stops working when the node boots it" "a newer kernel without NVIDIA modules:"
reset; kernel 7.0.0-38-generic nvidia; kernel 7.0.0-42-generic
eq "$(check)" "none 7.0.0-42-generic no" "the lab on 2026-11-12: booted 7.0.0-42, modules only for 7.0.0-38:"
eq "$(check | nv_problems | head -1)" "NVIDIA driver not loaded" "driver gone:"
reset; kernel 7.0.0-9-generic; kernel 7.0.0-10-generic nvidia
eq "$(check | cut -d' ' -f2)" "7.0.0-10-generic" "kernel versions sorted as versions, not text:"

# --- the flavour's modules package
KREL=7.0.0-43-generic; uname() { echo "$KREL"; }
AVAIL="linux-modules-nvidia-615-server-open-generic"
apt-cache() { [ "$1" = show ] && [[ " $AVAIL " == *" $2 "* ]]; }
META=linux-modules-nvidia-615-server-open-generic
eq "$(nv_kernel_meta)" "$META" "generic kernel: the generic flavour's package:"
KREL=6.8.0-1012-aws; eq "$(nv_kernel_meta)" "" "a flavour the archive has no package for: none:"
KREL=7.0.0-43-generic

# --- the driver stage's pin
nv_targets() { echo 0000:03:00.0; }
nvidia-smi() { [ -s "$NV_MODULE" ]; }
INST=""; dpkg() { [ "$1" = -s ] && [[ " $INST " == *" $2 "* ]]; }
reset; kernel 7.0.0-43-generic nvidia; echo 615.71.09 > "$NV_MODULE"; INST="$META"
eq "$(nv_driver_rev)" "615-server" "all well: the branch alone, as before (installed nodes keep the stage done):"
INST=""; eq "$(nv_driver_rev)" "615-server no-$META" "the modules package missing: the stage runs again once:"
reset; INST="$META"; eq "$(nv_driver_rev)" "615-server no-driver" "driver gone: the stage runs again:"
nv_targets() { :; }; eq "$(nv_driver_rev)" "615-server" "no NVIDIA GPU: the branch alone:"
nv_targets() { echo 0000:03:00.0; }

# --- the driver stage
apt_install() { local p; echo "apt_install $*" >> "$CALLS"   # a kernel's modules package puts nvidia.ko in place
  for p; do case $p in linux-modules-nvidia-615-server-open-[0-9]*) kernel "${p#linux-modules-nvidia-615-server-open-}" nvidia ;; esac; done; }
MODPROBE=ok; modprobe() { echo "modprobe $*" >> "$CALLS"; [ $MODPROBE = ok ] && echo 615.71.09 > "$NV_MODULE"; [ $MODPROBE = ok ]; }
wait_for() { shift 3; "$@"; }
nv_other_branches() { :; }
put_file() { echo "put_file $1" >> "$CALLS"; }
update-initramfs() { echo "update-initramfs" >> "$CALLS"; }
run() { ( stage_nvidia_driver ) > "$SANDBOX/out" 2>&1; }

reset; kernel 7.0.0-43-generic nvidia; echo 615.71.09 > "$NV_MODULE"; INST="nvidia-headless-no-dkms-615-server-open"; run
grep -qx "apt_install $META" "$CALLS" || fail "driver loaded: the modules package for later kernels added"
grep -q "update-initramfs\|modprobe nvidia" "$CALLS" && fail "driver loaded: nothing else changed"
reset; kernel 7.0.0-43-generic nvidia; echo 615.71.09 > "$NV_MODULE"; INST="$META"; run
[ -s "$CALLS" ] && fail "driver loaded, package there: nothing changed"

# the lab on 2026-11-12: the driver installed, the node booted a later kernel without NVIDIA modules
KREL=7.0.0-42-generic; AVAIL+=" linux-modules-nvidia-615-server-open-7.0.0-42-generic"
reset; kernel 7.0.0-38-generic nvidia; kernel 7.0.0-42-generic; INST="nvidia-headless-no-dkms-615-server-open $META"; run
grep -qx "apt_install linux-modules-nvidia-615-server-open-7.0.0-42-generic" "$CALLS" || fail "lost driver: modules for the running kernel"
grep -qx "modprobe nvidia" "$CALLS" || fail "lost driver: loaded without a reboot"
grep -q "NVIDIA driver loaded again: 615.71.09 on kernel 7.0.0-42-generic" "$SANDBOX/out" || fail "lost driver: message"
grep -q "update-initramfs\|put_file" "$CALLS" && fail "lost driver: no reinstall, no reboot"
MODPROBE=fail; reset; kernel 7.0.0-38-generic nvidia; kernel 7.0.0-42-generic; run
grep -q "reboot the node, then run oif install again" "$SANDBOX/out" || fail "lost driver, modprobe fails: the stage stops and says what to do"
MODPROBE=ok

# first install: the running kernel's modules and the flavour's package together
reset; kernel 7.0.0-42-generic; INST=""; run
grep -q "apt_install nvidia-headless-no-dkms-615-server-open linux-modules-nvidia-615-server-open-7.0.0-42-generic $META nvidia-utils-615-server" "$CALLS" \
  || fail "first install: driver, modules for this kernel and for later ones"
grep -qx "modprobe nvidia" "$CALLS" && fail "first install: loads after the reboot"
KREL=6.8.0-1012-aws; reset; kernel 6.8.0-1012-aws; run
grep -q "no prebuilt NVIDIA 615-server modules for kernel 6.8.0-1012-aws" "$SANDBOX/out" || fail "no modules in the archive: the stage stops"
KREL=7.0.0-43-generic

# --- the first node before a re-run
host_prefix() { [ "$1" = 10.0.0.11 ] && echo 10.0.0.11/24; return 0; }
CHECK=""; nv_nodes_check() { printf '%s\n' "$CHECK"; }
drift() { rm -f "$STATE/$NV_REPAIR_FILE"; touch "$DONE/nodes" "$DONE/gpu-verify"; nv_drift > "$SANDBOX/out" 2>&1; }
CHECK="gpu-nvidia 10.0.0.22 615.71.09 7.0.0-43-generic yes"; drift
[ -f "$DONE/nodes" ] && [ -f "$DONE/gpu-verify" ] || fail "all well: nothing runs again"
CHECK="gpu-nvidia 10.0.0.22 none 7.0.0-42-generic no"; drift
[ -f "$DONE/nodes" ] && fail "a node lost its driver: its node stages run again"
[ -f "$DONE/gpu-verify" ] && fail "a node lost its driver: the GPUs are checked again"
eq "$(cat "$STATE/$NV_REPAIR_FILE")" 10.0.0.22 "the node whose GPU Operator toolkit is restarted:"
grep -q "gpu-nvidia: NVIDIA driver not loaded" "$SANDBOX/out" || fail "lost driver: message"
CHECK="gpu-nvidia 10.0.0.22 615.71.09 7.0.0-44-generic no"; drift
[ -f "$DONE/nodes" ] && [ -f "$DONE/gpu-verify" ] || fail "next kernel without modules: shown by status, nothing runs again"
CHECK="cp1 10.0.0.11 none 7.0.0-42-generic no"; drift
[ -f "$DONE/nodes" ] || fail "this host: its own pin reruns the driver stage, not the nodes stage"
CHECK="gpu-nvidia 10.0.0.22 unreachable"; drift
[ -f "$DONE/nodes" ] || fail "an unreachable node is left to the nodes stage"
rm -f "$DONE/gpu-verify"; CHECK="gpu-nvidia 10.0.0.22 none 7.0.0-42-generic no"; touch "$DONE/nodes"; nv_drift > /dev/null 2>&1
[ -f "$DONE/nodes" ] || fail "not installed yet: no check"

# --- oif status
touch "$DONE/nvidia-driver"; SELF=./oif
CHECK="gpu-nvidia 10.0.0.22 none 7.0.0-42-generic no"; s=$(nv_status)
grep -q "\[!\] gpu-nvidia: NVIDIA driver not loaded" <<< "$s" || fail "status: driver gone"
grep -q "fix: sudo ./oif install" <<< "$s" || fail "status: the fix for a lost driver"
CHECK="gpu-nvidia 10.0.0.22 615.71.09 7.0.0-44-generic no"
grep -q "fix, on that node: sudo apt-get install linux-modules-nvidia-615-server-open-7.0.0-44-generic" <<< "$(nv_status)" || fail "status: the fix for the next kernel"
CHECK="gpu-nvidia 10.0.0.22 615.71.09 7.0.0-43-generic yes"
eq "$(nv_status | tail -1)" "  [ok] gpu-nvidia: driver 615.71.09; kernel 7.0.0-43-generic, booted next, has its modules" "status, all well:"
CHECK=""; eq "$(nv_status)" "" "status without NVIDIA GPUs: nothing:"

# --- the GPU Operator toolkit on a repaired node
node_name_of() { [ "$1" = 10.0.0.22 ] && echo gpu-nvidia; return 0; }
kc() { echo "kubectl $*" >> "$CALLS"; }
: > "$CALLS"; printf '10.0.0.22\n10.0.0.22\n' > "$STATE/$NV_REPAIR_FILE"; nv_operator_restart > /dev/null
eq "$(grep -c . "$CALLS")" 1 "one restart per node:"
grep -q -- "delete pod -l app=nvidia-container-toolkit-daemonset --field-selector spec.nodeName=gpu-nvidia" "$CALLS" || fail "the toolkit on that node"
finish
