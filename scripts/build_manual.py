#!/usr/bin/env python3
"""Build the RocRay manual (HTML and PDF) with Asciidoctor isolated in Docker.

The manual is the AsciiDoc book under `docs/`. It is separate from the
generated API reference, which `scripts/build_docs.py` builds from the
platform's module documentation into `www/<version>/`.

    scripts/build_manual.py                       # HTML into .docs-out/site
    scripts/build_manual.py --pdf                 # and the standalone PDF
    scripts/build_manual.py --pdf --output DIR    # somewhere else

Only Docker is needed on the machine running it; Asciidoctor, the PDF
converter, Mermaid and Chromium live in the image `.github/docs.Dockerfile`
describes.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
DEFAULT_OUT = ROOT / ".docs-out"
IMAGE = "roc-ray-docs:local"
# The container sees the checkout here; every path handed to Asciidoctor inside
# it must be under this directory.
MOUNT = Path("/documents")


def run(*command: str, **kwargs: object) -> None:
    subprocess.run(command, cwd=ROOT, check=True, **kwargs)


def build_inside_container(output: Path, want_pdf: bool, docs_version: str) -> None:
    site = output / "site"
    if site.exists():
        shutil.rmtree(site)
    site.mkdir(parents=True)

    # The theme is embedded in the page rather than linked, so the page keeps
    # working when opened straight from disk and Rouge's own stylesheet is
    # never left dangling by `linkcss`.
    theme_dir = DOCS / "theme"
    fonts_dir = theme_dir / "fonts"
    theme = ["-a", f"stylesdir={theme_dir}", "-a", "stylesheet=roc-ray.css"]
    diagram = [
        "-r", "asciidoctor-diagram",
        "-r", str(DOCS / "rouge_roc.rb"),
        "-a", "mermaid-format=svg",
        # Diagrams carry the manual's palette and sit on the same warm
        # ground as the page, so no white plate shows around them.
        "-a", "mermaid-background=FAFAF7",
        "-a", "mermaid-scale=2",
        "-a", f"mermaid-config={theme_dir / 'mermaid-config.json'}",
        "-a", f"mermaid-puppeteer-config={ROOT / '.github' / 'mermaid-puppeteer.json'}",
    ]
    version = ["-a", f"docs-version={docs_version}"]

    # One book, one page: the chapters cross-reference each other, and those
    # references only resolve when every chapter is part of the same document.
    run(
        "asciidoctor", "--failure-level=WARN",
        *diagram, *theme, *version, "-a", "source-highlighter=rouge",
        "-a", "toc=left", "-a", "sectanchors", "-D", str(site), str(DOCS / "index.adoc"),
    )

    images = DOCS / "images"
    if images.is_dir():
        shutil.copytree(images, site / "images", dirs_exist_ok=True)
    # The overview's gallery shows the same recordings as the README, which
    # live beside the examples they come from.
    (site / "images").mkdir(exist_ok=True)
    for recording in sorted((ROOT / "examples" / "gallery").glob("*.webp")):
        shutil.copy2(recording, site / "images" / recording.name)
    # The stylesheet is embedded in the page, so its @font-face URLs are
    # resolved relative to the page. The faces ship beside it.
    shutil.copytree(fonts_dir, site / "fonts", dirs_exist_ok=True)
    for face in ("SpaceGrotesk-Regular.ttf", "PlusJakartaSans-Regular.ttf"):
        if not (site / "fonts" / face).is_file():
            raise SystemExit(f"web font {face} was not published beside the page")

    index_html = (site / "index.html").read_text(encoding="utf-8")
    if "RocRay documentation theme" not in index_html:
        raise SystemExit("custom stylesheet was not embedded in the page")
    if not re.search(r'<img src="images/diag-mermaid-[^"]+\.svg"', index_html):
        raise SystemExit("Mermaid diagrams were not rendered to SVG")
    # Asciidoctor renders a cross reference it cannot resolve as its bare id in
    # brackets, and only mentions it in verbose mode.
    unresolved = sorted(set(re.findall(r'<a href="#([^"]+)">\[\1\]</a>', index_html)))
    if unresolved:
        raise SystemExit("unresolved cross references: " + ", ".join(unresolved))
    if 'data-lang="roc"' not in index_html or '<span class="k">' not in index_html:
        raise SystemExit("Roc source was not syntax highlighted")
    print(f"Site: {site / 'index.html'}")

    if want_pdf:
        manual = output / "roc-ray.pdf"
        run(
            "asciidoctor-pdf", "--failure-level=WARN", *diagram[:-2], *version,
            "-a", "source-highlighter=rouge",
            "-a", "rouge-style=rocray",
            "-a", f"pdf-themesdir={theme_dir}",
            "-a", "pdf-theme=roc-ray",
            # Two levels in print keeps the contents inside the pages
            # asciidoctor-pdf reserves for it. The web contents keeps three.
            "-a", "toclevels=2",
            # Vendored faces first, then the gem's own directory so the
            # bundled M+ 1mn mono and fallback faces stay resolvable.
            "-a", f"pdf-fontsdir={fonts_dir};GEM_FONTS_DIR",
            "-a", "mermaid-format=png",
            "-a", f"mermaid-puppeteer-config={ROOT / '.github' / 'mermaid-puppeteer.json'}",
            "-o", str(manual), str(DOCS / "index.adoc"),
        )
        if not manual.is_file() or not manual.stat().st_size:
            raise SystemExit("PDF manual was not generated")
        shutil.copy2(manual, site / manual.name)
        print(f"Manual: {manual}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pdf", action="store_true", help="also build the standalone PDF manual")
    parser.add_argument("--docs-version", default="unreleased",
                        help="platform version this manual documents (shown on its title page)")
    parser.add_argument("--output", help="output directory (default: .docs-out, or $DOCS_OUT)")
    parser.add_argument("--inside-container", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    output = Path(args.output or os.environ.get("DOCS_OUT", DEFAULT_OUT)).resolve()

    if args.inside_container:
        build_inside_container(output, args.pdf, args.docs_version)
        return

    try:
        relative_output = output.relative_to(ROOT)
    except ValueError:
        raise SystemExit(f"--output must be inside the checkout ({ROOT}), which is all the container sees")

    if shutil.which("docker") is None:
        raise SystemExit("Docker is required to build the manual")
    run("docker", "build", "--tag", IMAGE, "--file", ".github/docs.Dockerfile", ".github")
    command = [
        "docker", "run", "--rm", "--user", f"{os.getuid()}:{os.getgid()}",
        "--env", "XDG_CACHE_HOME=/tmp", "--env", "XDG_CONFIG_HOME=/tmp",
        "--volume", f"{ROOT}:{MOUNT}", "--workdir", str(MOUNT), IMAGE,
        "python3", "scripts/build_manual.py", "--inside-container",
        "--docs-version", args.docs_version,
        "--output", str(MOUNT / relative_output),
    ]
    if args.pdf:
        command.append("--pdf")
    run(*command)


if __name__ == "__main__":
    main()
