# Vendored libvpx (VP8 encoder)

Source: libvpx v1.16.0, https://chromium.googlesource.com/webm/libvpx
License: BSD-3-Clause (see `LICENSE`), with an additional patent grant in
`PATENTS`. VP8 is royalty-free, which is why it is here rather than H.264.

The vendored tree is the VP8 encoder's modules with every architecture-specific
SIMD directory (`x86/`, `arm/`, `mips/`, `ppc/`, `loongarch/`) and every
assembly source excluded. It is pruned by directory, not file by file, so it
also carries some sources the encoder does not use -- what actually gets
compiled is the explicit 74-file `libvpx_sources` list in `build.zig`. Dropping
the SIMD paths is what matters: those are NASM/GAS syntax that Zig cannot
assemble, and dropping them is what lets `zig build` compile this directly for
all four targets with no configure step and no per-OS CI runner.

## `config/`

libvpx's `configure` *generates* these; they are vendored so no configure run
is needed at build time. They were produced with:

    ../libvpx/configure \
        --target=generic-gnu \
        --disable-vp9 --disable-vp8-decoder --disable-vp9-encoder \
        --disable-vp9-decoder --enable-vp8-encoder \
        --disable-examples --disable-tools --disable-docs --disable-unit-tests \
        --disable-shared --enable-static --disable-multithread \
        --disable-runtime-cpu-detect --enable-pic

then `HAVE_PTHREAD_H` and `HAVE_UNISTD_H` were set to 0 by hand, since
multithreading is disabled and Windows has neither header.

The result is target-neutral: every `VPX_ARCH_*` and `HAVE_<simd>` is 0 and
`CONFIG_BIG_ENDIAN` is 0, which is true of all four targets we build. Re-run the
above to update, and re-apply the two edits.
