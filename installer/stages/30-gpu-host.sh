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
# T-143: the prebuilt modules are per kernel. A kernel update (unattended-upgrades) without NVIDIA modules for the new
# kernel leaves the node without its driver after the next reboot, and the GPU Operator then waits for a driver
# container forever. The flavour's modules package (linux-modules-nvidia-<branch>-open-<flavour>) brings the modules
# for every new kernel; the checks below find a node where that did not happen.
# NV_CHECK prints "<loaded driver or none> <newest installed kernel> <yes|no: it has NVIDIA modules>"; plain sh, it runs
# on other nodes over SSH too. Tests point NV_MODULE, NV_BOOT and NV_MODULES at fake folders.
# shellcheck disable=SC2016   # expanded where it runs
NV_CHECK='v=$(cat "${NV_MODULE:-/sys/module/nvidia/version}" 2>/dev/null) || v=""; k=$(ls "${NV_BOOT:-/boot}" | sed -n "s/^vmlinuz-//p" | sort -V | tail -1); m=no; [ -n "$k" ] && [ -n "$(find "${NV_MODULES:-/lib/modules}/$k" -name "nvidia.ko*" 2>/dev/null | head -1)" ] && m=yes; echo "${v:-none} ${k:-unknown} $m"'
nv_problems() {   # stdin: an NV_CHECK line -> what is wrong, one per line (nothing: all well)
  local v k m; read -r v k m || return 0
  [ "$v" = none ] && echo "NVIDIA driver not loaded"
  [ "$m" = no ] && echo "kernel $k has no NVIDIA modules: the GPU stops working when the node boots it"
  return 0; }
nv_kernel_meta() {   # the flavour's package that adds the NVIDIA modules for each new kernel (empty: the archive has none)
  local k p; k=$(uname -r); p="linux-modules-nvidia-$NVIDIA_DRIVER_BRANCH-open-${k#*-*-}"   # 7.0.0-43-generic: generic
  if apt-cache show "$p" >/dev/null 2>&1; then echo "$p"; fi; return 0; }
nv_driver_rev() {   # the stage's pin: the branch, plus what is wrong now, so either change runs the stage again
  local s=$NVIDIA_DRIVER_BRANCH m
  [ -n "$(nv_targets)" ] || { echo "$s"; return 0; }
  nv_driver_ok || s+=" no-driver"
  m=$(nv_kernel_meta); [ -z "$m" ] || dpkg -s "$m" >/dev/null 2>&1 || s+=" no-$m"
  echo "$s"; }
nv_follow_kernel() {   # the flavour's modules package, so the next kernel update brings NVIDIA modules too
  local m; m=$(nv_kernel_meta)
  if [ -z "$m" ]; then warn "no NVIDIA modules package for the kernel flavour of $(uname -r): a kernel update brings no NVIDIA modules; check 'oif status' after each one"
  elif ! dpkg -s "$m" >/dev/null 2>&1; then apt_install "$m"; ok "NVIDIA modules follow kernel updates ($m)"; fi
}
iso_list() { echo "${ISOLATE_GPUS//,/ }"; }
iso_ok() { local b f; for b in $(iso_list); do for f in $(slot_functions "$b"); do [ "$(drv "$f")" = vfio-pci ] || return 1; done; done; }

