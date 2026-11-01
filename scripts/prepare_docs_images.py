#!/usr/bin/env python3
"""Prepare and verify the manual's gallery stills.

Mermaid diagrams are rendered natively by roc-docs during the ordinary build.
Gallery recordings need PNG stills for PDF output. Checking needs Python;
--update also needs Pillow with WebP support.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
STILLS = DOCS / "images" / "gallery"
STILLS_MANIFEST = STILLS / "stills.json"
GALLERY = ROOT / "examples" / "gallery"
STILL_POSITION = 0.5


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


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
    parser.add_argument("--update", action="store_true", help="prepare gallery stills")
    args = parser.parse_args()
    if args.update:
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
