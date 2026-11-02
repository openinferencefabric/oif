#!/bin/bash
# T-201 Dynamo platform stage: when it installs, when it removes, what reruns it, and that oif's values keep Grove and
# Dynamo's bundled KAI off. Helm and kubectl are stubbed; the calls are recorded.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
OIF_HOME=$ROOT
# shellcheck source=../../installer/stages/85-dynamo.sh
. "$ROOT/installer/stages/85-dynamo.sh"
CALLS=$SANDBOX/calls
hl() { echo "helm $*" >> "$CALLS"; case " $* " in *" status "*) [ -f "$SANDBOX/installed" ] ;; esac; }
kc() { echo "kubectl $*" >> "$CALLS"; case "$*" in *"get dynamographdeployments"*) echo "team-c s4-qwen" ;; *"get deploy,statefulset"*) cat "$SANDBOX/workloads" 2>/dev/null ;; esac; return 0; }
fetch_pinned() { echo "fetch $1 $2" >> "$CALLS"; : > "$3"; }
NVIDIA=1; gpu_count() { [ "$1" = nvidia ] && echo "$NVIDIA" || echo 0; }
run() { rm -f "$CALLS"; ( stage_dynamo ) >/dev/null 2>&1; }

ok_ v_patches ""
ok_ v_patches all
ok_ v_patches none
no_ v_patches off

DYNAMO=""; run
grep -q "fetch https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-$DYNAMO_VERSION.tgz $DYNAMO_PLATFORM_SHA256" "$CALLS" \
  || fail "chart fetched from NGC with the pinned checksum"
grep -q "helm upgrade --install dynamo-platform .* -n dynamo-system .*platform/dynamo/values.yaml" "$CALLS" \
  || fail "installed (or takes over S-4's hand install) as release dynamo-platform in dynamo-system with oif's values"
eq "$(grep -c 'kubectl get crd dynamo.*\.nvidia\.com' "$CALLS")" 6 "all six CRDs checked:"

echo "deployment.apps/dynamo-platform-kai-scheduler" > "$SANDBOX/workloads"
no_ run   # Dynamo's own scheduler running is an error
rm -f "$SANDBOX/workloads"

NVIDIA=0; run
grep -q "helm upgrade" "$CALLS" && fail "no NVIDIA GPU: not installed"
NVIDIA=1

DYNAMO=none; touch "$SANDBOX/installed"; run
grep -q "helm uninstall dynamo-platform -n dynamo-system" "$CALLS" || fail "DYNAMO=none: release removed"
eq "$(grep -c 'kubectl delete crd dynamo.*\.nvidia\.com --ignore-not-found' "$CALLS")" 6 "DYNAMO=none: the six CRDs deleted:"
grep -q "kubectl delete namespace dynamo-system --ignore-not-found" "$CALLS" || fail "DYNAMO=none: namespace deleted"
grep -q "helm upgrade" "$CALLS" && fail "DYNAMO=none: nothing installed"
rm -f "$SANDBOX/installed"; run
grep -q "helm uninstall" "$CALLS" && fail "DYNAMO=none and nothing installed: no helm uninstall"

DYNAMO=""; a=$(dynamo_rev); DYNAMO=none; b=$(dynamo_rev); DYNAMO_VERSION=9.9.9; c=$(dynamo_rev)
[ "$a" != "$b" ] || fail "changing DYNAMO reruns the stage"
[ "$b" != "$c" ] || fail "a new DYNAMO_VERSION reruns the stage"

# every switch that would start a second scheduler or Grove stays off in oif's values
v=$ROOT/platform/dynamo/values.yaml
for k in kai-scheduler grove; do
  eq "$(sed -n "/^  $k:/,/^  [a-z]/p" "$v" | grep -cE '^    (install|enabled): false')" 2 "$k install and enabled false:"
done
finish
