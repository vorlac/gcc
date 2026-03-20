#!/usr/bin/env bash
#
# Usage:
#   ./build-gcc.sh [--clean] [--jobs N]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# WORKSPACE="${SCRIPT_DIR}"
WORKSPACE=~/gcc-trunk

GCC_SRC_DIR="${WORKSPACE}/gcc-src"
GCC_BUILD_DIR="${WORKSPACE}/gcc-build"
GCC_INSTALL_DIR="${WORKSPACE}/gcc-install"

GCC_GIT_URL="git@github.com:vorlac/gcc.git" # "git://gcc.gnu.org/git/gcc.git"
GCC_GIT_URL_HTTPS="https://github.com/vorlac/gcc.git" # "https://gcc.gnu.org/git/gcc.git"
GCC_GIT_BRANCH="aarch64-apple-darwin" # "master"

LANGUAGES="c,c++"
CLEAN=0
JOBS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)
            CLEAN=1
            shift
            ;;
        --jobs)
            JOBS="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--clean] [--jobs N]"
            exit 1
            ;;
    esac
done

if [[ -z "${JOBS}" ]]; then
    if command -v nproc &>/dev/null; then
        JOBS="$(nproc)"
    elif command -v sysctl &>/dev/null; then
        JOBS="$(sysctl -n hw.ncpu)"
    else
        JOBS=4
    fi
fi

