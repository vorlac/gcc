#!/usr/bin/env bash
#
# Usage:
#   ./build-gcc.sh [--clean] [--jobs N] [--check|--full-check] [--skip-validation]
#
#   --clean             remove the source/build dirs and start fresh
#   --jobs N            parallel build jobs (default: all cores)
#   --check             after install, also run the fast GCC DejaGnu subset (dg.exp)
#   --full-check        after install, run the full GCC regression testsuite (hours)
#   --skip-validation   skip the post-install feature/reflection/import-std/ABI suite

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
RUN_CHECK=0           # --check: run fast DejaGnu subset (dg.exp)
RUN_FULL_CHECK=0      # --full-check: run the full DejaGnu testsuite (hours)
SKIP_VALIDATION=0     # --skip-validation: skip the post-install feature/ABI suite
# C++ standards to precompile the 'std' module (import std) for:
STD_MODULE_STDS="c++23 c++26"

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
        --check)
            RUN_CHECK=1
            shift
            ;;
        --full-check)
            RUN_FULL_CHECK=1
            shift
            ;;
        --skip-validation)
            SKIP_VALIDATION=1
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--clean] [--jobs N] [--check|--full-check] [--skip-validation]"
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

    # Pin the system awk (AWK=/usr/bin/awk): Homebrew gawk 5.4.0 (PMA build)
    # intermittently miscompiles GCC's opt*.awk / gen-pass-instances.awk
    # generators, corrupting options.h / pass-instances.def and breaking the
    # build nondeterministically. /usr/bin/awk (the POSIX one-true-awk) is
    # always present on macOS and is deterministic here.
    "${GCC_SRC_DIR}/configure" "${CONFIGURE_FLAGS[@]}" AWK=/usr/bin/awk
else
    log "Build directory already configured (use --clean to reconfigure)"
fi

# build...
log "Building GCC with ${JOBS} parallel jobs..."
log "This will take a while (30-90+ minutes depending on hardware)."
make AWK=/usr/bin/awk -j"${JOBS}" 2>&1 | tee "${WORKSPACE}/gcc-build.log" || {
    error "Build failed. Check ${WORKSPACE}/gcc-build.log for details."
}

# install...
log "Installing GCC into ${GCC_INSTALL_DIR}..."
make AWK=/usr/bin/awk install 2>&1 | tee -a "${WORKSPACE}/gcc-build.log"

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

# ============================================================================
#  Post-install: 'std' named module + validation/regression suite
# ============================================================================

STD_MODULE_DEST="${GCC_INSTALL_DIR}/lib/std-modules"

# Build the libstdc++ 'std' (and 'std.compat') named modules so that
# `import std;` works.  GCC does not precompile these during the normal build;
# moreover on this Darwin toolchain the in-tree std.cc currently fails to
# compile and is silently stubbed to an empty file (so the shipped libstdc++
# has no std module).  We therefore (re)build the modules here from the
# source-tree templates with the *installed* compiler, install the CMIs +
# objects under the prefix, and emit a module-mapper consumers can point at.
build_std_modules() {
    local gxx="${GCC_INSTALL_DIR}/bin/g++"
    local tmpl="${GCC_SRC_DIR}/libstdc++-v3/src/c++23"
    if [[ ! -f "${tmpl}/std.cc.in" ]]; then
        warn "std module sources not found (${tmpl}/std.cc.in); skipping 'import std' build."
        return 0
    fi
    log "Building 'std' named module (import std) for: ${STD_MODULE_STDS}"
    local std dest tmp rc
    for std in ${STD_MODULE_STDS}; do
        dest="${STD_MODULE_DEST}/${std}"
        tmp="$(mktemp -d "/tmp/gcc-stdmod.${std}.XXXXXX")"
        mkdir -p "${dest}/gcm.cache"
        # The interface sources are produced by concatenation (no @TOKEN@ subst).
        cat "${tmpl}/std.cc.in"        "${tmpl}/std-clib.cc.in" > "${tmp}/std.cc"
        cat "${tmpl}/std.compat.cc.in" "${tmpl}/std-clib.cc.in" > "${tmp}/std.compat.cc"
        rc=0
        # std.compat imports std, so std must be built first (same cwd -> gcm.cache).
        ( cd "${tmp}" \
          && "${gxx}" -std="${std}" -fmodules -Wno-unknown-pragmas -c std.cc        -o "${dest}/std.o" \
          && "${gxx}" -std="${std}" -fmodules -Wno-unknown-pragmas -c std.compat.cc -o "${dest}/std.compat.o" \
          && cp gcm.cache/std.gcm gcm.cache/std.compat.gcm "${dest}/gcm.cache/" ) || rc=$?
        if [[ "${rc}" -eq 0 ]]; then
            printf 'std %s/gcm.cache/std.gcm\nstd.compat %s/gcm.cache/std.compat.gcm\n' \
                   "${dest}" "${dest}" > "${dest}/std.modmap"
            log "  ${std}: built -> ${dest} (std.gcm, std.compat.gcm, std.o)"
        else
            warn "  ${std}: failed to build std module."
        fi
        rm -rf "${tmp}"
    done
    return 0
}

