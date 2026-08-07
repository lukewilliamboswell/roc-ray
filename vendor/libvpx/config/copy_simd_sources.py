#!/usr/bin/env python3
"""Refresh the architecture-specific sources in the vendored libvpx tree.

The rest of the tree is pruned by directory (see README.md), but the SIMD
directories cannot be: they mix compiler-intrinsics `.c`, which Zig compiles,
with NASM/GAS `.asm`, which it cannot assemble. So the architecture files are
vendored one by one, from the same lists in `build.zig` that decide what gets
compiled -- a file cannot be in the tree without being built, or built without
being in the tree.

`vpx_dsp/x86/variance_sse2.c` is the one file vendored with an edit: its tail
declares and wraps helpers that live in `subpel_variance_sse2.asm`, so it is cut
at the upstream comment that says exactly that. Everything above the cut is the
whole-block variance and MSE kernels, which are self-contained. rtcd dispatch
for the sub-pixel variants falls back to C via prune_rtcd.py.

Run from regenerate.sh.
"""

import argparse
import os
import re
import sys

SUBPEL_MARKER = "// These definitions are for functions defined in subpel_variance.asm"
TRUNCATED = {"vpx_dsp/x86/variance_sse2.c": SUBPEL_MARKER}

ARCH_DIR_RE = re.compile(r"(^|/)(x86|arm|neon|mips|ppc|loongarch)(/|$)")

# There is no runtime CPU detection, so the ISA is fixed at compile time and
# every target running this binary must have it. Only the architecture baseline
# qualifies. libvpx also ships AVX2 and NEON-dotprod intrinsics, which are the
# tempting thing to reach for and would fault on hardware that lacks them.
BASELINE_ISA = {"x86_64": {"sse2"}, "arm64": {"neon"}}
ISA_IN_NAME = re.compile(
    r"_(mmx|sse|sse2|sse3|ssse3|sse4_1|avx|avx2|avx512|neon|neon_dotprod|"
    r"neon_i8mm|sve|sve2|vsx|msa|dspr2|mmi|lsx|lasx)\.c$"
)


def source_lists(build_zig):
    text = open(build_zig).read()
    out = {}
    for arch in ("x86_64", "arm64"):
        m = re.search(
            r"const libvpx_%s_sources = \[_\]\[\]const u8\{(.*?)\n\};" % arch,
            text, re.S,
        )
        if not m:
            sys.exit("%s: could not find `const libvpx_%s_sources`" % (build_zig, arch))
        out[arch] = re.findall(r'"([^"]+)"', m.group(1))
    return out


def copy_one(src_root, dst_root, rel, seen):
    if rel in seen:
        return
    seen.add(rel)
    src = os.path.join(src_root, rel)
    if not os.path.exists(src):
        sys.exit("missing from libvpx source tree: " + rel)
    text = open(src).read()
    marker = TRUNCATED.get(rel)
    if marker is not None:
        idx = text.find(marker)
        if idx < 0:
            sys.exit("%s: truncation marker not found -- check upstream changes" % rel)
        text = text[:idx].rstrip() + "\n"
    dst = os.path.join(dst_root, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w") as f:
        f.write(text)
    # Follow quoted includes so the headers these need come along too. Headers
    # outside an architecture directory are already vendored, but rewriting them
    # from the same tarball keeps the whole tree at one libvpx version.
    for inc in re.findall(r'#\s*include\s+"([^"]+)"', text):
        for cand in (os.path.normpath(os.path.join(os.path.dirname(rel), inc)),
                     os.path.normpath(inc)):
            if os.path.exists(os.path.join(src_root, cand)):
                copy_one(src_root, dst_root, cand, seen)
                break


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--libvpx", required=True, help="unpacked libvpx source tree")
    ap.add_argument("--vendor", required=True, help="vendor/libvpx directory")
    args = ap.parse_args()

    build_zig = os.path.join(args.vendor, "..", "..", "build.zig")
    lists = source_lists(build_zig)

    for arch, sources in sorted(lists.items()):
        for rel in sources:
            if not ARCH_DIR_RE.search(os.path.dirname(rel)):
                sys.exit("%s is listed as %s SIMD but is not under an "
                         "architecture directory" % (rel, arch))
            m = ISA_IN_NAME.search(os.path.basename(rel))
            if m and m.group(1) not in BASELINE_ISA[arch]:
                sys.exit("%s uses %s, which %s does not guarantee and nothing "
                         "here detects at runtime" % (rel, m.group(1), arch))

    seen = set()
    for _, sources in sorted(lists.items()):
        for rel in sources:
            copy_one(args.libvpx, args.vendor, rel, seen)

    # The whole point of the exercise: nothing Zig cannot assemble.
    stray = []
    for root, _, files in os.walk(args.vendor):
        for f in files:
            if f.endswith((".asm", ".S", ".s")):
                stray.append(os.path.join(root, f))
    if stray:
        sys.exit("assembly sources landed in the vendored tree:\n  " +
                 "\n  ".join(stray))

    print("  vendored %d architecture sources and headers" % len(seen))


if __name__ == "__main__":
    main()
