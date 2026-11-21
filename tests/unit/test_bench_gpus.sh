#!/bin/bash
# B-2: oif bench on NVIDIA. bench/gpus.py offers an NVIDIA GPU once it is on the nvidia driver and has a CDI device
# (nvidia-ctk cdi generate), and names its device node (/dev/nvidiaN, for the "anyone else on the GPU" checks) and UUID
# (the CDI device name). bench/gpu_sampler.py reads NVIDIA telemetry from nvidia-smi. Fake host: an RTX A6000 and a
# W7900 as on the lab node, a fake nvidia-smi on PATH.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
H=$SANDBOX/host; export BENCH_HOST_ROOT=$H
mkdir -p "$SANDBOX/drivers/nvidia" "$SANDBOX/drivers/amdgpu" "$SANDBOX/bin"
pci() {  # address vendor device driver
  local d=$H/sys/bus/pci/devices/$1; mkdir -p "$d/drm"
  echo "0x$2" > "$d/vendor"; echo "0x$3" > "$d/device"; echo 0x030000 > "$d/class"; ln -s "$SANDBOX/drivers/$4" "$d/driver"; }
pci 0000:82:00.0 10de 2230 nvidia
mkdir -p "$H/sys/bus/pci/devices/0000:82:00.0/drm/card1" "$H/proc/driver/nvidia/gpus/0000:82:00.0"
printf 'Model: \t\t NVIDIA RTX A6000\nDevice Minor: \t 0\n' > "$H/proc/driver/nvidia/gpus/0000:82:00.0/information"
pci 0000:c8:00.0 1002 7448 amdgpu
mkdir -p "$H/sys/bus/pci/devices/0000:c8:00.0/drm/card2" "$H/sys/bus/pci/devices/0000:c8:00.0/drm/renderD129"
echo "Radeon Pro W7900" > "$H/sys/bus/pci/devices/0000:c8:00.0/product_name"
echo $((48 * 1024 ** 3)) > "$H/sys/bus/pci/devices/0000:c8:00.0/mem_info_vram_total"
cat > "$SANDBOX/bin/nvidia-smi" <<'EOF'
#!/bin/bash
case "$*" in
  *--query-gpu=pci.bus_id,name,memory.total,uuid*) echo "00000000:82:00.0, NVIDIA RTX A6000, 49140, GPU-1111-aaaa" ;;
  *-lms*) for i in 1 2 3; do echo "97, 40000, 250.5, 71, 1800"; sleep 0.2; done; sleep 30 ;;
esac
EOF
chmod +x "$SANDBOX/bin/nvidia-smi"; export PATH=$SANDBOX/bin:$PATH
g() { python3 "$ROOT/bench/gpus.py" --json | python3 -c 'import json,sys
for l in sys.stdin:
    d = json.loads(l)
    if d["pci"] == sys.argv[1]: print(d.get(sys.argv[2]))' "$1" "$2"; }

# no CDI device yet: listed, not offered, and told how to fix it
eq "$(g 0000:82:00.0 usable)" "False" "A6000 without a CDI device:"
g 0000:82:00.0 why_not | grep -q "nvidia-ctk cdi generate" || fail "why_not names the fix: $(g 0000:82:00.0 why_not)"
# with the CDI spec (nvidia-ctk names the GPU by its UUID): offered, with its UUID and device node
mkdir -p "$H/etc/cdi"; printf 'kind: nvidia.com/gpu\ndevices:\n- name: "0"\n- name: GPU-1111-aaaa\n' > "$H/etc/cdi/nvidia.yaml"
eq "$(g 0000:82:00.0 usable)" "True" "A6000 with a CDI device:"
eq "$(g 0000:82:00.0 uuid)" "GPU-1111-aaaa" "UUID:"
eq "$(g 0000:82:00.0 dev)" "/dev/nvidia0" "device node:"
eq "$(g 0000:82:00.0 vram_gib)" "48" "memory:"
# AMD unchanged; its device node is the render node
eq "$(g 0000:c8:00.0 usable)" "True" "W7900:"
eq "$(g 0000:c8:00.0 dev)" "/dev/dri/renderD129" "W7900 device node:"

# gpu_sampler.py on NVIDIA: nvidia-smi's own 0.5 s loop, same columns as on AMD (no hotspot sensor: junction_c empty)
python3 "$ROOT/bench/gpu_sampler.py" nvidia:GPU-1111-aaaa "$SANDBOX/gpu.csv" & sp=$!
sleep 1.2; kill "$sp"; wait "$sp" 2>/dev/null
eq "$(head -1 "$SANDBOX/gpu.csv")" "t,busy,vram_mib,power_w,edge_c,junction_c,sclk_mhz" "sampler header:"
eq "$(sed -n 2p "$SANDBOX/gpu.csv" | cut -d, -f2-)" "97.0,40000.0,250.5,71.0,,1800.0" "NVIDIA sample:"
pgrep -f "nvidia-smi.*GPU-1111-aaaa" >/dev/null && fail "nvidia-smi left running after the sampler stopped"

# oif-bench.sh picks each stack's image by the GPU's vendor; SGLang has no NVIDIA image here (skipped)
die() { echo "die: $*"; }
eval "$(sed -n '/^image_of() {/,/esac; }/p' "$ROOT/bench/oif-bench.sh")"
BENCH_VLLM_IMAGE=rocm-vllm; DYNAMO_ROCM_IMAGE=rocm-dyn; BENCH_SGLANG_IMAGE=rocm-sgl; DYNAMO_SGLANG_ROCM_IMAGE=""
BENCH_VLLM_CUDA_IMAGE=cuda-vllm; DYNAMO_CUDA_IMAGE=cuda-dyn
VENDOR=AMD;    eq "$(image_of vllm-rs) $(image_of dynamo-vllm) $(image_of sglang)" "rocm-vllm rocm-dyn rocm-sgl" "AMD images:"
VENDOR=NVIDIA; eq "$(image_of vllm-api4) $(image_of dynamo-vllm) [$(image_of sglang)]" "cuda-vllm cuda-dyn []" "NVIDIA images:"
# build.sh: the CUDA build is the same script with --device cuda; anything else is refused before any work
out=$(bash "$ROOT/images/dynamo-vllm-rocm/build.sh" --device xpu 2>&1); rc=$?
eq "$rc $out" "2 --device is rocm or cuda" "build.sh --device xpu:"
finish