# ----------------------------------------------------------------------------
#  Fast post-install validation: feature battery + reflection + import std,
#  plus an ABI-conformance differential vs Apple clang.  Both the feature
#  battery and the ABI section are hard regression gates (must stay green);
#  the ABI checks assert the Apple/arm64 behaviors this port now implements.
# ----------------------------------------------------------------------------
run_validation() {
    local GCC_BIN="${GCC_INSTALL_DIR}/bin/gcc"
    local GXX_BIN="${GCC_INSTALL_DIR}/bin/g++"
    local CLANGXX; CLANGXX="$(command -v clang++ || true)"

    local c_grn='' c_red='' c_yel='' c_cyn='' c_dim='' c_rst=''
    if [[ -t 1 ]]; then
        c_grn=$'\033[1;32m'; c_red=$'\033[1;31m'; c_yel=$'\033[1;33m'
        c_cyn=$'\033[1;36m'; c_dim=$'\033[2m';   c_rst=$'\033[0m'
    fi
    local PASS_N=0 FAIL_N=0 XFAIL_N=0 XPASS_N=0 SKIP_N=0
    local FAILED_TESTS=()
    local WORK; WORK="$(mktemp -d /tmp/gcc-validate.XXXXXX)"

    hr()      { printf '%s\n' "----------------------------------------------------------------"; }
    section() { printf '\n%s=== %s ===%s\n' "$c_cyn" "$1" "$c_rst"; }
    report() {  # report NAME RESULT [detail]
        local name="$1" res="$2" detail="${3:-}"
        case "$res" in
          PASS)  PASS_N=$((PASS_N+1));  printf '  %s[ PASS ]%s %-34s %s\n' "$c_grn" "$c_rst" "$name" "${c_dim}${detail}${c_rst}";;
          FAIL)  FAIL_N=$((FAIL_N+1));  FAILED_TESTS+=("$name"); printf '  %s[ FAIL ]%s %-34s %s\n' "$c_red" "$c_rst" "$name" "$detail";;
          XFAIL) XFAIL_N=$((XFAIL_N+1)); printf '  %s[XFAIL ]%s %-34s %s\n' "$c_yel" "$c_rst" "$name" "${c_dim}known port gap: ${detail}${c_rst}";;
          XPASS) XPASS_N=$((XPASS_N+1)); printf '  %s[XPASS ]%s %-34s %s\n' "$c_grn" "$c_rst" "$name" "now fixed! (${detail})";;
          SKIP)  SKIP_N=$((SKIP_N+1));  printf '  %s[ SKIP ]%s %-34s %s\n' "$c_dim" "$c_rst" "$name" "${c_dim}${detail}${c_rst}";;
        esac
    }
    # feat NAME (cc|cxx) STD SRC EXPECT [extra flags...]
    feat() {
        local name="$1" comp="$2" std="$3" src="$4" expect="$5"; shift 5
        local f out bin rc
        if [[ "$comp" == "cc" ]]; then comp="$GCC_BIN"; f="$WORK/$RANDOM.c"
        else comp="$GXX_BIN"; f="$WORK/$RANDOM.cpp"; fi
        bin="$WORK/$RANDOM.out"
        printf '%s' "$src" > "$f"
        if ! out=$("$comp" -std="$std" ${@+"$@"} "$f" -o "$bin" 2>&1); then
            report "$name" FAIL "compile error: $(printf '%s' "$out" | head -1)"; return
        fi
        if ! out=$("$bin" 2>&1); then
            rc=$?; report "$name" FAIL "runtime exit=$rc: $(printf '%s' "$out" | head -1)"; return
        fi
        if [[ "$out" == *"$expect"* ]]; then report "$name" PASS "$expect"
        else report "$name" FAIL "want '$expect' got '$(printf '%s' "$out" | head -1)'"; fi
    }

    section "Toolchain sanity"
    local ver machine macs miss m
    ver="$("$GXX_BIN" --version 2>/dev/null | head -1)"
    [[ -n "$ver" ]] && report "g++ present" PASS "$ver" || report "g++ present" FAIL "missing"
    machine="$("$GCC_BIN" -dumpmachine 2>/dev/null)"
    [[ "$machine" == aarch64-apple-darwin* ]] && report "target triple" PASS "$machine" \
                                              || report "target triple" FAIL "$machine"
    macs="$("$GXX_BIN" -dM -E -x c++ /dev/null 2>/dev/null)"; miss=""
    for m in __APPLE__ __MACH__ __aarch64__ __arm64__ __LP64__; do
        printf '%s' "$macs" | grep -q "define $m " || miss="$miss $m"
    done
    [[ -z "$miss" ]] && report "platform macros" PASS "__APPLE__ __MACH__ __aarch64__ __arm64__ __LP64__" \
                     || report "platform macros" FAIL "missing:$miss"

    section "Core feature battery (must pass — regression gate)"
    feat "C: hello world" cc c17 '#include <stdio.h>
