# S-5: SGLang for RDNA3 (gfx1100), from SGLang's own docker/rocm-gfx1151.Dockerfile (amd_march) with the GPU target
# changed and aiter left out (RDNA has no aiter kernels; SGLANG_USE_AITER=0, Triton attention). The build context is the
# SGLang source with the pinned PRs applied (images/sglang-rocm/build.sh); every version comes from versions.env.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG GPU_ARCH
ARG RUST_VERSION
ARG MAX_JOBS=16
ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 PYTORCH_ROCM_ARCH=${GPU_ARCH} SGLANG_USE_AITER=0
RUN apt-get update && apt-get install -y --no-install-recommends cmake libnuma-dev && rm -rf /var/lib/apt/lists/* \
 && python3 -c "import torch; assert torch.version.hip; print('torch', torch.__version__, 'HIP', torch.version.hip)" \
 && test -x /opt/rocm/bin/hipcc
ENV PATH="/root/.cargo/bin:${PATH}" CARGO_BUILD_JOBS=8
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain ${RUST_VERSION} \
 && rustc --version
WORKDIR /sgl-workspace
COPY . /sgl-workspace/sglang
RUN cd sglang && rm -f python/pyproject.toml && mv python/pyproject_other.toml python/pyproject.toml
# the kernels, compiled for this GPU only
RUN cd sglang/python/sglang/kernels/aot && rm -f pyproject.toml && mv pyproject_rocm.toml pyproject.toml \
 && AMDGPU_TARGET=${GPU_ARCH} MAX_JOBS=${MAX_JOBS} python3 setup_rocm.py install
# SGLang's runtime dependencies for HIP (srt_hip: the torch 2.10 list; the image's own torch stays), then SGLang itself
RUN cd sglang && python3 - <<'PY'
import subprocess, sys, tomllib
from pathlib import Path
project = tomllib.loads(Path("python/pyproject.toml").read_text())["project"]
extras = project["optional-dependencies"]
reqs = list(project["dependencies"])
for group in ("runtime_base", "runtime_common", "srt_hip"):
    reqs += ["compressed-tensors==0.15.0" if r == "compressed-tensors" else r
             for r in extras[group] if not r.startswith("sglang[") and r != "torch"]
subprocess.check_call([sys.executable, "-m", "pip", "install", "--no-cache-dir", *dict.fromkeys(reqs)])
PY
RUN cd sglang && pip install --no-cache-dir --no-deps -e python
WORKDIR /sgl-workspace/sglang
CMD ["/bin/bash"]
