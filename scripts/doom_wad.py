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
from fractions import Fraction
from pathlib import Path

import PIL
from PIL import Image
from doom_midi import render as render_midi


VERSION = "0.13.0"
ZIP_URL = f"https://github.com/freedoom/freedoom/releases/download/v{VERSION}/freedoom-{VERSION}.zip"
ZIP_SHA256 = "3f9b264f3e3ce503b4fb7f6bdcb1f419d93c7b546f4df3e874dd878db9688f59"
WAD_MEMBER = f"freedoom-{VERSION}/freedoom1.wad"
WAD_SHA256 = "7323bcc168c5a45ff10749b339960e98314740a734c30d4b9f3337001f9e703d"
PILLOW_VERSION = "10.2.0"
MAP_NAME = "E1M1"
PRESENTATION_SPRITES = {"PISG", "PISF", "SHTG", "SHTF", "BAL1", "BEXP", "PUFF", "BLUD"}
HUD_GRAPHIC_PREFIXES = ("STBAR", "STTNUM", "STYSNUM", "STGNUM", "STKEYS", "STF", "STARMS", "STTPRCNT")
GAMEPLAY_SOUNDS = {
    "weapon/pistol": "DSPISTOL", "weapon/shotgun": "DSSHOTGN", "weapon/shotgun_cock": "DSSGCOCK",
    "world/door_open": "DSDOROPN", "world/door_close": "DSDORCLS",
    "world/blazing_door_open": "DSBDOPN", "world/blazing_door_close": "DSBDCLS",
    "world/platform_start": "DSPSTART", "world/platform_stop": "DSPSTOP", "world/platform_move": "DSSTNMOV",
    "world/switch_on": "DSSWTCHN", "world/switch_off": "DSSWTCHX",
    "pickup/item": "DSITEMUP", "pickup/weapon": "DSWPNUP", "pickup/powerup": "DSGETPOW", "pickup/key": "DSITEMUP",
    "monster/former_human_sight_1": "DSPOSIT1", "monster/former_human_sight_2": "DSPOSIT2", "monster/former_human_sight_3": "DSPOSIT3",
    "monster/former_human_active": "DSPOSACT", "monster/former_human_attack": "DSPISTOL", "monster/former_human_pain": "DSPOPAIN",
    "monster/former_human_death_1": "DSPODTH1", "monster/former_human_death_2": "DSPODTH2", "monster/former_human_death_3": "DSPODTH3",
    "monster/shotgun_guy_sight_1": "DSPOSIT1", "monster/shotgun_guy_sight_2": "DSPOSIT2", "monster/shotgun_guy_sight_3": "DSPOSIT3",
    "monster/shotgun_guy_active": "DSPOSACT", "monster/shotgun_guy_attack": "DSSHOTGN", "monster/shotgun_guy_pain": "DSPOPAIN",
    "monster/shotgun_guy_death_1": "DSPODTH1", "monster/shotgun_guy_death_2": "DSPODTH2", "monster/shotgun_guy_death_3": "DSPODTH3",
    "monster/imp_sight_1": "DSBGSIT1", "monster/imp_sight_2": "DSBGSIT2", "monster/imp_active": "DSBGACT",
    "monster/imp_melee": "DSCLAW", "monster/imp_ranged_attack": "DSFIRSHT", "monster/imp_pain": "DSDMPAIN",
    "monster/imp_death_1": "DSBGDTH1", "monster/imp_death_2": "DSBGDTH2",
    "player/pain": "DSPLPAIN", "player/death": "DSPLDETH", "player/death_high": "DSPDIEHI",
    "player/oof": "DSOOF", "player/no_way": "DSNOWAY",
    "effect/imp_projectile": "DSFIRSHT", "effect/imp_explosion": "DSFIRXPL", "effect/barrel_explosion": "DSBAREXP",
}

