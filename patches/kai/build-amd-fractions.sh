#!/bin/sh
# T-126 (ADR-032): builds what GPU fractions on AMD GPUs need, as image tarballs: KAI Scheduler's scheduler, binder and
# resource-reservation with oif's patches (patches/kai/), each the stock image with the patched binary on top, and the
# oif-amd-share NRI plugin (images/oif-amd-share/) on a static base. Runs in the pinned Go image as a Kubernetes Job
# (installer stage amd-fractions); needs no Docker and no registry.
#   env: KAI_VERSION KAI_SOURCE_SHA256 KAI_STOCK_REGISTRY KAI_PATCH_REGISTRY TAG CRANE_VERSION CRANE_SHA256
#        AMD_SHARE_BASE_IMAGE AMD_SHARE_IMAGE GPU_FRACTIONING_REF GPU_FRACTIONING_SHA256 FRACTIOND_IMAGE
#   mounts: /src (KAI source and crane, read), /patches (read), /plugin (plugin source, read), /out (write), /cache
set -eu
cd /tmp
cp "/src/crane-$CRANE_VERSION.tgz" crane.tgz   # downloaded and verified by the installer
echo "$CRANE_SHA256  crane.tgz" | sha256sum -c -
tar -xzf crane.tgz crane && rm crane.tgz
image() {   # tarball base new binary-path-in-image local-binary owner
  rm -rf /tmp/layer && mkdir -p "/tmp/layer/$(dirname "$4")" && cp "$5" "/tmp/layer/$4"
  tar -C /tmp/layer --owner="$6" --group=0 --mode=0755 -cf /tmp/layer.tar "$4"
  echo "== image $3 from $2"
  /tmp/crane append --platform linux/amd64 --base "$2" --new_layer /tmp/layer.tar --new_tag "$3" --output "/out/$1.tar"
  sha256sum "/out/$1.tar"
}

echo "== source KAI-Scheduler $KAI_VERSION"
cp "/src/kai-$KAI_VERSION.tgz" kai.tgz
echo "$KAI_SOURCE_SHA256  kai.tgz" | sha256sum -c -
tar -xzf kai.tgz && rm kai.tgz
cd "KAI-Scheduler-${KAI_VERSION#v}"
for p in /patches/*.patch; do echo "== patch ${p##*/}"; git apply -v "$p"; done
pkgs=$(cat /patches/*.patch | sed -n 's|^+++ b/\(.*\)/[^/]*\.go$|./\1/|p' | sort -u | paste -sd' ' -)
echo "== gofmt, vet, tests ($pkgs)"
test -z "$(gofmt -l $pkgs)" || { gofmt -d $pkgs; exit 1; }
go vet $pkgs
go test $pkgs > /tmp/test.log 2>&1 || { tail -40 /tmp/test.log; exit 1; }
cat /tmp/test.log
for c in scheduler binder resourcereservation; do
  cgo=0; [ "$c" = resourcereservation ] && cgo=1   # NVML (NVIDIA nodes) needs cgo, as upstream builds it
  echo "== build $c"; CGO_ENABLED=$cgo GOOS=linux GOARCH=amd64 go build -trimpath -o "/tmp/bin/$c" "./cmd/$c"
  image "kai-$c" "$KAI_STOCK_REGISTRY/$c:$KAI_VERSION" "$KAI_PATCH_REGISTRY/$c:$TAG" workspace/app "/tmp/bin/$c" 65532
done

echo "== oif-amd-share"
mkdir -p /tmp/plugin && cp /plugin/* /tmp/plugin/ && cd /tmp/plugin
test -z "$(gofmt -l .)" || { gofmt -d .; exit 1; }
go vet ./...
go test ./...
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o /tmp/bin/oif-amd-share .
image oif-amd-share "$AMD_SHARE_BASE_IMAGE" "$AMD_SHARE_IMAGE" oif-amd-share /tmp/bin/oif-amd-share 0

# T-139: KAI's gpu-fractioning fractiond with oif's AMD backend (hard VRAM cap, dmem cgroup), from the pinned fork
echo "== fractiond (gpu-fractioning $GPU_FRACTIONING_REF)"
cd /tmp && cp "/src/gpu-fractioning-$GPU_FRACTIONING_REF.tgz" gf.tgz
echo "$GPU_FRACTIONING_SHA256  gf.tgz" | sha256sum -c -
tar -xzf gf.tgz && rm gf.tgz && cd "gpu-fractioning-$GPU_FRACTIONING_REF"
export GOWORK=off   # the root module alone: fractiond and its ./pkg
go vet ./fractioning-manager/fractiond/...
go test ./fractioning-manager/fractiond/internal/amd/
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o /tmp/bin/fractiond ./fractioning-manager/fractiond/cmd
image oif-fractiond "$AMD_SHARE_BASE_IMAGE" "$FRACTIOND_IMAGE" fractiond /tmp/bin/fractiond 0
echo "== done"
