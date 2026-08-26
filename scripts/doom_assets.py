#!/usr/bin/env python3
"""Build the small, pinned Freedoom asset set used by the Doom vertical slice."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import shutil
import tarfile
import tempfile
import urllib.request
from pathlib import Path

import PIL
from PIL import Image


VERSION = "0.13.0"
ARCHIVE_URL = f"https://github.com/freedoom/freedoom/archive/refs/tags/v{VERSION}.tar.gz"
ARCHIVE_SHA256 = "860edb005bcf0b2acf29d10fd9130c91025301764a4d0d6dcffc503fdf8d2c77"
ARCHIVE_ROOT = f"freedoom-{VERSION}"
ATLAS_SIZE = (1024, 576)
PADDING = 2
PILLOW_VERSION = "10.2.0"

# These are intentionally source images, not assets decoded from an IWAD. Keeping
# the selection explicit makes upstream review and attribution straightforward.
IMAGES = (
    ("wall_concrete", "patches/aqconc02.png"),
    ("wall_brown", "patches/brown5.png"),
    ("wall_metal", "patches/aqmetl29.png"),
    ("wall_light", "patches/aqlite12.png"),
    ("door", "patches/aqdoor01.png"),
    ("wall_computer", "patches/aqcomp01.png"),
    ("wall_warning", "patches/graywarn.png"),
    ("door_locked", "patches/aqdoor02.png"),
    ("switch_off", "patches/sw1s0.png"),
    ("switch_on", "patches/sw1s1.png"),
    ("exit_sign", "patches/exit_grn.png"),
    ("floor", "flats/floor4_8.png"),
    ("ceiling", "flats/ceil3_5.png"),
    ("enemy_walk_0", "sprites/possa1.png"),
    ("enemy_walk_1", "sprites/possb1.png"),
    ("enemy_attack_0", "sprites/posse1.png"),
    ("enemy_attack_1", "sprites/possf1.png"),
    ("enemy_pain", "sprites/possg1.png"),
    ("enemy_die_0", "sprites/possh0.png"),
    ("enemy_die_1", "sprites/possi0.png"),
    ("enemy_die_2", "sprites/possj0.png"),
    ("enemy_die_3", "sprites/possk0.png"),
    ("enemy_die_4", "sprites/possl0.png"),
    ("pistol_0", "sprites/pisga0.png"),
    ("pistol_1", "sprites/pisgb0.png"),
    ("pistol_2", "sprites/pisgc0.png"),
    ("pistol_3", "sprites/pisgd0.png"),
    ("pistol_4", "sprites/pisge0.png"),
    ("ammo", "sprites/ammoa0.png"),
    ("health", "sprites/media0.png"),
    ("health_small", "sprites/stima0.png"),
    *((f"health_bonus_{frame}", f"sprites/bon1{frame}0.png") for frame in "abcd"),
    *((f"soul_{frame}", f"sprites/soul{frame}0.png") for frame in "abcd"),
    *((f"key_blue_{frame}", f"sprites/bkey{frame}0.png") for frame in "ab"),
    *((f"key_red_{frame}", f"sprites/rkey{frame}0.png") for frame in "ab"),
    *((f"key_yellow_{frame}", f"sprites/ykey{frame}0.png") for frame in "ab"),
    ("hud_bar", "graphics/stbar.png"),
    *((f"hud_digit_{n}", f"graphics/sttnum{n}.png") for n in range(10)),
    *(
        (f"enemy_walk_{frame}_{angle}", f"sprites/poss{frame}{angle}.png")
        for frame in "abcd"
        for angle in range(1, 9)
    ),
    *(
        (f"enemy_attack_{frame}_{angle}", f"sprites/poss{frame}{angle}.png")
        for frame in "ef"
        for angle in range(1, 9)
    ),
    *((f"enemy_pain_{angle}", f"sprites/possg{angle}.png") for angle in range(1, 9)),
)

AUDIO = (
    ("pistol.wav", "sounds/dspistol.wav"),
    ("enemy_alert.wav", "sounds/dsposit1.wav"),
    ("enemy_pain.wav", "sounds/dspopain.wav"),
    ("enemy_die.wav", "sounds/dspodth1.wav"),
    ("door_move.wav", "sounds/dsstnmov.wav"),
    ("switch_on.wav", "sounds/dsswtchn.wav"),
    ("switch_off.wav", "sounds/dsswtchx.wav"),
    ("pickup.wav", "sounds/dsitemup.wav"),
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def archive_bytes(path: Path | None) -> bytes:
    if path is not None:
        return path.read_bytes()
    request = urllib.request.Request(ARCHIVE_URL, headers={"User-Agent": "roc-ray-doom-assets/1"})
    with urllib.request.urlopen(request) as response:
        return response.read()


def member_bytes(archive: tarfile.TarFile, relative: str) -> bytes:
    member = archive.getmember(f"{ARCHIVE_ROOT}/{relative}")
    extracted = archive.extractfile(member)
    if extracted is None:
        raise RuntimeError(f"upstream member is not a regular file: {relative}")
    return extracted.read()


def pack_images(archive: tarfile.TarFile) -> tuple[Image.Image, dict[str, dict[str, object]]]:
    atlas = Image.new("RGBA", ATLAS_SIZE, (0, 0, 0, 0))
    entries: dict[str, dict[str, object]] = {}
    x = y = PADDING
    row_height = 0

    for name, source in IMAGES:
        source_bytes = member_bytes(archive, source)
        with Image.open(io.BytesIO(source_bytes)) as opened:
            image = opened.convert("RGBA")
        width, height = image.size
        if x + width + PADDING > ATLAS_SIZE[0]:
            x = PADDING
            y += row_height + PADDING
            row_height = 0
        if y + height + PADDING > ATLAS_SIZE[1]:
            raise RuntimeError(f"atlas is too small while packing {name}")
        atlas.alpha_composite(image, (x, y))
        entries[name] = {
            "x": x,
            "y": y,
            "width": width,
            "height": height,
            "source": source,
            "source_sha256": sha256(source_bytes),
        }
        x += width + PADDING
        row_height = max(row_height, height)
    return atlas, entries


def build(output: Path, supplied_archive: Path | None) -> None:
    compressed = archive_bytes(supplied_archive)
    actual = sha256(compressed)
    if actual != ARCHIVE_SHA256:
        raise RuntimeError(f"Freedoom archive checksum mismatch: expected {ARCHIVE_SHA256}, got {actual}")

    with tarfile.open(fileobj=io.BytesIO(compressed), mode="r:gz") as archive:
        atlas, entries = pack_images(archive)
        generated = output / "generated"
        audio_dir = generated / "audio"
        source_dir = output / "source"
        license_dir = output / "license"
        attribution_dir = output / "attribution"
        for directory in (generated, audio_dir, source_dir, license_dir, attribution_dir):
            directory.mkdir(parents=True, exist_ok=True)

        atlas.save(generated / "atlas.png", format="PNG", compress_level=9, optimize=False)
        (generated / "atlas.json").write_text(
            json.dumps({"width": ATLAS_SIZE[0], "height": ATLAS_SIZE[1], "sprites": entries}, indent=2)
            + "\n",
            encoding="utf-8",
        )

        source_files: dict[str, str] = {source: data["source_sha256"] for data in entries.values() for source in [str(data["source"])]}
        for destination, source in AUDIO:
            data = member_bytes(archive, source)
            (audio_dir / destination).write_bytes(data)
            source_files[source] = sha256(data)
        (license_dir / "COPYING.adoc").write_bytes(member_bytes(archive, "COPYING.adoc"))
        (attribution_dir / "CREDITS").write_bytes(member_bytes(archive, "CREDITS"))
        (attribution_dir / "CREDITS-MUSIC").write_bytes(member_bytes(archive, "CREDITS-MUSIC"))

    manifest = {
        "project": "Freedoom",
        "version": VERSION,
        "release": f"v{VERSION}",
        "source_url": ARCHIVE_URL,
        "archive_sha256": ARCHIVE_SHA256,
        "files": dict(sorted(source_files.items())),
    }
    (source_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    if PIL.__version__ != PILLOW_VERSION:
        raise SystemExit(
            f"Pillow {PILLOW_VERSION} is required for byte-reproducible output; found {PIL.__version__}"
        )
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="use an already downloaded v0.13.0 source tarball")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("examples/roc-doom-e1m1/assets/freedoom"),
        help="asset directory to populate",
    )
    parser.add_argument("--check", action="store_true", help="fail if regenerating would change checked-in output")
    args = parser.parse_args()

    if args.check:
        with tempfile.TemporaryDirectory(prefix="roc-ray-doom-assets-") as temporary:
            candidate = Path(temporary) / "freedoom"
            build(candidate, args.archive)
            expected = {p.relative_to(candidate): p.read_bytes() for p in candidate.rglob("*") if p.is_file()}
            # Another reproducible stage owns generated/e1m1 and its docs.
            # Compare only this source-selection stage's declared output.
            actual = {
                relative: (args.output / relative).read_bytes()
                for relative in expected
                if (args.output / relative).is_file()
            }
            if actual != expected:
                missing = sorted(str(p) for p in expected.keys() - actual.keys())
                changed = sorted(str(p) for p in expected.keys() & actual.keys() if expected[p] != actual[p])
                raise SystemExit(f"asset output differs (missing={missing}, changed={changed})")
        return

    build(args.output, args.archive)


if __name__ == "__main__":
    main()
