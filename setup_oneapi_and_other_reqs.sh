#!/bin/bash

#!/usr/bin/env bash
# install-llamacpp-sycl-deps.sh
# Sets up llama.cpp SYCL build dependencies on Fedora 44 with Intel Arc GPU
#
# What this does:
#   1. Adds the Intel oneAPI repo
#   2. Installs build tools, Intel GPU compute stack, and oneAPI toolkit
#   3. Builds and installs the level-zero loader from source
#      (Intel does not ship a Fedora-native RPM for this)

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run as root or with sudo"

if ! grep -q 'Fedora' /etc/os-release 2>/dev/null; then
    warn "This script targets Fedora 44. Proceed with caution on other distros."
fi

# ── 1. Intel oneAPI repo ───────────────────────────────────────────────────────
ONEAPI_REPO=/etc/yum.repos.d/oneAPI.repo

if [[ -f "$ONEAPI_REPO" ]]; then
    info "oneAPI repo already present, skipping"
else
    info "Adding Intel oneAPI repository"
    tee "$ONEAPI_REPO" << 'EOF'
[oneAPI]
name=Intel® oneAPI repository
baseurl=https://yum.repos.intel.com/oneapi
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://yum.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB
EOF
fi

# ── 2. System build tools ──────────────────────────────────────────────────────
info "Installing build tools"
dnf install -y \
    cmake \
    ninja-build \
    gcc \
    gcc-c++ \
    make \
    pkg-config \
    git

# ── 3. Intel GPU compute stack (from Fedora native repos) ─────────────────────
info "Installing Intel GPU compute stack"
dnf install -y \
    intel-gmmlib \
    intel-igc \
    intel-igc-libs \
    intel-opencl \
    intel-opencl-clang \
    intel-level-zero \
    opencl-filesystem \
    OpenCL-ICD-Loader \
    spirv-tools \
    spirv-tools-libs \
    spirv-headers-devel \
    vulkan-loader

# ── 4. oneAPI toolkit ─────────────────────────────────────────────────────────
# NOTE: Do NOT install the generic "intel-oneapi-compiler-shared" /
# "intel-oneapi-compiler-shared-runtime" meta-packages. dnf resolves those
# to an ancient 2021.1.x build, which every modern dpcpp-cpp-runtime
# conflicts with, making the whole transaction unsolvable.
# Pin a specific dpcpp-cpp version instead; it pulls in a matching
# compiler-shared/runtime automatically.
info "Installing Intel oneAPI toolkit packages"
dnf install -y --repo oneAPI \
    intel-oneapi-compiler-dpcpp-cpp-2025.2 \
    intel-oneapi-compiler-dpcpp-cpp-runtime-2025.2 \
    intel-oneapi-tbb \
    intel-oneapi-tbb-devel \
    intel-oneapi-mkl-core \
    intel-oneapi-mkl-devel \
    intel-oneapi-mkl-sycl \
    intel-oneapi-openmp

# Intel does not publish a Fedora-native level-zero loader RPM.
# The el9 RPM from intel-graphics-9.4-unified causes ABI mismatches.
# Build from upstream source instead.

LZ_SRC="${HOME}/level-zero-loader"
LZ_BIN="${LZ_SRC}/build"

if ldconfig -p | grep -q libze_loader; then
    info "level-zero loader already installed, skipping source build"
else
    info "Building level-zero loader from source"
    if [[ -d "$LZ_SRC" ]]; then
        warn "Source dir ${LZ_SRC} exists, pulling latest"
        git -C "$LZ_SRC" pull
    else
        git clone https://github.com/oneapi-src/level-zero "$LZ_SRC"
    fi

    cmake -B "$LZ_BIN" \
          -S "$LZ_SRC" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX=/usr

    cmake --build "$LZ_BIN" -j"$(nproc)"
    cmake --install "$LZ_BIN"
    ldconfig
    info "level-zero loader installed"
fi

# ── 6. Verify ─────────────────────────────────────────────────────────────────
info "Verifying SYCL device enumeration"
if command -v sycl-ls &>/dev/null; then
    sycl-ls
else
    warn "sycl-ls not found — source oneAPI env and retry:"
    warn "  source /opt/intel/oneapi/setvars.sh"
fi

info "Done. To build llama.cpp with SYCL:"
echo ""
echo "  source /opt/intel/oneapi/setvars.sh"
echo "  cmake -B build -DGGML_SYCL=ON -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx"
echo "  cmake --build build --config Release -j\$(nproc)"
echo ""
echo "Run with:"
echo "  ONEAPI_DEVICE_SELECTOR=level_zero:0 bin/llama-cli -m <model> --n-gpu-layers 99"
