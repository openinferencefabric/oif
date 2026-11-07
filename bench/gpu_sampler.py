"""GPU telemetry from amdgpu sysfs, every 0.5 s until SIGTERM: gpu_sampler.py /sys/class/drm/cardN/device out.csv

Columns: t (s since start), busy (%), vram_mib, power_w, edge_c, junction_c, sclk_mhz. No tools needed in the image."""
import glob, os, re, signal, sys, time

dev, out = sys.argv[1], sys.argv[2]
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
