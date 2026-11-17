#!/bin/bash
# T-212: build Dynamo's SGLang runtime image for RDNA3 (gfx1100: Radeon PRO W7900, RX 7900) from OIF's Dynamo fork
# (branch rocm, as T-211) and optionally push it to GHCR. It is upstream's own build, container/render.py --framework
# sglang --device rocm --target runtime, with one change made by build args only: the base is the S-5 image
# BENCH_SGLANG_IMAGE (by digest) instead of upstream's Instinct-only lmsysorg/sglang ROCm image, so the dynamo-sglang
# stack of oif bench runs exactly the SGLang its sglang stack serves. Dynamo adds no GPU kernels.
# Needs Docker (or Podman), git, about 150 GB free for images and build cache, 1-2 h; no GPU.
#   images/dynamo-sglang-rocm/build.sh                 build and smoke-test; prints the image name
#   images/dynamo-sglang-rocm/build.sh --push          also push to $DYNAMO_SGLANG_ROCM_IMAGE_REPO (log in to ghcr.io
#                                                      first: a GitHub token with write:packages, see guide 16)
#   images/dynamo-sglang-rocm/build.sh --ref <commit>  build another fork commit or branch (default: branch rocm)
# Run it under systemd-run or tmux: the build outlives an SSH session only if its shell does.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=../../versions.env
. "$ROOT/versions.env"
# shellcheck source=../lib.sh
. "$ROOT/images/lib.sh"
REF=$DYNAMO_ROCM_BRANCH; PUSH=0
WORK=${WORK:-$HOME/oif-build/dynamo-sglang-rocm}
while [ $# -gt 0 ]; do
  case $1 in
    --push) PUSH=1 ;;
    --ref) REF=${2:?--ref needs a commit or branch}; shift ;;
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
[ -n "${BENCH_SGLANG_IMAGE:-}" ] || die "BENCH_SGLANG_IMAGE is empty in versions.env: build and pin the S-5 image first (images/sglang-rocm)"
ref=$(split_image "$BENCH_SGLANG_IMAGE") || die "BENCH_SGLANG_IMAGE has no tag: '$BENCH_SGLANG_IMAGE'"
read -r base_repo base_tag <<< "$ref"
root=$($CT info --format '{{.DockerRootDir}}' 2>/dev/null || $CT info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo /var/lib)
mkdir -p "$WORK"
for d in "$root" "$WORK"; do
  f=$(df -P -BG "$d" 2>/dev/null | awk 'NR==2 {sub("G", "", $4); print $4}' || true)
  [ -n "$f" ] || { echo "   (cannot read free space of $d; continuing)"; continue; }
  echo "   $d: ${f} GB free"
  [ "$f" -ge 150 ] || die "$d needs about 150 GB free (base image twice, Rust/UCX/NIXL build layers, the result)"
done
if [ "$PUSH" = 1 ]; then
  cfg=${DOCKER_CONFIG:-$HOME/.docker}/config.json
  grep -q '"ghcr.io"' "$cfg" "${XDG_RUNTIME_DIR:-/nonexistent}/containers/auth.json" 2>/dev/null \
    || die "not logged in to ghcr.io: echo <token> | $CT login ghcr.io -u <github user> --password-stdin (token scope write:packages)"
fi

# ---------------------------------------------------------------- the base: its Python (the wheels must match it), torch, SGLang
say "base $BENCH_SGLANG_IMAGE"
$CT pull -q "$BENCH_SGLANG_IMAGE" >/dev/null || die "cannot pull $BENCH_SGLANG_IMAGE"
versions() {
  $CT run --rm --entrypoint python3 "$1" -c 'import sys, importlib.metadata as m, torch
print("%d.%d" % sys.version_info[:2], torch.__version__, m.version("sglang"))'
}
v=$(versions "$BENCH_SGLANG_IMAGE") || die "cannot read Python, torch and SGLang in the base"
read -r py base_torch base_sglang <<< "$v"
echo "   python $py, torch $base_torch, sglang $base_sglang"

# ---------------------------------------------------------------- source: the fork at one commit
say "Dynamo fork $DYNAMO_ROCM_GIT, $REF"
src=$WORK/src
if [ -d "$src/.git" ]; then git -C "$src" fetch -q origin; else git clone -q "$DYNAMO_ROCM_GIT" "$src"; fi
git -C "$src" -c advice.detachedHead=false checkout -q --force "origin/$REF" 2>/dev/null || git -C "$src" -c advice.detachedHead=false checkout -q --force "$REF"
commit=$(git -C "$src" rev-parse HEAD); short=${commit:0:10}
echo "   commit $commit"

