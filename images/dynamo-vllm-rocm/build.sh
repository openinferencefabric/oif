#!/bin/bash
# T-211 (ADR-002): build Dynamo's vLLM runtime image for AMD GPUs from OIF's Dynamo fork (branch rocm, the
# ROCm device of upstream PR ai-dynamo/dynamo#12537 rebased and co-developed) and optionally push it to GHCR.
# The image is upstream's own build: container/render.py --framework vllm --device rocm --target runtime, on
# vllm/vllm-openai-rocm (the AMD GPUs it serves are vLLM's ROCm list; Dynamo adds no GPU kernels).
# Needs Docker (or Podman), git, about 150 GB free for images and build cache, 1-2 h; no GPU.
#   images/dynamo-vllm-rocm/build.sh                 build and smoke-test; prints the image name
#   images/dynamo-vllm-rocm/build.sh --push          also push to $DYNAMO_ROCM_IMAGE_REPO (log in to ghcr.io first:
#                                                    a GitHub token with write:packages, see guide 16)
#   images/dynamo-vllm-rocm/build.sh --ref <commit>  build another fork commit or branch (default: branch rocm)
#   images/dynamo-vllm-rocm/build.sh --device cuda   B-2: the same fork commit with upstream's CUDA recipe (CUDA 13.0,
#                                                    runtime vllm/vllm-openai at the same vLLM release), pushed to
#                                                    $DYNAMO_CUDA_IMAGE_REPO; the NVIDIA counterpart for oif bench
# Run it under tmux or nohup: the build outlives an SSH session only if its shell does.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=../../versions.env
. "$ROOT/versions.env"
# shellcheck source=../lib.sh
. "$ROOT/images/lib.sh"
REF=$DYNAMO_ROCM_BRANCH; PUSH=0; DEVICE=rocm
while [ $# -gt 0 ]; do
  case $1 in
    --push) PUSH=1 ;;
    --ref) REF=${2:?--ref needs a commit or branch}; shift ;;
    --device) DEVICE=${2:?--device needs rocm or cuda}; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
  shift
done
case $DEVICE in
  rocm) REPO=$DYNAMO_ROCM_IMAGE_REPO; BASE=vllm/vllm-openai-rocm; RENDER_ARGS="--device rocm" ;;
  cuda) REPO=$DYNAMO_CUDA_IMAGE_REPO; BASE=vllm/vllm-openai; RENDER_ARGS="--device cuda --cuda-version 13.0" ;;
  *) echo "--device is rocm or cuda"; exit 2 ;;
