#!/bin/bash
# The NVIDIA driver branch checks (ADR-032): which loaded driver is good enough, and which installed packages belong to
# another branch and go when the node is upgraded.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=../../installer/stages/30-gpu-host.sh
. "$ROOT/installer/stages/30-gpu-host.sh"
NV_MODULE=$SANDBOX/nvidia-version
nvidia-smi() { [ -s "$NV_MODULE" ]; }
NVIDIA_DRIVER_BRANCH=615-server

eq "$(nv_want)" 615 "major version of the branch:"
rm -f "$NV_MODULE"; no_ nv_driver_ok                       # nouveau, nothing loaded
echo 595.91.07 > "$NV_MODULE"; no_ nv_driver_ok             # the older branch still running: upgrade and reboot
echo 615.71.09 > "$NV_MODULE"; ok_ nv_driver_ok
echo 620.10.01 > "$NV_MODULE"; ok_ nv_driver_ok             # newer than configured: kept, never downgraded

dpkg-query() { printf '%s\n' nvidia-headless-no-dkms-595-server-open libnvidia-compute-595-server nvidia-firmware-595-server-595.91.07 \
  linux-modules-nvidia-595-server-open-7.0.0-38-generic nvidia-utils-615-server linux-modules-nvidia-615-server-open-7.0.0-38-generic \
  nvidia-container-toolkit libnvidia-container1 linux-image-7.0.0-38-generic; }
eq "$(nv_other_branches | paste -sd' ')" \
  "nvidia-headless-no-dkms-595-server-open libnvidia-compute-595-server nvidia-firmware-595-server-595.91.07 linux-modules-nvidia-595-server-open-7.0.0-38-generic" \
  "older branch packages:"
dpkg-query() { printf '%s\n' nvidia-utils-615-server nvidia-container-toolkit; }
eq "$(nv_other_branches)" "" "nothing to remove on the configured branch:"
finish