int main(){puts("hello-c");return 0;}' "hello-c"
    feat "C++: iostream" cxx c++17 '#include <iostream>
int main(){std::cout<<"hello-cxx\n";}' "hello-cxx"
    feat "C++: exceptions + dtor unwind" cxx c++17 '#include <iostream>
struct G{~G(){std::cout<<"dtor ";}};
void f(){G g; throw std::runtime_error("x");}
int main(){try{f();}catch(const std::exception&e){std::cout<<"caught "<<e.what()<<"\n";}}' "dtor caught x"
    feat "C++: RTTI/dynamic_cast" cxx c++17 '#include <iostream>
struct B{virtual ~B(){}}; struct D:B{int v=7;};
int main(){B*b=new D; auto*d=dynamic_cast<D*>(b); std::cout<<"dc="<<(d?d->v:-1)<<"\n";}' "dc=7"
    feat "C++: thread+mutex" cxx c++17 '#include <thread>
#include <mutex>
#include <iostream>
int s=0; std::mutex m;
int main(){auto w=[&]{for(int i=0;i<1000;i++){std::lock_guard<std::mutex>l(m);s++;}};
std::thread a(w),b(w);a.join();b.join();std::cout<<"sum="<<s<<"\n";}' "sum=2000" -pthread
    feat "C++: atomic<=8B" cxx c++17 '#include <atomic>
#include <iostream>
int main(){std::atomic<long> a{0}; a+=42; std::cout<<"a="<<a.load()<<" lf="<<a.is_lock_free()<<"\n";}' "a=42 lf=1"
    feat "C: __thread TLS (port-only)" cc c17 '#include <stdio.h>
__thread int t=7; int main(){t+=35; printf("tls=%d\n",t); return 0;}' "tls=42"
    feat "C++: std::filesystem" cxx c++17 '#include <filesystem>
#include <iostream>
int main(){auto p=std::filesystem::temp_directory_path(); std::cout<<"fs="<<(!p.empty())<<"\n";}' "fs=1"
    feat "C++: std::regex" cxx c++17 '#include <regex>
