#!/bin/bash
#
# Regenerate the per-architecture libvpx configs in this directory.
#
#   ./regenerate.sh /path/to/unpacked/libvpx
#
# The tarball comes from
#   https://chromium.googlesource.com/webm/libvpx/+archive/refs/tags/v1.16.0.tar.gz
# and the version must match `vendor/libvpx/config/*/vpx_version.h`.
#
# Requirements: a C compiler (for libvpx's own `configure`), perl, python3, and
# `zig` + `nm`. Deliberately NOT required: yasm/nasm, and a cross compiler.
# libvpx's `configure` refuses to run for an x86 target without an assembler and
# needs a matching cross toolchain for an arm target, so we never ask it for
# either. Instead we run it once for the target-neutral `generic-gnu` build --
# which needs nothing but the host compiler -- and derive the two architecture
# configs from that. `rtcd.pl` is plain perl and generates the dispatch headers
# from a config file; feeding it the derived config reproduces byte-for-byte
# what a real `configure --target=x86_64-linux-gcc` / `--target=arm64-*` run
# emits, without either prerequisite.
#
# See README.md in this directory for what the result is and why it is shaped
# this way.
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 /path/to/unpacked/libvpx" >&2
    exit 2
fi
LIBVPX=$(cd "$1" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
VENDOR=$(cd "$HERE/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 1. The one configure run: target-neutral, no assembler, no cross toolchain.
#    Every VPX_ARCH_* and HAVE_<simd> comes out 0; step 3 turns on exactly the
#    ones each architecture guarantees.
mkdir -p "$WORK/generic"
(
    cd "$WORK/generic"
    "$LIBVPX/configure" \
        --target=generic-gnu \
        --disable-vp9 --disable-vp8-decoder --disable-vp9-encoder \
        --disable-vp9-decoder --enable-vp8-encoder \
        --disable-examples --disable-tools --disable-docs --disable-unit-tests \
        --disable-shared --enable-static --disable-multithread \
        --disable-runtime-cpu-detect --enable-pic >/dev/null
)
# `make` normally writes this one; it is version metadata, not configuration.
"$LIBVPX/build/make/version.sh" "$LIBVPX" "$WORK/generic/vpx_version.h"

# Multithreading is off and Windows has neither header, so neither is usable on
# every target we build. configure probes the *host*, so fix them by hand.
sed -i -e 's/^#define HAVE_PTHREAD_H 1$/#define HAVE_PTHREAD_H 0/' \
       -e 's/^#define HAVE_UNISTD_H 1$/#define HAVE_UNISTD_H 0/' \
       "$WORK/generic/vpx_config.h"

# rtcd.pl reads KEY=value lines, so project a vpx_config.h into that form.
config_mk() {
    sed -n -e 's/^#define \(CONFIG_[A-Z0-9_]*\) 1$/\1=yes/p' \
           -e 's/^#define \(CONFIG_[A-Z0-9_]*\) 0$/\1=/p' \
           -e 's/^#define \(HAVE_[A-Z0-9_]*\) 1$/\1=yes/p' \
           -e 's/^#define \(HAVE_[A-Z0-9_]*\) 0$/\1=/p' \
           "$1"
}

# 2. Refresh the vendored SIMD sources, from the same build.zig lists that
#    decide what gets compiled. Must happen before step 4, which compiles them.
python3 "$HERE/copy_simd_sources.py" --libvpx "$LIBVPX" --vendor "$VENDOR"

# 3. Derive one config per architecture. Only the baseline ISA is turned on:
#    SSE2 is guaranteed by x86-64, NEON by AArch64. Anything above that would
#    need runtime CPU detection, which is off.
gen_arch() {
    local arch=$1 rtcd_arch=$2 zig_target=$3
    shift 3
    local sed_args=() rtcd_opts=()
    while [ "$1" != "--" ]; do sed_args+=(-e "$1"); shift; done
    shift
    rtcd_opts=("$@")

    local out="$HERE/$arch"
    rm -rf "$out"
    mkdir -p "$out"
    sed "${sed_args[@]}" "$WORK/generic/vpx_config.h" > "$out/vpx_config.h"
    # A sed that matches nothing succeeds, and a config with no architecture set
    # still builds -- just entirely scalar, silently. Check each flip landed.
    local expr rhs
    for expr in "${sed_args[@]}"; do
        [ "$expr" = "-e" ] && continue
        rhs=${expr#s/^*}
        rhs=${rhs#*\$/}
        rhs=${rhs%/}
        grep -qxF "$rhs" "$out/vpx_config.h" || {
            echo "$arch: '$rhs' not in the generated vpx_config.h -- the flip" \
                 "matched nothing, so libvpx's config layout changed" >&2
            exit 1
        }
    done
    cp "$WORK/generic/vpx_version.h" "$out/"
    # vpx_config.c is just the string vpx_codec_build_config() returns. Say the
    # architecture too, so it does not claim to be the generic-gnu build.
    sed "s|--enable-pic\";|--enable-pic (derived for $arch)\";|" \
        "$WORK/generic/vpx_config.c" > "$out/vpx_config.c"

    config_mk "$out/vpx_config.h" > "$WORK/$arch.mk"
    local rtcd="$LIBVPX/build/make/rtcd.pl"
    perl "$rtcd" --arch="$rtcd_arch" --sym=vp8_rtcd --config="$WORK/$arch.mk" \
        "${rtcd_opts[@]}" "$LIBVPX/vp8/common/rtcd_defs.pl" > "$out/vp8_rtcd.h"
    perl "$rtcd" --arch="$rtcd_arch" --sym=vpx_dsp_rtcd --config="$WORK/$arch.mk" \
        "${rtcd_opts[@]}" "$LIBVPX/vpx_dsp/vpx_dsp_rtcd_defs.pl" > "$out/vpx_dsp_rtcd.h"
    perl "$rtcd" --arch="$rtcd_arch" --sym=vpx_scale_rtcd --config="$WORK/$arch.mk" \
        "${rtcd_opts[@]}" "$LIBVPX/vpx_scale/vpx_scale_rtcd.pl" > "$out/vpx_scale_rtcd.h"

    # 4. Point every dispatch entry we cannot satisfy back at the C version.
    #    rtcd.pl assumes the whole ISA is available, but libvpx implements much
    #    of x86 in NASM-syntax .asm that Zig cannot assemble and that we
    #    therefore do not vendor. Rather than guess, compile the SIMD sources
    #    build.zig actually lists and let the symbol table decide.
    python3 "$HERE/prune_rtcd.py" \
        --vendor "$VENDOR" \
        --config "$out" \
        --zig-target "$zig_target" \
        --arch "$arch"
}

gen_arch x86_64 x86_64 x86_64-linux-gnu \
    's/^#define VPX_ARCH_X86_64 0$/#define VPX_ARCH_X86_64 1/' \
    's/^#define HAVE_SSE2 0$/#define HAVE_SSE2 1/' \
    -- \
    --disable-mmx --disable-sse --disable-sse3 --disable-ssse3 --disable-sse4_1 \
    --disable-avx --disable-avx2 --disable-avx512

gen_arch arm64 arm64 aarch64-linux-gnu \
    's/^#define VPX_ARCH_ARM 0$/#define VPX_ARCH_ARM 1/' \
    's/^#define VPX_ARCH_AARCH64 0$/#define VPX_ARCH_AARCH64 1/' \
    's/^#define HAVE_NEON 0$/#define HAVE_NEON 1/' \
    -- \
    --disable-neon_dotprod --disable-neon_i8mm --disable-sve --disable-sve2

# The parity test's kernel table is derived from the rtcd headers, so it has to
# be regenerated with them -- otherwise it would check a stale dispatch list.
python3 "$HERE/generate_simd_parity.py" \
    --config-dir "$HERE/x86_64" --simd sse2 \
    --output "$HERE/x86_64/simd_parity_table.c" \
    --uncovered "$HERE/x86_64/simd_parity_uncovered.txt"

python3 "$HERE/generate_simd_parity.py" \
    --config-dir "$HERE/arm64" --simd neon \
    --output "$HERE/arm64/simd_parity_table.c" \
    --uncovered "$HERE/arm64/simd_parity_uncovered.txt"

echo "regenerated $HERE/x86_64 and $HERE/arm64"
