# shellcheck shell=bash
# T-130 (ADR-019 amendment 2026-11-05): accelerator domains as node labels. Agent oif-topology (images/oif-topology/,
# DaemonSet in platform/kubernetes/topology.yaml) labels each GPU node with oif.ai/accelerator-domain,
# oif.ai/accelerator-fabric and oif.ai/scaleout-zone, which KAI's Topology levels use (T-132). Kubernetes and its
# labels go with `oif uninstall`; without GPUs the agent is removed and so are its labels.
# T-131: Deployment oif-domains (the same image, --domains) keeps the AcceleratorDomain objects, a read-only view of
# those domains (vendor, nodes, GPUs in use); the CRD and its objects go with the agent.

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
domains_missing() {   # domains of labelled nodes without their AcceleratorDomain object (none: the view is complete)
  local want have
  want=$(kc get nodes -l "$DOMAIN_LABEL" -o jsonpath='{range .items[*]}{.metadata.labels.oif\.ai/accelerator-domain}{"\n"}{end}' | tr 'A-Z_' 'a-z-' | sort -u) || return 1
  have=$(kc get acceleratordomains -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort -u) || return 1
  comm -23 <(echo "$want") <(echo "$have") | grep . || true; }
domains_done() { local m; m=$(domains_missing) && [ -z "$m" ]; }

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
  kc -n oif-topology rollout restart ds/oif-topology deploy/oif-domains >> "$LOG" 2>&1   # a rebuilt image under its tag
  kc -n oif-topology rollout status ds/oif-topology --timeout=300s >> "$LOG" 2>&1 \
    || die "oif-topology not ready (kubectl -n oif-topology logs ds/oif-topology)"
  wait_for "every GPU node has an accelerator domain" 180 5 topology_done \
    || die "no accelerator domain on: $(topology_unlabelled | paste -sd' ') (kubectl -n oif-topology logs ds/oif-topology)"
  kc get nodes -l "$DOMAIN_LABEL" -o jsonpath='{range .items[*]}{.metadata.name}: domain {.metadata.labels.oif\.ai/accelerator-domain}, fabric {.metadata.labels.oif\.ai/accelerator-fabric}, zone {.metadata.labels.oif\.ai/scaleout-zone}{"\n"}{end}' \
    | sed 's/^/    /' | tee -a "$TLOG"
  ok "GPU nodes labelled with their accelerator domain (agent oif-topology; a node annotation with the same key overrides)"
  kc -n oif-topology rollout status deploy/oif-domains --timeout=300s >> "$LOG" 2>&1 \
    || die "oif-domains not ready (kubectl -n oif-topology logs deploy/oif-domains)"
  wait_for "an AcceleratorDomain object for every domain" 120 5 domains_done \
    || die "no AcceleratorDomain for: $(domains_missing | paste -sd' ') (kubectl -n oif-topology logs deploy/oif-domains)"
  kc get acceleratordomains 2>&1 | sed 's/^/    /' | tee -a "$TLOG"
  ok "AcceleratorDomain view up to date (kubectl get acceleratordomains; read only, kept by oif-domains)"
}
stage_after topology vendor-pool

# T-132 (ADR-019 amendment 2026-11-05): KAI packs a workload inside one domain. Run:ai network topology oif-accelerator
# (levels: scale-out zone > accelerator domain > host), linked to the GPU node pools; Run:ai's agent writes it as KAI
# Topology oif-accelerator, and Run:ai adds kai.scheduler/topology and a preferred placement at the host level to every
# workload submitted into those pools. A workload that must stay in one domain adds
# kai.scheduler/topology-required-placement: oif.ai/accelerator-domain (guide 17).
RUNAI_TOPOLOGY=oif-accelerator
RUNAI_TOPOLOGY_LEVELS=(oif.ai/scaleout-zone oif.ai/accelerator-domain kubernetes.io/hostname)
runai_topology_pools() {   # the node pools with GPUs, comma separated: one per vendor (several nodes) or default
  local v p=(); for v in nvidia amd; do [ "$(gpu_count "$v")" -gt 0 ] && p+=("$(pool_for "$v")"); done
  printf '%s\n' "${p[@]}" | sort -u | paste -sd,; }
runai_topology_rev() { echo "$RUNAI_TOPOLOGY ${RUNAI_TOPOLOGY_LEVELS[*]} $(runai_topology_pools)"; }

register_stage runai-topology runai_topology_rev
stage_runai_topology() {
  local pools; pools=$(runai_topology_pools)
  if [ -z "$pools" ]; then
    runai_api network-topology-delete "$RUNAI_TOPOLOGY" | sed 's/^/    /' | tee -a "$TLOG"
    ok "no GPUs: no network topology"; return 0
  fi
  runai_api network-topology "$RUNAI_TOPOLOGY" "$pools" "${RUNAI_TOPOLOGY_LEVELS[@]}" | sed 's/^/    /' | tee -a "$TLOG"
  [ "${PIPESTATUS[0]}" = 0 ] || die "Run:ai network topology $RUNAI_TOPOLOGY not set (Run:ai UI: Resources, Network topologies)"
  wait_for "KAI Topology $RUNAI_TOPOLOGY in the cluster" 300 5 kc get topologies.kai.scheduler "$RUNAI_TOPOLOGY" \
    || die "Run:ai's agent did not create KAI Topology $RUNAI_TOPOLOGY (kubectl -n runai logs deploy/runai-agent)"
  ok "workloads in node pools $pools are packed by accelerator domain (KAI Topology $RUNAI_TOPOLOGY, preferred: one host)"
}
stage_after runai-topology topology

topology_off() {   # no agent, no policy, none of its labels
  kc delete namespace oif-topology --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete validatingadmissionpolicybinding oif-topology-own-node --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete validatingadmissionpolicy oif-topology-own-node --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete clusterrolebinding oif-topology --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete clusterrole oif-topology --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete clusterrolebinding oif-domains --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete clusterrole oif-domains --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete crd acceleratordomains.oif.ai --ignore-not-found >> "$LOG" 2>&1 || true   # and its objects
  kc label nodes -l 'type notin (kwok)' oif.ai/accelerator-domain- oif.ai/accelerator-fabric- oif.ai/scaleout-zone- >> "$LOG" 2>&1 || true
}
