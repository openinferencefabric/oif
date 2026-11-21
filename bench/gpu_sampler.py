"""GPU telemetry every 0.5 s until SIGTERM: gpu_sampler.py /sys/class/drm/cardN/device out.csv   (AMD, amdgpu sysfs)
                                          gpu_sampler.py nvidia:<GPU UUID> out.csv            (NVIDIA, nvidia-smi)

Columns: t (s since start), busy (%), vram_mib, power_w, edge_c, junction_c, sclk_mhz. On NVIDIA edge_c is the GPU
temperature and junction_c stays empty (no hotspot sensor in nvidia-smi on most cards); sclk_mhz is the SM clock."""
import glob, os, re, signal, subprocess, sys, time

dev, out = sys.argv[1], sys.argv[2]
if dev.startswith("nvidia:"):
    smi = subprocess.Popen(["nvidia-smi", "-i", dev[7:], "--query-gpu=utilization.gpu,memory.used,power.draw,temperature.gpu,clocks.sm",
                            "--format=csv,noheader,nounits", "-lms", "500"], stdout=subprocess.PIPE, text=True)
    def stop(*_):  # wait for nvidia-smi: exiting first would leave it holding /dev/nvidiaN outside oif bench's tree
        smi.terminate()
        try:
            smi.wait(timeout=5)
        except subprocess.TimeoutExpired:
            smi.kill(); smi.wait()
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
    num = lambda x: str(float(x)) if re.match(r"^[0-9.]+$", x.strip()) else ""
    t0 = time.time()
    with open(out, "w") as f:
        f.write("t,busy,vram_mib,power_w,edge_c,junction_c,sclk_mhz\n")
        for line in smi.stdout:
            v = [x.strip() for x in line.split(",")]
            if len(v) == 5:
                f.write(",".join([str(round(time.time() - t0, 2)), num(v[0]), num(v[1]), num(v[2]), num(v[3]), "", num(v[4])]) + "\n")
                f.flush()
    sys.exit(0)
hw = (glob.glob(os.path.join(dev, "hwmon", "hwmon*")) or [""])[0]


def rd(path, scale=1.0):
    try:
        return float(open(path).read().split()[0]) * scale
    except Exception:
        return ""


def sclk():
    try:
        for line in open(os.path.join(dev, "pp_dpm_sclk")):
            if "*" in line:
                return float(re.search(r"(\d+)\s*Mhz", line, re.I).group(1))
    except Exception:
        pass
    return ""


def power():
    for name in ("power1_average", "power1_input"):  # microwatts
        v = rd(os.path.join(hw, name), 1e-6)
        if v != "":
            return round(v, 1)
    return ""


stop = False
signal.signal(signal.SIGTERM, lambda *_: globals().__setitem__("stop", True))
t0 = time.time()
with open(out, "w") as f:
    f.write("t,busy,vram_mib,power_w,edge_c,junction_c,sclk_mhz\n")
    while not stop:
        vram = rd(os.path.join(dev, "mem_info_vram_used"), 1 / 1048576)
        f.write(",".join(str(x) for x in (
            round(time.time() - t0, 2), rd(os.path.join(dev, "gpu_busy_percent")),
            round(vram) if vram != "" else "", power(),
            rd(os.path.join(hw, "temp1_input"), 1e-3), rd(os.path.join(hw, "temp2_input"), 1e-3), sclk())) + "\n")
        f.flush()
        time.sleep(0.5)
