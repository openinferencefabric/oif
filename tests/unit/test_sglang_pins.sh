#!/bin/bash
# S-5: SGLang for RDNA3 (gfx1100) is built from pinned sources only: the base image by digest, SGLang's amd_march
# branch at one commit, each upstream PR on top at one commit (the line AMD's daily RDNA CI runs green on), the GPU
# target and the Rust toolchain. A moving pin would make two builds of "the same" image differ.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
sha40='^[0-9a-f]{40}$'
[[ $SGLANG_ROCM_BASE_IMAGE =~ ^rocm/pytorch:[^@]+@sha256:[0-9a-f]{64}$ ]] || fail "base image pinned by digest: '$SGLANG_ROCM_BASE_IMAGE'"
[[ $SGLANG_ROCM_REF =~ $sha40 ]] || fail "SGLang ref is a full commit: '$SGLANG_ROCM_REF'"
eq "$SGLANG_ROCM_GIT" "https://github.com/sgl-project/sglang.git" "SGLang repository:"
n=0
for p in $SGLANG_ROCM_PRS; do
  n=$((n + 1)); [[ $p =~ ^[0-9]+:[0-9a-f]{40}$ ]] || fail "PR pin is number:full-commit: '$p'"
done
[ "$n" -ge 1 ] || fail "at least one PR pinned"
eq "$(tr ' ' '\n' <<< "$SGLANG_ROCM_PRS" | cut -d: -f1 | sort | uniq -d)" "" "no PR twice:"
[[ $SGLANG_ROCM_ARCH =~ ^gfx1[01][0-9a-f]{2}$ ]] || fail "an RDNA GPU target: '$SGLANG_ROCM_ARCH'"
[[ $SGLANG_ROCM_RUST =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Rust toolchain pinned to x.y.z: '$SGLANG_ROCM_RUST'"
eq "$SGLANG_ROCM_IMAGE_REPO" "ghcr.io/openinferencefabric/sglang-rocm" "image repository:"
finish