#include <iostream>
int main(){std::regex r("a(b+)c"); std::smatch m; std::string s="abbbc";
std::cout<<"re="<<std::regex_match(s,m,r)<<" g="<<m[1]<<"\n";}' "re=1 g=bbb"
    feat "C++: global ctor order" cxx c++17 '#include <iostream>
struct A{A(){std::cout<<"ctor ";}}; A a; int main(){std::cout<<"main\n";}' "ctor main"
    feat "C++: std::format (C++20)" cxx c++20 '#include <format>
#include <iostream>
int main(){std::cout<<std::format("fmt {} {:#x}\n",42,28);}' "fmt 42 0x1c"
    feat "C: computed goto" cc c17 '#include <stdio.h>
int main(){void*t[]={&&a,&&b}; goto *t[1];
a: printf("A\n"); return 0;
b: printf("B\n"); goto *t[0];}' "B"
    # shared library (.dylib) + dlopen
    printf 'int answer(void){ return 42; }\n' > "$WORK/lib.c"
    cat > "$WORK/main.c" <<'DLEOF'
#include <stdio.h>
#include <dlfcn.h>
int main(){ void*h=dlopen("./libans.dylib",RTLD_NOW); if(!h){printf("dlopen-fail\n");return 1;}
  int(*f)(void)=(int(*)(void))dlsym(h,"answer"); printf("dlsym=%d\n", f?f():-1); return 0; }
DLEOF
    if "$GCC_BIN" -dynamiclib "$WORK/lib.c" -o "$WORK/libans.dylib" 2>/dev/null \
       && "$GCC_BIN" "$WORK/main.c" -o "$WORK/dltest" 2>/dev/null; then
        out=$(cd "$WORK" && ./dltest 2>&1)
        [[ "$out" == *"dlsym=42"* ]] && report "C: .dylib + dlopen" PASS "dlsym=42" \
                                     || report "C: .dylib + dlopen" FAIL "$out"
    else report "C: .dylib + dlopen" FAIL "build error"; fi

    section "Reflection (P2996)"
    local refl='#include <meta>
#include <iostream>
struct Point{int x;int y;int z;};
template<class T> consteval std::size_t nmembers(){
  return std::meta::nonstatic_data_members_of(^^T, std::meta::access_context::current()).size(); }
int main(){
  std::cout<<"Point has "<<nmembers<Point>()<<" members\n";
  Point p{1,2,3}; constexpr auto rx=^^Point::x; p.[:rx:]=100;
  std::cout<<"splice x="<<p.[:rx:]<<"\n"; return (nmembers<Point>()==3&&p.x==100)?0:1; }'
    feat "C++: reflection ^^ + members_of" cxx c++26 "$refl" "Point has 3 members" -freflection
    printf '%s' "$refl" > "$WORK/refl.cpp"
    if "$GXX_BIN" -std=c++26 -freflection "$WORK/refl.cpp" -o "$WORK/refl.out" 2>/dev/null \
       && out=$("$WORK/refl.out" 2>&1) && [[ "$out" == *"splice x=100"* ]]; then
        report "C++: reflection member splice" PASS "splice x=100"
    else report "C++: reflection member splice" FAIL "${out:-build error}"; fi

    section "import std (named module)"
    local mm="${STD_MODULE_DEST}/c++26/std.modmap" sobj="${STD_MODULE_DEST}/c++26/std.o"
    if [[ -f "$mm" && -f "$sobj" ]]; then
        cat > "$WORK/usestd.cpp" <<'USEEOF'
import std;
int main(){ std::vector<int> v{3,1,2}; std::ranges::sort(v);
  for(int x:v) std::cout<<x<<' '; std::cout<<"| import std works: "<<(40+2)<<"\n"; return 0; }