# Standard Doom editor-number to sprite-prefix mapping for every thing type used
# by Freedoom 0.13.0 E1M1. Starts and invisible-only things deliberately map to
# null; unknown types fail extraction rather than silently losing artwork.
THING_SPRITES: dict[int, str | None] = {
    1: None, 2: None, 3: None, 4: None, 5: "BKEY", 8: "BPAK", 9: "SPOS",
    10: "PLAY", 11: None, 12: "PLAY", 15: "PLAY", 17: "CELP", 18: "POSS",
    19: "SPOS", 20: "TROO", 21: "SARG", 24: "POL5", 26: "CAND",
    43: "TRE1", 47: "SMIT", 48: "ELEC", 54: "TRE2", 58: "SARG", 60: "GOR4",
    2001: "SHOT", 2002: "MGUN", 2003: "LAUN", 2004: "PLAS", 2005: "CSAW",
    2007: "CLIP", 2008: "SHEL", 2010: "ROCK", 2011: "STIM", 2012: "MEDI",
    2013: "SOUL", 2014: "BON1", 2015: "BON2", 2018: "ARM1", 2019: "ARM2",
    2023: "PSTR", 2028: "COLU", 2035: "BAR1", 2046: "PMAP", 2047: "PVIS",
    2048: "AMMO", 2049: "SBOX", 3001: "TROO", 3002: "SARG", 3004: "POSS",
}

THING_SEMANTICS = {
    1:("Player 1 start","start","start_consumed"),2:("Player 2 start","start","start_ignored"),3:("Player 3 start","start","start_ignored"),4:("Player 4 start","start","start_ignored"),
    5:("Blue keycard","gameplay","implemented_pickup"),8:("Backpack","gameplay","gameplay_unimplemented"),9:("Shotgun guy","gameplay","implemented_actor"),
    10:("Bloody mess 1","decorative","decorative_ignored"),11:("Deathmatch start","start","start_ignored"),12:("Bloody mess 2","decorative","decorative_ignored"),15:("Dead player","decorative","decorative_ignored"),
    17:("Cell charge pack","gameplay","gameplay_unimplemented"),18:("Dead former human","decorative","decorative_ignored"),19:("Dead shotgun guy","decorative","decorative_ignored"),20:("Dead imp","decorative","decorative_ignored"),21:("Dead demon","decorative","decorative_ignored"),24:("Pool of blood and flesh","decorative","decorative_ignored"),26:("Candle","decorative","decorative_ignored"),43:("Burnt tree","decorative","decorative_ignored"),47:("Stalagmite","decorative","decorative_ignored"),48:("Tech pillar","decorative","decorative_ignored"),54:("Large brown tree","decorative","decorative_ignored"),58:("Spectre","gameplay","gameplay_unimplemented"),60:("Hanging victim, arms out","decorative","decorative_ignored"),
    2001:("Shotgun","gameplay","implemented_pickup"),2002:("Chaingun","gameplay","gameplay_unimplemented"),2003:("Rocket launcher","gameplay","gameplay_unimplemented"),2004:("Plasma rifle","gameplay","gameplay_unimplemented"),2005:("Chainsaw","gameplay","gameplay_unimplemented"),2007:("Ammo clip","gameplay","implemented_pickup"),2008:("Shotgun shells","gameplay","implemented_pickup"),2010:("Rocket","gameplay","gameplay_unimplemented"),2011:("Stimpack","gameplay","implemented_pickup"),2012:("Medikit","gameplay","implemented_pickup"),2013:("Soul sphere","gameplay","gameplay_unimplemented"),2014:("Health bonus","gameplay","implemented_pickup"),2015:("Armor bonus","gameplay","implemented_pickup"),2018:("Green armor","gameplay","implemented_pickup"),2019:("Blue armor","gameplay","implemented_pickup"),2023:("Berserk","gameplay","gameplay_unimplemented"),2028:("Floor lamp","decorative","decorative_ignored"),2035:("Explosive barrel","gameplay","implemented_actor"),2046:("Computer map","gameplay","gameplay_unimplemented"),2047:("Light amplification visor","gameplay","gameplay_unimplemented"),2048:("Box of bullets","gameplay","gameplay_unimplemented"),2049:("Box of shells","gameplay","gameplay_unimplemented"),3001:("Imp","gameplay","implemented_actor"),3002:("Demon","gameplay","gameplay_unimplemented"),3004:("Former human","gameplay","implemented_actor"),
}
if set(THING_SEMANTICS) != set(THING_SPRITES):
    raise RuntimeError("thing semantic and sprite tables differ")


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


