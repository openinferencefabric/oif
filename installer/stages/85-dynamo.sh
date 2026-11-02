# shellcheck shell=bash
# T-201 (S-4, guide 16): NVIDIA Dynamo's platform (operator and CRDs) with Grove and Dynamo's bundled KAI Scheduler off,
# so Dynamo's pods are scheduled by Run:ai's KAI under the project's quotas. Kubernetes objects only: uninstall removes
# them with the cluster, DYNAMO=none removes them from a running one. NVIDIA GPUs only until AMD serving (S-1).

DYNAMO_NS=dynamo-system
DYNAMO_RELEASE=dynamo-platform   # the release name of the hand install in S-4, so install takes that one over
DYNAMO_CRDS="dynamocomponentdeployments dynamographdeploymentrequests dynamographdeployments
             dynamographdeploymentscalingadapters dynamomodels dynamoworkermetadatas"

dynamo_rev() {   # the stage reruns when the chart, its values or DYNAMO change
  { echo "$DYNAMO_VERSION $DYNAMO_PLATFORM_SHA256 ${DYNAMO:-}"; cat "$OIF_HOME/platform/dynamo/values.yaml"; } | sha256sum | cut -c1-12; }

register_stage dynamo dynamo_rev
stage_dynamo() {
  if [ "${DYNAMO:-}" = none ]; then dynamo_off; ok "Dynamo off (DYNAMO=none)"; return 0; fi
  [ "$(gpu_count nvidia)" -gt 0 ] || { dynamo_off; ok "no NVIDIA GPU on any node: Dynamo not installed"; return 0; }
  mkdir -p "$STATE/charts"; local chart=$STATE/charts/dynamo-platform-$DYNAMO_VERSION.tgz c
  [ -s "$chart" ] || fetch_pinned "https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-$DYNAMO_VERSION.tgz" \
    "$DYNAMO_PLATFORM_SHA256" "$chart"
  log "Dynamo $DYNAMO_VERSION platform (operator and CRDs, 1-3 min)"
  hl upgrade --install "$DYNAMO_RELEASE" "$chart" -n "$DYNAMO_NS" --create-namespace \
    -f "$OIF_HOME/platform/dynamo/values.yaml" --wait --timeout 10m >> "$LOG" 2>&1 \
    || die "Dynamo chart failed (kubectl -n $DYNAMO_NS get pods; helm -n $DYNAMO_NS status $DYNAMO_RELEASE)"
  for c in $DYNAMO_CRDS; do
    kc get crd "$c.nvidia.com" >/dev/null 2>&1 || die "Dynamo CRD $c.nvidia.com missing (kubectl get crd | grep dynamo)"
  done
  kc -n "$DYNAMO_NS" wait deploy --all --for=condition=Available --timeout=300s >> "$LOG" 2>&1 \
    || die "Dynamo operator not ready (kubectl -n $DYNAMO_NS get pods)"
  dynamo_own_schedulers | grep -q . && die "Dynamo started its own scheduler: $(dynamo_own_schedulers | paste -sd' ') (platform/dynamo/values.yaml)"
  ok "Dynamo $DYNAMO_VERSION operator ready, 6 CRDs; no Grove or bundled KAI: Run:ai's KAI schedules Dynamo's pods"
}

dynamo_own_schedulers() {   # Grove or the bundled KAI running in Dynamo's namespace (there must be none; a finished
  # preflight Job is not a scheduler, so only long-running workloads count)
  kc -n "$DYNAMO_NS" get deploy,statefulset,daemonset -o name 2>/dev/null | grep -Ei 'grove|kai' || true; }

dynamo_off() {   # remove the platform from a running cluster; deleting the CRDs deletes every Dynamo deployment
  local c n
  if hl -n "$DYNAMO_NS" status "$DYNAMO_RELEASE" >/dev/null 2>&1; then
    n=$(kc get dynamographdeployments -A --no-headers 2>/dev/null | wc -l)
    [ "$n" = 0 ] || warn "deleting $n Dynamo deployment(s) with the platform"
    hl uninstall "$DYNAMO_RELEASE" -n "$DYNAMO_NS" --wait --timeout 5m >> "$LOG" 2>&1 || warn "helm uninstall $DYNAMO_RELEASE did not finish"
  fi
  for c in $DYNAMO_CRDS; do kc delete crd "$c.nvidia.com" --ignore-not-found --wait=true >> "$LOG" 2>&1 || warn "CRD $c.nvidia.com not deleted"; done
  kc delete namespace "$DYNAMO_NS" --ignore-not-found --wait=true >> "$LOG" 2>&1 || warn "namespace $DYNAMO_NS not deleted"
}
