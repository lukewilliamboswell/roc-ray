#!/usr/bin/env python3
"""Generate the SIMD/C parity test for the vendored libvpx.

Every SIMD kernel libvpx dispatches has a plain-C counterpart with the same
signature, so each one can be checked by running both over the same random
input and comparing. This emits that check as C, driven by whatever the rtcd
headers currently dispatch, so the test cannot drift away from the build.

The kernels reduce to a small number of signature shapes; each shape gets one
hand-written comparator in `simd_parity.c`, and this script emits the table of
calls. A dispatched kernel whose shape has no comparator is emitted into the
uncovered list, which the test reports and which
`vendor/libvpx/config/<arch>/simd_parity_uncovered.txt` pins -- so a new
uncovered kernel fails the build rather than quietly going unchecked.

Run through `regenerate.sh`; not meant to be invoked directly.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

# Signature shape -> the comparator in simd_parity.c that can drive it.
#
# Keys are the parameter list with names stripped, which is how the rtcd
# headers differ between kernels of the same shape.
SHAPES = {
    ("void", "uint8_t *, ptrdiff_t, const uint8_t *, const uint8_t *"): "intra_pred",
    ("unsigned int", "const uint8_t *, int, const uint8_t *, int"): "sad",
    ("void", "const uint8_t *, int, const uint8_t *const[4], int, uint32_t[4]"): "sad_x4",
    ("unsigned int", "const uint8_t *, int, const uint8_t *, int, unsigned int *"): "variance",
    ("unsigned int", "const uint8_t *, int, const uint8_t *, int, const uint8_t *"): "sad_avg",
    ("uint32_t", "const uint8_t *, int, int, int, const uint8_t *, int, uint32_t *"): "subpel_var",
    (
        "uint32_t",
        "const uint8_t *, int, int, int, const uint8_t *, int, uint32_t *, const uint8_t *",
    ): "subpel_var_avg",
}


# Words that are part of a type rather than a parameter name, so that a
# single-token parameter like `int` is not mistaken for a name and dropped.
TYPE_WORDS = {
    "char", "short", "int", "long", "float", "double", "void", "unsigned",
    "signed", "const", "struct", "ptrdiff_t", "size_t",
    "uint8_t", "uint16_t", "uint32_t", "uint64_t",
    "int8_t", "int16_t", "int32_t", "int64_t",
}


def normalise(params: str) -> str:
    """Reduce a parameter list to its shape, dropping names and whitespace."""
    params = re.sub(r"\s+", " ", params.strip())
    out = []
    for param in params.split(","):
        param = param.strip()
        # Array parameters carry their name before the brackets.
        param = re.sub(r"\b\w+\s*\[", "[", param)
        # A name attached to a pointer: `const uint8_t *src_ptr`.
        param = re.sub(r"\*\s*\w+$", "*", param)
        # A name separated from its type: `int stride`. Only when what precedes
        # it is itself a type, so a bare `int` survives untouched.
        match = re.match(r"^(.*?)\s+(\w+)$", param)
        if match and match.group(2) not in TYPE_WORDS:
            param = match.group(1)
        out.append(re.sub(r"\s*\*\s*", " *", param).strip())
    return ", ".join(out)


def parse(config_dir: pathlib.Path, simd: str) -> tuple[list, list]:
    """Return (covered, uncovered) kernels dispatched to `simd`."""
    prototypes: dict[str, tuple[str, str]] = {}
    dispatched: dict[str, str] = {}

    for header in sorted(config_dir.glob("*_rtcd.h")):
        text = header.read_text()
        for match in re.finditer(
            rf"^([A-Za-z_][\w \*]*?)\s+(\w+?)_(c|{simd})\((.*?)\);", text, re.M
        ):
            ret, name, _impl, params = match.groups()
            prototypes[name] = (ret.strip(), params)
        for match in re.finditer(rf"^#define (\w+) (\w+)_{simd}$", text, re.M):
            dispatched[match.group(1)] = match.group(2)

    covered, uncovered = [], []
    for name in sorted(dispatched):
        if name not in prototypes:
            uncovered.append(name)
            continue
        ret, params = prototypes[name]
        comparator = SHAPES.get((ret, normalise(params)))
        if comparator is None:
            uncovered.append(name)
        else:
            covered.append((name, comparator))
    return covered, uncovered


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config-dir", required=True, type=pathlib.Path)
    parser.add_argument("--simd", required=True, help="neon or sse2")
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--uncovered", required=True, type=pathlib.Path)
    args = parser.parse_args()

    covered, uncovered = parse(args.config_dir, args.simd)
    if not covered:
        print(
            f"error: no dispatched {args.simd} kernels found in {args.config_dir}.\n"
            "Either the rtcd headers changed shape or this arch dispatches nothing,\n"
            "and a parity test over zero kernels would pass vacuously.",
            file=sys.stderr,
        )
        return 1

    lines = [
        "// Generated by vendor/libvpx/config/generate_simd_parity.py -- do not edit.",
        "//",
        f"// {len(covered)} dispatched {args.simd} kernels, {len(uncovered)} without a comparator.",
        "",
        '#include "simd_parity.h"',
        "",
        "const RocRayParityKernel rocray_parity_kernels[] = {",
    ]
    for name, comparator in covered:
        lines.append(
            f'    {{ "{name}", ROCRAY_PARITY_{comparator.upper()}'
            f"({name}_c, {name}_{args.simd}) }},"
        )
    lines += [
        "};",
        "",
        "const int rocray_parity_kernel_count =",
        "    (int)(sizeof(rocray_parity_kernels) / sizeof(rocray_parity_kernels[0]));",
        "",
    ]
    args.output.write_text("\n".join(lines))
    args.uncovered.write_text("".join(f"{name}\n" for name in uncovered))

    print(
        f"{args.simd}: {len(covered)} kernels covered, {len(uncovered)} uncovered "
        f"-> {args.output.name}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
