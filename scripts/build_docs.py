#!/usr/bin/env python3
"""Build and validate the published API docs.

The platform and the `roc-ray-types` package are documented separately, because
`roc docs` attaches a nominal's receivers to the module that *declares* it. The
platform re-exports those types by alias, so its pages carry the signatures but
not the receivers -- `Camera2D.with_zoom`, `Mouse.State.position` and friends
only exist on the package's pages.

Layout, matching the existing versioned scheme:

    www/<version>/          platform docs
    www/<version>/types/    package docs, linked from every re-export module

`--check` builds both into a temporary directory and validates them without
touching `www/`, so the whole flow can be exercised locally.
"""

from __future__ import annotations

import argparse
import html
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLATFORM_ENTRY = ROOT / "platform" / "main.roc"
PACKAGE_ENTRY = ROOT / "package" / "main.roc"
TYPES_SUBDIR = "types"


class DocsError(RuntimeError):
    """A docs generation or validation failure with a user-facing message."""


def run_roc_docs(roc: str, entry: Path, output: Path) -> None:
    if output.exists():
        shutil.rmtree(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [roc, "docs", str(entry), f"--output={output}"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise DocsError(
            f"roc docs failed for {entry.relative_to(ROOT)}:\n{result.stdout}{result.stderr}"
        )


def exposed_modules(entry: Path) -> list[str]:
    """Read the `exposes [...]` list from a platform or package header."""
    text = entry.read_text(encoding="utf-8")
    match = re.search(r"(?:exposes\s*|^package\s*)\[([^\]]*)\]", text, re.M)
    if match is None:
        raise DocsError(f"could not find an exposes list in {entry.relative_to(ROOT)}")
    return [name.strip() for name in match.group(1).split(",") if name.strip()]


def check_modules(root: Path, entry: Path, label: str) -> list[str]:
    problems: list[str] = []
    if not (root / "index.html").is_file():
        problems.append(f"{label}: missing index.html")
    for module in exposed_modules(entry):
        if not (root / module / "index.html").is_file():
            problems.append(f"{label}: no page for exposed module {module}")
    return problems


def check_receivers_documented(types_root: Path) -> list[str]:
    """Every nominal receiver must appear somewhere, or the split lost docs."""
    problems: list[str] = []
    found = 0
    for page in types_root.glob("*/index.html"):
        ids = re.findall(r'<article class="entry[^"]*" id="([^"]+)"', page.read_text(encoding="utf-8"))
        found += len([i for i in ids if i.count(".") == 2])
    if found == 0:
        problems.append(
            f"{TYPES_SUBDIR}: no receivers documented at all -- the package docs "
            "are the only place they exist, so this means they were lost"
        )
    return problems


def check_cross_links(platform_root: Path, types_root: Path) -> list[str]:
    """Every relative link in the platform docs must resolve, and at least one
    module must point at the package docs.

    Checking only links that mention `types` would miss the failure that
    matters most -- a typo'd path resolves to nothing and mentions nothing.
    """
    problems: list[str] = []
    linked = 0
    types_resolved = types_root.resolve()
    for page in sorted(platform_root.glob("*/index.html")):
        for raw in re.findall(r'<a href="([^"]+)"', page.read_text(encoding="utf-8")):
            href = html.unescape(raw).split("#", 1)[0].split("?", 1)[0]
            if not href or href.startswith(("http:", "https:", "mailto:", "//", "/")):
                continue
            target = (page.parent / href).resolve()
            if target == types_resolved:
                linked += 1
            if not target.is_file() and not (target / "index.html").is_file():
                problems.append(f"{page.parent.name}: broken link {raw}")
    if linked == 0:
        problems.append(
            "no module links to the package docs; re-export modules should point "
            f"at ../{TYPES_SUBDIR}/ so readers can find the receivers"
        )
    return problems


def build(roc: str, version_root: Path) -> None:
    run_roc_docs(roc, PLATFORM_ENTRY, version_root)
    run_roc_docs(roc, PACKAGE_ENTRY, version_root / TYPES_SUBDIR)


def validate(version_root: Path) -> list[str]:
    problems = check_modules(version_root, PLATFORM_ENTRY, "platform")
    problems += check_modules(version_root / TYPES_SUBDIR, PACKAGE_ENTRY, TYPES_SUBDIR)
    problems += check_receivers_documented(version_root / TYPES_SUBDIR)
    problems += check_cross_links(version_root, version_root / TYPES_SUBDIR)
    return problems


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--roc", default="roc", help="Roc compiler binary")
    parser.add_argument(
        "--docs-root", default="www", help="versioned docs root (default: www)"
    )
    parser.add_argument("--version", help="release version, e.g. 0.10.0")
    parser.add_argument(
        "--check",
        action="store_true",
        help="build into a temporary directory and validate, leaving --docs-root alone",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        if args.check:
            with tempfile.TemporaryDirectory(prefix="rocray_docs_") as temporary:
                version_root = Path(temporary) / "preview"
                build(args.roc, version_root)
                problems = validate(version_root)
                where = "preview build"
        else:
            if not args.version:
                raise DocsError("--version is required unless --check is given")
            version_root = (ROOT / args.docs_root / args.version).resolve()
            build(args.roc, version_root)
            problems = validate(version_root)
            try:
                where = str(version_root.relative_to(ROOT))
            except ValueError:
                where = str(version_root)

        if problems:
            print(f"Docs validation failed for {where}:", file=sys.stderr)
            for problem in problems:
                print(f"  - {problem}", file=sys.stderr)
            return 1

        print(f"Docs built and validated: {where}")
        print(f"  platform -> {where}")
        print(f"  package  -> {where}/{TYPES_SUBDIR}")
        return 0
    except DocsError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
