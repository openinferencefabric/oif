"""T-132 lab helper: submit one training to team-c through the Run:ai API, report where its pod runs and the topology
KAI got (pod annotations and the pod group's topologyConstraint), delete it. Uses installer/tools/runai_api.py
(credentials in the environment, never printed).
  run NAME POOL COMPUTE-JSON [REQUIRED-LEVEL]   submit (with kai.scheduler/topology-required-placement=REQUIRED-LEVEL
                                                and kai.scheduler/topology=oif-accelerator when given: Run:ai adds
                                                its topology only to workloads without kai.scheduler/ annotations, and
                                                KAI ignores a required level without a topology), wait up to 4 min for
                                                Running, print, delete
  cleanup                                       delete every t132-* training
"""
import json
import os
import subprocess
import sys
import time

import runai_api as r

NS = os.environ["NS"]
REQUIRED = "kai.scheduler/topology-required-placement"


def kc(*args: str) -> str:
    return subprocess.run(["kubectl", "--kubeconfig", "/etc/kubernetes/admin.conf", *args],
                          capture_output=True, text=True).stdout


def delete(t: str, name: str) -> None:
    for _ in range(24):
        _, out = r.call("GET", "/api/v1/workloads", token=t)
        left = [w for w in (out or {}).get("workloads", []) if w["name"] == name]
        if not left:
            break
        for w in left:
            r.call("DELETE", f"/api/v1/workloads/trainings/{w['id']}", token=t)
        time.sleep(5)
    for _ in range(36):
        if not [p for p in kc("-n", NS, "get", "pods", "-o", "name").split() if f"/{name}-" in p]:
            return
        time.sleep(5)


def pod_of(name: str) -> dict | None:
    pods = [p for p in kc("-n", NS, "get", "pods", "-o", "name").split() if f"/{name}-" in p]
    return json.loads(kc("-n", NS, "get", pods[0], "-o", "json")) if pods else None


def main() -> None:
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    t = r.login()
    if cmd == "cleanup":
        _, out = r.call("GET", "/api/v1/workloads", token=t)
        for w in (out or {}).get("workloads", []):
            if w["name"].startswith("t132-"):
                delete(t, w["name"])
                print(f"deleted {w['name']}")
    elif cmd == "run" and len(sys.argv) in (5, 6):
        name, pool, compute = sys.argv[2:5]
        _, projs = r.call("GET", "/api/v1/org-unit/projects", token=t)
        proj = next(p for p in projs["projects"] if p["name"] == "team-c")
        spec = {"image": os.environ["BUSYBOX"], "command": "sleep", "args": "900", "compute": json.loads(compute), "nodePools": [pool]}
        if len(sys.argv) == 6:
            spec["annotations"] = [{"name": "kai.scheduler/topology", "value": "oif-accelerator"},
                                   {"name": REQUIRED, "value": sys.argv[5]}]
        body = {"name": name, "projectId": str(proj["id"]), "clusterId": proj["clusterId"], "spec": spec}
        st, out = r.call("POST", "/api/v1/workloads/trainings", body, token=t)
        if st not in (200, 201, 202):
            sys.exit(f"submit {name}: HTTP {st} {out}")
        p = None
        for _ in range(48):
            time.sleep(5)
            p = pod_of(name)
            if p and p["status"].get("phase") == "Running":
                break
        if not p:
            print("phase=none (no pod)")
        else:
            a = p["metadata"].get("annotations", {})
            pg = json.loads(kc("-n", NS, "get", "podgroups.scheduling.run.ai", a.get("pod-group-name", "-"), "-o", "json") or "{}")
            tc = (pg.get("spec") or {}).get("topologyConstraint") or {}
            print(f"phase={p['status'].get('phase')} node={p['spec'].get('nodeName')} "
                  f"topology={a.get('kai.scheduler/topology', '-')} preferred={a.get('kai.scheduler/topology-preferred-placement', '-')} "
                  f"required={a.get(REQUIRED, '-')} pg-topology={tc.get('topology', '-')} "
                  f"pg-preferred={tc.get('preferredTopologyLevel', '-')} pg-required={tc.get('requiredTopologyLevel', '-')}")
        delete(t, name)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
