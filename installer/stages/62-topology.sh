# shellcheck shell=bash
# T-130 (ADR-019 amendment 2026-11-05): accelerator domains as node labels. Agent oif-topology (images/oif-topology/,
# DaemonSet in platform/kubernetes/topology.yaml) labels each GPU node with oif.ai/accelerator-domain,
# oif.ai/accelerator-fabric and oif.ai/scaleout-zone, which KAI's Topology levels use (T-132). Kubernetes and its
# labels go with `oif uninstall`; without GPUs the agent is removed and so are its labels.

TOPOLOGY_SRC=$OIF_HOME/images/oif-topology
DOMAIN_LABEL=oif.ai/accelerator-domain
topology_build_rev() {   # what decides the image: its tag
  cat "$TOPOLOGY_SRC"/*.go "$TOPOLOGY_SRC"/go.mod "$OIF_HOME/images/build-go-image.sh" \
    "$OIF_HOME/platform/kubernetes/go-image-build-job.yaml" \
    | { cat; echo "$GO_BUILD_IMAGE $CRANE_VERSION $CRANE_SHA256 $AMD_SHARE_BASE_IMAGE"; } | sha256sum | cut -c1-12; }
topology_rev() { { topology_build_rev; cat "$OIF_HOME/platform/kubernetes/topology.yaml"; } | sha256sum | cut -c1-12; }

topology_unlabelled() {   # real nodes with a GPU and no accelerator domain yet (none: every GPU node is labelled)
  kc get nodes -l 'type notin (kwok)' -o jsonpath='{range .items[*]}{.metadata.name} {.status.allocatable.nvidia\.com/gpu}{.status.allocatable.amd\.com/gpu} {.metadata.labels.oif\.ai/accelerator-domain}{"\n"}{end}' \
    | awk '$2 != "" && $2 != "0" && $3 == "" {print $1}'
}
topology_done() { local u; u=$(topology_unlabelled) && [ -z "$u" ]; }

register_stage topology topology_rev
stage_topology() {
  if [ "$(gpu_count nvidia)" -eq 0 ] && [ "$(gpu_count amd)" -eq 0 ]; then
    topology_off; ok "no GPUs: no accelerator domains"; return 0
  fi
  export TOPOLOGY_IMAGE
  TOPOLOGY_IMAGE=oif.local/oif/oif-topology:$(topology_build_rev)
  go_image_build oif-topology "$TOPOLOGY_SRC" "$TOPOLOGY_IMAGE"
  runai_patch_spread oif-topology "$TOPOLOGY_IMAGE"
  platform_render kubernetes/topology.yaml
  kc apply -f "$STATE/topology.yaml" >> "$LOG" || die "oif-topology rejected"
  kc -n oif-topology rollout restart ds/oif-topology >> "$LOG" 2>&1   # a rebuilt image under its tag
  kc -n oif-topology rollout status ds/oif-topology --timeout=300s >> "$LOG" 2>&1 \
    || die "oif-topology not ready (kubectl -n oif-topology logs ds/oif-topology)"
  wait_for "every GPU node has an accelerator domain" 180 5 topology_done \
    || die "no accelerator domain on: $(topology_unlabelled | paste -sd' ') (kubectl -n oif-topology logs ds/oif-topology)"
  kc get nodes -l "$DOMAIN_LABEL" -o jsonpath='{range .items[*]}{.metadata.name}: domain {.metadata.labels.oif\.ai/accelerator-domain}, fabric {.metadata.labels.oif\.ai/accelerator-fabric}, zone {.metadata.labels.oif\.ai/scaleout-zone}{"\n"}{end}' \
    | sed 's/^/    /' | tee -a "$TLOG"
  ok "GPU nodes labelled with their accelerator domain (agent oif-topology; a node annotation with the same key overrides)"
}
stage_after topology vendor-pool

topology_off() {   # no agent, no policy, none of its labels
  kc delete namespace oif-topology --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete validatingadmissionpolicybinding oif-topology-own-node --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete validatingadmissionpolicy oif-topology-own-node --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete clusterrolebinding oif-topology --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete clusterrole oif-topology --ignore-not-found >> "$LOG" 2>&1 || true
  kc label nodes -l 'type notin (kwok)' oif.ai/accelerator-domain- oif.ai/accelerator-fabric- oif.ai/scaleout-zone- >> "$LOG" 2>&1 || true
}
