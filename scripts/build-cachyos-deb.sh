#!/usr/bin/env bash
set -euo pipefail

# Build a CachyOS Linux release as Debian .deb packages.
# This is a Debian-oriented translation of the CachyOS linux-cachyos PKGBUILD flow.
#
# Usage:
#   build-cachyos-deb.sh VARIANT PROCESSOR_OPT LLVM_LTO [SOURCE_TAG]
#
# Examples:
#   build-cachyos-deb.sh linux-cachyos X86_64_V3 full cachyos-7.2.8-1
#   build-cachyos-deb.sh linux-cachyos-bore X86_64_V3 thin cachyos-7.2.8-1
#
# SOURCE_TAG may also be omitted; in that case it is derived from the current
# upstream linux-cachyos/PKGBUILD.

UPSTREAM_PACKAGING_REPO="${UPSTREAM_PACKAGING_REPO:-https://raw.githubusercontent.com/CachyOS/linux-cachyos/master}"
UPSTREAM_SOURCE_REPO="${UPSTREAM_SOURCE_REPO:-https://github.com/CachyOS/linux}"
KERNEL_PATCH_REPO="${KERNEL_PATCH_REPO:-https://raw.githubusercontent.com/cachyos/kernel-patches/master}"

VARIANT="${1:?Variant is required}"
PROCESSOR_OPT="${2:?_processor_opt is required}"
LLVM_LTO="${3:?_use_llvm_lto is required}"
SOURCE_TAG="${4:-}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/work}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output}"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

case "$VARIANT" in
  linux-cachyos)         CPUSCHED='cachyos' ;;
  linux-cachyos-bore)    CPUSCHED='bore' ;;
  linux-cachyos-bmq)     CPUSCHED='bmq' ;;
  linux-cachyos-eevdf)   CPUSCHED='eevdf' ;;
  linux-cachyos-hardened) CPUSCHED='hardened' ;;
  linux-cachyos-rt-bore) CPUSCHED='rt-bore' ;;
  *) die "Unsupported Variant: $VARIANT" ;;
esac

case "$PROCESSOR_OPT" in
  X86_64_V2|X86_64_V3|X86_64_V4|ZEN4|NATIVE) ;;
  *) die "Unsupported _processor_opt: $PROCESSOR_OPT" ;;
esac

case "$LLVM_LTO" in
  full|thin|thin-dist|none) ;;
  *) die "Unsupported _use_llvm_lto: $LLVM_LTO" ;;
esac

resolve_latest_tag() {
  local pkgb
  local major minor tagrel
  pkgb="$(mktemp)"
  trap 'rm -f "$pkgb"' RETURN

  curl -fsSL --retry 5 --retry-all-errors \
    "${UPSTREAM_PACKAGING_REPO}/linux-cachyos/PKGBUILD" -o "$pkgb"

  major="$(awk -F= '/^_major=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$pkgb")"
  minor="$(awk -F= '/^_minor=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$pkgb")"
  tagrel="$(awk -F= '/^_tagrel=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$pkgb")"

  [[ -n "$major" && -n "$minor" && -n "$tagrel" ]] || \
    die 'Could not resolve _major/_minor/_tagrel from upstream PKGBUILD.'

  printf 'cachyos-%s.%s-%s\n' "$major" "$minor" "$tagrel"
}

if [[ -z "$SOURCE_TAG" ]]; then
  SOURCE_TAG="$(resolve_latest_tag)"
elif [[ "$SOURCE_TAG" != cachyos-* ]]; then
  if [[ "$SOURCE_TAG" =~ ^[0-9]+\.[0-9]+(\.[0-9]+|-rc[0-9]+)-[0-9]+$ ]]; then
    SOURCE_TAG="cachyos-${SOURCE_TAG}"
  else
    die "Invalid source tag: $SOURCE_TAG"
  fi
fi

if [[ ! "$SOURCE_TAG" =~ ^cachyos-[0-9]+\.[0-9]+(\.[0-9]+|-rc[0-9]+)-[0-9]+$ ]]; then
  die "Source tag must look like cachyos-7.2.8-1 or cachyos-7.2-rc8-1: $SOURCE_TAG"
fi

PKGREL="${SOURCE_TAG##*-}"

say "CachyOS build configuration"
printf '  Variant       : %s\n' "$VARIANT"
printf '  Scheduler     : %s\n' "$CPUSCHED"
printf '  CPU optimize  : %s\n' "$PROCESSOR_OPT"
printf '  LLVM LTO      : %s\n' "$LLVM_LTO"
printf '  Source tag    : %s\n' "$SOURCE_TAG"
printf '  Package rel   : %s\n' "$PKGREL"

