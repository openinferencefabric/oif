#!/bin/bash
# S-9 fake AMD GPU nodes for KWOK: labels as the AMD node labeller writes them, resources as the AMD device plugin
# names them (single, mixed, product), partition counts, and the topology domains (server for xGMI boards, rack for
# Helios). Checked against the AMD GPU Operator's documented output.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
GEN="$ROOT/tools/fake-gpu/fake_gpu_nodes.py"
q() { python3 "$GEN" "${@:2}" | python3 -c "import json, sys; items = json.load(sys.stdin)['items']; n = items[0]; L = n['metadata']['labels']; R = n['status']['allocatable']; print($1)"; }

eq "$(q 'L["amd.com/gpu.product-name"], L["beta.amd.com/gpu.product-name.AMD_Instinct_MI300X"], L["amd.com/gpu.device-id"], L["amd.com/gpu.vram"], R["amd.com/gpu"], len(items)' --profile mi300x --count 4)" \
  "AMD_Instinct_MI300X 8 74a1 192G 8 4" "MI300X server: labeller labels, 8 GPUs, 4 nodes:"
eq "$(q 'L["oif.ai/accelerator-domain"] == n["metadata"]["name"], L["oif.ai/accelerator-fabric"], n["spec"]["taints"][0]["key"], n["metadata"]["annotations"]["kwok.x-k8s.io/node"]' --profile mi355x)" \
  "True xgmi kwok.x-k8s.io/node fake" "8-GPU xGMI board: the server is the domain; tainted and managed by KWOK:"
eq "$(q 'R["amd.com/gpu"], L["amd.com/gpu.vram"], L["amd.com/gpu.cu-count"], L["amd.com/gpu.compute-memory-partition"], L["beta.amd.com/gpu.vram.36G"]' --profile mi355x --partition cpx_nps1)" \
  "64 36G 32 cpx_nps1 64" "MI355X in CPX: 64 partitions of 36 GB and 32 CUs:"
eq "$(q 'R["amd.com/cpx_nps4"], "amd.com/gpu" in R' --profile mi300x --partition cpx_nps4 --naming mixed)" \
  "64 False" "mixed naming: amd.com/<partition>:"
eq "$(q 'R["amd.com/gpu-mi300x-spx-nps1"]' --profile mi300x --naming product)" "8" "product naming: amd.com/gpu-mi300x-spx-nps1:"
eq "$(q 'R["amd.com/gpu-mi325x-cpx-nps1"]' --profile mi325x --partition cpx_nps1 --naming product)" "64" "product naming with CPX:"
eq "$(q 'len(items), len({i["metadata"]["labels"]["oif.ai/accelerator-domain"] for i in items}), sum(int(i["status"]["allocatable"]["amd.com/gpu"]) for i in items), L["oif.ai/accelerator-fabric"], "amd.com/gpu.product-name" in L, "oif.ai/fake-gpu-assumed" in n["metadata"]["annotations"]' --profile mi455x --racks 2)" \
  "36 2 144 ualoe False True" "Helios: 2 racks of 18 trays x 4 GPUs, one domain per rack, MI455X ids marked assumed:"
eq "$(q 'L["amd.com/gpu.product-name"], L["amd.com/gpu.family"], L["amd.com/gpu.vram"], L["amd.com/gpu.simd-count"], L["beta.amd.com/gpu.simd-count.192"], "amd.com/gpu.compute-memory-partition" in L' --profile w7900)" \
  "AMD_Radeon_Pro_W7900 GC_11_0_0 45G 192 1 False" "W7900, as the lab's real node is labelled (2 SIMDs per CU on RDNA):"
