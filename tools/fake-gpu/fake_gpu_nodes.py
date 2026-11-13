#!/usr/bin/env python3
"""Fake AMD Instinct GPU nodes for KWOK (S-9, ADR-020 amendment 2026-11-05).

Writes Kubernetes Node objects that look like nodes running the AMD GPU Operator: the labels of its node labeller
(ROCm/k8s-device-plugin cmd/k8s-node-labeller) and the extended resources of its device plugin, for each naming
strategy (single, mixed, product) and partition mode. KWOK (kubernetes-sigs/kwok) keeps them Ready; schedulers place
pods on them as on real nodes, so multi-GPU placement and topology logic can be tested without the hardware.
Standard library only; output is a v1 List (JSON, which kubectl reads as YAML).

  fake_gpu_nodes.py --profile mi300x --count 4                       4 x 8-GPU MI300X servers (one xGMI domain each)
  fake_gpu_nodes.py --profile mi355x --partition cpx_nps1 --count 1  one MI355X server in CPX: 64 partitions
  fake_gpu_nodes.py --profile mi455x --racks 2                       two Helios racks: 2 x 18 trays of 4 GPUs
  fake_gpu_nodes.py --profile mi300x --naming product --count 2      resources named amd.com/gpu-mi300x-spx-nps1
  fake_gpu_nodes.py --list                                           the profiles

Topology labels (OIF's, not the AMD GPU Operator's: AMD publishes no xGMI or UALink domain label yet):
  oif.ai/accelerator-domain  the GPUs a job can use over the scale-up fabric: the server for 8-GPU xGMI boards (and
                             for PCIe cards, whose GPUs talk over PCIe only), the rack for Helios (UALink over Ethernet)
  oif.ai/accelerator-fabric  xgmi, ualoe or pcie
  oif.ai/scaleout-zone       the Ethernet scale-out group the node is in
"""
import argparse
import json
import sys

# Facts per GPU model. device_id and name: ROCm/k8s-device-plugin cmd/k8s-node-labeller/amdgpu.ids. vram_gb, cus and
# GPUs per node: AMD's datasheets (MI300X/MI325X/MI350X/MI355X: 8 GPUs on a universal baseboard, each linked to its
# 7 peers over xGMI; MI455X: AMD Helios, 18 compute trays of 4 GPUs, 72 GPUs on UALink over Ethernet).
# family "AI" is what the labeller reports for these GPUs. assumed: values not in amdgpu.ids or a datasheet yet.
PROFILES = {
    "mi300x": dict(name="AMD Instinct MI300X", device_id="74A1", vram_gb=192, cus=304, gpus=8, fabric="xgmi",
                   domain="node", partitions=True, nps=("nps1", "nps2", "nps4"), family="AI"),
    "mi325x": dict(name="AMD Instinct MI325X", device_id="74A5", vram_gb=256, cus=304, gpus=8, fabric="xgmi",
                   domain="node", partitions=True, nps=("nps1", "nps4"), family="AI"),
    # two IODs (MI300X: four), so NPS1 or NPS2 only; NPS2 with DPX, QPX or CPX (CDNA4_NPS_WITH)
    "mi350x": dict(name="AMD Instinct MI350X", device_id="75A0", vram_gb=288, cus=256, gpus=8, fabric="xgmi",
                   domain="node", partitions=True, nps=("nps1", "nps2"), nps_with="cdna4", family="AI"),
    "mi355x": dict(name="AMD Instinct MI355X", device_id="75A3", vram_gb=288, cus=256, gpus=8, fabric="xgmi",
                   domain="node", partitions=True, nps=("nps1", "nps2"), nps_with="cdna4", family="AI"),
    # PCIe card, half an MI350X (one IOD, 4 XCDs); up to 8 per server, no Infinity Fabric between cards
    "mi350p": dict(name="AMD Instinct MI350P", device_id="75A8", vram_gb=144, cus=128, gpus=8, fabric="pcie",
                   domain="node", partitions=True, modes={"spx": 1, "dpx": 2, "cpx": 4}, nps=("nps1",), family="AI",
                   assumed="memory partition modes: not published, NPS1 only"),
    "mi455x": dict(name="AMD Instinct MI455X", device_id="", vram_gb=432, cus=256, gpus=4, fabric="ualoe",
                   domain="rack", rack_nodes=18, partitions=False, family="AI",
                   assumed="device id and product name: not in amdgpu.ids yet"),
    "w7900": dict(name="AMD Radeon Pro W7900", device_id="7448", vram_gb=45, cus=96, gpus=1, fabric="pcie",
                  domain="node", partitions=False, family="GC_11_0_0", simds_per_cu=2),
}
# Compute partitions per GPU, from AMD SMI's partitioning guide (rocm.docs.amd.com, amdsmi, conceptual/partition) and
# AMD's MI300X partitioning overview: SPX the whole GPU, DPX 2 devices of 4 XCDs, QPX 4 of 2 XCDs, CPX one device per
# XCD (8). Memory partitions (NPS), MI300X matrix: NPS1 with any compute mode, NPS2 with DPX, NPS4 with QPX or CPX;
# never more memory than compute partitions. Which NPS modes a GPU has is per profile (AMD's partitioning index:
# DPX + NPS2 on MI300X, MI350 and MI355, not on MI325). MI350X and MI355X (CDNA 4) have two IODs, so their memory is
# NPS1 or NPS2 (two 144 GB pools), and NPS2 goes with DPX, QPX or CPX (rocm.docs.amd.com gpu-arch/mi350: SPX/NPS1,
# DPX/NPS2, QPX/NPS2, CPX/NPS2; amdgpu driver 30.20.0 release notes: "NPS2 + CPX partitioning support for MI355X and
# MI350X"). A GPU with fewer XCDs has its own modes (MI350P, 4 XCDs: SPX, DPX, CPX of 4). TPX (3 partitions) exists
# only on the 6-XCD MI300A APU, which is not modelled.
COMPUTE_PARTITIONS = {"spx": 1, "dpx": 2, "qpx": 4, "cpx": 8}
MEMORY_PARTITIONS = ("nps1", "nps2", "nps4")
NPS_WITH = {"nps1": ("spx", "dpx", "qpx", "cpx"), "nps2": ("dpx",), "nps4": ("qpx", "cpx")}
NPS_WITH_BY = {"cdna3": NPS_WITH, "cdna4": {"nps1": ("spx", "dpx", "qpx", "cpx"), "nps2": ("dpx", "qpx", "cpx")}}
BRAND_WORDS = {"amd", "ati", "instinct", "radeon", "graphics", "series"}


