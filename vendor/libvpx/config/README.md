# Vendored libvpx (VP8 encoder)

Source: libvpx v1.16.0, https://chromium.googlesource.com/webm/libvpx
License: BSD-3-Clause (see `LICENSE`), with an additional patent grant in
`PATENTS`. VP8 is royalty-free, which is why it is here rather than H.264.

The vendored tree is the VP8 encoder's modules, carrying C only. libvpx writes
some of its SIMD as compiler intrinsics in `.c` files, which `zig cc` compiles
for every target we build, and the rest as NASM/GAS `.asm`, which Zig cannot
assemble. The intrinsics are in; the assembly is not, and no assembler is needed
to build or to re-vendor.

Most of the tree is pruned by directory, not file by file, so it also carries
some sources the encoder does not use. The architecture directories (`x86/`,
`arm/`) cannot be pruned that way, because they mix the two kinds of source, so
those files are vendored one at a time -- exactly the ones named in `build.zig`'s
`libvpx_x86_64_sources` and `libvpx_arm64_sources`. What actually gets compiled
is `libvpx_sources` plus whichever of those two matches the target.

One file is vendored with an edit: `vpx_dsp/x86/variance_sse2.c` is cut at the
upstream comment `// These definitions are for functions defined in
subpel_variance.asm`. Everything above the cut is the whole-block variance and
MSE kernels, which are self-contained; everything below wraps helpers that only
exist in that `.asm`. The dispatch entries for the sub-pixel variants fall back
to C.

## Coverage, and why the two architectures differ so much

On AArch64 libvpx implements all of VP8 in intrinsics -- the `.asm` beside those
files is 32-bit ARM only, and `HAVE_NEON_ASM` is 0 for us -- so `arm64/` is
exactly what `configure` emits for an arm64 VP8-encoder build, with nothing
pruned and NEON covering the whole hot path.

On x86-64 most of it is assembly. Only the quantizer, the whole-block variance
kernels and the bilinear predictor exist as SSE2 intrinsics; the forward DCT,
the loop filters, the IDCT, SAD and sub-pixel variance are `.asm` only. So
`x86_64/` keeps three source files and points ~150 dispatch entries back at C.
That is still worth 1.40x at 1920x1080 and 1.24x at 1280x720 and 320x180,
measured with `VP8E_SET_CPUUSED` 12 on a Ryzen 7 9700X (1080p: 71 -> 99 fps,
14.2 -> 10.1 ms/frame). What is left on x86 is the forward DCT, the loop
filters, the IDCT and `vpx_subtract_block`, which is most of the remaining time
and all of it assembly.

Only the ISA baseline each architecture guarantees is enabled: SSE2 on x86-64,
NEON on AArch64. `CONFIG_RUNTIME_CPU_DETECT` is 0, so nothing here asks the CPU
what it supports, and anything above the baseline -- including libvpx's AVX2
files, which are also intrinsics -- would be a fault waiting to happen on an
older machine. `copy_simd_sources.py` rejects a source list that reaches above
the baseline.

Setting `HAVE_SSE2` also switches `vp8/encoder/mcomp.c` to its `sadx4` motion
search, which is what every normal x86 libvpx build uses. Its four-at-a-time SAD
is one of the assembly-only kernels, so it runs the C version here; it still
measured slightly faster than the plain search.

## `config/`

libvpx's `configure` *generates* these; they are vendored so no configure run is
needed at build time. `config/x86_64/` serves x64glibc, x64mac and x64win, and
`config/arm64/` serves arm64mac: the generated headers vary by CPU architecture,
not by OS. `build.zig` puts exactly one of the two on the include path, so a
source can only ever see the config for the architecture it is being built for.

Regenerate both with:

    curl -sSL -o libvpx.tar.gz \
      "https://chromium.googlesource.com/webm/libvpx/+archive/refs/tags/v1.16.0.tar.gz"
    mkdir libvpx && tar xzf libvpx.tar.gz -C libvpx
    ./regenerate.sh ./libvpx

That script is the specification; the short version is that it runs `configure`
once for the target-neutral `generic-gnu` build, derives each architecture's
`vpx_config.h` from it by turning on that architecture's baseline ISA, and runs
libvpx's own `rtcd.pl` to generate the dispatch headers. Deriving them beats
running `configure` per target: `configure` refuses an x86 target without
yasm/nasm and needs a matching cross toolchain for an arm target, and neither
prerequisite buys anything -- the derived headers are byte-identical to what
those runs produce.

Then `prune_rtcd.py` compiles the SIMD sources `build.zig` lists and rewrites
every dispatch entry whose implementation nothing defines to the C version, so
the pruning is derived from the source lists rather than maintained beside them.

Requirements: a C compiler, perl, python3, `zig`, and an `nm`. Not yasm/nasm,
and not a cross compiler.

## Keeping it honest

`scripts/check_libvpx_archives.py` (run by `scripts/all_tests.py`) rejects any
assembly source in the vendored tree, and checks each built archive resolves
every `vpx_`/`vp8_` symbol its own members reference. A config that has drifted
from its source list shows up there as an unresolved `_sse2`/`_neon` symbol,
which is otherwise easy to miss: Roc links these archives statically, so a
dangling reference in a member nothing pulls in would stay quiet until it
didn't.

## SIMD/C parity

`zig build libvpx-parity` runs every dispatched SIMD kernel and its plain-C
counterpart over the same random input and compares the results. It builds for
the *native* target on purpose: this is the only check that a kernel actually
computes what its C reference does, and cross-compiling it would build the
kernels without ever executing them. `zig build test` depends on it, and CI
names it as its own step on both x86_64 and macos-15 (arm64) -- the latter is
the point, since an arm64 build swaps in ~200 NEON kernels that nothing else
would exercise.

Whole-encode output cannot be compared between a scalar and a SIMD build,
because `vp8_auto_select_speed` feeds wall-clock timing back into mode
decisions. Parity has to be checked per kernel.

`simd_parity_table.c` is generated from the rtcd headers by
`generate_simd_parity.py`, which `regenerate.sh` runs, so the table cannot drift
from what the build dispatches. Kernels whose signature has no comparator in
`../test/simd_parity.c` are listed in `simd_parity_uncovered.txt`; adding a
comparator for a shape moves every kernel of that shape into the table.
