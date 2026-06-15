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
    vulkan-loader \
    clinfo

# ── 4. oneAPI toolkit ─────────────────────────────────────────────────────────
# NOTE: Do NOT install the generic "intel-oneapi-compiler-shared" /
# "intel-oneapi-compiler-shared-runtime" meta-packages. dnf resolves those
# to an ancient 2021.1.x build, which every modern dpcpp-cpp-runtime
# conflicts with, making the whole transaction unsolvable.
#
# IMPORTANT: install the FULL "intel-oneapi-compiler-dpcpp-cpp-<ver>" SDK
# package, NOT just "-runtime". A bare "-runtime"/"-shared-runtime" install
# gives you the SYCL libraries (libsycl.so.*) but NO icx/icpx/headers — and
# if that runtime-only tree ends up as the "latest" compiler version, cmake
# either can't find a compiler at all, or you build with one version's
# compiler while linking against another version's libsycl, producing
# undefined sycl::_V1::* references. The full SDK package below pulls in its
# OWN matching runtime, keeping the whole toolchain on one version.
#
# Note: `dnf list available 'intel-oneapi-compiler-dpcpp-cpp-*'` may not
# surface the full SDK package due to glob handling, but it IS installable
# by exact name (verify with: dnf install --assumeno ...<pkg>).
ONEAPI_COMPILER_VERSION="2026.0"

info "Installing Intel oneAPI toolkit packages (dpcpp-cpp ${ONEAPI_COMPILER_VERSION})"
dnf install -y --repo oneAPI \
    intel-oneapi-compiler-dpcpp-cpp-2026.0 \
    intel-oneapi-tbb \
    intel-oneapi-tbb-devel \
    intel-oneapi-mkl-core \
    intel-oneapi-mkl-devel \
    intel-oneapi-mkl-sycl \
    intel-oneapi-openmp

# If a runtime-only package from a DIFFERENT version got pulled in
# previously as a transitive dependency, it leaves behind a second,
# incomplete /opt/intel/oneapi/compiler/<ver>/ tree that can sort ahead of
# the real SDK in PATH after sourcing setvars.sh, causing icx/icpx/sycl-ls
# to "not be found" even though the real SDK is installed.
# Remove any such stray runtime-only packages so only the full SDK remains.
info "Checking for stray runtime-only compiler packages from other versions"
for pkg in $(rpm -qa | grep -E 'intel-oneapi-(compiler-dpcpp-cpp-runtime|compiler-shared-runtime)-[0-9]' | grep -v "$ONEAPI_COMPILER_VERSION"); do
    warn "Removing stray package: $pkg (incomplete compiler tree, conflicts with ${ONEAPI_COMPILER_VERSION} SDK on PATH)"
    dnf remove -y "$pkg"
done

