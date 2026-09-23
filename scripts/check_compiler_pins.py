#!/usr/bin/env python3
"""Keep every development compiler pin in step with platform/main.roc.

`platform/main.roc` holds the development compiler pin. Every other tracked Roc
root that pins a compiler (the Wayland header, the examples, the test probes)
must name the same one. The nightly updater rewrites exactly the roots listed
in `.github/roc-nightly.json`, so that list must cover every pinned root, or
the next update silently leaves some behind.

Pins inside `##` doc comments are rejected outright: nothing rewrites them, so
a documented header would go stale on the first nightly update. A doc example
omits the `roc:` field instead; the compiler treats a missing pin as unpinned.

The published starter's compiler named in README.md is deliberately separate
and is not checked here: the "Published quickstart" CI job checks it unchanged.
"""

from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / ".github/roc-nightly.json"
PLATFORM = "platform/main.roc"
PIN = re.compile(r'\broc:\s*"(nightly-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]{7,40})"')


def header_pin(source: str) -> str | None:
    """The `roc:` literal in the leading header, ignoring comments and the body."""
    code = [line for line in source.splitlines() if not line.lstrip().startswith("#")]
    # The header is everything up to its first blank line after the opening
    # keyword; that covers both one-line app headers and the multi-line
    # platform header's `packages` record.
    header = []
    for line in code:
        if header and not line.strip():
            break
        if line.strip():
            header.append(line)
    match = PIN.search("\n".join(header))
    return match.group(1) if match else None


def check(root: Path = ROOT) -> list[str]:
    problems = []
    tracked = subprocess.check_output(["git", "ls-files", "-z", "*.roc"], cwd=root).split(b"\0")
    sources = {path.decode(): (root / path.decode()).read_text() for path in tracked if path}
    expected = header_pin(sources[PLATFORM])
    if expected is None:
        return [f"{PLATFORM} has no compiler pin"]

    pinned = set()
    for path, source in sorted(sources.items()):
        pin = header_pin(source)
        if pin is not None:
            pinned.add(path)
            if pin != expected:
                problems.append(f"{path} pins {pin}, but {PLATFORM} pins {expected}")
        for number, line in enumerate(source.splitlines(), 1):
            if line.lstrip().startswith("##") and PIN.search(line):
                problems.append(f"{path}:{number}: a doc comment pins a compiler; omit the roc: field "
                                "from documented headers, since no updater rewrites them")

    roots = set(json.loads(CONFIG.read_text())["compiler_roots"])
    for path in sorted(pinned - roots):
        problems.append(f"{path} pins a compiler but is not in {CONFIG.relative_to(root)} compiler_roots, "
                        "so the nightly updater would leave it behind")
    for path in sorted(roots - pinned):
        problems.append(f"{CONFIG.relative_to(root)} lists {path}, which has no compiler pin")
    return problems


def main() -> int:
    problems = check()
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
