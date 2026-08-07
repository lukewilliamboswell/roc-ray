#!/usr/bin/env python3
"""Check the built libvpx archives are self-contained.

The vendored libvpx is configured per architecture, and its rtcd dispatch
headers are post-processed to drop the entries whose implementation lives in an
assembly source we do not vendor (see vendor/libvpx/config/README.md). If that
post-processing ever falls out of step with the source lists in build.zig -- a
libvpx upgrade, an added or removed SIMD file -- the symptom is a dispatch entry
pointing at a `_sse2`/`_neon` symbol nothing defines.

Roc links these archives statically, so an unreferenced dangling member would go
unnoticed until someone's build broke. Check every archive directly instead:
every `vpx_`/`vp8_` symbol an archive member wants must be defined by some
member of the same archive.

Also checks that no assembly source crept into the vendored tree, which is the
invariant that lets `zig build` compile libvpx for all four targets with no
assembler.
"""

import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARCHIVES = [
    "platform/targets/x64glibc/libvpx.a",
    "platform/targets/x64mac/libvpx.a",
    "platform/targets/arm64mac/libvpx.a",
    "platform/targets/x64win/vpx.lib",
]


# GNU nm reads ELF and COFF but not Mach-O, so the two macOS archives need an
# llvm-nm. Try the ones that exist rather than hard-coding either.
# Version range covers what CI runners actually ship: ubuntu-22.04 images carry
# llvm-nm-13/14/15, newer images and local installs carry higher. GNU nm is last
# because it cannot read Mach-O, and reading none of an archive's symbols must
# fail rather than look like a clean result.
NM_CANDIDATES = ["llvm-nm"] + [f"llvm-nm-{v}" for v in range(21, 12, -1)] + ["nm"]


def read_symbols(nm, archive, flag):
    r = subprocess.run([nm, "-A", flag, archive], capture_output=True, text=True)
    if r.returncode != 0 or "file format not recognized" in r.stderr:
        return None
    out = set()
    for line in r.stdout.splitlines():
        parts = line.split()
        if not parts:
            continue
        # Mach-O decorates C symbols with a leading underscore.
        name = parts[-1].lstrip("_")
        if name.startswith(("vpx_", "vp8_")):
            out.add(name)
    return out


def symbols(archive):
    """(defined, undefined) libvpx symbols, or None if no nm can read it."""
    for nm in NM_CANDIDATES:
        if shutil.which(nm) is None:
            continue
        defined = read_symbols(nm, archive, "--defined-only")
        if defined is None:
            continue
        undefined = read_symbols(nm, archive, "--undefined-only")
        if undefined is None:
            continue
        return defined, undefined
    return None


def main():
    failures = []

    for root, _, files in os.walk(os.path.join(ROOT, "vendor", "libvpx")):
        for f in files:
            if f.endswith((".asm", ".S", ".s")):
                failures.append("assembly source in vendored libvpx: %s"
                                % os.path.relpath(os.path.join(root, f), ROOT))

    for rel in ARCHIVES:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            failures.append("%s: not built -- run `zig build` first" % rel)
            continue
        found = symbols(path)
        if found is None:
            failures.append("%s: no available nm could read it (tried %s)"
                            % (rel, ", ".join(NM_CANDIDATES)))
            continue
        defined, undefined = found
        missing = sorted(undefined - defined)
        if not defined:
            failures.append("%s: no libvpx symbols found at all -- nm read the "
                            "archive but produced nothing, so this check is "
                            "not actually checking anything" % rel)
        elif missing:
            failures.append("%s: %d libvpx symbols nothing defines: %s"
                            % (rel, len(missing), ", ".join(missing[:8])))
        else:
            print("ok   %s (%d libvpx symbols, all resolved)" % (rel, len(defined)))

    if failures:
        for f in failures:
            print("FAIL " + f, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
