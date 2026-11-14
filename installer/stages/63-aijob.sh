# shellcheck shell=bash
# T-133 (ADR-019): AIJob, a job that names no GPU vendor. Controller oif-aijob (images/oif-aijob/, Deployment in
# platform/kubernetes/aijob.yaml) picks the vendor from the AcceleratorDomain view (T-131) and creates a plain Job in
# that vendor's node pool, which Run:ai's scheduler places under the project's quota. Without GPUs it is removed; the
# CRD goes with it, and with it every AIJob and the Jobs they own.

AIJOB_SRC=$OIF_HOME/images/oif-aijob
aijob_build_rev() {   # what decides the image: its tag
  cat "$AIJOB_SRC"/*.go "$AIJOB_SRC"/go.mod "$OIF_HOME/images/build-go-image.sh" \
    "$OIF_HOME/platform/kubernetes/go-image-build-job.yaml" \
    | { cat; echo "$GO_BUILD_IMAGE $CRANE_VERSION $CRANE_SHA256 $AMD_SHARE_BASE_IMAGE"; } | sha256sum | cut -c1-12; }
aijob_pools() {   # each vendor's node pool: one per vendor on several nodes; the default pool (empty: no label) on one
  if multi_node; then echo "nvidia=nvidia,amd=amd"; else echo "nvidia=,amd="; fi; }
aijob_rev() { { aijob_build_rev; aijob_pools; cat "$OIF_HOME/platform/kubernetes/aijob.yaml"; } | sha256sum | cut -c1-12; }

register_stage aijob aijob_rev
stage_aijob() {
  if [ "$(gpu_count nvidia)" -eq 0 ] && [ "$(gpu_count amd)" -eq 0 ]; then
    aijob_off; ok "no GPUs: no AIJobs"; return 0
  fi
  export AIJOB_IMAGE AIJOB_POOLS
  AIJOB_IMAGE=oif.local/oif/oif-aijob:$(aijob_build_rev); AIJOB_POOLS=$(aijob_pools)
  go_image_build oif-aijob "$AIJOB_SRC" "$AIJOB_IMAGE"
  runai_patch_spread oif-aijob "$AIJOB_IMAGE"
  platform_render kubernetes/aijob.yaml
  kc apply -f "$STATE/aijob.yaml" >> "$LOG" || die "oif-aijob rejected"
  kc -n oif-aijob rollout restart deploy/oif-aijob >> "$LOG" 2>&1   # a rebuilt image under its tag
  kc -n oif-aijob rollout status deploy/oif-aijob --timeout=300s >> "$LOG" 2>&1 \
    || die "oif-aijob not ready (kubectl -n oif-aijob logs deploy/oif-aijob)"
  ok "AIJobs: a job that names no GPU vendor runs on one (kubectl get aijobs -A; controller oif-aijob, pools $AIJOB_POOLS)"
}
stage_after aijob runai-topology

aijob_off() {   # no controller, no CRD (its AIJobs and their Jobs go with it)
  kc delete namespace oif-aijob --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete crd aijobs.oif.ai --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete clusterrolebinding oif-aijob --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete clusterrole oif-aijob oif-aijob-edit --ignore-not-found >> "$LOG" 2>&1 || true
}