SOURCE_TARBALL_URL="${UPSTREAM_SOURCE_REPO}/releases/download/${SOURCE_TAG}/${SOURCE_TAG}.tar.gz"
PATCH_BASE="${KERNEL_PATCH_REPO}"

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT" "$OUTPUT_DIR"

TARBALL="$BUILD_ROOT/${SOURCE_TAG}.tar.gz"
SRC_DIR="$BUILD_ROOT/${SOURCE_TAG}"

say 'Downloading CachyOS source tarball'
curl -fL --retry 5 --retry-all-errors \
  "$SOURCE_TARBALL_URL" -o "$TARBALL"

say 'Extracting source'
tar -xzf "$TARBALL" -C "$BUILD_ROOT"
[[ -d "$SRC_DIR" ]] || die "Expected extracted source directory not found: $SRC_DIR"
rm -f "$TARBALL"

cd "$SRC_DIR"

KERNEL_VERSION="$(make -s kernelversion)"
KERNEL_MAJOR_MINOR="$(printf '%s\n' "$KERNEL_VERSION" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
[[ -n "$KERNEL_MAJOR_MINOR" ]] || die "Unable to derive kernel major/minor from $KERNEL_VERSION"

VARIANT_SUFFIX="${VARIANT#linux-}"

say 'Installing CachyOS configuration'
curl -fsSL --retry 5 --retry-all-errors \
  "${UPSTREAM_PACKAGING_REPO}/${VARIANT}/config" -o .config

[[ -s .config ]] || die "Downloaded configuration is empty: ${VARIANT}/config"

apply_patch_url() {
  local url="$1"
  local file
  file="$BUILD_ROOT/$(basename "$url")"
  say "Applying $(basename "$url")"
  curl -fsSL --retry 5 --retry-all-errors "$url" -o "$file"
  patch -Np1 < "$file"
}

# The upstream PKGBUILD adds dkms-clang.patch for all Clang/LTO builds.
if [[ "$LLVM_LTO" != 'none' ]]; then
  apply_patch_url "${PATCH_BASE}/${KERNEL_MAJOR_MINOR}/misc/dkms-clang.patch"
fi

# Scheduler-specific patches, matching the PKGBUILD's case statement.
case "$CPUSCHED" in
  bore)
    apply_patch_url "${PATCH_BASE}/${KERNEL_MAJOR_MINOR}/sched/0001-bore-cachy.patch"
    ;;
  bmq)
    apply_patch_url "${PATCH_BASE}/${KERNEL_MAJOR_MINOR}/sched/0001-prjc-cachy.patch"
    ;;
  hardened)
    apply_patch_url "${PATCH_BASE}/${KERNEL_MAJOR_MINOR}/sched/0001-bore-cachy.patch"
    apply_patch_url "${PATCH_BASE}/${KERNEL_MAJOR_MINOR}/misc/0001-hardened.patch"
    ;;
  rt)
    apply_patch_url "${PATCH_BASE}/${KERNEL_MAJOR_MINOR}/misc/0001-rt-i915.patch"
    ;;
  rt-bore)
    apply_patch_url "${PATCH_BASE}/${KERNEL_MAJOR_MINOR}/sched/0001-bore-cachy.patch"
    apply_patch_url "${PATCH_BASE}/${KERNEL_MAJOR_MINOR}/misc/0001-rt-i915.patch"
    ;;
  cachyos|eevdf)
    ;;
esac

# Match the version suffix logic in the supplied PKGBUILD, while also making
# the selected CPU optimization part of kernelrelease. This makes kernels built
# from the same source/variant distinguishable on the target Debian system.
# Examples:
#   7.2.8-1-cachyos-x86-64-v3-lto-full
#   7.2.8-1-cachyos-bore-x86-64-v3-lto-thin
CPU_SUFFIX="${PROCESSOR_OPT,,}"
CPU_SUFFIX="${CPU_SUFFIX//_/-}"
CPU_SUFFIX="${CPU_SUFFIX/zen4/znver4}"

# Encode the selected _use_llvm_lto value into kernelrelease too.
# This keeps kernels built with the same source/variant/CPU optimization
# distinguishable on Debian (and therefore gives them separate /lib/modules
# directories, initramfs names and package names).
case "$LLVM_LTO" in
  full)      LTO_SUFFIX='lto-full' ;;
  thin)      LTO_SUFFIX='lto-thin' ;;
  thin-dist) LTO_SUFFIX='lto-thin-dist' ;;
  none)      LTO_SUFFIX='lto-none' ;;
  *)         die "Unsupported _use_llvm_lto: $LLVM_LTO" ;;