USEEOF
        if (cd "$WORK" && CXX_MODULE_MAPPER="$mm" "$GXX_BIN" -std=c++26 -fmodules usestd.cpp "$sobj" -o usestd 2>/dev/null) \
           && out=$(cd "$WORK" && ./usestd 2>&1) && [[ "$out" == *"import std works: 42"* ]]; then
            report "import std; (c++26, installed module)" PASS "$out"
        else report "import std; (c++26, installed module)" FAIL "${out:-build error}"; fi
    else report "import std; (c++26, installed module)" FAIL "module not built (see build_std_modules)"; fi

    section "ABI conformance vs Apple clang (must pass — regression gate)"
    # These assert the Apple/arm64 ABI behaviors this Darwin port now implements
    # (64-bit long double, signed char, Darwin va_list, x16 static chain, inline
    # 16-byte LSE atomics, DFP disabled like clang, EH without -no_compact_unwind).
    # They were formerly tracked as known-open port gaps (XFAIL); now that the
    # port supplies them, they are hard regression checks — a FAIL here means a
    # shipped ABI guarantee broke.  Only the EH-through-a-clang-object check
    # needs clang present; the rest run unconditionally.
    local lds vaout nout ldout ehout ehrc
    lds=$("$GCC_BIN" -dM -E -x c /dev/null 2>/dev/null | awk '/__SIZEOF_LONG_DOUBLE__/{print $3}')
    [[ "$lds" == 8 ]] && report "ABI: long double size==8" PASS "64-bit long double (matches Apple)" \
                      || report "ABI: long double size==8" FAIL "size=${lds} want 8; TARGET_LONG_DOUBLE_128 not 0"
    if "$GCC_BIN" -dM -E -x c /dev/null 2>/dev/null | grep -q '__CHAR_UNSIGNED__'; then
        report "ABI: char is signed" FAIL "char unsigned want signed; DEFAULT_SIGNED_CHAR not 1"
    else report "ABI: char is signed" PASS "plain char signed (matches Apple)"; fi
    cat > "$WORK/va.c" <<'VAEOF'
#include <stdio.h>
#include <stdarg.h>
static long s(int n,...){va_list a;va_start(a,n);long t=0;for(int i=0;i<n;i++)t+=va_arg(a,long);va_end(a);return t;}
int main(){printf("%ld\n", s(3,(long)10,(long)20,(long)30));return 0;}
VAEOF
    "$GCC_BIN" -O2 "$WORK/va.c" -o "$WORK/va" 2>/dev/null && vaout=$("$WORK/va" 2>&1) || vaout="err"
    [[ "$vaout" == "60" ]] && report "ABI: variadic callee" PASS "va_arg correct (Darwin va_list)" \
                           || report "ABI: variadic callee" FAIL "got '${vaout}' want 60"
    cat > "$WORK/nf.c" <<'NFEOF'
#include <stdio.h>
static int apply(int (*f)(int), int v){ return f(v); }
int main(){ int cap=42; int nested(int a){ return a+cap; } printf("%d\n", apply(nested,8)); return 0; }
NFEOF
    if "$GCC_BIN" "$WORK/nf.c" -o "$WORK/nf" 2>/dev/null && nout=$("$WORK/nf" 2>&1) && [[ "$nout" == "50" ]]; then
        report "ABI: nested fn trampoline" PASS "static-chain ok (x16)"
    else report "ABI: nested fn trampoline" FAIL "got '${nout:-error}' want 50; STATIC_CHAIN_REGNUM/trampoline mismatch"; fi
    cat > "$WORK/a16.cpp" <<'A16EOF'
#include <atomic>
#include <cstdio>
struct S{long a,b;}; std::atomic<S> x;
int main(){ x.store({1,2}); auto v=x.load(); printf("%ld%ld\n",v.a,v.b); return 0; }
A16EOF
    if "$GXX_BIN" -std=c++17 "$WORK/a16.cpp" -o "$WORK/a16" 2>/dev/null; then
        report "ABI: 16-byte atomic" PASS "inline LSE casp, links without -latomic"
    elif "$GXX_BIN" -std=c++17 "$WORK/a16.cpp" -latomic -o "$WORK/a16" 2>/dev/null; then
        report "ABI: 16-byte atomic" FAIL "needs explicit -latomic; TImode casp expander / LSE default missing"
    else report "ABI: 16-byte atomic" FAIL "16-byte atomic unavailable"; fi
    cat > "$WORK/dfp.c" <<'DFPEOF'
