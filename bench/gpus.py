"""List the GPUs on this node for oif bench.

gpus.py            table for people: number, name, PCI address, memory, driver, usable or why not
gpus.py --json     the same as JSON lines (used by oif-bench.sh)

Usable: AMD GPUs on the amdgpu driver (ROCm stacks) and NVIDIA GPUs on the nvidia driver with a CDI device (CUDA
stacks, B-2; `nvidia-ctk cdi generate` writes the spec Docker and Podman read). A GPU with a monitor connected to one
of its outputs, or with less memory than BENCH_MIN_VRAM_GIB (default 16), is listed but not offered. Each GPU carries
`dev`, the device node only its users hold open (AMD render node, /dev/nvidiaN), and on NVIDIA its `uuid`.
BENCH_HOST_ROOT (tests) puts /sys, /proc and the CDI directories under another directory."""
import glob, json, os, re, subprocess, sys

VENDORS = {"0x1002": "AMD", "0x10de": "NVIDIA"}
MIN_GIB = int(os.environ.get("BENCH_MIN_VRAM_GIB") or 16)
HOST = os.environ.get("BENCH_HOST_ROOT", "")


def rd(p):
    try:
        return open(p).read().strip()
    except Exception:
        return ""


def lspci_name(pci):
    try:
        out = subprocess.run(["lspci", "-s", pci], capture_output=True, text=True, timeout=5).stdout
        name = out.split(": ", 1)[1].strip() if ": " in out else ""
        m = re.search(r"\[([^\]]+)\]\s*(\(rev [0-9a-f]+\))?$", name)  # "Navi 31 [Radeon Pro W7900]" -> the bracket
        return m.group(1) if m else name
    except Exception:
        return ""


def nvidia_info():
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=pci.bus_id,name,memory.total,uuid", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return {}
    info = {}
    for line in out.splitlines():
        bus, name, mem, uuid = [x.strip() for x in line.split(",")]
        info[bus.lower()[-12:]] = (name, round(int(mem) / 1024), uuid)
    return info


def cdi_has(uuid):
    """a CDI spec names this GPU (nvidia-ctk cdi generate lists each GPU by index and by UUID)"""
    return any(uuid in rd(f) for d in ("etc/cdi", "var/run/cdi") for f in glob.glob(f"{HOST}/{d}/*.y*ml") + glob.glob(f"{HOST}/{d}/*.json"))


gpus, nv = [], None
for d in sorted(glob.glob(f"{HOST}/sys/bus/pci/devices/*")):
    if not rd(f"{d}/class").startswith("0x03"):
        continue
    vendor = VENDORS.get(rd(f"{d}/vendor"))
    if not vendor:
        continue
    pci = os.path.basename(d)
    driver = os.path.basename(os.path.realpath(f"{d}/driver")) if os.path.exists(f"{d}/driver") else "none"
    g = {"pci": pci, "vendor": vendor, "id": f"{rd(f'{d}/vendor')[2:]}:{rd(f'{d}/device')[2:]}", "driver": driver,
         "sysfs": d, "display": False, "name": "", "vram_gib": None, "card": "", "render": "", "dev": "", "uuid": ""}
    drm = sorted(os.listdir(f"{d}/drm")) if os.path.isdir(f"{d}/drm") else []
    g["card"] = next((x for x in drm if x.startswith("card")), "")
    # a monitor on one of its outputs: the console or a desktop uses it (boot_vga alone is set on every VM's only GPU)
    if g["card"]:
        g["display"] = any(rd(c + "/status") == "connected" for c in glob.glob(f"{HOST}/sys/class/drm/{g['card']}-*"))
    g["render"] = next((x for x in drm if x.startswith("renderD")), "")
    if vendor == "AMD":
        g["name"] = rd(f"{d}/product_name") or lspci_name(pci) or f"AMD GPU {g['id']}"
        v = rd(f"{d}/mem_info_vram_total")
        g["vram_gib"] = round(int(v) / 2**30) if v else None
        g["dev"] = f"/dev/dri/{g['render']}" if g["render"] else ""
        if driver != "amdgpu":
            g["why_not"] = f"driver {driver}, not amdgpu (passed through to a VM?)"
    else:
        nv = nvidia_info() if nv is None else nv
        name, mem, uuid = nv.get(pci.lower()[-12:], ("", None, ""))
        g["name"] = name or lspci_name(pci) or f"NVIDIA GPU {g['id']}"
        g["vram_gib"], g["uuid"] = mem, uuid
        minor = re.search(r"Device Minor:\s*(\d+)", rd(f"{HOST}/proc/driver/nvidia/gpus/{pci}/information"))
        g["dev"] = f"/dev/nvidia{minor.group(1)}" if minor else ""
        if driver != "nvidia":
            g["why_not"] = f"driver {driver}, not nvidia"
        elif not uuid or not g["dev"]:
            g["why_not"] = "nvidia-smi does not report it"
        elif not cdi_has(uuid):
            g["why_not"] = "no CDI device for it: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml (guide 18, B-2)"
    if g["vram_gib"] is not None and g["vram_gib"] < MIN_GIB and "why_not" not in g:
        g["why_not"] = f"{g['vram_gib']} GiB, below the {MIN_GIB} GiB minimum"
    if g["display"] and "why_not" not in g:
        g["why_not"] = "a display is connected to it"
    g["usable"] = "why_not" not in g
    gpus.append(g)

for i, g in enumerate(gpus, 1):
    g["index"] = i
if "--json" in sys.argv:
    for g in gpus:
        print(json.dumps(g))
else:
    print(f"  {'#':>2}  {'GPU':<34} {'PCI':<13} {'memory':>7}  {'driver':<9} usable")
    for g in gpus:
        mem = f"{g['vram_gib']} GiB" if g["vram_gib"] else "?"
        print(f"  {g['index']:>2}  {g['name'][:34]:<34} {g['pci'][-12:]:<13} {mem:>7}  {g['driver']:<9} "
              f"{'yes' if g['usable'] else 'no: ' + g['why_not']}")
