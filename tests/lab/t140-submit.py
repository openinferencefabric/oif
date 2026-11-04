"""T-140 lab helper: submit one training to team-c through the Run:ai API as the patched form does, report where its
pod runs, delete it. Uses installer/tools/runai_api.py (credentials in the environment, never printed).
  presets                       oif's compute presets (names)
  run NAME COMPUTE-JSON POOL    submit, wait up to 4 min for Running, print phase/node/gpus, delete
  refused NAME COMPUTE-JSON POOL  submit, expect no pod and the oif-vendor-pool refusal, delete
  cleanup                       delete every t140-* training
"""
import json
import os
import subprocess
import sys
import time

import runai_api as r

NS = os.environ["NS"]


def kc(*args: str) -> str:
    return subprocess.run(["kubectl", "--kubeconfig", "/etc/kubernetes/admin.conf", *args],
                          capture_output=True, text=True).stdout


def token_project() -> tuple:
    t = r.login()
    _, projs = r.call("GET", "/api/v1/org-unit/projects", token=t)
    proj = next(p for p in projs["projects"] if p["name"] == "team-c")
    return t, proj


def submit(t: str, proj: dict, name: str, compute: str, pool: str) -> None:
    body = {"name": name, "projectId": str(proj["id"]), "clusterId": proj["clusterId"],
            "spec": {"image": os.environ["BUSYBOX"], "command": "sleep", "args": "900",
                     "compute": json.loads(compute), "nodePools": [pool]}}
    st, out = r.call("POST", "/api/v1/workloads/trainings", body, token=t)
    if st not in (200, 201, 202):
        sys.exit(f"submit {name}: HTTP {st} {out}")


def delete(t: str, name: str) -> None:
    """Delete the training and wait until Run:ai no longer lists it (its pods can go before the workload does)."""
    for _ in range(24):
        _, out = r.call("GET", "/api/v1/workloads", token=t)
        left = [w for w in (out or {}).get("workloads", []) if w["name"] == name]
        if not left:
            break
        for w in left:
            st, res = r.call("DELETE", f"/api/v1/workloads/trainings/{w['id']}", token=t)
            if st not in (200, 202, 204, 404):
                print(f"delete {name}: HTTP {st} {str(res)[:200]}")
        time.sleep(5)
    else:
        print(f"delete {name}: still listed by Run:ai after 2 min")
    for _ in range(36):
        if not [p for p in kc("-n", NS, "get", "pods", "-o", "name").split() if f"/{name}-" in p]:
            return
        time.sleep(5)


def pod_of(name: str) -> dict | None:
    pods = [p for p in kc("-n", NS, "get", "pods", "-o", "name").split() if f"/{name}-" in p]
    return json.loads(kc("-n", NS, "get", pods[0], "-o", "json")) if pods else None


def main() -> None:
    cmd = sys.argv[1]
    if cmd == "presets":
        t = r.login()
        _, out = r.call("GET", "/api/v1/asset/compute", token=t)
        print(" ".join(sorted(e["meta"]["name"] for e in out.get("entries", [])
                              if (e["meta"].get("description") or "").startswith("oif:"))))
    elif cmd == "cleanup":
        t = r.login()
        _, out = r.call("GET", "/api/v1/workloads", token=t)
        for w in (out or {}).get("workloads", []):
            if w["name"].startswith("t140-"):
                delete(t, w["name"])
                print(f"deleted {w['name']}")
    elif cmd == "run":
        name, compute, pool = sys.argv[2:5]
        t, proj = token_project()
        submit(t, proj, name, compute, pool)
        p = None
        for _ in range(48):
            time.sleep(5)
            p = pod_of(name)
            if p and p["status"].get("phase") == "Running":
                break
        if p:
            a = p["metadata"].get("annotations", {})
            gpus = a.get("runai-allocated-gpus", "")
            if gpus and "." in gpus:   # two decimals are enough to tell the sizes apart
                gpus = f"{float(gpus):.2f}".rstrip("0").rstrip(".")
            print(f"phase={p['status'].get('phase')} node={p['spec'].get('nodeName')} gpus={gpus} "
                  f"memory={a.get('runai-allocated-gpu-memory')} limits={[c.get('resources', {}).get('limits') for c in p['spec']['containers']]}")
            for c in p["status"].get("conditions", []):
                if c.get("status") != "True":
                    print(f"{c.get('type')} {c.get('reason')}: {(c.get('message') or '')[:200]}")
        else:
            print("phase=none (no pod)")
        delete(t, name)
    elif cmd == "refused":
        name, compute, pool = sys.argv[2:5]
        t, proj = token_project()
        submit(t, proj, name, compute, pool)
        time.sleep(40)
        events = kc("-n", NS, "get", "events", "--sort-by=.lastTimestamp", "-o", "custom-columns=MSG:.message")
        refusal = [e for e in events.splitlines() if "oif-vendor-pool" in e and "AMD" in e]
        print(f"pod={'yes' if pod_of(name) else 'none'} refused={'yes' if refusal and not pod_of(name) else 'no'}")
        if refusal:
            print(refusal[-1][:300])
        delete(t, name)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