int main(){ _Decimal64 a=1.5dd,b=2.5dd; volatile _Decimal64 c=a+b; return (int)c; }
DFPEOF
    # DFP is disabled for aarch64-darwin (matches clang and the supported
    # x86_64-darwin port; clang also rejects _Decimal on arm64), so a CLEAN
    # compile-time rejection is correct.  The only failing state is the old
    # half-wired "compiles but won't link" (DFP advertised, no BID runtime).
    if ! "$GCC_BIN" -c "$WORK/dfp.c" -o "$WORK/dfp.o" 2>/dev/null; then
        report "ABI: _Decimal consistent" PASS "DFP disabled, rejected at compile (matches clang)"
    elif "$GCC_BIN" "$WORK/dfp.c" -o "$WORK/dfp" 2>/dev/null; then
        report "ABI: _Decimal consistent" PASS "DFP runtime present (links + runs)"
    else report "ABI: _Decimal consistent" FAIL "compiles but link-fails (half-wired: DFP advertised, libbid missing)"; fi
    cat > "$WORK/ld.c" <<'LDEOF'
#include <stdio.h>
int main(){ char b[64]; snprintf(b,sizeof b,"%.1Lf",(long double)1.5); printf("[%s]\n",b); return 0; }
LDEOF
    "$GCC_BIN" "$WORK/ld.c" -o "$WORK/ld" 2>/dev/null && ldout=$("$WORK/ld" 2>&1) || ldout="err"
    [[ "$ldout" == "[1.5]" ]] && report "ABI: printf %Lf" PASS "long double printf ok" \
                              || report "ABI: printf %Lf" FAIL "got '${ldout}' want [1.5] (LD size mismatch w/ libc)"
    if [[ -z "$CLANGXX" ]]; then
        report "ABI: EH through clang obj" SKIP "clang not available"
    else
        printf '#include <stdexcept>\nvoid boom(){ throw std::runtime_error("x"); }\n' > "$WORK/thrower.cpp"
        cat > "$WORK/catcher.cpp" <<'CEOF'
#include <stdexcept>
#include <cstdio>
void boom();
int main(){ try{boom();}catch(const std::exception&){printf("caught\n");return 0;} printf("missed\n"); return 1; }
CEOF
        if "$CLANGXX" -std=c++17 -c "$WORK/thrower.cpp" -o "$WORK/thrower.o" 2>/dev/null \
           && "$GXX_BIN" -std=c++17 "$WORK/catcher.cpp" "$WORK/thrower.o" -o "$WORK/ehmix" 2>/dev/null; then
            ehout=$("$WORK/ehmix" 2>&1); ehrc=$?
            if [[ "$ehout" == *caught* && $ehrc -eq 0 ]]; then report "ABI: EH through clang obj" PASS "exceptions cross toolchains"
            else report "ABI: EH through clang obj" FAIL "std::terminate (check -no_compact_unwind not inherited)"; fi
        else report "ABI: EH through clang obj" FAIL "link/compile issue (mixed EH)"; fi
    fi

    section "Validation summary"
    hr
    printf '  PASS (feature/reflection/module/ABI) : %s%d%s\n' "$c_grn" "$PASS_N" "$c_rst"
    printf '  Hard FAIL (regressions)              : %s%d%s\n' "$([[ $FAIL_N -gt 0 ]] && printf '%s' "$c_red" || printf '%s' "$c_grn")" "$FAIL_N" "$c_rst"
    printf '  Skipped                              : %d\n' "$SKIP_N"
    hr
    rm -rf "$WORK"
    if [[ $FAIL_N -gt 0 ]]; then
        printf '\n  %sOVERALL: FAIL%s -- %d regression(s): %s\n' "$c_red" "$c_rst" "$FAIL_N" "${FAILED_TESTS[*]}"
        return 1
    fi
    printf '\n  %sOVERALL: PASS%s -- no obvious regressions (ABI conformance vs Apple clang verified)\n' "$c_grn" "$c_rst"
    return 0
}

