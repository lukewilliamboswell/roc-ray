#!/usr/bin/env python3
"""Build and validate the published API docs.

The platform and the `roc-ray-types` package are documented separately, because
`roc docs` attaches a nominal's receivers to the module that *declares* it. The
platform re-exports those types by alias, so its pages carry the signatures but
not the receivers -- `Camera2D.with_zoom`, `Mouse.Snapshot.position` and friends
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
PACKAGE_ENTRY = ROOT / "types" / "main.roc"
TYPES_SUBDIR = "types"
PRIVATE_ENTRIES = {
    "Draw": ("Frame.from_host", "Font.from_host!", "Font.for_host"),
    "Keys": ("exit_key_code",),
    "Mouse": ("cursor_code", "cursor_mode_code"),
    # `integer` is what every width-checked integer decoder is built from. It
    # has to live inside the nominal to be a receiver, but it reads as a
    # duplicate of `i64` next to it, so it is not part of the documented API.
    "Sqlite": ("Row.integer",),
}
APP_INTERNAL_TYPES = (
    "SubmittedRequest",
    "RawResponse",
    "PendingResponse",
    "RawCaptureStatus",
    "AppHost",
    "AppTransport",
    "CommandApply",
)

REEXPORT_LINKS = {
    "Color": "Color",
    "Devices": "Devices",
    "Window": "Window",
    "Keys": "Keys",
    "Mouse": "Mouse",
    "Gamepad": "Gamepad",
    "Time": "Time",
    "Math": "Math",
    "Camera": "Camera",
    "Physics": "Physics",
    "Capture": "Capture",
    "Draw": "Drawing",
}


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


def polish_platform_docs(platform_root: Path) -> None:
    """Hide compiler-required private bridges and link re-exported pure types."""
    pages = [platform_root / "index.html"] + [
        page
        for page in platform_root.glob("*/index.html")
        if page.parent.name != TYPES_SUBDIR
    ]
    for module, names in PRIVATE_ENTRIES.items():
        defining_page = platform_root / module / "index.html"
        source = defining_page.read_text(encoding="utf-8")
        for name in names:
            entry_id = f"{module}.{name}"
            source = re.sub(
                rf'\s*<article class="entry[^"]*" id="{re.escape(entry_id)}">.*?</article>',
                "",
                source,
                flags=re.S,
            )
        defining_page.write_text(source, encoding="utf-8")

        for page in pages:
            source = page.read_text(encoding="utf-8")
            for name in names:
                entry_id = f"{module}.{name}"
                source = re.sub(
                    rf'\s*<li[^>]*>\s*<a[^>]*href="(?:\.\./)?{module}/\#{re.escape(entry_id)}".*?</li>',
                    "",
                    source,
                    flags=re.S,
                )
            page.write_text(source, encoding="utf-8")

    for module, types_module in REEXPORT_LINKS.items():
        page = platform_root / module / "index.html"
        source = page.read_text(encoding="utf-8")
        link = f'<p class="types-package-link">Pure types and receivers: <a href="../types/{types_module}/">roc-ray-types {types_module}</a></p>'
        source = source.replace("</main>", f"{link}</main>", 1)
        page.write_text(source, encoding="utf-8")


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
    """Every relative link resolves and each re-export links to its pure page.

    Checking only links that mention `types` would miss the failure that
    matters most -- a typo'd path resolves to nothing and mentions nothing.
    """
    problems: list[str] = []
    linked: dict[str, set[Path]] = {}
    for page in sorted(platform_root.glob("*/index.html")):
        for raw in re.findall(r'<a href="([^"]+)"', page.read_text(encoding="utf-8")):
            href = html.unescape(raw).split("#", 1)[0].split("?", 1)[0]
            if not href or href.startswith(("http:", "https:", "mailto:", "//", "/")):
                continue
            target = (page.parent / href).resolve()
            linked.setdefault(page.parent.name, set()).add(target)
            if not target.is_file() and not (target / "index.html").is_file():
                problems.append(f"{page.parent.name}: broken link {raw}")
    for platform_module, types_module in REEXPORT_LINKS.items():
        expected = (types_root / types_module).resolve()
        if expected not in linked.get(platform_module, set()):
            problems.append(
                f"{platform_module}: no link to corresponding types page {types_module}"
            )
    return problems


def build(roc: str, version_root: Path) -> None:
    run_roc_docs(roc, PLATFORM_ENTRY, version_root)
    run_roc_docs(roc, PACKAGE_ENTRY, version_root / TYPES_SUBDIR)
    polish_platform_docs(version_root)


def validate(version_root: Path) -> list[str]:
    problems = check_modules(version_root, PLATFORM_ENTRY, "platform")
    problems += check_modules(version_root / TYPES_SUBDIR, PACKAGE_ENTRY, TYPES_SUBDIR)
    problems += check_receivers_documented(version_root / TYPES_SUBDIR)
    problems += check_cross_links(version_root, version_root / TYPES_SUBDIR)
    app_page = (version_root / "App" / "index.html").read_text(encoding="utf-8")
    for forbidden in (*APP_INTERNAL_TYPES, "AppTransport"):
        if forbidden in app_page:
            problems.append(f"App: private boundary term leaked into docs: {forbidden}")
    platform_pages = [version_root / "index.html"] + [
        page
        for page in version_root.glob("*/index.html")
        if page.parent.name != TYPES_SUBDIR
    ]
    platform_html = "".join(page.read_text(encoding="utf-8") for page in platform_pages)
    for module, names in PRIVATE_ENTRIES.items():
        for name in names:
            entry_id = f"{module}.{name}"
            if entry_id in platform_html:
                problems.append(f"platform: private adapter entry leaked into docs: {entry_id}")
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
