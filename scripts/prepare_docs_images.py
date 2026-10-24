#!/usr/bin/env python3
"""Prepare the manual's images for the shared documentation renderer.

The renderer (`roc-docs`, from roc-automation) reads only non-interlaced
8-bit RGB or RGBA PNG files, and it never runs Mermaid or converts images.
This script makes those inputs, and checks that the committed ones still
match their sources:

- every `[mermaid]` block in `docs/*.adoc` becomes a PNG under
  `docs/images/diagrams/`, registered in `docs/prepared-diagrams.json` by the
  SHA-256 of its source, as the renderer requires. An edited diagram fails the
  manual build until it is prepared again.
- every animated recording in `examples/gallery/` that the manual shows gets a
  still under `docs/images/gallery/`, recorded in
  `docs/images/gallery/stills.json` with the digest of the recording it came
  from. The manual shows the still and links to the recording.

    scripts/prepare_docs_images.py           # check that everything is current
    scripts/prepare_docs_images.py --update  # prepare what changed

Checking needs only Python. Updating needs Pillow (with WebP support) for
the stills, and Node and Chrome for Mermaid: diagrams are rendered with the
pinned Mermaid CLI through `npx`, using the Chrome that `PUPPETEER_EXECUTABLE_PATH`
names (or `google-chrome` on PATH).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
DIAGRAMS = DOCS / "images" / "diagrams"
REGISTRY = DOCS / "prepared-diagrams.json"
GALLERY = ROOT / "examples" / "gallery"
STILLS = DOCS / "images" / "gallery"
STILLS_MANIFEST = STILLS / "stills.json"
MERMAID_CONFIG = ROOT / "scripts" / "docs" / "mermaid-config.json"

# The Mermaid CLI the diagrams are rendered with. Changing it changes every
# diagram's pixels, so it is part of what the registry records.
MERMAID_CLI = "@mermaid-js/mermaid-cli@11.16.0"
# The manual's page colour, so no white plate shows around a diagram.
MERMAID_BACKGROUND = "FAFAF7"
MERMAID_SCALE = "2"

# Which frame of a recording the still shows, as a fraction of its length.
# The first frame is often a title screen or an empty board.
STILL_POSITION = 0.5

MERMAID_BLOCK = re.compile(r"^\[mermaid(?:[,\]].*)?$")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def mermaid_blocks() -> list[tuple[str, int, str]]:
    """Every Mermaid block as (chapter, line, body), the body as the renderer
    hashes it: the lines between the delimiters, joined by LF, with a final LF."""
    found = []
    for chapter in sorted(DOCS.glob("*.adoc")):
        lines = chapter.read_text(encoding="utf-8").split("\n")
        index = 0
        while index < len(lines):
            if MERMAID_BLOCK.match(lines[index]):
                delimiter = lines[index + 1]
                if len(delimiter) < 4 or set(delimiter) not in ({"."}, {"-"}):
                    raise SystemExit(f"{chapter.name}:{index + 1}: a [mermaid] block needs a delimited body")
                end = lines.index(delimiter, index + 2)
                body = "\n".join(lines[index + 2 : end]) + "\n"
                found.append((chapter.name, index + 1, body))
                index = end
            index += 1
    return found


def diagram_name(digest: str) -> str:
    return f"images/diagrams/{digest[:16]}.png"


def load_json(path: Path, empty: dict) -> dict:
    if not path.is_file():
        return empty
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def check_png(path: Path) -> str | None:
    """Why the renderer would refuse this PNG, or None."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return "not a PNG"
    bit_depth, colour_type, interlace = data[24], data[25], data[28]
    if bit_depth != 8 or colour_type not in (2, 6) or interlace != 0:
        return "not a non-interlaced 8-bit RGB or RGBA PNG"
    return None


def problems() -> list[str]:
    found = []
    registry = load_json(REGISTRY, {"diagrams": []})
    registered = {entry["source_sha256"]: entry for entry in registry.get("diagrams", [])}
    used = set()
    for chapter, line, body in mermaid_blocks():
        digest = sha256(body.encode("utf-8"))
        used.add(digest)
        entry = registered.get(digest)
        if entry is None:
            found.append(f"{chapter}:{line}: Mermaid diagram {digest[:16]} is not prepared")
            continue
        png = DOCS / entry["png"]
        if not png.is_file():
            found.append(f"{chapter}:{line}: {entry['png']} is missing")
        elif sha256(png.read_bytes()) != entry["png_sha256"]:
            found.append(f"{chapter}:{line}: {entry['png']} does not match its registered digest")
    for digest, entry in registered.items():
        if digest not in used:
            found.append(f"{REGISTRY.name}: {entry['png']} is registered for a diagram no chapter has")

    manifest = load_json(STILLS_MANIFEST, {"stills": []})
    for entry in manifest.get("stills", []):
        recording = ROOT / entry["recording"]
        still = DOCS / entry["png"]
        if not recording.is_file():
            found.append(f"{STILLS_MANIFEST.name}: {entry['recording']} no longer exists")
        elif sha256(recording.read_bytes()) != entry["recording_sha256"]:
            found.append(f"{entry['png']}: {entry['recording']} has changed since the still was made")
        if not still.is_file():
            found.append(f"{entry['png']} is missing")
        elif sha256(still.read_bytes()) != entry["png_sha256"]:
            found.append(f"{entry['png']} does not match its recorded digest")
    referenced = set()
    for chapter in DOCS.glob("*.adoc"):
        referenced.update(re.findall(r"image::?(images/gallery/[\w.-]+\.png)\[", chapter.read_text(encoding="utf-8")))
    stills = {entry["png"] for entry in manifest.get("stills", [])}
    for missing in sorted(referenced - stills):
        found.append(f"{missing} is shown in the manual but has no recording in {STILLS_MANIFEST.name}")

    for png in sorted((DOCS / "images").rglob("*.png")):
        why = check_png(png)
        if why:
            found.append(f"{png.relative_to(DOCS)}: {why}")
    return found