# Self-heal orphaned compiler trees: removing the runtime-only RPMs above
# (or earlier failed installs) can leave behind a /opt/intel/oneapi/compiler/<ver>/
# directory that no RPM owns. setvars.sh resolves the compiler via the
# `latest` symlink and by picking the highest version directory present, so
# a stale orphaned tree from a different version will keep shadowing the
# real SDK — exporting the wrong CMPLR_ROOT / LD_LIBRARY_PATH and breaking
# the link step (libsycl.so version mismatch). Delete any compiler version
# dir not owned by an installed RPM, then repoint `latest` at the real SDK.
COMPILER_BASE="/opt/intel/oneapi/compiler"
info "Checking for orphaned (non-RPM-owned) compiler trees under ${COMPILER_BASE}"
for verdir in "$COMPILER_BASE"/*/; do
    ver=$(basename "$verdir")
    [[ "$ver" == "latest" ]] && continue
    # A real SDK tree has an icx binary owned by an RPM; orphaned trees do not.
    if ! rpm -qf "${verdir}bin/icx" &>/dev/null && ! rpm -qf "${verdir}lib/libsycl.so" &>/dev/null; then
        warn "Removing orphaned compiler tree (no RPM owns it): ${verdir}"
        rm -rf "$verdir"
    fi
done

# Repoint the `latest` symlink at the installed SDK version if it is
# dangling or pointing at a version that no longer exists.
LATEST_LINK="${COMPILER_BASE}/latest"
if [[ -d "${COMPILER_BASE}/${ONEAPI_COMPILER_VERSION}" ]]; then
    if [[ ! -e "$LATEST_LINK" ]] || [[ "$(readlink "$LATEST_LINK")" != "$ONEAPI_COMPILER_VERSION" ]]; then
        warn "Repointing ${LATEST_LINK} -> ${ONEAPI_COMPILER_VERSION}"
        rm -f "$LATEST_LINK"
        ln -s "$ONEAPI_COMPILER_VERSION" "$LATEST_LINK"
    fi
fi

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
ONEAPI_COMPILER_BIN="/opt/intel/oneapi/compiler/${ONEAPI_COMPILER_VERSION}/bin"
ONEAPI_COMPILER_LIB="/opt/intel/oneapi/compiler/${ONEAPI_COMPILER_VERSION}/lib"

# Note: sycl-ls is no longer shipped in some recent oneAPI compiler
# releases, so use clinfo (installed above) to enumerate GPU devices
# via the OpenCL/level-zero stack instead.
info "Verifying GPU device enumeration"
if command -v clinfo &>/dev/null; then
    clinfo -l
else
    warn "clinfo not found — source oneAPI env and retry:"
    warn "  source /opt/intel/oneapi/setvars.sh --force"
fi

info "Done. To build llama.cpp with SYCL:"
echo ""
echo "  source /opt/intel/oneapi/setvars.sh --force"
echo ""
echo "  # With only the ${ONEAPI_COMPILER_VERSION} compiler tree present and 'latest'"
echo "  # pointing at it (the cleanup above guarantees this), a plain build works:"
echo "  rm -rf build"
echo "  cmake -B build -DGGML_SYCL=ON -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx"
echo "  cmake --build build --config Release -j\$(nproc)"
echo ""
echo "  # Fallback only if you intentionally keep multiple compiler versions"
echo "  # and the link step can't find libsycl.so.* (undefined sycl::_V1::*"
echo "  # references): pin the linker to the matching lib dir explicitly:"
echo "  #   -DCMAKE_EXE_LINKER_FLAGS=\"-Wl,-rpath,${ONEAPI_COMPILER_LIB}\""
echo "  #   -DCMAKE_SHARED_LINKER_FLAGS=\"-Wl,-rpath,${ONEAPI_COMPILER_LIB}\""
echo ""
echo "Run with:"
echo "  ONEAPI_DEVICE_SELECTOR=level_zero:0 bin/llama-cli -m <model> --n-gpu-layers 99"
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
    vulkan-loader \
    clinfo

# ── 4. oneAPI toolkit ─────────────────────────────────────────────────────────
# NOTE: Do NOT install the generic "intel-oneapi-compiler-shared" /
# "intel-oneapi-compiler-shared-runtime" meta-packages. dnf resolves those
# to an ancient 2021.1.x build, which every modern dpcpp-cpp-runtime
# conflicts with, making the whole transaction unsolvable.
#
# IMPORTANT: install the FULL "intel-oneapi-compiler-dpcpp-cpp-<ver>" SDK
# package, NOT just "-runtime". A bare "-runtime"/"-shared-runtime" install
# (which dnf may silently pull in as a transitive dep at a *different*,
# newer version) gives you libraries but no icx/icpx/sycl-ls — and if that
# runtime-only version ends up earlier in PATH than your real SDK, `cmake`
# will find a *different* compiler tree than the one you intended, or none
# at all.
#
# As of writing, the oneAPI dnf repo's "available" listing only surfaces
# the "-runtime"/"-shared-runtime" packages for the current default
# version (e.g. 2026.0) — the full SDK package for older versions
# (e.g. 2025.2) is still installable by exact name even though it doesn't
# show up in `dnf list available`. 2025.2 is confirmed working for
# llama.cpp SYCL builds, so pin it explicitly here.
ONEAPI_COMPILER_VERSION="2025.2"

info "Installing Intel oneAPI toolkit packages (dpcpp-cpp ${ONEAPI_COMPILER_VERSION})"
dnf install -y --repo oneAPI \
    intel-oneapi-compiler-dpcpp-cpp-2025.2 \
    intel-oneapi-tbb \
    intel-oneapi-tbb-devel \
    intel-oneapi-mkl-core \
    intel-oneapi-mkl-devel \
    intel-oneapi-mkl-sycl \
    intel-oneapi-openmp

# If a runtime-only package from a DIFFERENT version got pulled in
# previously as a transitive dependency, it leaves behind a second,
# incomplete /opt/intel/oneapi/compiler/<ver>/ tree that can sort ahead of
# the real SDK in PATH after sourcing setvars.sh, causing icx/icpx/sycl-ls
# to "not be found" even though the real SDK is installed.
# Remove any such stray runtime-only packages so only the full SDK remains.
info "Checking for stray runtime-only compiler packages from other versions"
for pkg in $(rpm -qa | grep -E 'intel-oneapi-(compiler-dpcpp-cpp-runtime|compiler-shared-runtime)-[0-9]' | grep -v "$ONEAPI_COMPILER_VERSION"); do
    warn "Removing stray package: $pkg (incomplete compiler tree, conflicts with ${ONEAPI_COMPILER_VERSION} SDK on PATH)"
    dnf remove -y "$pkg"
done

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
ONEAPI_COMPILER_BIN="/opt/intel/oneapi/compiler/${ONEAPI_COMPILER_VERSION}/bin"
ONEAPI_COMPILER_LIB="/opt/intel/oneapi/compiler/${ONEAPI_COMPILER_VERSION}/lib"

# Note: sycl-ls is no longer shipped in some recent oneAPI compiler
# releases, so use clinfo (installed above) to enumerate GPU devices
# via the OpenCL/level-zero stack instead.
info "Verifying GPU device enumeration"
if command -v clinfo &>/dev/null; then
    clinfo -l
else
    warn "clinfo not found — source oneAPI env and retry:"
    warn "  source /opt/intel/oneapi/setvars.sh --force"
fi

info "Done. To build llama.cpp with SYCL:"
echo ""
echo "  source /opt/intel/oneapi/setvars.sh --force"
echo ""
echo "  # If multiple oneAPI compiler versions are installed, an older/newer"
echo "  # runtime tree may shadow ${ONEAPI_COMPILER_VERSION} on PATH. Use explicit full paths"
echo "  # for icx/icpx to guarantee the ${ONEAPI_COMPILER_VERSION} SDK is used."
echo "  # The rpath flags ensure the linker finds libsycl.so.8 at"
echo "  # ${ONEAPI_COMPILER_LIB} (ld.bfd does not honor LD_LIBRARY_PATH"
echo "  # for this without it, causing undefined sycl::_V1::* references)."
echo "  cmake -B build -DGGML_SYCL=ON \\"
echo "    -DCMAKE_C_COMPILER=${ONEAPI_COMPILER_BIN}/icx \\"
echo "    -DCMAKE_CXX_COMPILER=${ONEAPI_COMPILER_BIN}/icpx \\"
echo "    -DCMAKE_EXE_LINKER_FLAGS=\"-Wl,-rpath,${ONEAPI_COMPILER_LIB}\" \\"
echo "    -DCMAKE_SHARED_LINKER_FLAGS=\"-Wl,-rpath,${ONEAPI_COMPILER_LIB}\""
echo "  cmake --build build --config Release -j\$(nproc)"
echo ""
echo "Run with:"
echo "  ONEAPI_DEVICE_SELECTOR=level_zero:0 bin/llama-cli -m <model> --n-gpu-layers 99"#!/bin/bash

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
    vulkan-loader \
    clinfo

# ── 4. oneAPI toolkit ─────────────────────────────────────────────────────────
# NOTE: Do NOT install the generic "intel-oneapi-compiler-shared" /
# "intel-oneapi-compiler-shared-runtime" meta-packages. dnf resolves those
# to an ancient 2021.1.x build, which every modern dpcpp-cpp-runtime
# conflicts with, making the whole transaction unsolvable.
#
# IMPORTANT: install the FULL "intel-oneapi-compiler-dpcpp-cpp-<ver>" SDK
# package, NOT just "-runtime". A bare "-runtime"/"-shared-runtime" install
# (which dnf may silently pull in as a transitive dep at a *different*,
# newer version) gives you libraries but no icx/icpx/sycl-ls — and if that
# runtime-only version ends up earlier in PATH than your real SDK, `cmake`
# will find a *different* compiler tree than the one you intended, or none
# at all.
#
# Rather than hardcoding a version (which silently goes stale as Intel
# ships new releases — the exact issue that caused this script to break),
# discover the latest dpcpp-cpp SDK version actually available in the repo
# and install that.
info "Detecting latest available oneAPI dpcpp-cpp SDK version"
DPCPP_PKG=$(dnf list available --repo oneAPI 'intel-oneapi-compiler-dpcpp-cpp-*' 2>/dev/null \
    | awk '/^intel-oneapi-compiler-dpcpp-cpp-[0-9]/ {print $1}' \
    | sort -t- -k5 -V | tail -1)

[[ -z "$DPCPP_PKG" ]] && error "Could not find any intel-oneapi-compiler-dpcpp-cpp-* package in the oneAPI repo"

DPCPP_VER=$(echo "$DPCPP_PKG" | grep -oE '[0-9]+\.[0-9]+$')
info "Using ${DPCPP_PKG} (version ${DPCPP_VER})"

info "Installing Intel oneAPI toolkit packages"
dnf install -y --repo oneAPI \
    "$DPCPP_PKG" \
    intel-oneapi-tbb \
    intel-oneapi-tbb-devel \
    intel-oneapi-mkl-core \
    intel-oneapi-mkl-devel \
    intel-oneapi-mkl-sycl \
    intel-oneapi-openmp

# If a runtime-only package from a DIFFERENT version got pulled in
# previously as a transitive dependency, it leaves behind a second,
# incomplete /opt/intel/oneapi/compiler/<ver>/ tree that can sort ahead of
# the real SDK in PATH after sourcing setvars.sh, causing icx/icpx/sycl-ls
# to "not be found" even though the real SDK is installed.
# Remove any such stray runtime-only packages so only the full SDK remains.
info "Checking for stray runtime-only compiler packages from other versions"
for pkg in $(rpm -qa | grep -E 'intel-oneapi-(compiler-dpcpp-cpp-runtime|compiler-shared-runtime)-[0-9]' | grep -v "$DPCPP_VER"); do
    warn "Removing stray package: $pkg (incomplete compiler tree, conflicts with ${DPCPP_VER} SDK on PATH)"
    dnf remove -y "$pkg"
done

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
ONEAPI_COMPILER_BIN="/opt/intel/oneapi/compiler/${DPCPP_VER}/bin"

# ── 6. Verify ─────────────────────────────────────────────────────────────────
ONEAPI_COMPILER_BIN="/opt/intel/oneapi/compiler/${DPCPP_VER}/bin"

# Note: sycl-ls is no longer shipped in some recent oneAPI compiler
# releases, so use clinfo (installed above) to enumerate GPU devices
# via the OpenCL/level-zero stack instead.
info "Verifying GPU device enumeration"
if command -v clinfo &>/dev/null; then
    clinfo -l
else
    warn "clinfo not found — source oneAPI env and retry:"
    warn "  source /opt/intel/oneapi/setvars.sh --force"
fi

info "Done. To build llama.cpp with SYCL:"
echo ""
echo "  source /opt/intel/oneapi/setvars.sh --force"
echo ""
echo "  # If multiple oneAPI compiler versions are installed, an older/newer"
echo "  # runtime tree may shadow ${DPCPP_VER} on PATH. Use explicit full paths"
echo "  # for icx/icpx to guarantee the ${DPCPP_VER} SDK is used:"
echo "  cmake -B build -DGGML_SYCL=ON \\"
echo "    -DCMAKE_C_COMPILER=${ONEAPI_COMPILER_BIN}/icx \\"
echo "    -DCMAKE_CXX_COMPILER=${ONEAPI_COMPILER_BIN}/icpx"
echo "  cmake --build build --config Release -j\$(nproc)"
echo ""
echo "Run with:"
echo "  ONEAPI_DEVICE_SELECTOR=level_zero:0 bin/llama-cli -m <model> --n-gpu-layers 99"#!/bin/bash

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