esac

RELEASE_SUFFIX="-${PKGREL}-${VARIANT_SUFFIX}-${CPU_SUFFIX}-${LTO_SUFFIX}"

# Use LOCALVERSION as the authoritative release suffix instead of relying only
# on localversion.* files. The upstream CachyOS source archive may already have
# generated release metadata, and Kbuild can otherwise reuse that stale value.
# Removing the generated release file and exporting LOCALVERSION guarantees that
# make prepare/kernelrelease/bindeb-pkg all use the exact same release string.
rm -f include/config/kernel.release include/generated/utsrelease.h
rm -f localversion.10-pkgrel localversion.20-pkgname
export LOCALVERSION="$RELEASE_SUFFIX"

say 'Selecting CPU optimization'
case "$PROCESSOR_OPT" in
  X86_64_V2)
    scripts/config -e GENERIC_CPU -d MZEN4 -d X86_NATIVE_CPU --set-val X86_64_VERSION 2
    ;;
  X86_64_V3)
    scripts/config -e GENERIC_CPU -d MZEN4 -d X86_NATIVE_CPU --set-val X86_64_VERSION 3
    ;;
  X86_64_V4)
    scripts/config -e GENERIC_CPU -d MZEN4 -d X86_NATIVE_CPU --set-val X86_64_VERSION 4
    ;;
  ZEN4)
    scripts/config -d GENERIC_CPU -e MZEN4 -d X86_NATIVE_CPU
    ;;
  NATIVE)
    scripts/config -d GENERIC_CPU -d MZEN4 -e X86_NATIVE_CPU
    ;;
esac

say 'Applying CachyOS scheduler/config selections'
scripts/config -e CACHY

# This mirrors the supplied PKGBUILD exactly for its _cpusched values.
case "$CPUSCHED" in
  cachyos|bore|hardened)
    scripts/config -e SCHED_BORE
    ;;
  bmq)
    scripts/config -e SCHED_ALT -e SCHED_BMQ
    ;;
  eevdf)
    :
    ;;
  rt)
    scripts/config -e PREEMPT_RT
    ;;
  rt-bore)
    scripts/config -e SCHED_BORE -e PREEMPT_RT
    ;;
esac

say "Selecting ${LLVM_LTO} LTO"
# Clear the LTO choice first so that old config values cannot survive the override.
for sym in LTO_NONE LTO_CLANG_THIN LTO_CLANG_THIN_DIST LTO_CLANG_FULL; do
  scripts/config -d "$sym" 2>/dev/null || true
done

case "$LLVM_LTO" in
  thin)      scripts/config -e LTO_CLANG_THIN ;;
  thin-dist) scripts/config -e LTO_CLANG_THIN_DIST ;;
  full)      scripts/config -e LTO_CLANG_FULL ;;
  none)      scripts/config -e LTO_NONE ;;
esac

say 'Selecting fixed CachyOS tuning from the supplied PKGBUILD'
# _HZ_ticks=1000
scripts/config -d HZ_300 -e HZ_1000 --set-val HZ 1000

# _tickrate=full
scripts/config \
  -d HZ_PERIODIC \
  -d NO_HZ_IDLE \
  -d CONTEXT_TRACKING_FORCE \
  -e NO_HZ_FULL_NODEF \
  -e NO_HZ_FULL \
  -e NO_HZ \
  -e NO_HZ_COMMON \
  -e CONTEXT_TRACKING

# _preempt=full, except RT variants where the upstream PKGBUILD does not set PREEMPT.
if [[ "$CPUSCHED" != 'rt' && "$CPUSCHED" != 'rt-bore' ]]; then
  scripts/config -e PREEMPT -d PREEMPT_LAZY
fi

# _hugepage=always
scripts/config -d TRANSPARENT_HUGEPAGE_MADVISE -e TRANSPARENT_HUGEPAGE_ALWAYS

# _cc_harder=yes
scripts/config \
  -d CC_OPTIMIZE_FOR_PERFORMANCE \
  -d CC_OPTIMIZE_FOR_SIZE \
  -e CC_OPTIMIZE_FOR_PERFORMANCE_O3

# Explicit CI requirement from the user/upstream CI behavior.
scripts/config -d DEBUG_KERNEL -e DEBUG_INFO_REDUCED

# Ensure the config is fully resolved with the same compiler mode that will be used for the build.
# This is important for Clang LTO choices: Kconfig must see LLVM capabilities.
say 'Running olddefconfig'
if [[ "$LLVM_LTO" != 'none' ]]; then
  make LLVM=1 LLVM_IAS=1 olddefconfig