def clipped_halfplane(
    polygon: list[tuple[Fraction, Fraction]],
    origin: tuple[int, int],
    direction: tuple[int, int],
    keep_right: bool,
) -> list[tuple[Fraction, Fraction]]:
    """Clip a CCW polygon to one side of a Doom BSP partition."""
    ox, oy = origin
    dx, dy = direction

    def side(point: tuple[Fraction, Fraction]) -> Fraction:
        px, py = point
        return Fraction(dx) * (py - oy) - Fraction(dy) * (px - ox)

    def inside(value: Fraction) -> bool:
        return value <= 0 if keep_right else value >= 0

    result = []
    for start, end in zip(polygon, polygon[1:] + polygon[:1]):
        start_side = side(start)
        end_side = side(end)
        start_inside = inside(start_side)
        end_inside = inside(end_side)
        if start_inside:
            result.append(start)
        if start_inside != end_inside:
            amount = start_side / (start_side - end_side)
            result.append((start[0] + amount * (end[0] - start[0]),
                           start[1] + amount * (end[1] - start[1])))

    # Clipping through an existing corner can produce duplicate or collinear
    # points. Canonicalize them while all coordinates are still exact.
    deduplicated = []
    for point in result:
        if not deduplicated or point != deduplicated[-1]:
            deduplicated.append(point)
    if len(deduplicated) > 1 and deduplicated[0] == deduplicated[-1]:
        deduplicated.pop()
    changed = True
    while changed and len(deduplicated) >= 3:
        changed = False
        simplified = []
        count = len(deduplicated)
        for index, point in enumerate(deduplicated):
            before = deduplicated[(index - 1) % count]
            after = deduplicated[(index + 1) % count]
            cross = ((point[0] - before[0]) * (after[1] - point[1])
                     - (point[1] - before[1]) * (after[0] - point[0]))
            if cross == 0:
                changed = True
            else:
                simplified.append(point)
        deduplicated = simplified
    return deduplicated