eq "$(q 'L["amd.com/gpu.simd-count"]' --profile mi300x)" "1216" "MI300X: 4 SIMDs per CU on CDNA:"
eq "$(q 'R["amd.com/gpu"], L["amd.com/gpu.vram"], L["amd.com/gpu.cu-count"]' --profile mi300x --partition dpx_nps2)" "16 96G 152" "MI300X DPX + NPS2: 2 devices of 96 GB and 152 CUs per GPU (AMD's guide):"
eq "$(q 'R["amd.com/gpu"], L["amd.com/gpu.vram"], L["amd.com/gpu.cu-count"]' --profile mi300x --partition cpx_nps4)" "64 24G 38" "MI300X CPX + NPS4: 8 devices of 24 GB and 38 CUs per GPU (AMD's guide):"
eq "$(q 'R["amd.com/gpu"], L["amd.com/gpu.vram"], L["amd.com/gpu.cu-count"], L["amd.com/gpu.compute-memory-partition"]' --profile mi300x --partition qpx_nps4)" "32 48G 76 qpx_nps4" "MI300X QPX + NPS4: 4 devices of 48 GB and 76 CUs per GPU (AMD SMI guide):"
ok_ python3 "$GEN" --profile mi300x --partition qpx_nps1
no_ python3 "$GEN" --profile mi300x --partition qpx_nps2
no_ python3 "$GEN" --profile mi300x --partition spx_nps4
no_ python3 "$GEN" --profile mi300x --partition cpx_nps2
ok_ python3 "$GEN" --profile mi355x --partition dpx_nps2
no_ python3 "$GEN" --profile mi325x --partition dpx_nps2
no_ python3 "$GEN" --profile mi355x --partition cpx_nps4   # two IODs: no NPS4 on MI350X/MI355X
no_ python3 "$GEN" --profile mi350x --partition qpx_nps4
ok_ python3 "$GEN" --profile mi355x --partition cpx_nps2   # AMD: CPX/NPS2 and QPX/NPS2 on MI350 Series
ok_ python3 "$GEN" --profile mi350x --partition qpx_nps2
no_ python3 "$GEN" --profile mi355x --partition spx_nps2   # never more memory than compute partitions
eq "$(q 'R["amd.com/gpu"], L["amd.com/gpu.vram"], L["amd.com/gpu.cu-count"], L["amd.com/gpu.compute-memory-partition"]' --profile mi355x --partition cpx_nps2)"   "64 36G 32 cpx_nps2" "MI355X CPX + NPS2: 8 devices of 36 GB and 32 CUs per GPU (AMD's MI350 page):"
eq "$(python3 "$GEN" --profile mi355x --partition cpx_nps4 2>&1 >/dev/null)"   "mi355x: CPX with NPS4 is not a valid mode (compute modes SPX, DPX, QPX, CPX; NPS1 with SPX, DPX, QPX, CPX; NPS2 with DPX, QPX, CPX)"   "the error names the GPU's own rules:"
eq "$(q 'R["amd.com/gpu"], L["amd.com/gpu.product-name"], L["amd.com/gpu.device-id"], L["amd.com/gpu.vram"], L["oif.ai/accelerator-fabric"]' --profile mi350p)" \
  "8 AMD_Instinct_MI350P 75a8 144G pcie" "MI350P server: 8 PCIe cards of 144 GB, no xGMI:"
eq "$(q 'R["amd.com/gpu"], L["amd.com/gpu.vram"], L["amd.com/gpu.cu-count"], R.get("amd.com/gpu-mi350p-cpx-nps1")' --profile mi350p --partition cpx_nps1)" "32 36G 32 None" "MI350P in CPX: 4 partitions of 36 GB and 32 CUs per card:"
eq "$(q 'R["amd.com/gpu-mi350p-dpx-nps1"]' --profile mi350p --partition dpx_nps1 --naming product)" "16" "MI350P DPX, product naming:"
no_ python3 "$GEN" --profile mi350p --partition qpx_nps1
no_ python3 "$GEN" --profile mi350p --partition cpx_nps4
no_ python3 "$GEN" --profile w7900 --partition cpx_nps1
no_ python3 "$GEN" --profile mi455x --partition dpx_nps1
ok_ python3 "$GEN" --list
finish
