#!/usr/bin/env python3
"""Build and validate RocRay's complete platform API documentation.

All public types, receivers, and effects are documented under www/<version>/.
`--check` builds into a temporary directory without changing published docs.
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
PRIVATE_ENTRIES = {
    "Assets": ("Store.for_host",),
    "Draw": ("Frame.from_host", "Font.from_host!", "Font.for_host", "RenderTexture.for_host"),
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


# The name `roc docs` shows in the sidebar and the index title is the entry
# file's stem, which would otherwise name the platform "main".
PLATFORM_DISPLAY_NAME = "roc-ray"

# The phase sentence every effect entry has to carry, so a reader never has to
# guess which callback an effect may be called from. `roc docs` renders a
# backtick span as `<code>`, so these are compared against doc text with the
# tags turned back into backticks and whitespace collapsed.
PHASE_SENTENCES = (
    # Changes host state.
    "Legal in `init!`, `update!`, and tasks; refused in `render!`.",
    # Waits.
    "Legal in `init!`, where it blocks startup, and in tasks, where it parks "
    "the task; refused in `update!` and `render!`.",
    # Draws.
    "Legal in `render!` only.",
    # Reads something the host already has.
    "Legal in any callback, `render!` included.",
    # One-way diagnostic annotations, the deliberate render exception.
    "Legal in `init!`, `update!`, `render!`, and tasks.",
    # One-off startup work, holding an `App.Startup`.
    "Legal only in `init!`.",
    # Hands the host deferred work.
    "Legal in `update!` and in tasks; refused in `init!` and `render!`.",
    # Waits for a frame that has to be drawn first.
    "Legal only in a task, where it parks the task; refused in `init!`, "
    "`update!`, and `render!`.",
)


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


def module_header_doc(entry: Path) -> str:
    """The `##` comment block at the top of an entry module, as plain text.

    `roc docs` renders a module header only for modules that have a page, and
    the entry module of a platform or package has none -- its header would
    otherwise be written for nobody. Reading it here keeps the front door's
    prose in the source file it describes.
    """
    lines: list[str] = []
    for line in entry.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("##"):
            lines.append(stripped[2:].removeprefix(" "))
            continue
        if stripped:
            break
    return "\n".join(lines).strip()


def render_doc_markdown(text: str) -> str:
    """Render the doc-comment subset: paragraphs, backtick spans, ```roc fences.

    Deliberately no headings, lists, bold or italics: `roc docs` does not
    render them either, so anything this accepted that it does not would be a
    trap for whoever wrote it.
    """
    out: list[str] = []
    paragraph: list[str] = []
    fence: list[str] | None = None

    def flush_paragraph() -> None:
        if not paragraph:
            return
        body = inline_markdown(" ".join(paragraph))
        out.append(f"                <p>{body}</p>")
        paragraph.clear()

    for line in text.splitlines():
        if line.strip().startswith("```"):
            if fence is None:
                flush_paragraph()
                fence = []
            else:
                code = html.escape("\n".join(fence))
                out.append(f"                <pre><code>{code}</code></pre>")
                fence = None
            continue
        if fence is not None:
            fence.append(line)
        elif line.strip():
            paragraph.append(line.strip())
        else:
            flush_paragraph()
    flush_paragraph()
    return "\n".join(out)


def inline_markdown(text: str) -> str:
    """Escape a paragraph and turn its backtick spans into `<code>`."""
    parts = text.split("`")
    rendered = []
    for index, part in enumerate(parts):
        escaped = html.escape(part)
        rendered.append(f"<code>{escaped}</code>" if index % 2 else escaped)
    return "".join(rendered)


SITE_NAME_PATTERN = re.compile(r'(<h1 class="pkg-full-name"><a href="[^"]*">)([^<]*)(</a></h1>)')


def write_index_body(root: Path, entry: Path, display_name: str) -> None:
    """Give the site's front page the entry module's header as its body."""
    header = module_header_doc(entry)
    if not header:
        raise DocsError(
            f"{entry.relative_to(ROOT)} has no `##` module header, so the docs "
            "index would render empty"
        )
    page = root / "index.html"
    source = page.read_text(encoding="utf-8")
    body = render_doc_markdown(header)
    block = f'        <div class="module-doc">\n{body}\n        </div>\n'
    marker = '        <div class="index-decoration">'
    if marker not in source:
        raise DocsError(f"{page}: no index body to fill in")
    page.write_text(source.replace(marker, block + marker, 1), encoding="utf-8")