if ! [[ "${JOBS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --jobs requires a positive integer, got '${JOBS}'"
    exit 1
fi

log()   { printf '\033[1;32m>>> %s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33mWARN: %s\033[0m\n' "$*"; }
error() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

check_tool() {
    command -v "$1" &>/dev/null || error "Required tool '$1' not found. Please install it."
}

log "Checking build prerequisites..."
for tool in git make gcc g++ flex bison; do
    # On macOS, g++ may be clang++; that's fine for bootstrapping
    if [[ "$tool" == "g++" ]] && command -v c++ &>/dev/null; then
        continue
    fi
    if [[ "$tool" == "gcc" ]] && command -v cc &>/dev/null; then
        continue
    fi
    check_tool "$tool"
done

# check for required deps...
if command -v brew &>/dev/null; then
    HOMEBREW_PREFIX="$(brew --prefix)"
    for lib in gmp mpfr libmpc isl; do
        if ! brew list --formula "$lib" &>/dev/null 2>&1; then
            error "Missing Homebrew package: $lib. Install with: brew install $lib"
        fi
    done
    log "Homebrew packages (gmp, mpfr, libmpc, isl) found at ${HOMEBREW_PREFIX}"
else
    warn "Homebrew not found. Falling back to GCC's download_prerequisites."
fi

# clean gcc src dir...
if [[ "${CLEAN}" -eq 1 ]]; then
    log "Cleaning gcc source repo directory..."
    rm -rf "${GCC_SRC_DIR}"
fi

if [[ -d "${GCC_SRC_DIR}/.git" ]]; then
    log "GCC source directory exists. Updating..."
    cd "${GCC_SRC_DIR}"

    # # atash local changes
    # if ! git diff --quiet 2>/dev/null; then
    #     warn "Local modifications detected in gcc-src, stashing..."
    #     git stash
    # fi

    git fetch origin "${GCC_GIT_BRANCH}"
    git checkout "${GCC_GIT_BRANCH}"
    git pull --ff-only origin "${GCC_GIT_BRANCH}" || {
        warn "Fast-forward pull failed. Resetting to origin/${GCC_GIT_BRANCH}..."
        git reset --hard "origin/${GCC_GIT_BRANCH}"
    }

    mkdir -p "${WORKSPACE}"
    cd "${WORKSPACE}"
else
    log "Cloning gcc: ${GCC_GIT_URL_HTTPS} [origin/${GCC_GIT_BRANCH}]..."
    git clone --depth=1 --branch="${GCC_GIT_BRANCH}" "${GCC_GIT_URL_HTTPS}" "${GCC_SRC_DIR}"
fi

# gcc ships a convenient script that fetches
# all prereqs/deps into the source tree
if ! command -v brew &>/dev/null; then
    log "Running contrib/download_prerequisites..."
    cd "${GCC_SRC_DIR}"
    ./contrib/download_prerequisites
    cd "${WORKSPACE}"
fi

# clean build dir...
if [[ "${CLEAN}" -eq 1 ]]; then
    log "Cleaning build directory: ${GCC_BUILD_DIR}"
    rm -rf "${GCC_BUILD_DIR}"
fi

mkdir -p "${GCC_BUILD_DIR}"
mkdir -p "${GCC_INSTALL_DIR}"
cd "${GCC_BUILD_DIR}"

# configure...
CONFIGURE_FLAGS=(
    --prefix="${GCC_INSTALL_DIR}"
    --enable-languages="${LANGUAGES}"
    --disable-multilib
    --disable-bootstrap
    --disable-nls
    --disable-libsanitizer
    --enable-checking=release
    --with-system-zlib
)

# point to the homebrew installed deps
if command -v brew &>/dev/null; then
    HOMEBREW_PREFIX="$(brew --prefix)"
    CONFIGURE_FLAGS+=(
        --with-gmp="${HOMEBREW_PREFIX}"
        --with-mpfr="${HOMEBREW_PREFIX}"
        --with-mpc="${HOMEBREW_PREFIX}"
        --with-isl="${HOMEBREW_PREFIX}"
    )

    # for macOS with xcode/clt, set sysroot
    # so gcc can find system headers properly
    if xcode-select -p &>/dev/null; then
        SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null || true)"
        if [[ -n "${SDK_PATH}" ]]; then
            CONFIGURE_FLAGS+=( --with-sysroot="${SDK_PATH}" )
        fi
    fi
fi

# only reconfigure if makefile doesn't
# already exist (allows resuming builds)
if [[ ! -f "${GCC_BUILD_DIR}/Makefile" ]]; then
    log "Configuring GCC..."
    log "  Install prefix: ${GCC_INSTALL_DIR}"
    log "  Languages:      ${LANGUAGES}"
    log "  Flags:          ${CONFIGURE_FLAGS[*]}"

    "${GCC_SRC_DIR}/configure" "${CONFIGURE_FLAGS[@]}"
else
    log "Build directory already configured (use --clean to reconfigure)"
fi

# build...
log "Building GCC with ${JOBS} parallel jobs..."
log "This will take a while (30-90+ minutes depending on hardware)."
make -j"${JOBS}" 2>&1 | tee "${WORKSPACE}/gcc-build.log" || {
    error "Build failed. Check ${WORKSPACE}/gcc-build.log for details."
}

# install...
log "Installing GCC into ${GCC_INSTALL_DIR}..."
make install 2>&1 | tee -a "${WORKSPACE}/gcc-build.log"

# validate...
log "Verifying installation..."
GCC_BIN="${GCC_INSTALL_DIR}/bin/gcc"
GXX_BIN="${GCC_INSTALL_DIR}/bin/g++"

if [[ ! -x "${GXX_BIN}" ]]; then
    error "g++ not found at ${GXX_BIN}"
    error "Installation may have failed."
fi

GCC_VERSION="$("${GXX_BIN}" --version | head -1)"
log "Installed: ${GCC_VERSION}"

# quick smoke test for reflection support
SMOKE_TEST=$(mktemp /tmp/gcc-reflection-test.XXXXXX.cpp)
cat > "${SMOKE_TEST}" << 'CPPEOF'
#include <meta>
#include <iostream>

struct Point {
    int x;
    int y;
};

int main() {
    constexpr auto members = ^^Point | std::meta::members_of | std::meta::filter(std::meta::is_nonstatic_data_member);
    std::cout << "Point has " << members.size() << " members\n";
    [:members[0]:] p{};
    return 0;
}
CPPEOF

log "Running reflection smoke test..."
if "${GXX_BIN}" -std=c++26 -freflection -o /dev/null "${SMOKE_TEST}" 2>/dev/null; then
    log "Reflection smoke test PASSED"
elif "${GXX_BIN}" -std=c++2c -o /dev/null "${SMOKE_TEST}" 2>/dev/null; then
    log "Reflection smoke test PASSED (using -std=c++2c)"
else
    warn "Reflection smoke test did not compile."
    warn "This may be expected if the API has changed. Try manually:"
    warn "  ${GXX_BIN} -std=c++2c -freflection your_file.cpp"
fi

rm -f "${SMOKE_TEST}"
cat << EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  gcc trunk installed successfully!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Version:    ${GCC_VERSION}
  gcc:        ${GCC_BIN}
  g++:        ${GXX_BIN}
  Install:    ${GCC_INSTALL_DIR}

  Usage:
    ${GXX_BIN} -std=c++2c -freflection your_file.cpp

  Or add to your PATH:
    export PATH="${GCC_INSTALL_DIR}/bin:\$PATH"

  Build log:  ${WORKSPACE}/gcc-build.log
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