else
  make olddefconfig
fi

# Recreate include/config/kernel.release after the final config and release
# suffix are in place. Without this explicit prepare, an existing generated
# kernel.release can keep the source archive's original release string.
say 'Regenerating kernelrelease metadata'
rm -f include/config/kernel.release include/generated/utsrelease.h
if [[ "$LLVM_LTO" != 'none' ]]; then
  make LLVM=1 LLVM_IAS=1 prepare
else
  make prepare
fi

EXPECTED_KERNELRELEASE="$(make -s kernelrelease)"
EXPECTED_SUFFIX="${KERNEL_VERSION}${RELEASE_SUFFIX}"
if [[ "$EXPECTED_KERNELRELEASE" != "$EXPECTED_SUFFIX" ]]; then
  die "kernelrelease mismatch: expected ${EXPECTED_SUFFIX}, got ${EXPECTED_KERNELRELEASE}"
fi

say 'Kernel configuration summary'
printf '  kernelversion = %s\n' "$(make -s kernelversion)"
printf '  kernelrelease = %s\n' "$(make -s kernelrelease)"
printf '  compiler = %s\n' "$(grep -E '^CONFIG_CC_VERSION_TEXT=' .config | head -n1)"
printf '  CACHY = %s\n' "$(grep -E '^CONFIG_CACHY=' .config || true)"
printf '  DEBUG_KERNEL = %s\n' "$(grep -E '^CONFIG_DEBUG_KERNEL=' .config || printf 'not set\n')"
printf '  HZ = %s\n' "$(grep -E '^CONFIG_HZ=' .config | head -n1)"
printf '  PREEMPT = %s\n' "$(grep -E '^CONFIG_PREEMPT(_LAZY)?=' .config | head -n3 | tr '\n' ' ' || true)"
printf '  LTO = %s\n' "$(grep -E '^CONFIG_LTO_' .config | head -n5 | tr '\n' ' ' || true)"
printf '  CPU = %s\n' "$(grep -E '^CONFIG_(GENERIC_CPU|MZEN4|X86_NATIVE_CPU|X86_64_VERSION)=' .config | tr '\n' ' ' || true)"

# Kbuild uses LLVM=1 to switch all relevant compiler/binutils utilities to Clang/LLVM.
MAKE_FLAGS=(ARCH=x86_64 KBUILD_DEBARCH=amd64)
if [[ "$LLVM_LTO" != 'none' ]]; then
  MAKE_FLAGS+=(LLVM=1 LLVM_IAS=1)
fi

export KBUILD_BUILD_USER='cachyos-debian'
export KBUILD_BUILD_HOST='github-actions'

# The kernel mkdebian script currently requests compat 12. Current Ubuntu
# runners provide a newer versioned debhelper compatibility level, so make the
# generated Build-Depends match the installed provider while keeping compat-12
# behavior through DH_COMPAT (supported by debhelper 13).
export DH_COMPAT=12
DEBHELPER_COMPAT_SUPPORTED="$(dpkg-query -W -f='${Provides}' debhelper 2>/dev/null \
  | tr ',' '\n' \
  | sed -n 's/^debhelper-compat (= \([0-9]\+\)).*/\1/p' \
  | sort -n \
  | tail -n 1)"
DEBHELPER_COMPAT_SUPPORTED="${DEBHELPER_COMPAT_SUPPORTED:-13}"
DEB_CONTROL_TEMPLATE="scripts/package/mkdebian"
if [[ -f "$DEB_CONTROL_TEMPLATE" ]] && grep -q 'Build-Depends: debhelper-compat (= 12)' "$DEB_CONTROL_TEMPLATE"; then
  sed -i -E "s/debhelper-compat \(= 12\)/debhelper-compat (= ${DEBHELPER_COMPAT_SUPPORTED})/g" "$DEB_CONTROL_TEMPLATE"
else
  die 'Could not locate the kernel mkdebian debhelper compatibility template.'
fi

# Keep ccache usable across ephemeral GitHub-hosted runners.
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
export CCACHE_BASEDIR="${CCACHE_BASEDIR:-$ROOT_DIR}"
export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"
mkdir -p "$CCACHE_DIR"
ccache --set-config=max_size=4G >/dev/null
ccache --set-config=compression=true >/dev/null

# With /usr/lib/ccache ahead of the compiler directories, gcc/clang invocations
# transparently pass through ccache.
export PATH="/usr/lib/ccache:${PATH}"

