#!/bin/bash
# T-140 compute presets: which vendors' presets a cluster gets, and runai_api.py compute-presets against a stubbed
# Run:ai API (create, update only on a change, delete only oif's presets of other vendors).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
OIF_HOME=$ROOT
for f in "$ROOT"/installer/stages/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done
NV=1; AMD=1; AMD_ONLY=gpu-amd
gpu_count() { case "$1" in nvidia) echo "$NV" ;; amd) echo "$AMD" ;; esac; }
amd_only_nodes() { echo "$AMD_ONLY"; }
AMD_FRACTIONS=""; eq "$(preset_kinds)" "nvidia amd amd-fractions" "both vendors, AMD fractions on:"
AMD_FRACTIONS=none; eq "$(preset_kinds)" "nvidia amd" "AMD_FRACTIONS=none: whole AMD GPUs only:"
AMD_FRACTIONS=""; AMD_ONLY=""; eq "$(preset_kinds)" "nvidia amd" "no AMD-only node: whole AMD GPUs only:"
NV=0; AMD=0; eq "$(preset_kinds)" "" "no GPU:"
NV=1; AMD=0; a=$(runai_presets_rev); AMD=1; b=$(runai_presets_rev)
[ "$a" != "$b" ] || fail "a new vendor reruns the stage"

python3 -c 'import json, sys; [json.loads(open(sys.argv[1]).read())]' "$ROOT/platform/runai/compute-presets.json" || fail "presets file is JSON"
eq "$(python3 - "$ROOT/platform/runai/compute-presets.json" <<'PY'
import json, re, sys
ps = json.load(open(sys.argv[1]))
bad = [p["meta"]["name"] for p in ps if not re.fullmatch(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?", p["meta"]["name"])
       or not p["meta"]["description"].startswith("oif: ") or not p["meta"]["name"].startswith(p["vendor"].split("-")[0] + "-")]
amd_whole = next(p for p in ps if p["meta"]["name"] == "amd-1-gpu")["spec"]
print(bad, amd_whole["gpuDevicesRequest"], amd_whole["extendedResources"])
PY
)" "[] 0 [{'resource': 'amd.com/gpu', 'quantity': '1'}]" "names, descriptions, the whole AMD GPU as amd.com/gpu:"

out=$(RUNAI_URL=https://x PYTHONPATH="$ROOT/installer/tools" python3 - "$ROOT/platform/runai/compute-presets.json" <<'PY'
import json, sys, runai_api as r
calls = []
have = [  # on the server: one current, one outdated, one oif preset of a vendor gone, one of the user's own
    {"meta": {"id": "1", "name": "nvidia-1-gpu", "description": "oif: NVIDIA, 1 whole GPU (node pool nvidia)"}, "spec": {"gpuDevicesRequest": 1}},
    {"meta": {"id": "2", "name": "nvidia-half-gpu", "description": "oif: old"}, "spec": {"gpuDevicesRequest": 1}},
    {"meta": {"id": "3", "name": "amd-1-gpu", "description": "oif: AMD"}, "spec": {}},
    {"meta": {"id": "4", "name": "my-preset", "description": "mine"}, "spec": {}},
]
def call(method, path, body=None, token=None):
    calls.append((method, path, (body or {}).get("meta", {}).get("name"), (body or {}).get("meta", {}).get("scope")))
    return (200, {"entries": have}) if method == "GET" else (202, {})
r.call = call
r.compute_presets("t", sys.argv[1], ["nvidia"])
print(json.dumps(calls[1:]))
PY
)
out=$(tail -1 <<< "$out")
eq "$(python3 -c 'import json,sys; print([c[0]+" "+c[1]+" "+str(c[2])+" "+str(c[3]) for c in json.loads(sys.argv[1])])' "$out")" \
  "['PUT /api/v1/asset/compute/2 nvidia-half-gpu None', 'POST /api/v1/asset/compute nvidia-quarter-gpu tenant', 'POST /api/v1/asset/compute nvidia-12gb tenant', 'DELETE /api/v1/asset/compute/3 None None']" \
  "nvidia only: current kept, outdated updated, missing created (tenant), AMD's removed, the user's own left:"
finish
