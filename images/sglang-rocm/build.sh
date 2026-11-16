#!/bin/bash
# S-5: build SGLang for RDNA3 (gfx1100: Radeon PRO W7900, RX 7900) and optionally push it to GHCR. Upstream SGLang has
# no RDNA image (its ROCm images are Instinct-only); this builds the line AMD's daily RDNA CI runs green on: the
# amd_march branch at SGLANG_ROCM_REF with the PRs of SGLANG_ROCM_PRS on top, sgl-kernel compiled for
# SGLANG_ROCM_ARCH, no aiter, on SGLANG_ROCM_BASE_IMAGE (torch 2.10 + ROCm 7.2.4). Every pin is in versions.env.
# Needs Docker (or Podman), git, about 100 GB free, roughly 1 h; no GPU.
#   images/sglang-rocm/build.sh           build and smoke-test; prints the image name
#   images/sglang-rocm/build.sh --push    also push to $SGLANG_ROCM_IMAGE_REPO (log in to ghcr.io first: a GitHub
#                                         token with write:packages, as for images/dynamo-vllm-rocm, guide 16)
# Run it under tmux or nohup: the build outlives an SSH session only if its shell does.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=../../versions.env
. "$ROOT/versions.env"
PUSH=0
WORK=${WORK:-$HOME/oif-build/sglang-rocm}
while [ $# -gt 0 ]; do
  case $1 in
    --push) PUSH=1 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
  shift
done
say() { echo "== $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------- prerequisites
if command -v docker >/dev/null 2>&1; then CT=docker; elif command -v podman >/dev/null 2>&1; then CT=podman; else die "needs docker or podman"; fi
command -v git >/dev/null || die "needs git"
$CT info >/dev/null 2>&1 || die "$CT is installed but not usable by $(id -un) (daemon down, or not in the docker group)"
root=$($CT info --format '{{.DockerRootDir}}' 2>/dev/null || $CT info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo /var/lib)
mkdir -p "$WORK"
for d in "$root" "$WORK"; do
  f=$(df -P -BG "$d" 2>/dev/null | awk 'NR==2 {sub("G", "", $4); print $4}' || true)
  [ -n "$f" ] || { echo "   (cannot read free space of $d; continuing)"; continue; }
  echo "   $d: ${f} GB free"
  [ "$f" -ge 100 ] || die "$d needs about 100 GB free (the ROCm PyTorch base image, the kernel build, the result)"
done
if [ "$PUSH" = 1 ]; then
  cfg=${DOCKER_CONFIG:-$HOME/.docker}/config.json
  grep -q '"ghcr.io"' "$cfg" "${XDG_RUNTIME_DIR:-/nonexistent}/containers/auth.json" 2>/dev/null \
    || die "not logged in to ghcr.io: echo <token> | $CT login ghcr.io -u <github user> --password-stdin (token scope write:packages)"
fi

# ---------------------------------------------------------------- source: amd_march at one commit, the pinned PRs on top
say "SGLang $SGLANG_ROCM_GIT at ${SGLANG_ROCM_REF:0:10}, PRs: $(tr ' ' '\n' <<< "$SGLANG_ROCM_PRS" | cut -d: -f1 | sed 's/^/#/' | xargs)"
src=$WORK/src
if [ -d "$src/.git" ]; then git -C "$src" fetch -q origin; else git clone -q "$SGLANG_ROCM_GIT" "$src"; fi
git -C "$src" -c advice.detachedHead=false checkout -q --force "$SGLANG_ROCM_REF"
git -C "$src" clean -qfdx
for p in $SGLANG_ROCM_PRS; do
  n=${p%%:*} c=${p#*:}
  git -C "$src" fetch -q origin "refs/pull/$n/head" || die "cannot fetch PR #$n"
  [ "$(git -C "$src" rev-parse FETCH_HEAD)" = "$c" ] || echo "   note: PR #$n has moved on since it was pinned; applying the pinned commit ${c:0:10}"
  git -C "$src" cherry-pick --no-commit "$c" >/dev/null || die "PR #$n (${c:0:10}) does not apply on ${SGLANG_ROCM_REF:0:10}"
  echo "   applied #$n ${c:0:10}"
done
prs=$(sha256sum <<< "$SGLANG_ROCM_PRS" | cut -c1-8)

# ---------------------------------------------------------------- build
img=$SGLANG_ROCM_IMAGE_REPO:${SGLANG_ROCM_REF:0:10}-$SGLANG_ROCM_ARCH-prs$prs
log=$WORK/build-${SGLANG_ROCM_REF:0:10}.log
say "build $img (log: $log)"
start=$(date +%s)
if ! (cd "$src" && DOCKER_BUILDKIT=1 $CT build --platform linux/amd64 -f "$ROOT/images/sglang-rocm/Dockerfile" \
        --build-arg BASE_IMAGE="$SGLANG_ROCM_BASE_IMAGE" --build-arg GPU_ARCH="$SGLANG_ROCM_ARCH" \
        --build-arg RUST_VERSION="$SGLANG_ROCM_RUST" \
        --label org.opencontainers.image.source=https://github.com/openinferencefabric/oif \
        --label org.opencontainers.image.revision="$SGLANG_ROCM_REF" \
        --label ai.oif.sglang.prs="$SGLANG_ROCM_PRS" -t "$img" . ) > "$log" 2>&1; then
  tail -40 "$log"; die "build failed after $(( ($(date +%s) - start) / 60 )) min; full log $log"
fi
echo "   built in $(( ($(date +%s) - start) / 60 )) min"

# ---------------------------------------------------------------- smoke test (no GPU needed)
say "smoke test"
$CT run --rm -i --entrypoint python3 "$img" - <<'PY' || die "smoke test failed: the image does not carry a working ROCm SGLang"
import importlib.metadata as m, importlib.util, torch
assert torch.version.hip, "torch is not a ROCm build"
assert not importlib.util.find_spec("aiter"), "aiter must not be installed (RDNA has no aiter kernels)"
import sglang, sgl_kernel  # noqa: F401  the server package and the kernels built for this GPU
from sglang.srt.entrypoints import http_server  # noqa: F401  what launch_server imports
def v(*names):  # ROCm images ship Triton as pytorch-triton-rocm
    for n in names:
        try: return m.version(n)
        except m.PackageNotFoundError: pass
    return "-"
print(f"   torch {torch.__version__} (HIP {torch.version.hip}), triton {v('triton', 'pytorch-triton-rocm')}, "
      f"sglang {v('sglang')}, sglang-kernel {v('sglang-kernel')}")
PY
echo "   size $($CT image inspect "$img" --format '{{.Size}}' | awk '{printf "%.1f GB", $1/1e9}')"

# ---------------------------------------------------------------- push
if [ "$PUSH" = 1 ]; then
  say "push $img"
  $CT push "$img" > "$WORK/push.log" 2>&1 || { tail -20 "$WORK/push.log"; die "push failed"; }
  digest=$($CT image inspect "$img" --format '{{range .RepoDigests}}{{println .}}{{end}}' | grep "^$SGLANG_ROCM_IMAGE_REPO@" | head -1)
  echo "   pushed; pin it in versions.env:  BENCH_SGLANG_IMAGE=$img@${digest#*@}"
  echo "   a new GHCR package is private: make it public in the organisation's Packages settings when it should be"
else
  echo "   not pushed (add --push)"
fi
say "done: $img"