def chrome() -> str:
    configured = os.environ.get("PUPPETEER_EXECUTABLE_PATH")
    if configured:
        return configured
    for name in ("google-chrome", "chromium", "chromium-browser"):
        path = shutil.which(name)
        if path:
            return path
    raise SystemExit("set PUPPETEER_EXECUTABLE_PATH to a Chrome or Chromium executable")


def normalise_png(path: Path) -> None:
    """Rewrite as the non-interlaced 8-bit RGB PNG the renderer reads."""
    from PIL import Image

    with Image.open(path) as image:
        image.load()
        flat = Image.new("RGB", image.size, "#" + MERMAID_BACKGROUND)
        rgba = image.convert("RGBA")
        flat.paste(rgba, mask=rgba.getchannel("A"))
    flat.save(path, format="PNG", optimize=True)


def update_diagrams() -> None:
    registry = load_json(REGISTRY, {"schema_version": 2, "diagrams": []})
    registered = {entry["source_sha256"]: entry for entry in registry.get("diagrams", [])}
    entries = []
    DIAGRAMS.mkdir(parents=True, exist_ok=True)
    keep = set()
    for chapter, line, body in mermaid_blocks():
        digest = sha256(body.encode("utf-8"))
        name = diagram_name(digest)
        png = DOCS / name
        keep.add(png)
        entry = registered.get(digest)
        if entry is None or not png.is_file() or sha256(png.read_bytes()) != entry["png_sha256"]:
            print(f"rendering {chapter}:{line} -> {name}")
            with tempfile.TemporaryDirectory(prefix="rocray-mermaid-") as scratch:
                scratch_dir = Path(scratch)
                source = scratch_dir / "diagram.mmd"
                source.write_text(body, encoding="utf-8")
                puppeteer = scratch_dir / "puppeteer.json"
                puppeteer.write_text(
                    json.dumps({"executablePath": chrome(), "args": ["--no-sandbox", "--disable-crashpad"]}),
                    encoding="utf-8",
                )
                output = scratch_dir / "diagram.png"
                subprocess.run(
                    ["npx", "--yes", MERMAID_CLI, "--input", str(source), "--output", str(output),
                     "--configFile", str(MERMAID_CONFIG), "--puppeteerConfigFile", str(puppeteer),
                     "--backgroundColor", MERMAID_BACKGROUND, "--scale", MERMAID_SCALE, "--quiet"],
                    check=True,
                )
                normalise_png(output)
                shutil.copyfile(output, png)
        entries.append({
            "source": chapter,
            "source_sha256": digest,
            "href": name,
            "png": name,
            "png_sha256": sha256(png.read_bytes()),
            "svg": "",
            "svg_sha256": "",
        })
    for stale in DIAGRAMS.glob("*.png"):
        if stale not in keep:
            stale.unlink()
    write_json(REGISTRY, {
        "schema_version": 2,
        "recipe": {
            "mermaid_cli": MERMAID_CLI,
            "config": MERMAID_CONFIG.relative_to(ROOT).as_posix(),
            "config_sha256": sha256(MERMAID_CONFIG.read_bytes()),
            "background": MERMAID_BACKGROUND,
            "scale": int(MERMAID_SCALE),
            "command": "scripts/prepare_docs_images.py --update",
        },
        "diagrams": entries,
    })


def update_stills() -> None:
    from PIL import Image

    referenced = set()
    for chapter in DOCS.glob("*.adoc"):
        referenced.update(re.findall(r"image::?images/gallery/([\w.-]+)\.png\[", chapter.read_text(encoding="utf-8")))
    STILLS.mkdir(parents=True, exist_ok=True)
    entries = []
    for name in sorted(referenced):
        recording = GALLERY / f"{name}.webp"
        if not recording.is_file():
            raise SystemExit(f"the manual shows images/gallery/{name}.png, but {recording.relative_to(ROOT)} does not exist")
        still = STILLS / f"{name}.png"
        with Image.open(recording) as image:
            frames = getattr(image, "n_frames", 1)
            frame = min(frames - 1, int(frames * STILL_POSITION))
            image.seek(frame)
            image.load()
            rgb = image.convert("RGB")
        rgb.save(still, format="PNG", optimize=True)
        entries.append({
            "recording": recording.relative_to(ROOT).as_posix(),
            "recording_sha256": sha256(recording.read_bytes()),
            "frame": frame,
            "png": f"images/gallery/{name}.png",
            "png_sha256": sha256(still.read_bytes()),
        })
    for stale in STILLS.glob("*.png"):
        if stale.stem not in referenced:
            stale.unlink()
    write_json(STILLS_MANIFEST, {"position": STILL_POSITION, "stills": entries})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--update", action="store_true", help="prepare every diagram and still that is not current")
    args = parser.parse_args()
    if args.update:
        update_diagrams()
        update_stills()
    found = problems()
    if found:
        print("The manual's prepared images are not current:", file=sys.stderr)
        for problem in found:
            print(f"  - {problem}", file=sys.stderr)
        if not args.update:
            print("Run scripts/prepare_docs_images.py --update and commit the result.", file=sys.stderr)
        return 1
    print("The manual's prepared images are current.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
