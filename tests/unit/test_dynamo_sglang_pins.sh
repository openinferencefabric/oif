#!/bin/bash
# T-212: Dynamo's SGLang runtime for gfx1100 is built FROM the S-5 image, by digest, so the dynamo-sglang stack is
# measured on exactly the SGLang the sglang stack serves. Dynamo's Dockerfile takes the base as two build args,
# BASE_IMAGE and BASE_IMAGE_TAG, joined as ${BASE_IMAGE}:${BASE_IMAGE_TAG}; the digest has to ride in the tag.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=../../images/lib.sh
. "$ROOT/images/lib.sh"
d=sha256:a8ba09b476422ca54fe6ed3a18d5e1b2d99c0e4c9d75fc7d6ff4dfd636acf9e9
eq "$(split_image "ghcr.io/org/sglang-rocm:v1-gfx1100@$d")" "ghcr.io/org/sglang-rocm v1-gfx1100@$d" "repo, tag@digest:"
eq "$(split_image "localhost:5000/org/app:v1@$d")" "localhost:5000/org/app v1@$d" "a registry port is not the tag:"
eq "$(split_image "ghcr.io/org/app:v1")" "ghcr.io/org/app v1" "a tag alone:"
no_ split_image "ghcr.io/org/app@$d"
no_ split_image "ghcr.io/org/app"

[[ $BENCH_SGLANG_IMAGE =~ ^ghcr\.io/openinferencefabric/sglang-rocm:[^@]+@sha256:[0-9a-f]{64}$ ]] || fail "the base, BENCH_SGLANG_IMAGE, pinned by digest: '$BENCH_SGLANG_IMAGE'"
eq "$DYNAMO_SGLANG_ROCM_IMAGE_REPO" "ghcr.io/openinferencefabric/dynamo-sglang-rocm" "image repository:"
[ -z "$DYNAMO_SGLANG_ROCM_IMAGE" ] || [[ $DYNAMO_SGLANG_ROCM_IMAGE =~ ^$DYNAMO_SGLANG_ROCM_IMAGE_REPO:[^@]+@sha256:[0-9a-f]{64}$ ]] \
  || fail "DYNAMO_SGLANG_ROCM_IMAGE empty or pinned by digest: '$DYNAMO_SGLANG_ROCM_IMAGE'"
finish
