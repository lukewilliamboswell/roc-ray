#!/usr/bin/env python3
"""Convert a release-notes AsciiDoc file to GitHub Markdown.

Release notes are written once, in `docs/releases/<version>.adoc`, so they
appear in the manual. A GitHub release page renders Markdown, so the release
workflow converts the same file.

Only the subset of AsciiDoc that release notes need is accepted: section
titles, paragraphs, bulleted and numbered lists (with `+` continuations),
`[source]` listing blocks, simple tables, thematic breaks, block ids, links,
`<<id,text>>` cross references, and constrained `*bold*` and `_emphasis_`.
Anything else is an error rather than a page that renders garbled, so a new
construct has to be taught here before it can be published.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


class ConversionError(RuntimeError):
    """A construct the converter does not support, with its line number."""


BLOCK_ID = re.compile(r"^\[(?:#[\w.-]+|\[[\w.-]+\])\]$")
LEGACY_ANCHOR = re.compile(r"^\[\[[\w.-]+\]\]$")
TITLE = re.compile(r"^(=+) (.+)$")
SOURCE = re.compile(r"^\[source(?:,([\w+-]+))?\]$")
TABLE_ATTRS = re.compile(r"^\[cols=\"[^\"]*\"(?:,\s*options=\"header\")?\]$")
BULLET = re.compile(r"^(\*+) (.*)$")
NUMBERED = re.compile(r"^(\.+) (.*)$")
COMMENT = re.compile(r"^//(?!/)")

# Inline patterns, applied outside code spans only.
URL_LINK = re.compile(r"(?:link:)?((?:https?://|#)[^\s\[\]]+)\[([^\]]*)\]")
XREF = re.compile(r"<<([\w.-]+),([^>]+)>>")
BARE_XREF = re.compile(r"<<[^>]*>>")
BOLD = re.compile(r"(?<![\w*])\*(?=\S)([^*]*?\S)\*(?![\w*])")
EMPHASIS = re.compile(r"(?<![\w_])_(?=\S)([^_]*?\S)_(?![\w_])")


def convert_inline(text: str, line: int) -> str:
    """Convert one line of inline markup, leaving `code` spans untouched."""
    # Code spans are set aside behind placeholders, so markup inside them is
    # left alone while bold text or link text may still contain one.
    spans: list[str] = []

    def hold(match: re.Match[str]) -> str:
        inner = match.group(1)
        # `+literal+` is AsciiDoc's way to show markup verbatim.
        if len(inner) >= 2 and inner.startswith("+") and inner.endswith("+"):
            inner = inner[1:-1]
        spans.append(f"`{inner}`")
        return f"\x00{len(spans) - 1}\x00"

    text = re.sub(r"`([^`]*)`", hold, text)
    text = XREF.sub(lambda m: f"[{m.group(2)}](#{m.group(1)})", text)
    if BARE_XREF.search(text):
        raise ConversionError(f"line {line}: a cross reference needs link text")
    text = URL_LINK.sub(lambda m: f"[{m.group(2) or m.group(1)}]({m.group(1)})", text)
    text = BOLD.sub(r"**\1**", text)
    text = EMPHASIS.sub(r"*\1*", text)
    for macro in ("link:", "image:", "footnote:", "pass:", "kbd:", "btn:", "menu:"):
        if macro in text:
            raise ConversionError(f"line {line}: unsupported inline macro {macro}")
    return re.sub(r"\x00(\d+)\x00", lambda m: spans[int(m.group(1))], text)


def split_cells(row: str, line: int) -> list[str]:
    """Split a table row on unescaped `|`, keeping `\\|` for Markdown."""
    if not row.startswith("|"):
        raise ConversionError(f"line {line}: a table row must start with '|': {row!r}")
    cells: list[str] = []
    current = ""
    index = 1
    while index < len(row):
        char = row[index]
        if char == "\\" and index + 1 < len(row) and row[index + 1] == "|":
            current += "\\|"
            index += 2
            continue
        if char == "|":
            cells.append(current.strip())
            current = ""
        else:
            current += char
        index += 1
    cells.append(current.strip())
    return cells


def convert(source: str) -> str:
    lines = source.splitlines()
    out: list[str] = []
    index = 0
    # Indentation for a block attached to the previous list item with `+`.
    continuation = ""
    list_indent = ""

    def emit(text: str) -> None:
        out.append(text)

    while index < len(lines):
        line = lines[index]
        number = index + 1

        if COMMENT.match(line):
            index += 1
            continue
        if line.startswith("////"):
            raise ConversionError(f"line {number}: comment blocks are not supported")
        if BLOCK_ID.match(line) or LEGACY_ANCHOR.match(line):
            index += 1
            continue
        if line == "+":
            continuation = list_indent
            if out and out[-1] != "":
                emit("")
            index += 1
            continue
        if not line.strip():
            continuation = ""
            list_indent = ""
            emit("")
            index += 1
            continue

        title = TITLE.match(line)
        if title:
            emit("#" * len(title.group(1)) + " " + convert_inline(title.group(2), number))
            index += 1
            continue

        if line == "'''":
            emit("---")
            index += 1
            continue

        source_block = SOURCE.match(line)
        if source_block:
            if index + 1 >= len(lines) or lines[index + 1] != "----":
                raise ConversionError(f"line {number}: [source] must be followed by a ---- block")
            language = source_block.group(1) or ""
            end = index + 2
            while end < len(lines) and lines[end] != "----":
                end += 1
            if end >= len(lines):
                raise ConversionError(f"line {number}: unterminated ---- block")
            indent = continuation
            emit(f"{indent}```{language}")
            for body in lines[index + 2:end]:
                emit(f"{indent}{body}" if body else "")
            emit(f"{indent}```")
            index = end + 1
            continue

        table_attrs = TABLE_ATTRS.match(line)
        if table_attrs or line == "|===":
            header = table_attrs is not None and 'options="header"' in line
            start = index + 1 if table_attrs else index
            if start >= len(lines) or lines[start] != "|===":
                raise ConversionError(f"line {number}: table attributes must be followed by |===")
            end = start + 1
            rows: list[list[str]] = []
            while end < len(lines) and lines[end] != "|===":
                if lines[end].strip():
                    rows.append([convert_inline(cell, end + 1) for cell in split_cells(lines[end], end + 1)])
                end += 1
            if end >= len(lines):
                raise ConversionError(f"line {number}: unterminated table")
            if not rows:
                raise ConversionError(f"line {number}: empty table")
            width = len(rows[0])
            if any(len(row) != width for row in rows):
                raise ConversionError(f"line {number}: every table row must be one line with the same number of cells")
            head, body = (rows[0], rows[1:]) if header else ([""] * width, rows)
            emit("| " + " | ".join(head) + " |")
            emit("|" + "|".join(" --- " for _ in range(width)) + "|")
            for row in body:
                emit("| " + " | ".join(row) + " |")
            index = end + 1
            continue

        bullet = BULLET.match(line)
        numbered = NUMBERED.match(line)
        if bullet or numbered:
            match = bullet or numbered
            depth = len(match.group(1))
            indent = "  " * (depth - 1)
            marker = "- " if bullet else "1. "
            emit(f"{indent}{marker}{convert_inline(match.group(2), number)}")
            list_indent = indent + " " * len(marker)
            continuation = ""
            index += 1
            continue

        if line.startswith(("[", ":", "include::", "ifdef::", "ifndef::", "endif::", "image::", "....", "____", "====", "****", "----")):
            raise ConversionError(f"line {number}: unsupported AsciiDoc construct: {line!r}")

        # A paragraph line, possibly continuing a list item.
        indent = continuation or (list_indent if list_indent and out and out[-1] != "" else "")
        emit(f"{indent}{convert_inline(line, number)}")
        index += 1

    text = "\n".join(out)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip() + "\n"


def convert_file(path: Path) -> str:
    try:
        return convert(path.read_text(encoding="utf-8"))
    except ConversionError as err:
        raise ConversionError(f"{path}: {err}") from None


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} NOTES.adoc", file=sys.stderr)
        raise SystemExit(2)
    try:
        sys.stdout.write(convert_file(Path(sys.argv[1])))
    except ConversionError as err:
        print(f"error: {err}", file=sys.stderr)
        raise SystemExit(1)
