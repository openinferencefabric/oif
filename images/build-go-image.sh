#!/bin/sh
# Builds one of oif's own Go components (images/<name>/, standard library only) into an image tarball: gofmt, vet and
# tests first, then the static binary on top of the base image. Runs in the pinned Go image as a Kubernetes Job
# (platform/kubernetes/go-image-build-job.yaml); needs no Docker and no registry.
#   env: NAME IMAGE BASE_IMAGE CRANE_VERSION CRANE_SHA256
#   mounts: /src (crane, read), /module (the component's source, read), /out (write), /cache
set -eu
cd /tmp
cp "/src/crane-$CRANE_VERSION.tgz" crane.tgz   # downloaded and verified by the installer
echo "$CRANE_SHA256  crane.tgz" | sha256sum -c -
tar -xzf crane.tgz crane && rm crane.tgz
echo "== $NAME"
mkdir -p /tmp/module && cp /module/* /tmp/module/ && cd /tmp/module
test -z "$(gofmt -l .)" || { gofmt -d .; exit 1; }
go vet ./...
go test ./...
mkdir -p /tmp/layer
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o "/tmp/layer/$NAME" .
tar -C /tmp/layer --owner=0 --group=0 --mode=0755 -cf /tmp/layer.tar "$NAME"
echo "== image $IMAGE from $BASE_IMAGE"
/tmp/crane append --platform linux/amd64 --base "$BASE_IMAGE" --new_layer /tmp/layer.tar --new_tag "$IMAGE" --output "/out/$NAME.tar"
sha256sum "/out/$NAME.tar"
echo "== done"