# ---------------------------------------------------------------- render (in a throwaway Python container)
say "render: sglang, rocm, runtime"
$CT run --rm -v "$src":/src:Z -w /src "$DYNAMO_ROCM_RENDER_IMAGE" sh -c \
  'pip -q install --root-user-action=ignore pyyaml jinja2 >/dev/null && PYTHONUTF8=1 python container/render.py --framework sglang --device rocm --target runtime --output-short-filename >/dev/null'
df=$src/container/rendered.Dockerfile
[ -s "$df" ] || die "render produced no $df"

# ---------------------------------------------------------------- build: upstream's Dockerfile, the base swapped by build args
img=$DYNAMO_SGLANG_ROCM_IMAGE_REPO:$short-sglang-${base_tag%%@*}
log=$WORK/build-$short.log
say "build $img (log: $log)"
start=$(date +%s)
if ! (cd "$src" && DOCKER_BUILDKIT=1 $CT build --platform linux/amd64 -f container/rendered.Dockerfile \
        --build-arg BASE_IMAGE="$base_repo" --build-arg BASE_IMAGE_TAG="$base_tag" \
        --build-arg RUNTIME_IMAGE="$base_repo" --build-arg RUNTIME_IMAGE_TAG="$base_tag" \
        --build-arg WHEEL_BUILDER_IMAGE="$BENCH_SGLANG_IMAGE" --build-arg PYTHON_VERSION="$py" \
        --label org.opencontainers.image.source=https://github.com/openinferencefabric/dynamo \
        --label org.opencontainers.image.revision="$commit" \
        --label org.opencontainers.image.base.name="$BENCH_SGLANG_IMAGE" -t "$img" . ) > "$log" 2>&1; then
  tail -40 "$log"; die "build failed after $(( ($(date +%s) - start) / 60 )) min; full log $log"
fi
echo "   built in $(( ($(date +%s) - start) / 60 )) min"

# ---------------------------------------------------------------- smoke test (no GPU needed)
say "smoke test"
v=$(versions "$img") || die "smoke test failed: cannot read torch and SGLang in $img"
read -r _ torch_v sglang_v <<< "$v"
[ "$torch_v $sglang_v" = "$base_torch $base_sglang" ] \
  || die "smoke test failed: torch $torch_v, sglang $sglang_v; the base has torch $base_torch, sglang $base_sglang (Dynamo's install must not replace them)"
$CT run --rm -i --entrypoint python3 "$img" - <<'PY' || die "smoke test failed: the image does not carry a working ROCm Dynamo stack"
import importlib.metadata as m, importlib.util, torch
assert torch.version.hip, "torch is not a ROCm build"
assert not importlib.util.find_spec("aiter"), "aiter must not be installed (RDNA has no aiter kernels)"
assert importlib.util.find_spec("nixl_rocm"), "nixl_rocm missing"
assert not importlib.util.find_spec("nixl_cu12"), "nixl_cu12 must not be installed"
import sgl_kernel, dynamo.sglang, dynamo.frontend  # noqa: F401
# not dynamo.sglang.main or SGLang's server modules: they ask the GPU for its architecture when imported, and this
# test runs without a GPU; serving on the GPU is the lab check (T-212)
print(f"   torch {torch.__version__} (HIP {torch.version.hip}), sglang {m.version('sglang')}, "
      f"ai-dynamo {m.version('ai-dynamo')}, ai-dynamo-runtime {m.version('ai-dynamo-runtime')}")
PY
echo "   size $($CT image inspect "$img" --format '{{.Size}}' | awk '{printf "%.1f GB", $1/1e9}')"

# ---------------------------------------------------------------- push
if [ "$PUSH" = 1 ]; then
  say "push $img"
  digest=$(push_image "$CT" "$img" "$WORK/push-$short.log") && [ -n "$digest" ] || { tail -20 "$WORK/push-$short.log"; die "push failed"; }
  echo "   pushed; pin it in versions.env:  DYNAMO_SGLANG_ROCM_IMAGE=$img@$digest"
  echo "   a new GHCR package is private: make it public in the organisation's Packages settings when it should be"
else
  echo "   not pushed (add --push)"
fi
say "done: $img"
