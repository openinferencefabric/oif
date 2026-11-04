# shellcheck shell=bash
# T-126 (ADR-032): GPU fractions on AMD GPUs. KAI Scheduler's fraction path is written for NVIDIA; oif rebuilds its
# scheduler, binder and resource-reservation with patches (patches/kai/) so a fraction on an AMD GPU node is reserved
# with an amd.com/gpu and named in pod annotations, and runs the oif-amd-share NRI plugin on AMD GPU nodes to give the
# pod that GPU. T-139 (ADR-032 amendment): KAI's gpu-fractioning fractiond with oif's AMD backend caps each fraction
# pod's VRAM with the Linux dmem cgroup (dmem.max = share x VRAM) on nodes whose kernel supports it (6.14+); elsewhere,
# or with AMD_VRAM_CAP=none, the share is soft (OIF_GPU_MEMORY_FRACTION and PyTorch's cap tell the workload).
# Needs a node whose GPUs are AMD only (multi-node, T-123); AMD_FRACTIONS=none puts KAI's stock images back.

KAI_STOCK_REGISTRY=ghcr.io/kai-scheduler/kai-scheduler
KAI_PATCH_REGISTRY=oif.local/kai-scheduler
KAI_COMPONENTS="scheduler binder resourcereservation"

amd_fractions_build_rev() {   # what decides the images: their tag
  cat "$OIF_HOME/patches/kai/build-amd-fractions.sh" "$OIF_HOME/patches/kai/$KAI_VERSION"/*.patch \
    "$OIF_HOME"/images/oif-amd-share/*.go "$OIF_HOME"/images/oif-amd-share/go.* "$OIF_HOME/platform/gpu-amd/amd-fractions-build-job.yaml" \
    | { cat; echo "$GO_BUILD_IMAGE $CRANE_VERSION $CRANE_SHA256 $KAI_VERSION $KAI_SOURCE_SHA256 $AMD_SHARE_BASE_IMAGE $GPU_FRACTIONING_REF $GPU_FRACTIONING_SHA256"; } \
    | sha256sum | cut -c1-12; }
amd_fractions_rev() {   # the stage reruns when the images, the plugins' manifests, AMD_FRACTIONS or AMD_VRAM_CAP change
  { amd_fractions_build_rev; cat "$OIF_HOME/platform/gpu-amd/amd-share.yaml" "$OIF_HOME/platform/gpu-amd/amd-vram-cap.yaml"
    echo "${AMD_FRACTIONS:-} ${AMD_VRAM_CAP:-} gpu-memory-label"; } | sha256sum | cut -c1-12; }
amd_only_nodes() {   # nodes whose GPUs are all AMD: where oif shares an AMD GPU
  kc get nodes -o json | python3 -c 'import json,sys
for n in json.load(sys.stdin)["items"]:
    a = n["status"].get("allocatable", {})
    if int(a.get("amd.com/gpu", "0")) > 0 and int(a.get("nvidia.com/gpu", "0")) == 0: print(n["metadata"]["name"])'; }

register_stage amd-fractions amd_fractions_rev
stage_amd_fractions() {
  if [ "${AMD_FRACTIONS:-}" = none ]; then amd_fractions_off; ok "GPU fractions on AMD GPUs off (AMD_FRACTIONS=none)"; return 0; fi
  local nodes; nodes=$(amd_only_nodes | paste -sd' ')
  [ -n "$nodes" ] || { amd_fractions_off; ok "no node with AMD GPUs only: AMD GPUs are shared only there (whole GPUs elsewhere)"; return 0; }
  local tag c img
  tag=$KAI_VERSION-oif-$(amd_fractions_build_rev)
  export AMD_SHARE_IMAGE=oif.local/oif/oif-amd-share:$tag FRACTIOND_IMAGE=oif.local/oif/oif-fractiond:$tag
  amd_fractions_build "$tag"
  for c in $KAI_COMPONENTS; do runai_patch_spread "kai-$c" "$KAI_PATCH_REGISTRY/$c:$tag"; done
  runai_patch_spread oif-amd-share "$AMD_SHARE_IMAGE"
  runai_patch_spread oif-fractiond "$FRACTIOND_IMAGE"
  # Run:ai's operator writes KAI's config: point it at the patched images (the reservation pods run on GPU nodes)
  kc -n runai patch runaiconfig runai --type merge -p "$(python3 - "$KAI_PATCH_REGISTRY" "$tag" <<'PY'
import json, sys
img = lambda n: {"image": {"registry": sys.argv[1], "name": n, "tag": sys.argv[2], "pullPolicy": "IfNotPresent"}}
print(json.dumps({"spec": {"runai-scheduler": img("scheduler"),
                           "binder": dict(img("binder"), resourceReservation=img("resourcereservation"))}}))
PY
)" >> "$LOG" || die "RunaiConfig rejected the patched KAI images"
  for c in binder $(kc -n runai get deploy -o name | sed -n 's|^deployment.apps/\(runai-scheduler-.*\)|\1|p'); do
    img=$KAI_PATCH_REGISTRY/scheduler:$tag; [ "$c" = binder ] && img=$KAI_PATCH_REGISTRY/binder:$tag   # one scheduler per pool
    wait_for "$c runs the patched KAI image" 600 10 bash -c \
      "kubectl --kubeconfig $KCFG -n runai get deploy $c -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -qxF '$img' && kubectl --kubeconfig $KCFG -n runai rollout status deploy/$c --timeout=10s" \
      || die "$c did not roll out $img (kubectl -n runai describe deploy $c)"
  done
  ok "KAI scheduler and binder patched for AMD GPU fractions ($tag)"
  export KAI_BINDER_USER
  KAI_BINDER_USER=system:serviceaccount:runai:$(kc -n runai get deploy binder -o jsonpath='{.spec.template.spec.serviceAccountName}')
  [ "$KAI_BINDER_USER" != system:serviceaccount:runai: ] || die "cannot find KAI binder's service account"
  render "$OIF_HOME/platform/gpu-amd/amd-share.yaml" | kc apply -f - >> "$LOG" || die "oif-amd-share rejected"
  kc -n oif-system rollout status ds/oif-amd-share --timeout=300s >> "$LOG" 2>&1 \
    || die "oif-amd-share not running on every AMD GPU node (kubectl -n oif-system get pods -o wide)"
  amd_gpu_memory_label "$nodes"
  amd_vram_cap "$nodes"
  ok "AMD GPUs on $nodes can be shared: Run:ai GPU fractions in pool $(pool_for amd); $VRAM_CAP_MSG"
}
# T-140: KAI sizes a fraction asked for in GPU memory (Run:ai's "GPU memory", e.g. 12 GB) from the node label
# nvidia.com/gpu.memory (MiB per GPU), which only NVIDIA's GPU feature discovery sets; without it a memory fraction on
# an AMD node never schedules. oif sets it on the AMD-only nodes from the VRAM the kernel reports (dmem.capacity), or
# from the AMD node labeller's amd.com/gpu.vram, and marks it so only the labels it set are removed.
AMD_MEM_MARK=oif.ai/gpu-memory-label
amd_vram_mib() {   # node: MiB of VRAM of its smallest AMD GPU, empty if unknown
  local b v
  b=$(amd_node_run "$1" "awk '/^drm\/.*\/vram /{print \$2}' /sys/fs/cgroup/dmem.capacity 2>/dev/null | sort -n | head -1" 2>/dev/null)
  if [[ $b =~ ^[0-9]+$ ]] && [ "$b" -gt 0 ]; then echo $((b / 1048576)); return; fi
  v=$(kc get node "$1" -o jsonpath='{.metadata.labels.amd\.com/gpu\.vram}' 2>/dev/null)   # e.g. 45G
  [[ $v =~ ^([0-9]+)G$ ]] && echo $((BASH_REMATCH[1] * 1024))
}
amd_gpu_memory_label() {   # nodes: label each with its GPU memory for KAI; drop oif's label from nodes no longer listed
  local n mib done_=""
  for n in $1; do
    mib=$(amd_vram_mib "$n")
    if [ -z "$mib" ]; then warn "$n: AMD GPU memory unknown (no dmem.capacity, no amd.com/gpu.vram): GPU fractions by memory will not schedule there"; continue; fi
    kc label node "$n" "nvidia.com/gpu.memory=$mib" "$AMD_MEM_MARK=set" --overwrite >> "$LOG" || die "cannot label node $n with its GPU memory"
    done_="$done_ $n ($mib MiB)"
  done
  amd_gpu_memory_unlabel "$1"
  [ -z "$done_" ] || ok "AMD GPU memory for fractions by GB:$done_"
}
amd_gpu_memory_unlabel() {   # [nodes to keep]: remove the labels oif set from every other node
  local n
  for n in $(kc get nodes -l "$AMD_MEM_MARK" -o name 2>/dev/null | sed 's|^node/||'); do
    [[ " ${1:-} " == *" $n "* ]] || kc label node "$n" nvidia.com/gpu.memory- "$AMD_MEM_MARK-" >> "$LOG" 2>&1 || true
  done
}
amd_node_run() {   # node-name command: run the command on that Kubernetes node (this host, or over SSH with the cluster key)
  local name addr role
  if ! multi_node || [ "$1" = "$(this_node)" ]; then bash -c "$2"; return; fi
  while read -r -u 3 name addr role; do
    [ "$(node_name_of "$addr")" = "$1" ] && { node_ssh "$addr" "$2"; return; }
  done 3< <(nodes_list)
  return 1
}
amd_vram_cap() {   # nodes: the hard VRAM cap (T-139) on the AMD nodes whose kernel caps VRAM with dmem; soft elsewhere
  local n hard="" soft="" k
  if [ "${AMD_VRAM_CAP:-}" = none ]; then
    amd_vram_cap_off; VRAM_CAP_MSG="memory isolation is soft (AMD_VRAM_CAP=none)"; return 0
  fi
  for n in $1; do
    if amd_node_run "$n" "grep -q '^drm/.*/vram' /sys/fs/cgroup/dmem.capacity 2>/dev/null"; then hard="$hard $n"; else
      soft="$soft $n"; k=$(amd_node_run "$n" "uname -r" 2>/dev/null || echo "?")
      warn "$n (kernel $k): no amdgpu VRAM region in /sys/fs/cgroup/dmem.capacity (needs Linux 6.14+): its AMD fractions keep a soft memory share"
    fi
  done
  # label the capable nodes first, then unlabel the rest, so a node that stays capable never loses its fractiond
  for n in $hard; do kc label node "$n" oif.ai/amd-vram-cap=dmem --overwrite >> "$LOG" || die "cannot label node $n"; done
  for n in $(kc get nodes -l oif.ai/amd-vram-cap -o name | sed 's|^node/||'); do
    [[ " $hard " == *" $n "* ]] || kc label node "$n" oif.ai/amd-vram-cap- >> "$LOG" || die "cannot unlabel node $n"
  done
  if [ -z "$hard" ]; then
    kc -n oif-system delete daemonset oif-fractiond --ignore-not-found >> "$LOG" 2>&1
    VRAM_CAP_MSG="memory isolation is soft (no node's kernel caps VRAM)"; return 0
  fi
  render "$OIF_HOME/platform/gpu-amd/amd-vram-cap.yaml" | kc apply -f - >> "$LOG" || die "oif-fractiond rejected"
  kc -n oif-system rollout status ds/oif-fractiond --timeout=300s >> "$LOG" 2>&1 \
    || die "fractiond not ready on every node labelled oif.ai/amd-vram-cap=dmem (kubectl -n oif-system logs ds/oif-fractiond)"
  ok "hard VRAM cap (dmem) for AMD fractions on${hard}"
  VRAM_CAP_MSG="memory isolation is hard on${hard}${soft:+, soft on${soft}}"
}
amd_vram_cap_off() {   # no cap: fractiond and its node labels removed (pods keep the cap they started with until they end)
  local n
  kc -n oif-system delete daemonset oif-fractiond --ignore-not-found --wait=true >> "$LOG" 2>&1 || true
  for n in $(kc get nodes -l oif.ai/amd-vram-cap -o name 2>/dev/null | sed 's|^node/||'); do
    kc label node "$n" oif.ai/amd-vram-cap- >> "$LOG" 2>&1 || true
  done
}
amd_fractions_build() {   # tag: build the four images once per tag (Job -> tarballs -> containerd on this node)
  local tag=$1 out=$STATE/build/runai c ok_=1
  for c in $KAI_COMPONENTS; do runai_image_loaded "$KAI_PATCH_REGISTRY/$c:$tag" && [ -s "$out/kai-$c.tar" ] || ok_=0; done
  runai_image_loaded "$AMD_SHARE_IMAGE" && [ -s "$out/oif-amd-share.tar" ] || ok_=0
  runai_image_loaded "$FRACTIOND_IMAGE" && [ -s "$out/oif-fractiond.tar" ] || ok_=0
  [ $ok_ = 1 ] && { ok "patched KAI, oif-amd-share and fractiond images already built ($tag)"; return 0; }
  runai_fetch_resumable "https://codeload.github.com/kai-scheduler/KAI-scheduler/tar.gz/refs/tags/$KAI_VERSION" \
    "$KAI_SOURCE_SHA256" "$STATE/build/src/kai-$KAI_VERSION.tgz"
  runai_fetch_resumable "https://github.com/google/go-containerregistry/releases/download/$CRANE_VERSION/go-containerregistry_Linux_x86_64.tar.gz" \
    "$CRANE_SHA256" "$STATE/build/src/crane-$CRANE_VERSION.tgz"
  runai_fetch_resumable "https://codeload.github.com/$GPU_FRACTIONING_REPO/tar.gz/$GPU_FRACTIONING_REF" \
    "$GPU_FRACTIONING_SHA256" "$STATE/build/src/gpu-fractioning-$GPU_FRACTIONING_REF.tgz"
  kc create namespace oif-build --dry-run=client -o yaml | kc apply -f - >> "$LOG"
  kc -n oif-build create configmap amd-fractions-build --from-file="$OIF_HOME/patches/kai/build-amd-fractions.sh" \
    --dry-run=client -o yaml | kc apply -f - >> "$LOG"
  kc -n oif-build create configmap kai-patches --from-file="$OIF_HOME/patches/kai/$KAI_VERSION/" --dry-run=client -o yaml \
    | kc apply -f - >> "$LOG"
  kc -n oif-build create configmap oif-amd-share-src --from-file="$OIF_HOME/images/oif-amd-share/" --dry-run=client -o yaml \
    | kc apply -f - >> "$LOG"
  mkdir -p "$out"; for c in $KAI_COMPONENTS; do rm -f "$out/kai-$c.tar"; done; rm -f "$out/oif-amd-share.tar" "$out/oif-fractiond.tar"
  kc -n oif-build delete job amd-fractions-build --ignore-not-found --wait=true >> "$LOG" 2>&1
  export KAI_VERSION KAI_SOURCE_SHA256 KAI_STOCK_REGISTRY KAI_PATCH_REGISTRY CRANE_VERSION CRANE_SHA256 AMD_SHARE_BASE_IMAGE GO_BUILD_IMAGE \
    GPU_FRACTIONING_REF GPU_FRACTIONING_SHA256
  KAI_PATCH_TAG=$tag AMD_FRACTIONS_OUT=$out RUNAI_BUILD_SRC=$STATE/build/src RUNAI_BUILD_CACHE=$STATE/build/cache BUILD_NODE=$(this_node) \
    render "$OIF_HOME/platform/gpu-amd/amd-fractions-build-job.yaml" | kc apply -f - >> "$LOG" || die "build Job for AMD GPU fractions rejected"
  log "building KAI $KAI_VERSION with $(cd "$OIF_HOME/patches/kai/$KAI_VERSION" && ls ./*.patch | sed 's|./||' | paste -sd' '), oif-amd-share and fractiond (10-30 min; longer on a slow link)"
  wait_for "AMD GPU fractions build finished" 14400 15 bash -c \
    "kubectl --kubeconfig $KCFG -n oif-build get job amd-fractions-build -o jsonpath='{.status.conditions[*].type}' | grep -qE 'Complete|Failed'" || true
  kc -n oif-build logs job/amd-fractions-build 2>&1 | grep -E '^(==|ok|FAIL|---)' | sed 's/^/    /' | tee -a "$TLOG"
  [ "$(kc -n oif-build get job amd-fractions-build -o jsonpath='{.status.succeeded}')" = 1 ] \
    || die "AMD GPU fractions build failed (kubectl -n oif-build logs job/amd-fractions-build)"
  for c in $KAI_COMPONENTS; do amd_fractions_import "kai-$c" "$KAI_PATCH_REGISTRY/$c:$tag"; done
  amd_fractions_import oif-amd-share "$AMD_SHARE_IMAGE"
  amd_fractions_import oif-fractiond "$FRACTIOND_IMAGE"
}
amd_fractions_import() {   # tarball-name image: into containerd on this node
  [ -s "$STATE/build/runai/$1.tar" ] || die "no image file $1.tar from the build"
  ctr -n k8s.io images import "$STATE/build/runai/$1.tar" >> "$LOG" 2>&1 || die "cannot import $2 into containerd"
  runai_image_loaded "$2" || die "image $2 not found after import"
  ok "image $2 loaded into containerd"
}
amd_fractions_off() {   # KAI's stock images back; the plugins and the policy removed (no pod is given a shared AMD GPU)
  local p
  amd_vram_cap_off
  amd_gpu_memory_unlabel ""
  for p in /spec/runai-scheduler/image /spec/binder/image /spec/binder/resourceReservation/image; do
    kc -n runai patch runaiconfig runai --type json -p "[{\"op\":\"remove\",\"path\":\"$p\"}]" >> "$LOG" 2>&1 || true
  done
  kc delete validatingadmissionpolicybinding oif-amd-share-annotations --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete validatingadmissionpolicy oif-amd-share-annotations --ignore-not-found >> "$LOG" 2>&1 || true
  # waits until the plugin is gone, so "off" is true when the stage ends and turning it on again finds no namespace
  # still terminating (T-128)
  kc delete namespace oif-system --ignore-not-found --timeout=180s >> "$LOG" 2>&1 \
    || warn "namespace oif-system is still being removed (kubectl get namespace oif-system)"
}
stage_after amd-fractions runai-amd-templates