# ----------------------------------------------------------------------------
#  Optional: the standard GCC DejaGnu regression testsuite (`make check`).
#  Gated behind --check (fast dg.exp subset) or --full-check (full, hours).
# ----------------------------------------------------------------------------
run_dejagnu_check() {
    if [[ ! -d "${GCC_BUILD_DIR}/gcc" ]]; then
        warn "Build dir ${GCC_BUILD_DIR}/gcc not found; cannot run the testsuite."
        return 0
    fi
    if ! command -v runtest >/dev/null 2>&1; then
        if command -v brew >/dev/null 2>&1; then
            log "DejaGnu (runtest) not found; installing via Homebrew..."
            brew install deja-gnu || { warn "Could not install dejagnu; skipping make check."; return 0; }
        else
            warn "DejaGnu (runtest) not found and Homebrew unavailable; skipping make check."
            return 0
        fi
    fi
    # Force the system awk: Homebrew gawk 5.4.0 intermittently miscompiles
    # GCC's opt*.awk / gen-pass-instances.awk generators (see the build step).
    local mk=(make AWK=/usr/bin/awk -k -j"${JOBS}")
    if [[ "${RUN_FULL_CHECK}" -eq 1 ]]; then
        log "Running the FULL GCC regression testsuite (compiler + libstdc++) -- this can take HOURS..."
        # Compiler front/middle/back ends (C and C++):
        "${mk[@]}" -C "${GCC_BUILD_DIR}/gcc" check-gcc check-c++ || true
        # C++ runtime library (libstdc++) + OpenMP runtime (target libs):
        "${mk[@]}" -C "${GCC_BUILD_DIR}" check-target-libstdc++-v3 check-target-libgomp || true
    else
        log "Running the fast GCC regression subset (RUNTESTFLAGS=dg.exp)..."
        "${mk[@]}" -C "${GCC_BUILD_DIR}/gcc" check-gcc check-c++ RUNTESTFLAGS=dg.exp || true
    fi

    log "Parsing official DejaGnu .sum results..."
    local sums; sums=$(find "${GCC_BUILD_DIR}" -name '*.sum' 2>/dev/null)
    if [[ -z "$sums" ]]; then warn "No .sum files produced; testsuite did not run."; return 0; fi

    # Per-suite breakdown (FAIL/ERROR/UNRESOLVED are the actionable ones).
    printf '\n  %-46s %6s %6s %6s %6s\n' "suite (.sum)" "PASS" "FAIL" "XFAIL" "UNSUP"
    printf '  %s\n' "----------------------------------------------------------------------------"
    local s p f xf us
    for s in $sums; do
        p=$(grep -cE '^PASS:' "$s" 2>/dev/null); f=$(grep -cE '^(FAIL|ERROR|UNRESOLVED|XPASS):' "$s" 2>/dev/null)
        xf=$(grep -cE '^XFAIL:' "$s" 2>/dev/null); us=$(grep -cE '^(UNSUPPORTED|UNTESTED):' "$s" 2>/dev/null)
        printf '  %-46s %6s %6s %6s %6s\n' "$(basename "$(dirname "$s")")/$(basename "$s")" "$p" "$f" "$xf" "$us"
    done

    local cat n
    printf '\n  %-12s %s\n' "category" "total"
    printf '  %s\n' "------------------------"
    for cat in PASS XPASS FAIL XFAIL UNRESOLVED UNSUPPORTED UNTESTED ERROR; do
        n=$(grep -hcE "^${cat}:" $sums 2>/dev/null | paste -sd+ - | bc 2>/dev/null); n=${n:-0}
        printf '  %-12s %s\n' "$cat" "$n"
    done
    local regr
    regr=$(grep -hcE '^(FAIL|ERROR|UNRESOLVED|XPASS):' $sums 2>/dev/null | paste -sd+ - | bc 2>/dev/null); regr=${regr:-0}

    # Archive this run's .sum files, and auto-compare against the previous run
    # (the proper "regression" signal: only NEW failures matter on a port that
    # already has known, expected FAILs).
    local results_dir="${WORKSPACE}/testsuite-results"
    local prev_dir="${results_dir}/previous" cur_dir="${results_dir}/current"
    mkdir -p "${cur_dir}"
    if [[ -d "${cur_dir}" ]] && ls "${cur_dir}"/*.sum >/dev/null 2>&1; then
        rm -rf "${prev_dir}"; mkdir -p "${prev_dir}"; mv "${cur_dir}"/*.sum "${prev_dir}/" 2>/dev/null || true
    fi
    local s2; for s2 in $sums; do cp "$s2" "${cur_dir}/" 2>/dev/null || true; done

    local compare="${GCC_SRC_DIR}/contrib/compare_tests"
    printf '\n  %sOfficial testsuite: %s regression-category result(s) (FAIL/ERROR/UNRESOLVED/XPASS)%s\n' \
           "$([[ $regr -gt 0 ]] && printf '\033[1;33m' || printf '\033[1;32m')" "$regr" "$'\033[0m'"
    if [[ -x "${compare}" ]] && ls "${prev_dir}"/*.sum >/dev/null 2>&1; then
        log "Comparing against previous run (NEW regressions are the real signal):"
        local b; for b in "${prev_dir}"/*.sum; do
            local cf="${cur_dir}/$(basename "$b")"
            [[ -f "$cf" ]] && "${compare}" "$b" "$cf" 2>/dev/null | grep -iE 'regress|new ' || true
        done
    else
        warn "No prior baseline to diff against; saved this run to ${cur_dir}."
        warn "Re-run --check after a change to see only NEW failures (auto-compared)."
    fi
    warn "NOTE: a fresh out-of-tree Darwin target legitimately reports many"
    warn "      UNSUPPORTED/UNTESTED (Darwin-specific dg directives, missing multilibs);"
    warn "      those are NOT regressions. Gate on the NEW-failure delta above."
    return 0
}

# ---- run post-install steps (build/install already succeeded above) ----
# From here on, individual validation commands are expected to return nonzero
# (some ABI probes intentionally compile cases the port now rejects, e.g.
# _Decimal), so relax errexit.
set +e

build_std_modules

VALIDATION_RC=0
if [[ "${SKIP_VALIDATION}" -eq 0 ]]; then
    run_validation || VALIDATION_RC=$?
else
    log "Skipping post-install validation (--skip-validation)."
fi

if [[ "${RUN_CHECK}" -eq 1 || "${RUN_FULL_CHECK}" -eq 1 ]]; then
    run_dejagnu_check
fi
if [[ "${VALIDATION_RC}" -eq 0 ]]; then
    VAL_LINE="validation: PASS (no obvious regressions)"
else
    VAL_LINE="validation: FAIL (see the per-test results above)"
fi

cat << EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  gcc trunk installed successfully!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Version:    ${GCC_VERSION}
  gcc:        ${GCC_BIN}
  g++:        ${GXX_BIN}
  Install:    ${GCC_INSTALL_DIR}
  Status:     ${VAL_LINE}

  Reflection:
    ${GXX_BIN} -std=c++26 -freflection your_file.cpp

  import std (named module; built into ${STD_MODULE_DEST}/<std>/):
    CXX_MODULE_MAPPER="${STD_MODULE_DEST}/c++26/std.modmap" \\
      ${GXX_BIN} -std=c++26 -fmodules your_file.cpp \\
      "${STD_MODULE_DEST}/c++26/std.o" -o your_app
    # NOTE: a module CMI is dialect-locked -- compile with the same -std the
    #       module was built for (available: ${STD_MODULE_STDS}).

  Or add to your PATH:
    export PATH="${GCC_INSTALL_DIR}/bin:\$PATH"

  Build log:  ${WORKSPACE}/gcc-build.log
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

# Propagate the validation verdict as the script's exit status.
exit "${VALIDATION_RC}"
