#!/bin/bash
# T-138 Thanos receive on three control-plane nodes: the repair of a cluster installed without the chart's headless
# service (hashring 127.0.0.1 alone, every remote write refused), and nothing done on a repaired one. kubectl is
# stubbed with the objects as the Bitnami chart 16.0.7 renders them; the calls and the objects sent are recorded.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
OIF_HOME=$ROOT
for f in "$ROOT"/installer/stages/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done
CALLS=$SANDBOX/calls; FIX=$SANDBOX/fix; mkdir -p "$FIX"
ROLLED="2,2,3,3,3,rev-new,rev-new"   # generation, observed, replicas, updated, ready, current and update revision
kc() {
  local last=${*: -1}
  echo "kubectl $*" >> "$CALLS"
  case "$*" in
    *"jsonpath={.spec.replicas}"*) echo 3 ;;
    *"jsonpath={.metadata.generation}"*) echo "$ROLLED" ;;
    *"get sts runai-backend-thanos-receive -o json") cat "$FIX/sts.json" ;;
    *"get svc runai-backend-thanos-receive -o json") cat "$FIX/svc.json" ;;
    *"get configmap runai-backend-thanos-receive -o json") cat "$FIX/cm.json" ;;
    *"apply -f "*) cp "$last" "$SANDBOX/sent-headless.json" ;;
    *"--patch-file "*) cp "$last" "$SANDBOX/sent-cm.json" ;;
    *"create -f "*) cp "$last" "$SANDBOX/sent-sts.json" ;;
  esac
  return 0
}
stock() {   # the receive objects before T-138: no headless service, ring 127.0.0.1, local endpoint 127.0.0.1
  cat > "$FIX/sts.json" <<'EOF'
{"apiVersion": "apps/v1", "kind": "StatefulSet",
 "metadata": {"name": "runai-backend-thanos-receive", "namespace": "runai-backend", "uid": "u1", "resourceVersion": "9",
              "labels": {"app.kubernetes.io/component": "receive", "app.kubernetes.io/managed-by": "Helm"}},
 "spec": {"replicas": 3, "serviceName": "runai-backend-thanos-receive",
          "selector": {"matchLabels": {"app.kubernetes.io/component": "receive"}},
          "template": {"spec": {"containers": [{"name": "receive", "args": ["receive", "--label=replica=\"$(NAME)\"",
              "--receive.local-endpoint=127.0.0.1:10901", "--receive.hashrings-file=/var/lib/thanos-receive/hashrings.json",
              "--receive.replication-factor=3"],
            "ports": [{"name": "grpc", "containerPort": 10901}, {"name": "http", "containerPort": 10902},
                      {"name": "remote-write", "containerPort": 19291}, {"name": "capnproto", "containerPort": 19391}]}]}}},
 "status": {"replicas": 3}}
EOF
  echo '{"metadata": {"name": "runai-backend-thanos-receive", "labels": {"app.kubernetes.io/component": "receive"}}, "spec": {"selector": {"app.kubernetes.io/component": "receive", "app.kubernetes.io/name": "thanos"}}}' > "$FIX/svc.json"
  echo '{"data": {"hashrings.json": "[{\"endpoints\": [{\"address\": \"127.0.0.1:10901\", \"capnproto_address\": \"127.0.0.1:19391\"}]}]"}}' > "$FIX/cm.json"
}
run() { rm -f "$CALLS" "$SANDBOX"/sent-*.json; thanos_receive_ring > "$SANDBOX/out" 2>&1 || fail "thanos_receive_ring failed: $(cat "$SANDBOX/out")"; }
q() { python3 -c "import json, sys; d = json.load(open(sys.argv[1])); print($2)" "$1"; }

stock; run
eq "$(q "$SANDBOX/sent-headless.json" 'd["metadata"]["name"], d["spec"]["clusterIP"], sorted(d["spec"]["selector"].items()), [p["name"] + ":" + str(p["port"]) for p in d["spec"]["ports"]]')" \
  "runai-backend-thanos-receive-headless None [('app.kubernetes.io/component', 'receive'), ('app.kubernetes.io/name', 'thanos')] ['http:10902', 'grpc:10901', 'capnproto:19391']" \
  "headless service, the receivers' selector and ports:"
eq "$(q "$SANDBOX/sent-cm.json" '[e["address"] for e in json.loads(d["data"]["hashrings.json"])[0]["endpoints"]]')" \
  "['runai-backend-thanos-receive-0.runai-backend-thanos-receive-headless.runai-backend.svc.cluster.local:10901', 'runai-backend-thanos-receive-1.runai-backend-thanos-receive-headless.runai-backend.svc.cluster.local:10901', 'runai-backend-thanos-receive-2.runai-backend-thanos-receive-headless.runai-backend.svc.cluster.local:10901']" \
  "hashring lists the three receivers:"
eq "$(q "$SANDBOX/sent-sts.json" 'd["spec"]["serviceName"], [a for a in d["spec"]["template"]["spec"]["containers"][0]["args"] if "local-endpoint" in a], sorted(d["metadata"]), "status" in d')" \
  "runai-backend-thanos-receive-headless ['--receive.local-endpoint=\$(NAME).runai-backend-thanos-receive-headless.\$(NAMESPACE).svc.cluster.local:10901'] ['labels', 'name', 'namespace'] False" \
  "StatefulSet on the headless service, each receiver its own endpoint, no server fields:"
grep -q "delete sts runai-backend-thanos-receive --cascade=orphan" "$CALLS" || fail "StatefulSet re-created without deleting its pods"
grep -q "jsonpath={.metadata.generation}" "$CALLS" || fail "waits for the receivers"
# the wait: a just re-created StatefulSet (no status yet) or one still replacing its pods is not done
ROLLED="1,,3,,,,"; no_ thanos_receive_rolled
ROLLED="2,2,3,1,3,rev-old,rev-new"; no_ thanos_receive_rolled
ROLLED="2,2,3,3,2,rev-new,rev-new"; no_ thanos_receive_rolled
ROLLED="2,1,3,3,3,rev-new,rev-new"; no_ thanos_receive_rolled
ROLLED="2,2,3,3,3,rev-new,rev-new"; ok_ thanos_receive_rolled

# a repaired cluster (or one installed with the chart value): the service is applied again, nothing else changes
cp "$SANDBOX/sent-sts.json" "$FIX/sts.json"
python3 -c 'import json, sys; c = json.load(open(sys.argv[1])); print(json.dumps({"data": c["data"]}))' "$SANDBOX/sent-cm.json" > "$FIX/cm.json"
run
[ -e "$SANDBOX/sent-cm.json" ] && fail "repaired: hashring patched again"
grep -q "delete sts" "$CALLS" && fail "repaired: StatefulSet re-created again"
grep -q "apply -f " "$CALLS" || fail "repaired: headless service applied (idempotent)"
grep -q "every receiver in the hashring (3 copies" "$SANDBOX/out" || fail "reports the receivers"
finish
