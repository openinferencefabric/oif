#!/bin/bash
# T-132 stage runai-topology: which node pools get network topology oif-accelerator, and runai_api.py network-topology
# against a stubbed Run:ai API (create, link the pools, recreate when the levels change, nothing when up to date,
# delete unlinks first; a PATCH always carries networkTopologyId, since Run:ai clears it when the field is missing).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
OIF_HOME=$ROOT
for f in "$ROOT"/installer/stages/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done
NV=1; AMD=1
gpu_count() { case "$1" in nvidia) echo "$NV" ;; amd) echo "$AMD" ;; esac; }
OIF_NODES="cp1=192.0.2.11:control"; eq "$(runai_topology_pools)" "amd,nvidia" "several nodes, both vendors: both pools:"
AMD=0; eq "$(runai_topology_pools)" "nvidia" "NVIDIA only:"
OIF_NODES=""; AMD=1; eq "$(runai_topology_pools)" "default" "one node: the default pool:"
NV=0; AMD=0; eq "$(runai_topology_pools)" "" "no GPU: none:"
OIF_NODES="cp1=192.0.2.11:control"; NV=1; AMD=0; a=$(runai_topology_rev); AMD=1; b=$(runai_topology_rev)
[ "$a" != "$b" ] || fail "a new vendor's pool reruns the stage"
eq "${RUNAI_TOPOLOGY_LEVELS[*]}" "oif.ai/scaleout-zone oif.ai/accelerator-domain kubernetes.io/hostname" "levels, top first:"

api() {   # scenario: what the stubbed server holds; prints the calls that change something
  RUNAI_URL=https://x PYTHONPATH="$ROOT/installer/tools" python3 - "$@" <<'PY'
import json, sys, runai_api as r
LEVELS = ["oif.ai/scaleout-zone", "oif.ai/accelerator-domain", "kubernetes.io/hostname"]
scenario = sys.argv[1]
pools = [{"id": "p1", "name": "nvidia", "networkTopologyId": None}, {"id": "p2", "name": "amd", "networkTopologyId": None},
         {"id": "p0", "name": "default", "networkTopologyId": None}]
tops = []
if scenario in ("same", "changed", "delete"):
    tops.append({"id": "t1", "name": "oif-accelerator", "phase": "Ready", "levels": LEVELS if scenario != "changed" else LEVELS[1:]})
    pools[0]["networkTopologyId"] = pools[1]["networkTopologyId"] = "t1"
calls = []
def call(method, path, body=None, token=None):
    if method == "GET":
        if path.startswith("/api/v1/network-topologies"):
            return 200, {"networkTopologies": tops}
        if path.startswith("/api/v1/node-pools"):
            return 200, {"nodePools": pools}
        if path == "/api/v1/clusters":
            return 200, [{"uuid": "c1"}]
    calls.append(f"{method} {path} {json.dumps(body, sort_keys=True) if body is not None else ''}".strip())
    if method == "POST":
        tops.append({"id": "t2", "name": body["name"], "phase": "Ready", "levels": body["levels"]})
    elif method == "DELETE":
        tops[:] = [t for t in tops if not path.endswith(t["id"])]
    elif method == "PATCH":
        next(p for p in pools if path.endswith(p["id"]))["networkTopologyId"] = body["networkTopologyId"]
    return 202, {}
r.call = call
if scenario == "delete":
    r.network_topology_delete("t", "oif-accelerator")
else:
    r.network_topology("t", "oif-accelerator", ["nvidia", "amd"], LEVELS)
print("|".join(calls))
PY
}
eq "$(api new | tail -1)" \
  'POST /api/v1/network-topologies {"clusterId": "c1", "levels": ["oif.ai/scaleout-zone", "oif.ai/accelerator-domain", "kubernetes.io/hostname"], "name": "oif-accelerator"}|PATCH /api/v1/node-pools/p1 {"networkTopologyId": "t2"}|PATCH /api/v1/node-pools/p2 {"networkTopologyId": "t2"}' \
  "new: created, the GPU pools linked, default untouched:"
eq "$(api same | tail -1)" "" "up to date: no change:"
eq "$(api changed | tail -1)" \
  'PATCH /api/v1/node-pools/p1 {"networkTopologyId": null}|PATCH /api/v1/node-pools/p2 {"networkTopologyId": null}|DELETE /api/v1/network-topologies/t1|POST /api/v1/network-topologies {"clusterId": "c1", "levels": ["oif.ai/scaleout-zone", "oif.ai/accelerator-domain", "kubernetes.io/hostname"], "name": "oif-accelerator"}|PATCH /api/v1/node-pools/p1 {"networkTopologyId": "t2"}|PATCH /api/v1/node-pools/p2 {"networkTopologyId": "t2"}' \
  "levels changed: unlinked, deleted, recreated, linked again:"
eq "$(api delete | tail -1)" \
  'PATCH /api/v1/node-pools/p1 {"networkTopologyId": null}|PATCH /api/v1/node-pools/p2 {"networkTopologyId": null}|DELETE /api/v1/network-topologies/t1' \
  "delete: pools unlinked first:"

CALLS=$SANDBOX/calls
runai_api() { echo "runai_api $*" >> "$CALLS"; echo "network topology ok"; }
kc() { echo "kubectl $*" >> "$CALLS"; }
wait_for() { shift 3; "$@"; }
NV=1; AMD=1; rm -f "$CALLS"; ( stage_runai_topology ) > "$SANDBOX/out" 2>&1 || fail "stage failed: $(cat "$SANDBOX/out")"
grep -qxF "runai_api network-topology oif-accelerator amd,nvidia oif.ai/scaleout-zone oif.ai/accelerator-domain kubernetes.io/hostname" "$CALLS" \
  || fail "GPUs: topology set on the GPU pools ($(cat "$CALLS"))"
grep -q "kubectl get topologies.kai.scheduler oif-accelerator" "$CALLS" || fail "waits for the KAI Topology"
NV=0; AMD=0; rm -f "$CALLS"; ( stage_runai_topology ) > "$SANDBOX/out" 2>&1
grep -qxF "runai_api network-topology-delete oif-accelerator" "$CALLS" || fail "no GPUs: topology deleted"
finish
