#!/usr/bin/env python3
"""Extract Freedoom Phase 1 E1M1 and its referenced artwork deterministically."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import struct
import tempfile
import urllib.request
import zipfile
from collections import Counter
from pathlib import Path

import PIL
from PIL import Image


VERSION = "0.13.0"
ZIP_URL = f"https://github.com/freedoom/freedoom/releases/download/v{VERSION}/freedoom-{VERSION}.zip"
ZIP_SHA256 = "3f9b264f3e3ce503b4fb7f6bdcb1f419d93c7b546f4df3e874dd878db9688f59"
WAD_MEMBER = f"freedoom-{VERSION}/freedoom1.wad"
WAD_SHA256 = "7323bcc168c5a45ff10749b339960e98314740a734c30d4b9f3337001f9e703d"
PILLOW_VERSION = "10.2.0"
MAP_NAME = "E1M1"

# Standard Doom editor-number to sprite-prefix mapping for every thing type used
# by Freedoom 0.13.0 E1M1. Starts and invisible-only things deliberately map to
# null; unknown types fail extraction rather than silently losing artwork.
THING_SPRITES: dict[int, str | None] = {
    1: None, 2: None, 3: None, 4: None, 5: "BKEY", 8: "BPAK", 9: "SPOS",
    10: "PLAY", 11: None, 12: "PLAY", 15: "POSS", 17: "SARG", 18: "HEAD",
    19: "SKUL", 20: "TROO", 21: "SPOS", 24: "POL5", 26: "CAND",
    43: "TRE1", 47: "SMIT", 48: "ELEC", 54: "TRE2", 58: "SARG", 60: "GOR4",
    2001: "SHOT", 2002: "MGUN", 2003: "LAUN", 2004: "PLAS", 2005: "CSAW",
    2007: "CLIP", 2008: "SHEL", 2010: "ROCK", 2011: "STIM", 2012: "MEDI",
    2013: "SOUL", 2014: "BON1", 2015: "BON2", 2018: "ARM1", 2019: "ARM2",
    2023: "PSTR", 2028: "COLU", 2035: "BAR1", 2046: "PMAP", 2047: "PVIS",
    2048: "AMMO", 2049: "SBOX", 3001: "TROO", 3002: "SARG", 3004: "POSS",
}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def name8(raw: bytes) -> str | None:
    value = raw.rstrip(b"\0").decode("ascii")
    return None if value == "-" else value


class Wad:
    def __init__(self, data: bytes):
        self.data = data
        magic, count, directory = struct.unpack_from("<4sii", data)
        if magic != b"IWAD":
            raise ValueError(f"expected IWAD, found {magic!r}")
        self.lumps: list[tuple[str, int, int]] = []
        for index in range(count):
            offset, size, raw_name = struct.unpack_from("<ii8s", data, directory + index * 16)
            self.lumps.append((raw_name.rstrip(b"\0").decode("ascii"), offset, size))

    def bytes_at(self, index: int) -> bytes:
        _, offset, size = self.lumps[index]
        return self.data[offset : offset + size]

    def last(self, name: str) -> bytes:
        for index in range(len(self.lumps) - 1, -1, -1):
            if self.lumps[index][0] == name:
                return self.bytes_at(index)
        raise KeyError(name)

    def map_lumps(self, marker: str) -> dict[str, bytes]:
        start = next(i for i, lump in enumerate(self.lumps) if lump[0] == marker)
        expected = ("THINGS", "LINEDEFS", "SIDEDEFS", "VERTEXES", "SEGS", "SSECTORS", "NODES", "SECTORS", "REJECT", "BLOCKMAP")
        result = {name: self.bytes_at(start + 1 + offset) for offset, name in enumerate(expected)}
        actual = tuple(self.lumps[start + 1 + offset][0] for offset in range(len(expected)))
        if actual != expected:
            raise ValueError(f"{marker} is not a classic Doom map: {actual}")
        return result


def records(data: bytes, fmt: str):
    size = struct.calcsize(fmt)
    if len(data) % size:
        raise ValueError(f"lump size {len(data)} is not divisible by record size {size}")
    return struct.iter_unpack(fmt, data)


def parse_map(wad: Wad) -> tuple[dict[str, object], set[str], set[str], set[str]]:
    lumps = wad.map_lumps(MAP_NAME)
    vertices = [{"x": x, "y": y} for x, y in records(lumps["VERTEXES"], "<hh")]
    linedefs = [
        {"start_vertex": a, "end_vertex": b, "flags": flags, "special": special, "tag": tag,
         "right_sidedef": None if right == 0xFFFF else right, "left_sidedef": None if left == 0xFFFF else left}
        for a, b, flags, special, tag, right, left in records(lumps["LINEDEFS"], "<HHHHHHH")
    ]
    sidedefs = []
    textures: set[str] = set()
    for x, y, upper, lower, middle, sector in records(lumps["SIDEDEFS"], "<hh8s8s8sH"):
        names = [name8(upper), name8(lower), name8(middle)]
        textures.update(name for name in names if name is not None)
        sidedefs.append({"x_offset": x, "y_offset": y, "upper_texture": names[0],
                         "lower_texture": names[1], "middle_texture": names[2], "sector": sector})
    sectors = []
    flats: set[str] = set()
    for floor, ceiling, floor_name, ceiling_name, light, special, tag in records(lumps["SECTORS"], "<hh8s8shhh"):
        floor_flat = name8(floor_name)
        ceiling_flat = name8(ceiling_name)
        assert floor_flat is not None and ceiling_flat is not None
        flats.update((floor_flat, ceiling_flat))
        sectors.append({"floor_height": floor, "ceiling_height": ceiling, "floor_flat": floor_flat,
                        "ceiling_flat": ceiling_flat, "light_level": light, "special": special, "tag": tag})
    things = []
    prefixes: set[str] = set()
    for x, y, angle, thing_type, flags in records(lumps["THINGS"], "<hhhhH"):
        if thing_type not in THING_SPRITES:
            raise ValueError(f"no sprite mapping for E1M1 thing type {thing_type}")
        prefix = THING_SPRITES[thing_type]
        if prefix is not None:
            prefixes.add(prefix)
        things.append({"x": x, "y": y, "angle": angle, "type": thing_type, "flags": flags,
                       "sprite_prefix": prefix})
    segs = [{"start_vertex": a, "end_vertex": b, "angle": angle, "linedef": line,
             "direction": direction, "offset": offset}
            for a, b, angle, line, direction, offset in records(lumps["SEGS"], "<HHHHHH")]
    subsectors = [{"seg_count": count, "first_seg": first} for count, first in records(lumps["SSECTORS"], "<HH")]
    nodes = []
    for values in records(lumps["NODES"], "<hhhhhhhhhhhhHH"):
        x, y, dx, dy, rt, rb, rl, rr, lt, lb, ll, lr, rc, lc = values
        child = lambda value: {"kind": "subsector" if value & 0x8000 else "node", "index": value & 0x7FFF}
        nodes.append({"x": x, "y": y, "dx": dx, "dy": dy,
                      "right_bbox": {"top": rt, "bottom": rb, "left": rl, "right": rr},
                      "left_bbox": {"top": lt, "bottom": lb, "left": ll, "right": lr},
                      "right_child": child(rc), "left_child": child(lc)})
    block = lumps["BLOCKMAP"]
    origin_x, origin_y, columns, rows = struct.unpack_from("<hhhh", block)
    offsets = struct.unpack_from(f"<{columns * rows}H", block, 8)
    blocklists = []
    for word_offset in offsets:
        # Every Doom block list starts with a dummy zero word. A real linedef 0
        # may immediately follow it, so skip exactly one word rather than all
        # leading zeroes.
        cursor = word_offset * 2 + 2
        values = []
        while True:
            value = struct.unpack_from("<h", block, cursor)[0]
            cursor += 2
            if value == -1:
                break
            values.append(value)
        blocklists.append(values)
    result = {
        "format": "doom", "map": MAP_NAME, "units": "Doom map units", "vertices": vertices,
        "linedefs": linedefs, "sidedefs": sidedefs, "sectors": sectors, "things": things,
        "segs": segs, "subsectors": subsectors, "nodes": nodes,
        "blockmap": {"origin_x": origin_x, "origin_y": origin_y, "columns": columns, "rows": rows,
                     "linedef_lists": blocklists},
        "reject": {"encoding": "hex", "bytes": lumps["REJECT"].hex()},
    }
    return result, textures, flats, prefixes


def palette(wad: Wad) -> list[tuple[int, int, int, int]]:
    raw = wad.last("PLAYPAL")[:768]
    return [(raw[i], raw[i + 1], raw[i + 2], 255) for i in range(0, 768, 3)]


def doom_picture(data: bytes, colors: list[tuple[int, int, int, int]]) -> Image.Image:
    width, height, _, _ = struct.unpack_from("<hhhh", data)
    offsets = struct.unpack_from(f"<{width}I", data, 8)
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    pixels = image.load()
    for x, offset in enumerate(offsets):
        previous = -1
        while data[offset] != 255:
            top = data[offset]
            length = data[offset + 1]
            if top <= previous:
                top += previous
            previous = top
            offset += 3
            for dy, index in enumerate(data[offset : offset + length]):
                y = top + dy
                if 0 <= y < height:
                    pixels[x, y] = colors[index]
            offset += length + 1
    return image


def texture_definitions(wad: Wad) -> dict[str, tuple[int, int, list[tuple[int, int, int]]]]:
    patch_names_raw = wad.last("PNAMES")
    count = struct.unpack_from("<I", patch_names_raw)[0]
    patch_names = [name8(patch_names_raw[4 + i * 8 : 12 + i * 8]) for i in range(count)]
    definitions = {}
    for lump_name in ("TEXTURE1", "TEXTURE2"):
        try:
            data = wad.last(lump_name)
        except KeyError:
            continue
        texture_count = struct.unpack_from("<I", data)[0]
        offsets = struct.unpack_from(f"<{texture_count}I", data, 4)
        for offset in offsets:
            name, _, width, height, _, patch_count = struct.unpack_from("<8sIhhIh", data, offset)
            patches = []
            cursor = offset + 22
            for _ in range(patch_count):
                x, y, patch_index, _, _ = struct.unpack_from("<hhHhh", data, cursor)
                cursor += 10
                patch_name = patch_names[patch_index]
                assert patch_name is not None
                patches.append((x, y, patch_name))
            texture_name = name8(name)
            assert texture_name is not None
            definitions[texture_name] = (width, height, patches)
    return definitions


def world_images(wad: Wad, textures: set[str], flats: set[str]) -> dict[str, tuple[Image.Image, dict[str, object]]]:
    colors = palette(wad)
    definitions = texture_definitions(wad)
    output = {}
    for name in sorted(textures):
        if name not in definitions:
            raise ValueError(f"referenced texture {name} has no TEXTURE definition")
        width, height, patches = definitions[name]
        image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        for x, y, patch_name in patches:
            image.alpha_composite(doom_picture(wad.last(patch_name), colors), (x, y))
        output[f"texture/{name}"] = (image, {"kind": "texture", "doom_name": name})
    for name in sorted(flats):
        raw = wad.last(name)
        if len(raw) != 4096:
            raise ValueError(f"referenced flat {name} has {len(raw)} bytes, expected 4096")
        image = Image.new("RGBA", (64, 64))
        image.putdata([colors[index] for index in raw])
        output[f"flat/{name}"] = (image, {"kind": "flat", "doom_name": name})
    return output


def sprite_images(wad: Wad, prefixes: set[str]) -> dict[str, tuple[Image.Image, dict[str, object]]]:
    colors = palette(wad)
    output = {}
    start = next(i for i, lump in enumerate(wad.lumps) if lump[0] == "S_START") + 1
    end = next(i for i, lump in enumerate(wad.lumps[start:], start) if lump[0] == "S_END")
    for name, offset, size in wad.lumps[start:end]:
        if any(name.startswith(prefix) for prefix in prefixes) and size >= 8:
            try:
                image = doom_picture(wad.data[offset : offset + size], colors)
            except (IndexError, struct.error, ValueError):
                continue
            aliases = []
            suffix = name[4:]
            if len(suffix) not in (2, 4) or not suffix[0].isalpha() or not suffix[1].isdigit():
                raise ValueError(f"unexpected Doom sprite lump name: {name}")
            aliases.append({"frame": suffix[0], "angle": int(suffix[1]), "mirrored": False})
            if len(suffix) == 4:
                if not suffix[2].isalpha() or not suffix[3].isdigit():
                    raise ValueError(f"unexpected Doom sprite lump name: {name}")
                aliases.append({"frame": suffix[2], "angle": int(suffix[3]), "mirrored": True})
            output[name] = (image, {"kind": "sprite", "doom_name": name,
                                   "sprite": name[:4], "aliases": aliases})
    missing = sorted(prefix for prefix in prefixes if not any(name.startswith(prefix) for name in output))
    if missing:
        raise ValueError(f"no sprite lumps found for prefixes: {missing}")
    return output


def write_atlas(path: Path, images: dict[str, tuple[Image.Image, dict[str, object]]]) -> dict[str, object]:
    width, padding = 2048, 2
    x = y = padding
    row_height = 0
    placements = {}
    for name in sorted(images, key=lambda n: (-images[n][0].height, -images[n][0].width, n)):
        image, metadata = images[name]
        if x + image.width + padding > width:
            x = padding
            y += row_height + padding
            row_height = 0
        placements[name] = (x, y, image, metadata)
        x += image.width + padding
        row_height = max(row_height, image.height)
    used_height = y + row_height + padding
    height = max(64, 1 << math.ceil(math.log2(used_height)))
    atlas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    entries = []
    for name in sorted(placements):
        px, py, image, metadata = placements[name]
        atlas.alpha_composite(image, (px, py))
        entries.append({"name": name, "rect": {"x": px, "y": py, "width": image.width,
                                                "height": image.height}, **metadata})
    atlas.save(path, format="PNG", compress_level=9, optimize=False)
    return {"width": width, "height": height, "entries": entries}


def obtain_zip(path: Path | None) -> bytes:
    if path:
        return path.read_bytes()
    request = urllib.request.Request(ZIP_URL, headers={"User-Agent": "roc-ray-doom-wad/1"})
    with urllib.request.urlopen(request) as response:
        return response.read()


def build(output: Path, supplied_zip: Path | None) -> None:
    archive = obtain_zip(supplied_zip)
    if digest(archive) != ZIP_SHA256:
        raise ValueError("Freedoom release ZIP checksum mismatch")
    with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
        wad_bytes = zipped.read(WAD_MEMBER)
    if digest(wad_bytes) != WAD_SHA256:
        raise ValueError("Freedoom Phase 1 WAD checksum mismatch")
    wad = Wad(wad_bytes)
    map_data, textures, flats, prefixes = parse_map(wad)
    output.mkdir(parents=True, exist_ok=True)
    (output / "map.json").write_text(json.dumps(map_data, indent=2) + "\n")
    world = write_atlas(output / "world_atlas.png", world_images(wad, textures, flats))
    sprites = write_atlas(output / "sprite_atlas.png", sprite_images(wad, prefixes))
    (output / "world_atlas.json").write_text(json.dumps(world, indent=2) + "\n")
    (output / "sprite_atlas.json").write_text(json.dumps(sprites, indent=2) + "\n")
    music_dir = output / "music"
    music_dir.mkdir(exist_ok=True)
    midi = wad.last("D_E1M1")
    if not midi.startswith(b"MThd"):
        raise ValueError("D_E1M1 is not a standard MIDI file")
    (music_dir / "e1m1.mid").write_bytes(midi)
    stats = {key: len(map_data[key]) for key in ("vertices", "linedefs", "sidedefs", "sectors", "things", "segs", "subsectors", "nodes")}
    manifest = {"project": "Freedoom: Phase 1", "version": VERSION, "release_url": ZIP_URL,
                "release_zip_sha256": ZIP_SHA256, "wad_member": WAD_MEMBER, "wad_sha256": WAD_SHA256,
                "map": MAP_NAME, "map_stats": stats, "thing_type_counts": dict(sorted(Counter(t["type"] for t in map_data["things"]).items())),
                "texture_count": len(textures), "flat_count": len(flats), "sprite_prefixes": sorted(prefixes),
                "sprite_lump_count": len(sprites["entries"]), "music_lump": "D_E1M1",
                "music_path": "music/e1m1.mid", "music_sha256": digest(midi)}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def files(root: Path) -> dict[Path, bytes]:
    return {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()}


def main() -> None:
    if PIL.__version__ != PILLOW_VERSION:
        raise SystemExit(f"Pillow {PILLOW_VERSION} required; found {PIL.__version__}")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="official freedoom-0.13.0.zip for offline extraction")
    parser.add_argument("--output", type=Path, default=Path("examples/doom/assets/freedoom/generated/e1m1"))
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        with tempfile.TemporaryDirectory(prefix="doom-wad-") as temporary:
            candidate = Path(temporary) / "e1m1"
            build(candidate, args.archive)
            if files(candidate) != files(args.output):
                raise SystemExit("E1M1 WAD extraction output differs; run scripts/doom_wad.py")
    else:
        build(args.output, args.archive)


if __name__ == "__main__":
    main()
