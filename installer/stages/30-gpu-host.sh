# shellcheck shell=bash
# T-102 GPUs on the host: NVIDIA driver from the Ubuntu archive (replaces nouveau), AMD display cards isolated with
# vfio-pci, one reboot (asked first), then a check that both took effect. AMD compute GPUs are not touched here.

nv_targets() { discover_gpus; if [ -n "${NVIDIA_GPUS:-}" ]; then echo "${NVIDIA_GPUS//,/ }"; else echo "${NV_BDFS[*]}"; fi; }
NV_MODULE=${NV_MODULE:-/sys/module/nvidia/version}                   # tests point this at a fake file
nv_loaded() { cat "$NV_MODULE" 2>/dev/null || true; }                 # the NVIDIA kernel module running now (empty: none)
nv_want() { echo "${NVIDIA_DRIVER_BRANCH%%-*}"; }                      # the configured branch's major version, e.g. 615
nv_driver_ok() { local v; v=$(nv_loaded); [ -n "$v" ] && [ "${v%%.*}" -ge "$(nv_want)" ] && nvidia-smi -L >/dev/null 2>&1; }
nv_other_branches() {   # installed packages of NVIDIA driver branches other than the configured one (an upgrade replaces them)
  local p b; dpkg-query -W -f='${Package}
' 2>/dev/null | grep nvidia | while read -r p; do
    b=$(grep -oE -- '-[0-9]{3}(-server)?' <<< "$p" | head -1) || true; b=${b#-}
    [ -n "$b" ] && [ "$b" != "$NVIDIA_DRIVER_BRANCH" ] && echo "$p"
  done; return 0; }
iso_list() { echo "${ISOLATE_GPUS//,/ }"; }
iso_ok() { local b f; for b in $(iso_list); do for f in $(slot_functions "$b"); do [ "$(drv "$f")" = vfio-pci ] || return 1; done; done; }

register_stage nvidia-driver NVIDIA_DRIVER_BRANCH   # a new branch reaches installed nodes too (ADR-032)
stage_nvidia_driver() {
  [ -n "$(nv_targets)" ] || { warn "no NVIDIA GPU: driver skipped"; return 0; }
  if nv_driver_ok; then ok "NVIDIA driver loaded: $(nv_loaded) (branch $NVIDIA_DRIVER_BRANCH or newer)"; return 0; fi
  local br=$NVIDIA_DRIVER_BRANCH old p f=/etc/modprobe.d/90-oif-nouveau.conf
  [ "${br%%-*}" -ge "$NVIDIA_DRIVER_MIN" ] || die "NVIDIA_DRIVER_BRANCH $br is older than $NVIDIA_DRIVER_MIN"
  old=$(nv_other_branches | paste -sd' ')
  if [ -n "$(nv_loaded)" ]; then log "upgrading the NVIDIA driver $(nv_loaded) to the $br branch (one reboot)"
  else log "installing the NVIDIA $br driver (headless, open kernel modules, prebuilt for kernel $(uname -r))"; fi
  # the modules built for the running kernel: the -generic package follows the newest kernel in the archive and would
  # install that kernel too, which the node then boots and uninstall later removes from under it
  local mods; mods="linux-modules-nvidia-$br-open-$(uname -r)"
  if ! apt-cache show "$mods" >/dev/null 2>&1; then
    mods="linux-modules-nvidia-$br-open-generic"
    warn "no prebuilt NVIDIA modules for kernel $(uname -r): $mods brings the newest kernel too (uninstall keeps whichever kernel runs)"
  fi
  apt_install "nvidia-headless-no-dkms-$br-open" "$mods" "nvidia-utils-$br" "nvidia-compute-utils-$br"
  if [ -n "$old" ]; then   # apt replaced most of them; the rest would load the old branch's modules or firmware
    old=$(for p in $old; do if dpkg -s "$p" >/dev/null 2>&1; then echo "$p"; fi; done | paste -sd' ')   # a false test last must not fail the loop
    # shellcheck disable=SC2086   # a list of package names
    [ -z "$old" ] || DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq $old >> "$LOG" 2>&1 || die "cannot remove the older NVIDIA driver: $old (see $LOG)"
    ok "older NVIDIA driver branch removed"
  fi
  rm -f "$DONE/reboot-asked"   # the reboot for this driver is a new reason, not a second try of an earlier one
  # written once: on an upgrade the file is already oif's, and a backup of it would be "restored" by uninstall
  recorded "FILE $f" || put_file "$f" $'# oif: the NVIDIA driver replaces nouveau\nblacklist nouveau\noptions nouveau modeset=0\n'
  rec "INITRAMFS"; update-initramfs -u -k "$(uname -r)" >/dev/null
  ok "NVIDIA $br driver installed; it loads after the reboot"
}

# AMD compute GPUs run on the kernel's own amdgpu driver; it needs the GPU firmware files, which minimal images (cloud
# images, e.g. a lab VM) leave out. A full Ubuntu install has them, so there this stage changes nothing.
amd_gpu_up() { local b; for b in $(amd_targets); do [ "$(drv "$b")" = amdgpu ] || return 1; done; [ -e /dev/kfd ]; }
register_stage amd-firmware
stage_amd_firmware() {
  [ -n "$(amd_targets)" ] || { ok "no AMD compute GPU"; return 0; }
  if amd_gpu_up; then ok "AMD GPU $(amd_targets) on amdgpu, /dev/kfd present"; return 0; fi
  if apt-cache show linux-firmware-amd-graphics >/dev/null 2>&1; then apt_install linux-firmware-amd-graphics; else apt_install linux-firmware; fi
  ok "AMD GPU firmware installed"
  # amdgpu loaded but holding no device (it failed without firmware): load it again now; otherwise a reboot starts it.
  # lsmod is read whole: an awk that exits at the first match cuts lsmod off, and pipefail then reads that as failure.
  local users; users=$(lsmod | awk '$1 == "amdgpu" {print $3}')
  if [ -z "$users" ] || [ "$users" = 0 ]; then
    { modprobe -r amdgpu 2>/dev/null || true; } && modprobe amdgpu && wait_for "AMD GPU started by amdgpu" 60 3 amd_gpu_up || true
  fi
  amd_gpu_up || reboot_ask "start the AMD GPU with its firmware"
}

register_stage gpu-isolation
stage_gpu_isolation() {
  [ -n "$(iso_list)" ] || { ok "no GPUs to isolate"; return 0; }
  if iso_ok; then ok "already on vfio-pci: $(iso_list)"; return 0; fi
  [ -n "$(ls /sys/kernel/iommu_groups 2>/dev/null)" ] || die "IOMMU is off: enable it in the BIOS (AMD-Vi or VT-d) to isolate $(iso_list)"
  local b f ids=""
  for b in $(iso_list); do for f in $(slot_functions "$b"); do ids="${ids:+$ids,}$(pci_ids "$f")"; done; done
  ids=$(echo "$ids" | tr ',' '\n' | awk '!s[$0]++' | paste -sd,)
  local p mine   # vfio-pci binds by device id: no other device may share one
  mine=" $(for b in $(iso_list); do slot_functions "$b"; done | paste -sd' ') "
  for p in "$PCI_ROOT"/*; do
    [[ $mine == *" ${p##*/} "* ]] && continue
    [[ ",$ids," == *",$(pci_ids "${p##*/}"),"* ]] && die "${p##*/} has the same device id as a GPU to isolate; vfio-pci would take it too"
  done
  # vfio-pci claims these device ids at boot, before amdgpu and the HDMI audio driver
  put_file /etc/modprobe.d/90-oif-vfio.conf "# oif: GPU(s) $(iso_list) kept away from Kubernetes
options vfio-pci ids=$ids
softdep amdgpu pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
"
  put_file /etc/modules-load.d/90-oif-vfio.conf $'vfio\nvfio_iommu_type1\nvfio_pci\n'
  rec "INITRAMFS"; update-initramfs -u -k "$(uname -r)" >/dev/null
  ok "vfio-pci set for device ids $ids; it takes effect after the reboot"
}

register_stage reboot NVIDIA_DRIVER_BRANCH
stage_reboot() {   # one reboot for the driver and the isolation; never a second one for the same reason
  local why=() b
  if [ -n "$(nv_targets)" ] && ! nv_driver_ok; then
    if [ -n "$(nv_loaded)" ]; then why+=("load the NVIDIA $NVIDIA_DRIVER_BRANCH driver instead of $(nv_loaded)")
    else why+=("load the NVIDIA driver instead of nouveau"); fi
  fi
  iso_ok || why+=("bind $(iso_list) to vfio-pci")
  [ -n "$(amd_targets)" ] && ! amd_gpu_up && why+=("start the AMD GPU with its firmware")
  [ ${#why[@]} = 0 ] && { ok "no reboot needed"; return 0; }
  if [ -f "$DONE/reboot-asked" ] && [ "$(cat "$DONE/reboot-asked")" != "$(cat /proc/sys/kernel/random/boot_id)" ]; then
    for b in $(nv_targets); do warn "$b: driver '$(drv "$b")' (lsmod | grep -E 'nvidia|nouveau'; journalctl -k | grep -i nvidia)"; done
    die "still needed after the reboot: $(printf '%s; ' "${why[@]}")not rebooting again"
  fi
  cat /proc/sys/kernel/random/boot_id > "$DONE/reboot-asked"
  local msg; msg=$(printf '%s; ' "${why[@]}"); reboot_ask "${msg%; }"
}

register_stage host-verify NVIDIA_DRIVER_BRANCH
stage_host_verify() {
  local b v
  if [ -n "$(nv_targets)" ]; then
    v=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
    [ "${v%%.*}" -ge "$(nv_want)" ] || die "NVIDIA driver $v is older than the configured $NVIDIA_DRIVER_BRANCH branch"
    for b in $(nv_targets); do [ "$(drv "$b")" = nvidia ] || die "$b is on driver '$(drv "$b")', not nvidia"; done
    ok "NVIDIA driver $v: $(nvidia-smi --query-gpu=name --format=csv,noheader | paste -sd, -)"
  fi
  if [ -n "$(amd_targets)" ]; then
    amd_gpu_up || die "AMD GPU $(amd_targets) not started by amdgpu (sudo dmesg | grep -i amdgpu)"
    ok "AMD GPU $(amd_targets) on amdgpu, /dev/kfd present"
  fi
  iso_ok || die "not on vfio-pci: $(iso_list) (lspci -nnk -s $(iso_list | cut -d' ' -f1))"
  [ -n "$(iso_list)" ] && ok "isolated on vfio-pci: $(iso_list)"
  swapon --noheadings | grep . >/dev/null && die "swap is on again (check /etc/fstab and systemd swap units)"
  ok "swap off"
  systemctl is-active -q containerd || die "containerd is not running (journalctl -u containerd)"
  ok "containerd running"
}
