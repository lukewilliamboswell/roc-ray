#!/usr/bin/env python3
"""Point rtcd dispatch entries we cannot satisfy back at the C implementation.

`rtcd.pl` assumes that if an ISA is enabled, every specialization written for it
is available. That is not true here: libvpx implements a large part of its x86
SIMD in NASM-syntax `.asm`, which Zig cannot assemble and which this vendored
tree therefore does not carry. Only the compiler-intrinsics `.c` files are
vendored.

So rather than curate a list of which functions survive -- which would rot
silently on the next libvpx upgrade -- compile the SIMD sources `build.zig`
lists for this architecture and read their symbol table. Any `#define fn
fn_<isa>` whose right-hand side nothing defines is rewritten to `fn_c`.

Run from regenerate.sh; see README.md in this directory.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

# ISA suffixes rtcd.pl can append, longest-first so `neon_dotprod` is not
# mistaken for `neon`.
ISA_SUFFIXES = [
    "neon_dotprod", "neon_i8mm", "neon", "sve2", "sve",
    "avx512", "avx2", "avx", "sse4_1", "ssse3", "sse3", "sse2", "sse", "mmx",
    "vsx", "msa", "dspr2", "mmi", "lsx", "lasx",
]

RTCD_HEADERS = ["vp8_rtcd.h", "vpx_dsp_rtcd.h", "vpx_scale_rtcd.h"]

BANNER = (
    "// Post-processed by vendor/libvpx/config/prune_rtcd.py: %d dispatch\n"
    "// entries whose implementation lives in an assembly source we do not\n"
    "// vendor were pointed back at the C version. Do not edit; see README.md.\n"
)


def simd_sources(build_zig, arch):
    """The per-architecture SIMD file list from build.zig -- the single source
    of truth for what actually gets compiled."""
    text = open(build_zig).read()
    name = "libvpx_%s_sources" % arch
    m = re.search(
        r"const %s = \[_\]\[\]const u8\{(.*?)\n\};" % re.escape(name), text, re.S
    )
    if not m:
        sys.exit("%s: could not find `const %s`" % (build_zig, name))
    return re.findall(r'"([^"]+)"', m.group(1))


def defined_symbols(vendor, config_dir, zig_target, sources):
    syms = set()
    with tempfile.TemporaryDirectory() as tmp:
        for rel in sources:
            obj = os.path.join(tmp, rel.replace("/", "_") + ".o")
            subprocess.run(
                ["zig", "cc", "-target", zig_target, "-O2", "-std=gnu99",
                 "-Wno-unused-function", "-I", vendor, "-I", config_dir,
                 "-c", os.path.join(vendor, rel), "-o", obj],
                check=True,
            )
            out = subprocess.run(
                ["nm", "--defined-only", obj], check=True,
                capture_output=True, text=True,
            ).stdout
            for line in out.splitlines():
                parts = line.split()
                if len(parts) >= 3:
                    syms.add(parts[2])
    # A symbol set that carries no ISA suffix at all means the compile or the
    # `nm` parse produced nothing usable -- for instance a Mach-O target, whose
    # symbols carry a leading underscore. Silently pruning every entry back to C
    # would still build and still pass, just slowly, so refuse instead.
    if not any(base_name(s) for s in syms):
        sys.exit("no SIMD symbols found in the compiled sources -- refusing to "
                 "prune every dispatch entry")
    return syms


def base_name(impl):
    for isa in ISA_SUFFIXES:
        if impl.endswith("_" + isa):
            return impl[: -(len(isa) + 1)]
    return None


def prune(path, available):
    lines = open(path).read().splitlines(True)
    out = []
    changed = []
    banner_at = None
    for line in lines:
        m = re.match(r"^#define (\w+) (\w+)\s*$", line)
        if m:
            name, impl = m.group(1), m.group(2)
            base = base_name(impl)
            if base is not None and impl not in available:
                changed.append((name, impl))
                line = "#define %s %s_c\n" % (name, base)
        if line.startswith("// This file is generated."):
            banner_at = len(out) + 1
        out.append(line)
    if banner_at is None:
        sys.exit("%s: no `// This file is generated.` line to mark up -- is this "
                 "an rtcd header?" % path)
    out.insert(banner_at, BANNER % len(changed))
    open(path, "w").writelines(out)
    return changed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vendor", required=True, help="vendor/libvpx directory")
    ap.add_argument("--config", required=True, help="config/<arch> directory")
    ap.add_argument("--zig-target", required=True)
    ap.add_argument("--arch", required=True)
    args = ap.parse_args()

    build_zig = os.path.join(args.vendor, "..", "..", "build.zig")
    sources = simd_sources(build_zig, args.arch)
    available = defined_symbols(args.vendor, args.config, args.zig_target, sources)

    total = 0
    for header in RTCD_HEADERS:
        path = os.path.join(args.config, header)
        changed = prune(path, available)
        total += len(changed)
        print("  %s/%s: %d entries pointed back at C"
              % (args.arch, header, len(changed)))
    kept = sum(1 for s in available if base_name(s))
    print("  %s: %d SIMD symbols kept, %d dispatch entries reverted"
          % (args.arch, kept, total))


if __name__ == "__main__":
    main()