def subsector_cells(vertices, nodes, subsectors, segs, linedefs, sidedefs):
    min_x = min(vertex["x"] for vertex in vertices)
    max_x = max(vertex["x"] for vertex in vertices)
    min_y = min(vertex["y"] for vertex in vertices)
    max_y = max(vertex["y"] for vertex in vertices)
    if min_x >= max_x or min_y >= max_y:
        raise ValueError("map vertex bounds are degenerate")
    bounds = {"min_x": min_x, "min_y": min_y, "max_x": max_x, "max_y": max_y}
    initial = [(Fraction(min_x), Fraction(min_y)), (Fraction(max_x), Fraction(min_y)),
               (Fraction(max_x), Fraction(max_y)), (Fraction(min_x), Fraction(max_y))]
    leaves: dict[int, list[tuple[Fraction, Fraction]]] = {}
    visited_nodes = set()

    def descend(child, polygon):
        if child["kind"] == "subsector":
            index = child["index"]
            if index in leaves:
                raise ValueError(f"BSP reaches subsector {index} more than once")
            leaves[index] = polygon
            return
        index = child["index"]
        if index in visited_nodes:
            raise ValueError(f"BSP reaches node {index} more than once")
        if not 0 <= index < len(nodes):
            raise ValueError(f"BSP node index {index} is out of range")
        visited_nodes.add(index)
        node = nodes[index]
        if node["dx"] == 0 and node["dy"] == 0:
            raise ValueError(f"BSP node {index} has a zero partition vector")
        origin = (node["x"], node["y"])
        direction = (node["dx"], node["dy"])
        descend(node["right_child"], clipped_halfplane(polygon, origin, direction, True))
        descend(node["left_child"], clipped_halfplane(polygon, origin, direction, False))

    root = {"kind": "node", "index": len(nodes) - 1}
    descend(root, initial)
    expected = set(range(len(subsectors)))
    if set(leaves) != expected:
        raise ValueError(f"BSP subsector coverage mismatch: missing={sorted(expected - set(leaves))}")
    expected_nodes = set(range(len(nodes)))
    if visited_nodes != expected_nodes:
        raise ValueError(f"BSP node coverage mismatch: missing={sorted(expected_nodes - visited_nodes)}")

    def number(value: Fraction):
        return value.numerator if value.denominator == 1 else round(float(value), 9)

    output = []
    for index in range(len(subsectors)):
        polygon = leaves[index]
        if len(polygon) < 3:
            raise ValueError(f"subsector {index} clips to fewer than three points")
        crosses = []
        for before, point, after in zip(polygon[-1:] + polygon[:-1], polygon, polygon[1:] + polygon[:1]):
            crosses.append((point[0] - before[0]) * (after[1] - point[1])
                           - (point[1] - before[1]) * (after[0] - point[0]))
        if any(cross <= 0 for cross in crosses):
            raise ValueError(f"subsector {index} polygon is degenerate, clockwise, or non-convex")
        subsection = subsectors[index]
        sector_ids = set()
        for seg_index in range(subsection["first_seg"], subsection["first_seg"] + subsection["seg_count"]):
            seg = segs[seg_index]
            line = linedefs[seg["linedef"]]
            side_index = line["right_sidedef"] if seg["direction"] == 0 else line["left_sidedef"]
            if side_index is not None:
                sector_ids.add(sidedefs[side_index]["sector"])
        if len(sector_ids) != 1:
            raise ValueError(f"subsector {index} resolves to sectors {sorted(sector_ids)}")
        output.append({"subsector": index, "sector": next(iter(sector_ids)),
                       "points": [{"x": number(x), "y": number(y)} for x, y in polygon]})
    return bounds, output


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
    polygon_bounds, subsector_polygons = subsector_cells(
        vertices, nodes, subsectors, segs, linedefs, sidedefs
    )
    result = {
        "format": "doom", "map": MAP_NAME, "units": "Doom map units", "vertices": vertices,
        "linedefs": linedefs, "sidedefs": sidedefs, "sectors": sectors, "things": things,
        "segs": segs, "subsectors": subsectors, "nodes": nodes,
        "subsector_polygon_bounds": polygon_bounds, "subsector_polygons": subsector_polygons,
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
    for name, offset, size in wad.lumps:
        if name not in output and any(name.startswith(prefix) for prefix in HUD_GRAPHIC_PREFIXES):
            image = doom_picture(wad.data[offset : offset + size], colors)
            output[name] = (image, {"kind": "graphic", "doom_name": name,
                                   "sprite": "", "aliases": []})
    missing_graphics = sorted(prefix for prefix in HUD_GRAPHIC_PREFIXES if not any(name.startswith(prefix) for name in output))
    if missing_graphics:
        raise ValueError(f"no HUD graphic lumps found for prefixes: {missing_graphics}")
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


def doom_sound_wav(data: bytes, lump_name: str) -> tuple[bytes, int, int]:
    """Decode one DMX format-3 sound lump to canonical mono 8-bit PCM WAV."""
    if len(data) < 8:
        raise ValueError(f"sound lump {lump_name} is shorter than its DMX header")
    encoding, sample_rate, sample_count = struct.unpack_from("<HHI", data)
    if encoding != 3:
        raise ValueError(f"sound lump {lump_name} has DMX encoding {encoding}, expected 3")
    if sample_rate == 0:
        raise ValueError(f"sound lump {lump_name} has zero sample rate")
    samples = data[8:]
    if sample_count != len(samples):
        raise ValueError(f"sound lump {lump_name} declares {sample_count} samples but contains {len(samples)}")
    fmt = struct.pack("<HHIIHH", 1, 1, sample_rate, sample_rate, 1, 8)
    wav = (b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + len(samples)) + b"WAVE"
           + b"fmt " + struct.pack("<I", len(fmt)) + fmt
           + b"data" + struct.pack("<I", len(samples)) + samples)
    return wav, sample_rate, sample_count


def thing_coverage(map_data: dict[str, object]) -> list[dict[str, object]]:
    counts = Counter(thing["type"] for thing in map_data["things"])
    unknown = set(counts) - set(THING_SEMANTICS)
    absent = set(THING_SEMANTICS) - set(counts)
    if unknown or absent:
        raise ValueError(f"pinned E1M1 thing inventory changed: unknown={sorted(unknown)}, absent={sorted(absent)}")
    coverage = []
    for editor_type in sorted(counts):
        semantic, classification, status = THING_SEMANTICS[editor_type]
        if editor_type in {9, 58, 2035, 3001, 3002, 3004}:
            status = "implemented_actor"
        elif classification == "decorative":
            status = "implemented_decoration"
        elif classification == "gameplay":
            status = "implemented_pickup"
        coverage.append({"editor_type": editor_type, "count": counts[editor_type], "semantic_kind": semantic,
                         "classification": classification, "sprite_prefix": THING_SPRITES[editor_type],
                         "implementation_status": status})
    if sum(entry["count"] for entry in coverage) != 292:
        raise ValueError("pinned E1M1 no longer contains exactly 292 things")
    return coverage