def label_name(name: str) -> str:
    """Product name as the labeller writes it: spaces to _, ( ) dropped, / to _."""
    return name.replace(" ", "_").replace("(", "").replace(")", "").replace("/", "_")


def product_resource(name: str) -> str:
    """The device plugin's product name in resource names (AMD Instinct MI300X -> gpu-mi300x)."""
    words = [w for w in name.lower().replace("/", " ").split() if w not in BRAND_WORDS]
    return "gpu-" + "-".join(words)


def labeller(kind: str, value: str, count: int) -> dict:
    """The three forms the node labeller writes for a property every GPU of the node shares."""
    return {f"amd.com/gpu.{kind}": value, f"beta.amd.com/gpu.{kind}": value, f"beta.amd.com/gpu.{kind}.{value}": str(count)}


def node(profile: str, name: str, partition: str, naming: str, domain: str, zone: str) -> dict:
    p = PROFILES[profile]
    cp, mp = partition.split("_")
    if (cp, mp) != ("spx", "nps1") and not p["partitions"]:
        raise SystemExit(f"{profile} does not support partitioning")
    modes = p.get("modes", COMPUTE_PARTITIONS)
    pairs = NPS_WITH_BY[p.get("nps_with", "cdna3")]
    if p["partitions"] and (cp not in modes or mp not in p["nps"] or cp not in pairs[mp]):
        rules = "; ".join(f"{m.upper()} with {', '.join(c.upper() for c in pairs[m] if c in modes)}" for m in p["nps"])
        raise SystemExit(f"{profile}: {cp.upper()} with {mp.upper()} is not a valid mode (compute modes "
                         f"{', '.join(modes).upper()}; {rules})")
    per_gpu = modes[cp]
    devices = p["gpus"] * per_gpu
    labels = {"type": "kwok", "kubernetes.io/hostname": name, "kubernetes.io/os": "linux", "kubernetes.io/arch": "amd64",
              "feature.node.kubernetes.io/amd-gpu": "true", "oif.ai/gpu-vendor": "amd", "oif.ai/fake-gpu-profile": profile,
              "oif.ai/accelerator-domain": domain, "oif.ai/accelerator-fabric": p["fabric"], "oif.ai/scaleout-zone": zone}
    labels |= labeller("family", p["family"], devices)
    if p["device_id"]:
        labels |= labeller("device-id", p["device_id"].lower(), devices)
        labels |= labeller("product-name", label_name(p["name"]), devices)
    # the labeller reads each device's memory bank: a compute partition of a GPU reports its share (ROCm/gpu-operator#555)
    labels |= labeller("vram", f"{round(p['vram_gb'] / per_gpu)}G", devices)
    labels |= labeller("cu-count", str(p["cus"] // per_gpu), devices)
    # SIMDs per CU: 4 on CDNA (Instinct), 2 on RDNA (Radeon; the lab's W7900 node reports 192 for 96 CUs)
    labels |= labeller("simd-count", str(p["cus"] // per_gpu * p.get("simds_per_cu", 4)), devices)
    if p["partitions"]:
        labels |= {"amd.com/gpu.compute-memory-partition": partition, "amd.com/gpu.compute-partitioning-supported": "true",
                   "amd.com/gpu.memory-partitioning-supported": "true"}
    if naming == "single":
        resource = "amd.com/gpu"
    elif naming == "mixed":
        resource = f"amd.com/{partition}" if p["partitions"] else "amd.com/gpu"
    else:
        resource = f"amd.com/{product_resource(p['name'])}" + (f"-{cp}-{mp}" if p["partitions"] else "") \
            if p["device_id"] else "amd.com/gpu"
    res = {"cpu": "192", "memory": "2Ti", "pods": "110", "ephemeral-storage": "8Ti", resource: str(devices)}
    annotations = {"kwok.x-k8s.io/node": "fake", "oif.ai/fake-gpu": f"{p['name']}, {p['gpus']} GPUs, {partition}"}
    if p.get("assumed"):
        annotations["oif.ai/fake-gpu-assumed"] = p["assumed"]
    return {"apiVersion": "v1", "kind": "Node",
            "metadata": {"name": name, "labels": labels, "annotations": annotations},
            "spec": {"taints": [{"key": "kwok.x-k8s.io/node", "value": "fake", "effect": "NoSchedule"}]},
            "status": {"allocatable": res, "capacity": dict(res)}}


def nodes(args: argparse.Namespace) -> list:
    p = PROFILES[args.profile]
    out = []
    if p["domain"] == "rack":
        for r in range(1, args.racks + 1):
            for t in range(1, p["rack_nodes"] + 1):
                name = f"{args.prefix}{args.profile}-r{r}-t{t:02d}"
                out.append(node(args.profile, name, args.partition, args.naming, f"{args.prefix}{args.profile}-r{r}", args.zone))
    else:
        for i in range(1, args.count + 1):
            name = f"{args.prefix}{args.profile}-{i:02d}"
            out.append(node(args.profile, name, args.partition, args.naming, name, args.zone))
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--profile", choices=sorted(PROFILES))
    ap.add_argument("--count", type=int, default=1, help="servers")
    ap.add_argument("--racks", type=int, default=1, help="racks (rack-scale profiles)")
    ap.add_argument("--partition", default="spx_nps1",
                    choices=[f"{c}_{m}" for c in COMPUTE_PARTITIONS for m in MEMORY_PARTITIONS])
    ap.add_argument("--naming", default="single", choices=("single", "mixed", "product"),
                    help="the device plugin's resource_naming_strategy")
    ap.add_argument("--prefix", default="fake-", help="node name prefix")
    ap.add_argument("--zone", default="zone-1", help="oif.ai/scaleout-zone")
    ap.add_argument("--list", action="store_true", help="list the profiles")
    a = ap.parse_args()
    if a.list:
        for k, p in sorted(PROFILES.items()):
            print(f"{k:7} {p['name']:24} {p['gpus']} GPUs/node, {p['vram_gb']} GB, {p['fabric']}, domain = {p['domain']}"
                  + (f" ({p['rack_nodes']} nodes)" if p["domain"] == "rack" else "") + (f"; assumed: {p['assumed']}" if p.get("assumed") else ""))
        return
    if not a.profile:
        ap.error("--profile is required")
    json.dump({"apiVersion": "v1", "kind": "List", "items": nodes(a)}, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main()
