#!/usr/bin/env python3
"""Build the RocRay manual (HTML and PDF) with Asciidoctor isolated in Docker.

The manual is the AsciiDoc book under `docs/`. It is separate from the
generated API reference, which `scripts/build_docs.py` builds from the
platform's module documentation into `.docs-api/<version>/`.

    scripts/build_manual.py                       # HTML into .docs-out/site
    scripts/build_manual.py --pdf                 # and the standalone PDF
    scripts/build_manual.py --pdf --output DIR    # somewhere else

Only Docker is needed on the machine running it; Asciidoctor, the PDF
converter, Mermaid and Chromium live in the image `.github/docs.Dockerfile`
describes.
"""

from __future__ import annotations

import argparse
import base64
import os
import re
import shutil
import subprocess
from html import unescape
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
    # asciidoctor-diagram reuses a rendered diagram when its source is
    # unchanged, but not when mermaid-config.json is, so a stale PNG would
    # survive a theme change. Render from scratch each time, and keep the
    # cache out of the published site.
    diagram_cache = output / ".diagram-cache"
    for stale in (diagram_cache, output / ".asciidoctor", output / "images"):
        if stale.exists():
            shutil.rmtree(stale)

    theme_dir = DOCS / "theme"
    fonts_dir = theme_dir / "fonts"
    use_theme_fonts_in_chromium(fonts_dir)

    # The theme is embedded in the page rather than linked, so the page keeps
    # working when opened straight from disk and Rouge's own stylesheet is
    # never left dangling by `linkcss`. The docinfo footer adds the contents
    # navigation script (collapsing bar on phones, current-section highlight).
    theme = [
        "-a", f"stylesdir={theme_dir}", "-a", "stylesheet=roc-ray.css",
        "-a", "docinfo=shared-footer", "-a", f"docinfodir={theme_dir}",
    ]
    extensions = [
        "-r", "asciidoctor-diagram",
        "-r", str(DOCS / "rouge_roc.rb"),
        # Keeps typographic replacements out of inline code, links diagrams
        # to their SVGs, and wraps tables so they scroll in their own box.
        "-r", str(theme_dir / "manual_extensions.rb"),
    ]
    diagram = [
        "-a", f"diagram-cachedir={diagram_cache}",
        "-a", "mermaid-format=svg",
        # Diagrams carry the manual's palette and sit on the same warm
        # ground as the page, so no white plate shows around them.
        "-a", "mermaid-background=FAFAF7",
        "-a", "mermaid-scale=2",
        "-a", f"mermaid-config={theme_dir / 'mermaid-config.json'}",
        "-a", f"mermaid-puppeteer-config={ROOT / '.github' / 'mermaid-puppeteer.json'}",
    ]
    version = ["-a", f"docs-version={docs_version}"]
    # The page offers the PDF only when this build makes one; see the
    # postprocessor in manual_extensions.rb.
    pdf_link = ["-a", "manual-pdf"] if want_pdf else []

    # One book, one page: the chapters cross-reference each other, and those
    # references only resolve when every chapter is part of the same document.
    run(
        "asciidoctor", "--failure-level=WARN",
        *extensions, *diagram, *theme, *version, *pdf_link, "-a", "source-highlighter=rouge",
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

    diagrams = sorted((site / "images").glob("diag-mermaid-*.svg"))
    for svg in diagrams:
        finish_diagram_svg(svg, fonts_dir / "PlusJakartaSans-Regular.ttf")

    index_html = (site / "index.html").read_text(encoding="utf-8")
    check_html(index_html, site, want_pdf)
    check_rendering(site / "index.html")
    print(f"Site: {site / 'index.html'}")

    if want_pdf:
        manual = output / "roc-ray.pdf"
        run(
            "asciidoctor-pdf", "--failure-level=WARN", *extensions, *diagram[:-2], *version,
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
        check_pdf(manual, index_html)
        shutil.copy2(manual, site / manual.name)
        print(f"Manual: {manual}")


def use_theme_fonts_in_chromium(fonts_dir: Path) -> None:
    """Let the Chromium that lays out Mermaid diagrams use the manual's faces.

    Mermaid measures each label in the browser that renders it. Unless that
    browser has the face the diagram names, it measures a fallback, and the
    boxes no longer fit the text a reader sees.
    """
    config_dir = Path(os.environ.get("XDG_CACHE_HOME", "/tmp")) / "roc-ray-manual-fontconfig"
    config_dir.mkdir(parents=True, exist_ok=True)
    config = config_dir / "fonts.conf"
    config.write_text(
        '<?xml version="1.0"?>\n<!DOCTYPE fontconfig SYSTEM "fonts.dtd">\n<fontconfig>\n'
        '  <include ignore_missing="yes">/etc/fonts/fonts.conf</include>\n'
        f"  <dir>{fonts_dir}</dir>\n"
        f"  <cachedir>{config_dir / 'cache'}</cachedir>\n"
        "</fontconfig>\n",
        encoding="utf-8",
    )
    os.environ["FONTCONFIG_FILE"] = str(config)


def finish_diagram_svg(svg: Path, face: Path) -> None:
    """Give a Mermaid SVG a natural size and the face it was measured with.

    Mermaid writes `width="100%"`, which leaves an `<img>` without an intrinsic
    size: the diagram then stretches or shrinks with the column instead of
    showing at the size its labels were laid out for. An SVG shown through
    `<img>` also cannot load the page's web fonts, so the face is embedded.
    """
    text = svg.read_text(encoding="utf-8")
    root = re.search(r"<svg\b[^>]*>", text)
    if not root:
        raise SystemExit(f"{svg.name} has no <svg> element")
    tag = root.group(0)
    view_box = re.search(r"""viewBox=['"]([^'"]+)['"]""", tag)
    if not view_box:
        raise SystemExit(f"{svg.name} has no viewBox")
    width, height = (float(n) for n in view_box.group(1).replace(",", " ").split()[2:4])
    new_tag = re.sub(r"""\s(?:width|height)=['"][^'"]*['"]""", "", tag)
    new_tag = new_tag.replace("<svg", f'<svg width="{width:g}" height="{height:g}"', 1)
    font = base64.b64encode(face.read_bytes()).decode("ascii")
    style = (
        "<style>@font-face{font-family:\"Plus Jakarta Sans\";font-weight:400;font-style:normal;"
        f"src:url(data:font/ttf;base64,{font}) format(\"truetype\");}}</style>"
    )
    svg.write_text(text.replace(tag, new_tag + style, 1), encoding="utf-8")


# Characters Asciidoctor's typographic replacements produce. None of them is
# ever meant inside code: `=>`, `->`, `...` and quotes are Roc syntax there.
REPLACED_IN_CODE = {
    "⇒": "'=>' became a double arrow",
    "→": "'->' became an arrow",
    "←": "'<-' became an arrow",
    "…": "'...' became an ellipsis",
    "​": "a zero-width space was inserted",
    "—": "'--' became an em dash",
    "‘": "a quote was curled",
    "’": "an apostrophe was curled",
    "“": "a quote was curled",
    "”": "a quote was curled",
}


def code_spans(html: str) -> list[str]:
    """The text of every <code> element, entities decoded, tags removed."""
    spans = []
    for body in re.findall(r"<code\b[^>]*>(.*?)</code>", html, re.S):
        spans.append(unescape(re.sub(r"<[^>]+>", "", body)))
    return spans


def check_html(index_html: str, site: Path, want_pdf: bool) -> None:
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
    if re.search(r'data-lang="(?:sh|bash)"', index_html) and not re.search(
        r'<code data-lang="(?:sh|bash)">\s*<span class="nf">', index_html
    ):
        raise SystemExit("shell commands were not highlighted")

    corrupted = []
    inline = re.findall(r"<code>(.*?)</code>", index_html, re.S)
    for span in inline:
        # A span that swallowed a space and a backtick ran on past where the
        # author meant it to end (`init!`'s, `expect`s). A lone literal
        # backtick run, such as a Markdown fence, has no space in it.
        if "`" in span and " " in span:
            corrupted.append(f"  {unescape(span)[:80]!r}: a backtick inside inline code; the spans paired up wrongly")
    for span in code_spans(index_html):
        found = sorted({why for char, why in REPLACED_IN_CODE.items() if char in span})
        if found:
            corrupted.append(f"  {span[:80]!r}: {'; '.join(found)}")
    if corrupted:
        raise SystemExit(
            "typographic replacements reached code, so copied code would not compile:\n"
            + "\n".join(corrupted)
            + "\n(a backtick followed by an apostrophe, as in `init!`'s, is Asciidoctor's"
            " curved-apostrophe syntax: write ``init!``'s instead)"
        )

    # The manual loads nothing from other hosts: no icon fonts, no CDNs.
    remote = sorted(set(re.findall(r'<(?:link|script)\b[^>]*(?:href|src)="(https?://[^"]+)"', index_html)))
    if remote:
        raise SystemExit("the page loads third-party resources: " + ", ".join(remote))

    # Every Rouge token must take its block's ground. Rouge's stylesheet
    # paints some tokens (whitespace among them) with its light background,
    # which showed as white boxes in dark mode. The theme resets it; this
    # keeps the reset from being lost. check_rendering verifies the result.
    if not re.search(r"#content pre\.rouge span\s*\{\s*background:\s*transparent;\s*\}", index_html):
        raise SystemExit("the reset that keeps Rouge tokens off their own background is missing")

    links_pdf = 'href="roc-ray.pdf"' in index_html
    if links_pdf and not want_pdf:
        raise SystemExit("the page links roc-ray.pdf, but this build makes no PDF")
    if want_pdf and not links_pdf:
        print("note: the page does not link the PDF manual")


def check_rendering(page: Path) -> None:
    """Load the page in headless Chromium and check what a reader sees.

    Covers the dark-mode token backgrounds, text contrast in both schemes, and
    page-level horizontal scroll and the contents bar at phone width.
    """
    script = ROOT / "scripts" / "check_manual_render.cjs"
    modules = subprocess.run(["npm", "root", "-g"], check=True, capture_output=True, text=True).stdout.strip()
    env = dict(os.environ)
    env["NODE_PATH"] = os.pathsep.join(
        [f"{modules}/@mermaid-js/mermaid-cli/node_modules", modules, env.get("NODE_PATH", "")]
    )
    subprocess.run(["node", str(script), str(page)], cwd=ROOT, check=True, env=env)


def check_pdf(manual: Path, index_html: str) -> None:
    """The PDF sets code with the same text the HTML does.

    The PDF converter goes through the same substitutions, so the text around
    every `=>`, `->`, `...`, `--` or quote in an inline code span must appear in
    the PDF's text unchanged. Only a few characters either side are compared,
    because the PDF wraps long spans (at hyphens, inside table cells) where the
    HTML does not. The text is read in content-stream order (`-raw`): layout
    order interleaves the lines of neighbouring table cells.
    """
    if shutil.which("pdftotext") is None:
        raise SystemExit("pdftotext is needed to check the PDF manual's code")
    text = subprocess.run(
        ["pdftotext", "-raw", "-enc", "UTF-8", str(manual), "-"], check=True, capture_output=True, text=True
    ).stdout
    flat = re.sub(r"\s+", "", text)
    risky = re.compile(r"=>|->|<-|\.\.\.|--|'|\"")
    missing = []
    for body in sorted(set(re.findall(r"<code>(.*?)</code>", index_html, re.S))):
        span = re.sub(r"\s+", "", unescape(re.sub(r"<[^>]+>", "", body)))
        for match in risky.finditer(span):
            fragment = span[max(0, match.start() - 4):match.end() + 4]
            if fragment not in flat:
                missing.append(f"  {fragment!r} (from {span[:60]!r})")
    if missing:
        raise SystemExit("inline code is not set verbatim in the PDF:\n" + "\n".join(sorted(set(missing))))


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