def name_site(root: Path, display_name: str) -> None:
    """Replace the filename-derived site name in the title and every sidebar.

    `roc docs` derives it from the entry, so the platform site would be called
    "main". Which of the two parts of the path it
    picks is not worth predicting: read the name off the index page and replace
    exactly that.
    """
    index = root / "index.html"
    source = index.read_text(encoding="utf-8")
    match = SITE_NAME_PATTERN.search(source)
    if match is None:
        raise DocsError(f"{index}: no site name to replace")
    current = match.group(2)
    escaped = html.escape(display_name)
    for page in root.rglob("index.html"):
        text = page.read_text(encoding="utf-8")
        replaced = SITE_NAME_PATTERN.sub(
            lambda m: m.group(1) + escaped + m.group(3) if m.group(2) == current else m.group(0),
            text,
        )
        replaced = replaced.replace(f"<title>{current} Docs</title>", f"<title>{escaped} Docs</title>", 1)
        if replaced != text:
            page.write_text(replaced, encoding="utf-8")


def strip_empty_type_defs(root: Path) -> None:
    """Drop the `:= []` line every module nominal renders as its definition.

    Modules are declared as `X := [].{ ... }` so their entries can be
    receivers. That empty tag union is a compiler-shaped detail, and printed
    under the module name it reads as though the module were a type with no
    values.
    """
    for page in root.rglob("index.html"):
        source = page.read_text(encoding="utf-8")
        replaced = re.sub(
            r'\s*<pre class="entry-type-def"><code class="entry-type-def-code">'
            r":= \[\]</code></pre>",
            "",
            source,
        )
        if replaced != source:
            page.write_text(replaced, encoding="utf-8")


