#!/bin/bash
# Acceptance test for T-128 (hardening after the external review), run on the first node after  sudo ./oif install
# on several nodes with AMD GPU fractions on. Creates and deletes test pods in project team-c's namespace and sets
# team-c's AMD quota to 2 GPUs for the run (1 again at the end); otherwise read-only unless an option says so.
#   sudo tests/lab/t128-hardening.sh                 policy, plugin start log, soft memory, whole and half GPU
#   sudo tests/lab/t128-hardening.sh --image-copy    + another image under the UI's tag on a node: install fixes it
#                                                     and restarts the UI; a second install restarts nothing (slow)
#   sudo tests/lab/t128-hardening.sh --expect-off    after AMD_FRACTIONS=none in .env and  sudo ./oif install
#                                                     --reconfigure: stock KAI, no plugin
#   sudo tests/lab/t128-hardening.sh --redis-restart restart cluster-redis (with a workspace open in a browser)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); OIF_HOME=$ROOT; SELF=$ROOT/oif
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 2; }
# shellcheck source=../../versions.env
. "$ROOT/versions.env"
for f in "$ROOT"/installer/lib/*.sh "$ROOT"/installer/stages/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done
INTERACTIVE=0; TLOG=/dev/null
config_load_saved
multi_node || { echo "T-128 needs a multi-node install (OIF_NODES)"; exit 2; }
MODE=${1:-}

FAILS=0; N=0
check() { N=$((N + 1)); if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi; }
info() { echo "  INFO  $*"; }
refused() { ! "$@"; }   # the command must fail (admission refuses it)
finish_() { echo "T-128: $((N - FAILS))/$N checks passed"; [ "$FAILS" = 0 ]; exit $?; }

# ---------------------------------------------------------------- AMD_FRACTIONS=none: KAI's stock images, no plugin
if [ "$MODE" = --expect-off ]; then
  echo "T-128 AMD GPU fractions off (AMD_FRACTIONS=none)"
  check "RunaiConfig names no patched KAI image" bash -c "! kubectl --kubeconfig $KCFG -n runai get runaiconfig runai -o json | grep -qF '$KAI_PATCH_REGISTRY'"
  check "binder runs KAI's stock image" bash -c "kubectl --kubeconfig $KCFG -n runai get deploy binder -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q '^$KAI_STOCK_REGISTRY/'"
  for d in $(kc -n runai get deploy -o name | sed -n 's|^deployment.apps/\(runai-scheduler-.*\)|\1|p'); do
    check "$d runs KAI's stock image" bash -c "kubectl --kubeconfig $KCFG -n runai get deploy $d -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q '^$KAI_STOCK_REGISTRY/'"
  done
  check "no oif-amd-share plugin (namespace oif-system gone)" bash -c "! kubectl --kubeconfig $KCFG get namespace oif-system"
  check "no annotation policy" bash -c "! kubectl --kubeconfig $KCFG get validatingadmissionpolicy oif-amd-share-annotations"
  tpl=$(runai_api templates); info "templates: $(paste -sd' ' <<< "$tpl" | cut -c1-200)"
  check "no half-GPU AMD templates offered (removed when fractions went off)" refused grep -q rocm-half-gpu <<< "$tpl"
  check "the whole-GPU AMD templates stay" grep -q rocm-1-gpu <<< "$tpl"
  finish_
fi

# ---------------------------------------------------------------- cluster-redis restart (workspace logins, ADR-022)
if [ "$MODE" = --redis-restart ]; then
  echo "T-128 cluster-redis restart: keep a Jupyter workspace open in the browser, then reload it when this finishes"
  kc -n runai delete pod -l app.kubernetes.io/name=cluster-redis --wait=true >/dev/null 2>&1 \
    || kc -n runai get pods -o name | grep cluster-redis | xargs -r kubectl --kubeconfig "$KCFG" -n runai delete --wait=true >/dev/null
  wait_for "cluster-redis back" 300 5 bash -c "kubectl --kubeconfig $KCFG -n runai get pods --no-headers | grep cluster-redis | grep -q '1/1 *Running'"
  check "cluster-redis running again" bash -c "kubectl --kubeconfig $KCFG -n runai get pods --no-headers | grep cluster-redis | grep -q '1/1 *Running'"
  echo "        Now reload the workspace tab: note whether it opens directly or asks you to log in again."
  finish_
fi

# ---------------------------------------------------------------- the same tag with other content on a node
if [ "$MODE" = --image-copy ]; then
  echo "T-128 a node with another image under the patched UI's tag"
  img=$RUNAI_PATCH_REGISTRY/frontend:$RUNAI_VERSION-oif1
  good=$(ctr -n k8s.io images ls | awk -v i="$img" '$1 == i {print $3}')
  read -r name addr _ < <(other_nodes)
  other=$(node_ssh "$addr" "sudo ctr -n k8s.io images ls -q | grep -m1 pause")
  [ -n "$good" ] && [ -n "$other" ] || { echo "  FAIL  cannot find the UI image here or a pause image on $name"; exit 1; }
  node_ssh "$addr" "sudo ctr -n k8s.io images tag --force '$other' '$img'" >/dev/null
  digest_on() { node_ssh "$1" "sudo ctr -n k8s.io images ls | awk -v i='$img' '\$1 == i {print \$3}'"; }
  check "$name holds another image under $img (test set-up)" bash -c "[ '$(digest_on "$addr")' != '$good' ]"
  before=$(kc -n runai-backend get deploy runai-backend-frontend -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}')
  rm -f "$DONE/runai-patches"   # run that stage again (the build is reused; the copy to the nodes runs)
  "$SELF" install > /tmp/t128-install-1.log 2>&1; rc=$?
  check "install with the runai-patches stage again succeeds" [ "$rc" = 0 ]
  check "$name has the patched UI image again" bash -c "[ '$(digest_on "$addr")' = '$good' ]"
  after=$(kc -n runai-backend get deploy runai-backend-frontend -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}')
  check "the UI was restarted (its pods on $name drop what they ran)" [ "$after" != "$before" ]
  check "every UI pod runs and is ready" bash -c "kubectl --kubeconfig $KCFG -n runai-backend rollout status deploy/runai-backend-frontend --timeout=60s"
  "$SELF" install > /tmp/t128-install-2.log 2>&1; rc=$?
  check "a second install succeeds" [ "$rc" = 0 ]
  check "and restarts nothing (UI restart time unchanged)" bash -c "[ \"\$(kubectl --kubeconfig $KCFG -n runai-backend get deploy runai-backend-frontend -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}')\" = '$after' ]"
  echo "        install logs: /tmp/t128-install-1.log, /tmp/t128-install-2.log"
  finish_
fi

# ---------------------------------------------------------------- default: policy, plugin, memory, whole and half GPU
echo "T-128 AMD GPU sharing: guard, plugin, soft memory isolation, whole and half GPU on one node"
NS=$(runai_api project-pools team-c nvidia=1 amd=2)
ROCM=$ROCM_PYTORCH_IMAGE
cleanup() { kc -n "$NS" delete pod -l app.kubernetes.io/part-of=oif-t128 --ignore-not-found --wait=true >/dev/null 2>&1
  kc -n "$NS" delete configmap t128-probe --ignore-not-found >/dev/null 2>&1; }
cleanup
trap 'cleanup; runai_api project-pools team-c nvidia=1 amd=1 >/dev/null 2>&1' EXIT
phase() { kc -n "$NS" get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
logs() { kc -n "$NS" logs "$1" 2>/dev/null; }

# the probes: a pod that keeps to its share, and one that lifts PyTorch's cap and takes what it can
kc -n "$NS" apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: {name: t128-probe}
data:
  polite.py: |
    import os, time, torch
    print("share", os.environ.get("OIF_GPU_MEMORY_FRACTION"), "cap", os.environ.get("PYTORCH_ALLOC_CONF"), flush=True)
    x = torch.empty(20 * 2**30 // 2, dtype=torch.float16, device="cuda")
    print("HOLDING 20 GiB", flush=True)
    while True:
        try:
            y = torch.empty(2**30 // 2, dtype=torch.float16, device="cuda"); del y; ok = "ok"
        except torch.OutOfMemoryError:
            ok = "REFUSED"
        print("one more GiB inside my share:", ok, flush=True); time.sleep(10)
  greedy.py: |
    import os, time, torch
    torch.cuda.set_per_process_memory_fraction(1.0)   # ignores the share oif set
    held, step = [], 2**30
    while True:
        try:
            held.append(torch.empty(step // 2, dtype=torch.float16, device="cuda"))
        except torch.OutOfMemoryError:
            break
    print("GREEDY HOLDS %d GiB (share 0.5 of %.0f GiB)" % (len(held), torch.cuda.mem_get_info()[1] / 2**30), flush=True)
    time.sleep(3600)
EOF
half_pod() {   # name script
  kc -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  labels: {runai/node-pool: amd, app.kubernetes.io/part-of: oif-t128}
  annotations: {gpu-fraction: "0.5"}
spec:
  schedulerName: runai-scheduler
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
    - {name: main, image: $ROCM, command: [python3, -u, /probe/$2], volumeMounts: [{name: probe, mountPath: /probe}]}
  volumes: [{name: probe, configMap: {name: t128-probe}}]
EOF
}
whole_pod() {   # name
  kc -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  labels: {runai/node-pool: amd, app.kubernetes.io/part-of: oif-t128}
spec:
  schedulerName: runai-scheduler
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
    - {name: main, image: $ROCM, command: [sleep, "3600"], resources: {limits: {amd.com/gpu: 1}}}
EOF
}

# 1. the plugin finds the GPU at start
AMD_NODE=$(amd_only_nodes | head -1)
plog=$(kc -n oif-system logs "$(kc -n oif-system get pods --field-selector "spec.nodeName=$AMD_NODE" -o jsonpath='{.items[0].metadata.name}')" 2>/dev/null)
check "oif-amd-share on $AMD_NODE lists its AMD GPU at start" grep -qE 'AMD GPUs on this node: [0-9a-f]{4}:' <<< "$plog"
info "$(grep -m1 'AMD GPUs on this node\|WARNING' <<< "$plog")"
tpl=$(runai_api templates)
check "the half-GPU AMD templates are offered" bash -c "grep -q '^pytorch-rocm-half-gpu ' <<< '$tpl' && grep -q '^jupyter-lab-rocm-half-gpu ' <<< '$tpl'"

# 2. soft memory isolation: a pod that keeps to its share next to one that does not
half_pod t128-polite polite.py
wait_for "t128-polite holds 20 GiB" 600 5 bash -c "kubectl --kubeconfig $KCFG -n $NS logs t128-polite 2>/dev/null | grep -q 'HOLDING 20 GiB'" >/dev/null
check "a half-GPU pod holds 20 GiB of its 22.5 GiB share" grep -q 'HOLDING 20 GiB' <<< "$(logs t128-polite)"
check "it can take one more GiB while alone" bash -c "kubectl --kubeconfig $KCFG -n $NS logs t128-polite | grep -q 'inside my share: ok'"
half_pod t128-greedy greedy.py
wait_for "t128-greedy done allocating" 600 5 bash -c "kubectl --kubeconfig $KCFG -n $NS logs t128-greedy 2>/dev/null | grep -q 'GREEDY HOLDS'" >/dev/null
sleep 25
info "$(logs t128-greedy | grep 'GREEDY HOLDS')"
info "the first pod now: $(logs t128-polite | tail -1)"
check "soft limit shown: a pod that lifts PyTorch's cap takes more than its share" \
  bash -c "kubectl --kubeconfig $KCFG -n $NS logs t128-greedy | awk '/GREEDY HOLDS/ { f = \$3 > \$6 * \$8 } END { exit !f }'"
echo "        (expected with soft isolation: the greedy pod takes the free memory; the first may be refused inside its share)"

# 3. the annotation guard: only KAI's binder names a GPU for a pod
binder="system:serviceaccount:runai:$(kc -n runai get deploy binder -o jsonpath='{.spec.template.spec.serviceAccountName}')"
check "the policy allows exactly the binder's account ($binder)" bash -c "kubectl --kubeconfig $KCFG get validatingadmissionpolicy oif-amd-share-annotations -o jsonpath='{.spec.validations[0].expression}' | grep -qF \"'$binder'\""
pod_json=$(kc -n "$NS" get pod t128-polite -o json)
gpu=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["metadata"]["annotations"].get("oif.ai/amd-gpu", ""))' <<< "$pod_json")
check "the binder named the GPU on the half-GPU pod ($gpu)" [ -n "$gpu" ]
check "a new pod with oif.ai/amd-gpu is refused" refused bash -c "kubectl --kubeconfig $KCFG -n $NS run t128-sneak --image=$BUSYBOX_IMAGE --restart=Never --dry-run=server --annotations=oif.ai/amd-gpu=$gpu -- sleep 1"
check "changing the GPU on a running pod is refused" refused kc -n "$NS" annotate pod t128-polite --overwrite --dry-run=server "oif.ai/amd-gpu=0000:ff:00.0"
check "changing its share is refused" refused kc -n "$NS" annotate pod t128-polite --overwrite --dry-run=server "oif.ai/amd-gpu-fraction=1"
check "removing the GPU annotation is refused" refused kc -n "$NS" annotate pod t128-polite --dry-run=server "oif.ai/amd-gpu-"
check "adding another oif.ai/amd-gpu* annotation is refused" refused kc -n "$NS" annotate pod t128-polite --dry-run=server "oif.ai/amd-gpu-container=other"
check "other annotations still change freely" kc -n "$NS" annotate pod t128-polite --overwrite --dry-run=server "oif.ai/t128-note=fine"

# 4. a whole GPU and a half on the one AMD GPU: never both (team-c has 2 AMD GPUs of quota for this run)
kc -n "$NS" delete pod t128-greedy --wait=true >/dev/null 2>&1
whole_pod t128-whole
sleep 60
check "a whole AMD GPU waits while a half is in use" [ "$(phase t128-whole)" = Pending ]
info "t128-whole: $(kc -n "$NS" get events --field-selector involvedObject.name=t128-whole -o jsonpath='{.items[-1:].message}' 2>/dev/null | cut -c1-160)"
kc -n "$NS" delete pod t128-polite --wait=true >/dev/null 2>&1
wait_for "t128-whole runs once the half is gone" 300 5 bash -c "[ \"\$(kubectl --kubeconfig $KCFG -n $NS get pod t128-whole -o jsonpath='{.status.phase}')\" = Running ]" >/dev/null
check "the whole GPU runs once the half is gone" [ "$(phase t128-whole)" = Running ]
half_pod t128-half polite.py
sleep 60
check "a half waits while the whole GPU is in use" [ "$(phase t128-half)" = Pending ]
info "t128-half: $(kc -n "$NS" get events --field-selector involvedObject.name=t128-half -o jsonpath='{.items[-1:].message}' 2>/dev/null | cut -c1-160)"
kc -n "$NS" delete pod t128-whole --wait=true >/dev/null 2>&1
wait_for "t128-half runs once the whole GPU is free" 300 5 bash -c "[ \"\$(kubectl --kubeconfig $KCFG -n $NS get pod t128-half -o jsonpath='{.status.phase}')\" = Running ]" >/dev/null
check "the half runs once the whole GPU is free" [ "$(phase t128-half)" = Running ]
finish_
