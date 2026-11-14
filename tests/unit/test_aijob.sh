#!/bin/bash
# T-133 stage aijob: the controller is built and deployed when the cluster has GPUs, removed (with the CRD) otherwise;
# each vendor's pool; what reruns it; the manifest refuses cross-vendor jobs and spec changes and gives the controller
# only what it needs. kubectl and the build are stubbed. The translation is tested in Go (images/oif-aijob).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
OIF_HOME=$ROOT
for f in "$ROOT"/installer/stages/60-runai.sh "$ROOT"/installer/stages/61-vendor-pool.sh "$ROOT"/installer/stages/62-topology.sh \
         "$ROOT"/installer/stages/63-aijob.sh; do
  # shellcheck source=/dev/null
  . "$f" || { echo "      FAIL: cannot load $f"; exit 1; }
done
CALLS=$SANDBOX/calls
kc() { echo "kubectl $*" >> "$CALLS"; case "$*" in *"apply -f -"*) cat > /dev/null ;; esac; return 0; }
go_image_build() { echo "build $1 $3" >> "$CALLS"; }
runai_patch_spread() { echo "spread $1 $2" >> "$CALLS"; }
NV=1; AMD=1; MULTI=yes
gpu_count() { [ "$1" = nvidia ] && echo "$NV" || echo "$AMD"; }
multi_node() { [ "$MULTI" = yes ]; }
run() { rm -f "$CALLS"; ( stage_aijob ) > "$SANDBOX/out" 2>&1; }

order=" ${STAGES[*]} "
[[ $order == *" runai-topology aijob "* ]] || fail "aijob runs right after runai-topology (it reads the AcceleratorDomain view)"

run
grep -q "^build oif-aijob oif.local/oif/oif-aijob:" "$CALLS" || fail "GPUs: controller image built"
grep -q "^spread oif-aijob " "$CALLS" || fail "image copied to the other nodes"
grep -q "kubectl apply -f $OIF_STATE/aijob.yaml" "$CALLS" || fail "manifest applied"
grep -q "rollout status deploy/oif-aijob" "$CALLS" || fail "waits for the controller"
grep -q "pools nvidia=nvidia,amd=amd" "$SANDBOX/out" || fail "several nodes: one pool per vendor"
MULTI=no; eq "$(aijob_pools)" "nvidia=,amd=" "one node: the default pool, no label:"
a=$(aijob_rev); MULTI=yes; b=$(aijob_rev)
[ "$a" != "$b" ] || fail "a change of pools reruns the stage"

NV=0; AMD=0; run
grep -q "^build" "$CALLS" && fail "no GPUs: nothing built"
grep -q "kubectl delete crd aijobs.oif.ai placementpolicies.oif.ai" "$CALLS" || fail "no GPUs: the CRDs (and every AIJob and policy) removed"
grep -q "kubectl delete namespace oif-aijob" "$CALLS" || fail "no GPUs: the controller removed"

out=$(AIJOB_IMAGE=img:x AIJOB_POOLS=nvidia=nvidia,amd=amd SYSTEM_LABEL=node-role.kubernetes.io/runai-system render "$ROOT/platform/kubernetes/aijob.yaml")
grep -q 'rule: "!has(self.allowCrossVendor) || !self.allowCrossVendor"' <<< "$out" || fail "allowCrossVendor: true refused"
grep -q "rule: self == oldSelf" <<< "$out" || fail "the spec cannot change"
grep -q "enum: \[nvidia, amd\]" <<< "$out" || fail "preferVendor is a known vendor"
grep -q "command: \[/oif-aijob, \"--pools=nvidia=nvidia,amd=amd\"" <<< "$out" || fail "the controller gets the pools"
grep -q "rbac.authorization.k8s.io/aggregate-to-edit: \"true\"" <<< "$out" || fail "namespace editors may use AIJobs"
grep -q "{apiGroups: \[batch\], resources: \[jobs\], verbs: \[list, create\]}" <<< "$out" || fail "the controller may only list and create Jobs"
grep -q "privileged\|hostPath" <<< "$out" && fail "the AIJob template offers no privileges or host paths"
grep -q "x-kubernetes-list-type: set" <<< "$out" || fail "PlacementPolicy: no vendor twice in the order"
grep -q "items: {type: string, enum: \[nvidia, amd\]}" <<< "$out" || fail "PlacementPolicy: only known vendors"
role=$(grep -A6 "name: oif-placementpolicy-admin" <<< "$out")
grep -q "aggregate-to-admin" <<< "$role" || fail "namespace admins set the policy"
grep -q "aggregate-to-edit" <<< "$role" && fail "editors do not set the policy"
grep -q "resources: \[aijobs, acceleratordomains, placementpolicies\], verbs: \[list\]" <<< "$out" || fail "the controller only lists policies"
finish