def coverage_markdown(coverage: list[dict[str, object]]) -> str:
    lines = ["# Freedoom Phase 1 E1M1 thing coverage", "",
             "Generated by `scripts/doom_wad.py` from the pinned WAD. Do not edit by hand.", "",
             "| Editor type | Count | Semantic kind | Class | Sprite | Implementation status |",
             "|---:|---:|---|---|---|---|"]
    for entry in coverage:
        sprite = entry["sprite_prefix"] or "—"
        lines.append(f"| {entry['editor_type']} | {entry['count']} | {entry['semantic_kind']} | {entry['classification']} | {sprite} | `{entry['implementation_status']}` |")
    lines += ["", f"Total: **{sum(entry['count'] for entry in coverage)} things across {len(coverage)} editor types.**", ""]
    return "\n".join(lines)


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
    coverage = thing_coverage(map_data)
    prefixes.update(PRESENTATION_SPRITES)
    output.mkdir(parents=True, exist_ok=True)
    (output / "map.json").write_text(json.dumps(map_data, indent=2) + "\n")
    (output / "thing_coverage.json").write_text(json.dumps({"map": MAP_NAME, "thing_count": 292, "entries": coverage}, indent=2) + "\n")
    (output / "THING_COVERAGE.md").write_text(coverage_markdown(coverage))
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
    music_wav, music_requirements = render_midi(midi)
    (music_dir / "e1m1.wav").write_bytes(music_wav)
    sound_dir = output / "sounds"
    sound_dir.mkdir(exist_ok=True)
    for stale_sound in sound_dir.glob("*.wav"):
        stale_sound.unlink()
    sounds = []
    for logical_name, lump_name in sorted(GAMEPLAY_SOUNDS.items()):
        try:
            raw_sound = wad.last(lump_name)
        except KeyError as error:
            raise ValueError(f"required gameplay sound lump {lump_name} ({logical_name}) is missing") from error
        wav, sample_rate, sample_count = doom_sound_wav(raw_sound, lump_name)
        relative_path = f"sounds/{logical_name.replace('/', '_')}.wav"
        (output / relative_path).write_bytes(wav)
        sounds.append({"name": logical_name, "lump": lump_name, "path": relative_path,
                       "sample_rate": sample_rate, "sample_count": sample_count,
                       "source_sha256": digest(raw_sound), "wav_sha256": digest(wav)})
    stats = {key: len(map_data[key]) for key in ("vertices", "linedefs", "sidedefs", "sectors", "things", "segs", "subsectors", "nodes")}
    polygon_sizes = [len(polygon["points"]) for polygon in map_data["subsector_polygons"]]
    manifest = {"project": "Freedoom: Phase 1", "version": VERSION, "release_url": ZIP_URL,
                "release_zip_sha256": ZIP_SHA256, "wad_member": WAD_MEMBER, "wad_sha256": WAD_SHA256,
                "map": MAP_NAME, "map_stats": stats, "thing_type_counts": dict(sorted(Counter(t["type"] for t in map_data["things"]).items())),
                "thing_coverage_path": "thing_coverage.json", "thing_coverage_markdown_path": "THING_COVERAGE.md",
                "subsector_polygon_count": len(polygon_sizes),
                "subsector_polygon_point_count": sum(polygon_sizes),
                "subsector_polygon_min_points": min(polygon_sizes),
                "subsector_polygon_max_points": max(polygon_sizes),
                "texture_count": len(textures), "flat_count": len(flats), "sprite_prefixes": sorted(prefixes),
                "sprite_lump_count": len(sprites["entries"]),
                "presentation_sprite_prefixes": sorted(PRESENTATION_SPRITES),
                "hud_graphic_prefixes": list(HUD_GRAPHIC_PREFIXES),
                "hud_graphic_lump_count": sum(1 for entry in sprites["entries"] if entry["kind"] == "graphic"),
                "gameplay_sounds": sounds,
                "gameplay_sound_count": len(sounds),
                "music_lump": "D_E1M1",
                "music_path": "music/e1m1.mid", "music_sha256": digest(midi),
                "music_render_path": "music/e1m1.wav", "music_render_sha256": digest(music_wav),
                "music_requirements": music_requirements}
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