# LLVM is used only for LTO builds. For a no-LTO build keep the actual compiler
# on GCC rather than merely omitting LLVM=1 from the make command line.
if [[ "$LLVM_LTO" != 'none' ]]; then
  command -v clang >/dev/null || die 'clang is not available in PATH'
  command -v ld.lld >/dev/null || die 'ld.lld is not available in PATH'
  export LIBCLANG_PATH="${LIBCLANG_PATH:-/usr/lib/llvm-22/lib}"
  # Match dpkg's GNU target triple when Clang is used.
  export CC="clang --target=x86_64-linux-gnu"
  export HOSTCC="clang --target=x86_64-linux-gnu"
else
  export CC='gcc'
  export HOSTCC='gcc'
fi

# Rust is optional in the final CachyOS config. Only run the kernel Rust
# capability check when CONFIG_RUST is actually enabled.
if grep -q '^CONFIG_RUST=[ym]' .config; then
  RUST_MAKE_FLAGS=()
  if [[ "$LLVM_LTO" != 'none' ]]; then
    RUST_MAKE_FLAGS+=(LLVM=1 LLVM_IAS=1)
  fi

  if [[ -n "${RUST_LIB_SRC:-}" && ! -d "${RUST_LIB_SRC}" ]]; then
    echo "Warning: RUST_LIB_SRC does not exist: ${RUST_LIB_SRC}" >&2
  fi

  if make "${RUST_MAKE_FLAGS[@]}" rustavailable >/tmp/rustavailable.log 2>&1; then
    echo 'Rust toolchain is available.'
  else
    cat /tmp/rustavailable.log >&2
    die 'The selected kernel config requires Rust, but the available toolchain failed rustavailable.'
  fi
else
  echo 'Rust support is not required by the final config; skipping rustavailable.'
fi

KERNELRELEASE="$EXPECTED_KERNELRELEASE"
DEB_VERSION="${KERNEL_VERSION}-${PKGREL}"

say 'Building Debian packages'
printf '  KERNELRELEASE = %s\n' "$KERNELRELEASE"
printf '  KDEB_PKGVERSION = %s\n' "$DEB_VERSION"
printf '  MAKE_FLAGS = %s\n' "${MAKE_FLAGS[*]}"
printf '  ccache = %s\n' "$(ccache -s 2>/dev/null | grep -E 'cache hit|cache miss|files in cache' | tr '\n' ' ' || true)"

# bindeb-pkg builds and packages the kernel in one step, producing linux-image,
# linux-headers and other Debian packages in the parent directory.
make "${MAKE_FLAGS[@]}" \
  -j"$(nproc)" \
  KDEB_PKGVERSION="$DEB_VERSION" \
  bindeb-pkg

say 'Collecting output packages'
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

find "$BUILD_ROOT" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.changes' -o -name '*.buildinfo' \) -print0 \
  | while IFS= read -r -d '' f; do
      cp -av "$f" "$OUTPUT_DIR/"
    done

shopt -s nullglob
DEBS=("$OUTPUT_DIR"/*.deb)
(( ${#DEBS[@]} > 0 )) || die 'No .deb packages were generated.'

say 'Writing build information'
{
  echo "variant=${VARIANT}"
  echo "cpusched=${CPUSCHED}"
  echo "processor_opt=${PROCESSOR_OPT}"
  echo "llvm_lto=${LLVM_LTO}"
  echo "source_tag=${SOURCE_TAG}"
  echo "kernel_version=${KERNEL_VERSION}"
  echo "release_suffix=${RELEASE_SUFFIX}"
  echo "kernelrelease=${KERNELRELEASE}"
  echo "debian_package_version=${DEB_VERSION}"
  echo "host_arch=$(dpkg --print-architecture 2>/dev/null || printf 'amd64')"
  echo "clang=$(clang --version 2>/dev/null | head -n 1 || true)"
  echo "rustc=$(rustc --version 2>/dev/null || true)"
  echo
  echo 'selected config:'
  grep -E '^CONFIG_(CACHY|DEBUG_KERNEL|DEBUG_INFO_REDUCED|LTO_|HZ=|PREEMPT=|PREEMPT_RT=|PREEMPT_LAZY=|NO_HZ|CONTEXT_TRACKING|TRANSPARENT_HUGEPAGE|CC_OPTIMIZE_FOR|GENERIC_CPU|X86_64_VERSION|X86_NATIVE_CPU|MZEN4|SCHED_BORE|SCHED_ALT|SCHED_BMQ)=' .config || true
  echo
  echo 'packages:'
  printf '%s\n' "${DEBS[@]}"
  echo
  echo 'ccache statistics:'
  ccache --show-stats || true
} > "$OUTPUT_DIR/build-info.txt"

say 'Build complete'
ls -lh "$OUTPUT_DIR"