esac
WORK=${WORK:-$HOME/oif-build/dynamo-$DEVICE}
say() { echo "== $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------- prerequisites
if command -v docker >/dev/null 2>&1; then CT=docker; elif command -v podman >/dev/null 2>&1; then CT=podman; else die "needs docker or podman"; fi
command -v git >/dev/null || die "needs git"
$CT info >/dev/null 2>&1 || die "$CT is installed but not usable by $(id -un) (daemon down, or not in the docker group)"
root=$($CT info --format '{{.DockerRootDir}}' 2>/dev/null || $CT info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo /var/lib)
mkdir -p "$WORK"
free_gb() { df -P -BG "$1" 2>/dev/null | awk 'NR==2 {sub("G", "", $4); print $4}'; }
for d in "$root" "$WORK"; do
  f=$(free_gb "$d" || true)
  [ -n "$f" ] || { echo "   (cannot read free space of $d; continuing)"; continue; }
  echo "   $d: ${f} GB free"
  [ "$f" -ge 150 ] || die "$d needs about 150 GB free (base image twice, Rust/UCX/NIXL build layers, the result)"
done
if [ "$PUSH" = 1 ]; then
  cfg=${DOCKER_CONFIG:-$HOME/.docker}/config.json
  grep -q '"ghcr.io"' "$cfg" "${XDG_RUNTIME_DIR:-/nonexistent}/containers/auth.json" 2>/dev/null \
    || die "not logged in to ghcr.io: echo <token> | $CT login ghcr.io -u <github user> --password-stdin (token scope write:packages)"
fi

# ---------------------------------------------------------------- source: the fork at one commit, Linux line endings
say "Dynamo fork $DYNAMO_ROCM_GIT, $REF"
src=$WORK/src
if [ -d "$src/.git" ]; then git -C "$src" fetch -q origin; else git clone -q "$DYNAMO_ROCM_GIT" "$src"; fi
git -C "$src" -c advice.detachedHead=false checkout -q --force "origin/$REF" 2>/dev/null || git -C "$src" -c advice.detachedHead=false checkout -q --force "$REF"
commit=$(git -C "$src" rev-parse HEAD); short=${commit:0:10}
echo "   commit $commit"

# ---------------------------------------------------------------- render (in a throwaway Python container)
say "render: vllm, $DEVICE, runtime"
$CT run --rm -v "$src":/src:Z -w /src "$DYNAMO_ROCM_RENDER_IMAGE" sh -c \
  "pip -q install --root-user-action=ignore pyyaml jinja2 >/dev/null && python container/render.py --framework vllm $RENDER_ARGS --target runtime --output-short-filename >/dev/null"
df=$src/container/rendered.Dockerfile
[ -s "$df" ] || die "render produced no $df"
vllm_tag=$(sed -n 's/^ARG RUNTIME_IMAGE_TAG=//p' "$df" | head -1)
echo "   base $BASE:$vllm_tag"

# ---------------------------------------------------------------- build
img=$REPO:$short-vllm${vllm_tag#v}
log=$WORK/build-$short.log
say "build $img (log: $log)"
start=$(date +%s)
if ! (cd "$src" && DOCKER_BUILDKIT=1 $CT build --platform linux/amd64 -f container/rendered.Dockerfile \
        --label org.opencontainers.image.source=https://github.com/openinferencefabric/dynamo \
        --label org.opencontainers.image.revision="$commit" -t "$img" . ) > "$log" 2>&1; then
  tail -40 "$log"; die "build failed after $(( ($(date +%s) - start) / 60 )) min; full log $log"
fi
echo "   built in $(( ($(date +%s) - start) / 60 )) min"

# ---------------------------------------------------------------- smoke test (no GPU needed)
say "smoke test"
$CT run --rm -i -e DEVICE="$DEVICE" --entrypoint python3 "$img" - <<'PY' || die "smoke test failed: the image does not carry a working $DEVICE Dynamo stack"
import importlib.metadata as m, importlib.util, os, torch, vllm
if os.environ["DEVICE"] == "rocm":
    assert torch.version.hip, "torch is not a ROCm build"
    assert importlib.util.find_spec("nixl_rocm"), "nixl_rocm missing"
    assert not importlib.util.find_spec("nixl_cu12"), "nixl_cu12 must not be installed"
else:
    assert torch.version.cuda and not torch.version.hip, "torch is not a CUDA build"
import dynamo.vllm, dynamo.frontend  # noqa: F401  the worker and frontend import
print(f"   torch {torch.__version__} (HIP {torch.version.hip}, CUDA {torch.version.cuda}), vllm {vllm.__version__}, "
      f"ai-dynamo {m.version('ai-dynamo')}, ai-dynamo-runtime {m.version('ai-dynamo-runtime')}")
PY
echo "   size $($CT image inspect "$img" --format '{{.Size}}' | awk '{printf "%.1f GB", $1/1e9}')"

# ---------------------------------------------------------------- push
if [ "$PUSH" = 1 ]; then
  say "push $img"
  digest=$(push_image "$CT" "$img" "$WORK/push-$short.log") && [ -n "$digest" ] || { tail -20 "$WORK/push-$short.log"; die "push failed"; }
  echo "   pushed; pin it in versions.env:  DYNAMO_$(tr a-z A-Z <<< "$DEVICE")_IMAGE=$img@$digest"
  echo "   a new GHCR package is private: make it public in the organisation's Packages settings when it should be"
else
  echo "   not pushed (add --push)"
fi
say "done: $img"