register_stage nvidia-driver nv_driver_rev   # a new branch reaches installed nodes too (ADR-032); so does a lost driver (T-143)
stage_nvidia_driver() {
  [ -n "$(nv_targets)" ] || { warn "no NVIDIA GPU: driver skipped"; return 0; }
  local br=$NVIDIA_DRIVER_BRANCH old p f=/etc/modprobe.d/90-oif-nouveau.conf k; k=$(uname -r)
  if nv_driver_ok; then ok "NVIDIA driver loaded: $(nv_loaded) (branch $br or newer)"; nv_follow_kernel; return 0; fi
  [ "${br%%-*}" -ge "$NVIDIA_DRIVER_MIN" ] || die "NVIDIA_DRIVER_BRANCH $br is older than $NVIDIA_DRIVER_MIN"
  # T-143: the driver is installed, but the kernel running now came later and has no NVIDIA modules: add them and load it
  if [ -z "$(nv_loaded)" ] && dpkg -s "nvidia-headless-no-dkms-$br-open" >/dev/null 2>&1 && apt-cache show "linux-modules-nvidia-$br-open-$k" >/dev/null 2>&1; then
    log "the NVIDIA $br driver is installed but kernel $k has no NVIDIA modules (a kernel update): adding them"
    apt_install "linux-modules-nvidia-$br-open-$k"
    modprobe nvidia >> "$LOG" 2>&1 && wait_for "NVIDIA driver loaded" 30 2 nv_driver_ok \
      || die "the NVIDIA driver did not load on kernel $k (sudo dmesg | grep -i nvidia); reboot the node, then run oif install again"
    ok "NVIDIA driver loaded again: $(nv_loaded) on kernel $k"; nv_follow_kernel; return 0
  fi
  old=$(nv_other_branches | paste -sd' ')
  if [ -n "$(nv_loaded)" ]; then log "upgrading the NVIDIA driver $(nv_loaded) to the $br branch (one reboot)"
  else log "installing the NVIDIA $br driver (headless, open kernel modules, prebuilt for kernel $k)"; fi
  # the modules built for the running kernel, and the flavour's package that adds them for each later kernel (T-143). That
  # package follows the newest kernel in the archive, so on a node behind on updates it installs that kernel too (the
  # node boots it; uninstall never removes the kernel that runs)
  local mods=() meta; meta=$(nv_kernel_meta)
  apt-cache show "linux-modules-nvidia-$br-open-$k" >/dev/null 2>&1 && mods+=("linux-modules-nvidia-$br-open-$k")
  [ -n "$meta" ] && mods+=("$meta")
  [ ${#mods[@]} -gt 0 ] || die "no prebuilt NVIDIA $br modules for kernel $k in the archive (apt-cache search linux-modules-nvidia-$br)"
  [ -n "$meta" ] || warn "no NVIDIA modules package for the kernel flavour of $k: a kernel update brings no NVIDIA modules; check 'oif status' after each one"
  apt_install "nvidia-headless-no-dkms-$br-open" "${mods[@]}" "nvidia-utils-$br" "nvidia-compute-utils-$br"
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

# T-126 (ADR-032): KAI's admission gives every GPU-fraction pod the runtime class "nvidia" before a node is chosen. A
# node whose GPUs are all AMD has no NVIDIA runtime; there that name runs plain runc, so a fraction KAI places on the
# AMD GPU starts (oif's NRI plugin gives it the GPU). NVIDIA pods never land there: each vendor has its own pool.
AMD_RUNTIME_FILE=/etc/containerd/conf.d/90-oif-amd-fractions.toml
register_stage amd-runtime
stage_amd_runtime() {
  if [ -z "$(amd_targets)" ] || [ -n "$(nv_targets)" ]; then ok "not a node with AMD GPUs only: containerd unchanged"; return 0; fi
  [ -d "${AMD_RUNTIME_FILE%/*}" ] || rec "DIR ${AMD_RUNTIME_FILE%/*}"
  put_file "$AMD_RUNTIME_FILE" "# oif (T-126): runtime class nvidia on an AMD GPU node = runc, for KAI's GPU-fraction pods
version = 3
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.nvidia]
  runtime_type = 'io.containerd.runc.v2'
  [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.nvidia.options]
    SystemdCgroup = true
"
  systemctl restart containerd   # running containers keep running
  wait_for "containerd running" 60 2 ctr version || die "containerd did not start (journalctl -u containerd)"
  containerd config dump 2>/dev/null | grep -qF "runtimes.nvidia]" || die "containerd did not take $AMD_RUNTIME_FILE"
  ok "runtime class nvidia runs runc on this AMD GPU node (GPU fractions)"
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