def polish_platform_docs(platform_root: Path) -> None:
    """Hide compiler-required private bridges."""
    pages = [platform_root / "index.html"] + [
        page
        for page in platform_root.glob("*/index.html")
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


def check_receivers_documented(platform_root: Path) -> list[str]:
    """Check representative receivers on their defining platform pages."""
    expected = {
        "App": ("Input.for_tests", "Input.with_messages"),
        "Camera": ("Camera2D.with_zoom",),
        "Mouse": ("Snapshot.position",),
        "Font": ("measure",),
        "Texture": ("stub",),
    }
    problems = []
    for module, receivers in expected.items():
        source = (platform_root / module / "index.html").read_text(encoding="utf-8")
        for receiver in receivers:
            if f'id="{module}.{receiver}"' not in source:
                problems.append(f"{module}: missing documented receiver {receiver}")
    return problems


def check_cross_links(platform_root: Path) -> list[str]:
    """Every relative API documentation link resolves."""
    problems: list[str] = []
    for page in sorted(platform_root.glob("*/index.html")):
        for raw in re.findall(r'<a href="([^"]+)"', page.read_text(encoding="utf-8")):
            href = html.unescape(raw).split("#", 1)[0].split("?", 1)[0]
            if not href or href.startswith(("http:", "https:", "mailto:", "//", "/")):
                continue
            target = (page.parent / href).resolve()
            if not target.is_file() and not (target / "index.html").is_file():
                problems.append(f"{page.parent.name}: broken link {raw}")
    return problems


def build(roc: str, version_root: Path) -> None:
    run_roc_docs(roc, PLATFORM_ENTRY, version_root)
    strip_empty_type_defs(version_root)
    write_index_body(version_root, PLATFORM_ENTRY, PLATFORM_DISPLAY_NAME)
    name_site(version_root, PLATFORM_DISPLAY_NAME)
    polish_platform_docs(version_root)


TAG_PATTERN = re.compile(r"<[^>]+>")
CODE_PATTERN = re.compile(r"<code[^>]*>(.*?)</code>", re.S)


def doc_text(fragment: str) -> str:
    """Rendered doc HTML back to plain text, with `<code>` as backticks."""
    text = CODE_PATTERN.sub(lambda match: f"`{match.group(1)}`", fragment)
    text = TAG_PATTERN.sub("", text)
    return " ".join(html.unescape(text).split())


ENTRY_START_PATTERN = re.compile(r'<article class="entry[^"]*" id="([^"]+)">')
ENTRY_DOC_PATTERN = re.compile(r'<div class="entry-doc">(.*?)</div>', re.S)
MODULE_DOC_PATTERN = re.compile(r'<div class="module-doc">(.*?)</div>', re.S)
PARAGRAPH_PATTERN = re.compile(r"<p>(.*?)</p>", re.S)
UNFENCED_CODE_PATTERN = re.compile(r"^[a-z_][A-Za-z0-9_]*[!?]?\s*(=[^=]|\()")


def entries(source: str) -> list[tuple[str, str]]:
    """Every documented entry on a page, as (id, the HTML that belongs to it).

    A receiver is rendered as an `<article>` nested inside its nominal's, so
    matching articles as balanced pairs would attribute the nominal's closing
    tag to the first receiver. Each entry's own HTML runs from its opening tag
    to the next entry's, which is where its doc lives either way.
    """
    starts = list(ENTRY_START_PATTERN.finditer(source))
    return [
        (
            match.group(1),
            source[match.end() : starts[index + 1].start() if index + 1 < len(starts) else len(source)],
        )
        for index, match in enumerate(starts)
    ]


def platform_pages(version_root: Path) -> list[Path]:
    return [
        page
        for page in sorted(version_root.glob("*/index.html"))
    ]


def check_phase_sentences(version_root: Path) -> list[str]:
    """Every effect entry says which callbacks it may be called from.

    A module header saying it for the module as a whole is not enough: a
    reader lands on an entry from search, and the answer has to be there.
    """
    problems: list[str] = []
    for page in platform_pages(version_root):
        source = page.read_text(encoding="utf-8")
        for entry_id, body in entries(source):
            if not entry_id.split(".")[-1].endswith("!"):
                continue
            doc = ENTRY_DOC_PATTERN.search(body)
            text = doc_text(doc.group(1)) if doc else ""
            if not any(sentence in text for sentence in PHASE_SENTENCES):
                problems.append(
                    f"{page.parent.name}: {entry_id} has no phase sentence"
                )
    return problems


def check_prose_renders(version_root: Path) -> list[str]:
    """Catch the two ways doc prose silently renders as something else.

    A snippet written without a ```roc fence renders as a paragraph of run
    together code, and a bullet or heading renders as a literal `-` or `#`,
    because `roc docs` renders neither.
    """
    problems: list[str] = []
    pages = platform_pages(version_root)
    for page in pages:
        source = page.read_text(encoding="utf-8")
        where = page.relative_to(version_root).parent
        blocks = [
            (entry_id, body)
            for entry_id, entry in entries(source)
            for body in ENTRY_DOC_PATTERN.findall(entry)
        ]
        blocks += [("module header", body) for body in MODULE_DOC_PATTERN.findall(source)]
        for entry_id, body in blocks:
            for paragraph in PARAGRAPH_PATTERN.findall(body):
                text = doc_text(paragraph)
                if not text:
                    continue
                if UNFENCED_CODE_PATTERN.match(text):
                    problems.append(
                        f"{where}: {entry_id} has a paragraph that reads as "
                        f"unfenced code: {text[:60]!r}"
                    )
                if text[0] in "*-#":
                    problems.append(
                        f"{where}: {entry_id} has a paragraph starting with "
                        f"{text[0]!r}, which renders literally: {text[:60]!r}"
                    )
    return problems


def validate(version_root: Path) -> list[str]:
    problems = check_modules(version_root, PLATFORM_ENTRY, "platform")
    problems += check_receivers_documented(version_root)
    problems += check_cross_links(version_root)
    problems += check_phase_sentences(version_root)
    problems += check_prose_renders(version_root)
    app_source = (version_root / "App" / "index.html").read_text(encoding="utf-8")
    app_blocks = [body for _, body in entries(app_source)]
    app_blocks += [body for body in MODULE_DOC_PATTERN.findall(app_source)]
    app_text = " ".join(app_blocks)
    for forbidden in (*APP_INTERNAL_TYPES, "AppTransport"):
        if forbidden in app_text:
            problems.append(f"App: private boundary term leaked into docs: {forbidden}")
    platform_pages = [version_root / "index.html"] + [
        page
        for page in version_root.glob("*/index.html")
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
        return 0
    except DocsError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
