# shellcheck shell=bash
# T-129 (ADR-032): one GPU vendor per workload. On several nodes with both GPU vendors, webhook oif-vendor-pool pins a
# pod in a Run:ai project to one vendor's node pool when it asks for that vendor's GPU or when its workload is in that
# pool, and policy oif-vendor-agnostic-gpu refuses a GPU fraction that names no vendor while its pools allow both
# (platform/kubernetes/vendor-pool.yaml). The webhook is built here from images/oif-vendor-pool/ and served with a
# certificate from oif's CA. With one GPU vendor there is nothing to choose, and both are removed.

VENDOR_POOL_SRC=$OIF_HOME/images/oif-vendor-pool
vendor_pool_build_rev() {   # what decides the image: its tag
  cat "$VENDOR_POOL_SRC"/*.go "$VENDOR_POOL_SRC"/go.mod "$OIF_HOME/images/build-go-image.sh" \
    "$OIF_HOME/platform/kubernetes/go-image-build-job.yaml" \
    | { cat; echo "$GO_BUILD_IMAGE $CRANE_VERSION $CRANE_SHA256 $AMD_SHARE_BASE_IMAGE"; } | sha256sum | cut -c1-12; }
vendor_pool_rev() { { vendor_pool_build_rev; cat "$OIF_HOME/platform/kubernetes/vendor-pool.yaml"; } | sha256sum | cut -c1-12; }

register_stage vendor-pool vendor_pool_rev
stage_vendor_pool() {
  if ! multi_node || [ "$(gpu_count nvidia)" -eq 0 ] || [ "$(gpu_count amd)" -eq 0 ]; then
    vendor_pool_off; ok "one GPU vendor (or one node): no vendor pool to choose"; return 0
  fi
  export VENDOR_POOL_IMAGE VENDOR_POOL_CA
  VENDOR_POOL_IMAGE=oif.local/oif/oif-vendor-pool:$(vendor_pool_build_rev)
  go_image_build oif-vendor-pool "$VENDOR_POOL_SRC" "$VENDOR_POOL_IMAGE"
  runai_patch_spread oif-vendor-pool "$VENDOR_POOL_IMAGE"
  vendor_pool_cert
  VENDOR_POOL_CA=$(base64 -w0 < "$PKI/ca.crt")
  kc create namespace oif-vendor-pool --dry-run=client -o yaml | kc apply -f - >> "$LOG"
  kc -n oif-vendor-pool create secret tls oif-vendor-pool-tls --cert="$PKI/vendor-pool.crt" --key="$PKI/vendor-pool.key" \
    --dry-run=client -o yaml | kc apply -f - >> "$LOG" || die "TLS secret for oif-vendor-pool rejected"
  platform_render kubernetes/vendor-pool.yaml
  kc apply -f "$STATE/vendor-pool.yaml" >> "$LOG" || die "oif-vendor-pool rejected"
  kc -n oif-vendor-pool rollout restart deploy/oif-vendor-pool >> "$LOG" 2>&1   # a renewed certificate or a rebuilt image under its tag
  kc -n oif-vendor-pool rollout status deploy/oif-vendor-pool --timeout=300s >> "$LOG" 2>&1 \
    || die "oif-vendor-pool not ready (kubectl -n oif-vendor-pool logs deploy/oif-vendor-pool)"
  ok "a pod asking for one vendor's GPU, or whose workload is in a vendor's pool, runs in that pool (webhook oif-vendor-pool)"
  ok "a GPU fraction that names no vendor must choose pool nvidia or amd (ValidatingAdmissionPolicy oif-vendor-agnostic-gpu)"
}
stage_after vendor-pool one-vendor

vendor_pool_off() {   # no webhook, no policy (pods are created as they are)
  kc delete mutatingwebhookconfiguration oif-vendor-pool --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete validatingadmissionpolicybinding oif-vendor-agnostic-gpu --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete validatingadmissionpolicy oif-vendor-agnostic-gpu --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete clusterrolebinding oif-vendor-pool --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete clusterrole oif-vendor-pool --ignore-not-found >> "$LOG" 2>&1 || true
  kc delete namespace oif-vendor-pool --ignore-not-found >> "$LOG" 2>&1 || true
}

vendor_pool_cert() {   # serving certificate for the webhook's service, from oif's CA (renewed when 30 days are left)
  local cn=oif-vendor-pool.oif-vendor-pool.svc
  if [ -s "$PKI/vendor-pool.crt" ] && openssl x509 -checkend 2592000 -noout -in "$PKI/vendor-pool.crt" >/dev/null 2>&1 \
     && openssl verify -CAfile "$PKI/ca.crt" "$PKI/vendor-pool.crt" >/dev/null 2>&1; then return 0; fi
  openssl req -newkey rsa:2048 -nodes -keyout "$PKI/vendor-pool.key" -out "$PKI/vendor-pool.csr" -subj "/CN=$cn" 2>>"$LOG" \
    || die "cannot create the webhook's key"
  printf 'subjectAltName=DNS:%s,DNS:%s.cluster.local\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\n' \
    "$cn" "$cn" > "$PKI/vendor-pool.ext"
  openssl x509 -req -in "$PKI/vendor-pool.csr" -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" -CAcreateserial -days 825 -sha256 \
    -extfile "$PKI/vendor-pool.ext" -out "$PKI/vendor-pool.crt" 2>>"$LOG" || die "cannot sign the webhook's certificate"
  chmod 600 "$PKI/vendor-pool.key"
  ok "certificate for $cn from oif's CA"
}

go_image_build() {   # name source-dir image: build one of oif's Go components once per tag (Job -> tarball -> containerd)
  local name=$1 src=$2 image=$3 out=$STATE/build/runai   # where runai_patch_spread copies images to the other nodes from
  runai_image_loaded "$image" && [ -s "$out/$name.tar" ] && { ok "$image already built"; return 0; }
  runai_fetch_resumable "https://github.com/google/go-containerregistry/releases/download/$CRANE_VERSION/go-containerregistry_Linux_x86_64.tar.gz" \
    "$CRANE_SHA256" "$STATE/build/src/crane-$CRANE_VERSION.tgz"
  kc create namespace oif-build --dry-run=client -o yaml | kc apply -f - >> "$LOG"
  kc -n oif-build create configmap go-image-build --from-file="$OIF_HOME/images/build-go-image.sh" --dry-run=client -o yaml \
    | kc apply -f - >> "$LOG"
  kc -n oif-build create configmap "$name-src" --from-file="$src/" --dry-run=client -o yaml | kc apply -f - >> "$LOG"
  mkdir -p "$out"; rm -f "$out/$name.tar"
  kc -n oif-build delete job "$name-build" --ignore-not-found --wait=true >> "$LOG" 2>&1
  NAME=$name IMAGE=$image BASE_IMAGE=$AMD_SHARE_BASE_IMAGE GO_IMAGE_OUT=$out RUNAI_BUILD_SRC=$STATE/build/src \
    RUNAI_BUILD_CACHE=$STATE/build/cache BUILD_NODE=$(this_node) GO_BUILD_IMAGE=$GO_BUILD_IMAGE CRANE_VERSION=$CRANE_VERSION \
    CRANE_SHA256=$CRANE_SHA256 render "$OIF_HOME/platform/kubernetes/go-image-build-job.yaml" | kc apply -f - >> "$LOG" \
    || die "build Job for $name rejected"
  log "building $name (a few minutes)"
  wait_for "$name build finished" 1800 10 bash -c \
    "kubectl --kubeconfig $KCFG -n oif-build get job $name-build -o jsonpath='{.status.conditions[*].type}' | grep -qE 'Complete|Failed'" || true
  kc -n oif-build logs "job/$name-build" 2>&1 | grep -E '^(==|ok|FAIL|---)' | sed 's/^/    /' | tee -a "$TLOG"
  [ "$(kc -n oif-build get job "$name-build" -o jsonpath='{.status.succeeded}')" = 1 ] \
    || die "$name build failed (kubectl -n oif-build logs job/$name-build)"
  ctr -n k8s.io images import "$out/$name.tar" >> "$LOG" 2>&1 || die "cannot import $image into containerd"
  runai_image_loaded "$image" || die "image $image not found after import"
  ok "image $image loaded into containerd"
}
