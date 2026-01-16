#!/usr/bin/env python3
"""Extract the pinned Roc commit hash from build.zig.zon."""

import re
from pathlib import Path


def main() -> None:
    zon_path = Path(__file__).resolve().parent.parent / "build.zig.zon"
    try:
        contents = zon_path.read_text()
    except FileNotFoundError:
        raise SystemExit(f"Missing build.zig.zon at {zon_path}")

    match = re.search(r"roc-lang/roc#([0-9a-fA-F]{40})", contents)
    if not match:
        raise SystemExit("Could not find roc commit in build.zig.zon")

    print(match.group(1))


if __name__ == "__main__":
    main()
