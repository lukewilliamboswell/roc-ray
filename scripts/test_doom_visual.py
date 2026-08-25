#!/usr/bin/env python3
"""Capture representative native Libre Doom frames and a shareable WebM."""

from __future__ import annotations

import argparse
import json
import math
import shutil
import struct
import subprocess
import sys
import zlib
from pathlib import Path


FAST_CHECKPOINTS = (
    "spawn", "strafe-left", "strafe-right", "mouse-turn",
    "west-sky-portal", "first-corridor-wall-hole", "open-portal-collision", "colu-portal-navigation",
    "door-closed", "door-open", "combat",
)


def rgba_rows(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise RuntimeError(f"{path.name} is not a PNG")
    offset = 8
    chunks: list[bytes] = []
    width = height = 0
    while offset < len(data):
        length = int.from_bytes(data[offset : offset + 4], "big")
        kind = data[offset + 4 : offset + 8]
        payload = data[offset + 8 : offset + 8 + length]
        offset += 12 + length
        if kind == b"IHDR":
            width, height, depth, color, _compression, _filter, interlace = struct.unpack(">IIBBBBB", payload)
            if (depth, color, interlace) != (8, 6, 0):
                raise RuntimeError(f"{path.name} is not non-interlaced RGBA8")
        elif kind == b"IDAT":
            chunks.append(payload)
        elif kind == b"IEND":
            break
    raw = zlib.decompress(b"".join(chunks))
    stride = width * 4
    previous = bytearray(stride)
    pixels = bytearray()
    cursor = 0
    for _ in range(height):
        filter_kind = raw[cursor]
        encoded = raw[cursor + 1 : cursor + 1 + stride]
        cursor += stride + 1
        row = bytearray(stride)
        for index, value in enumerate(encoded):
            left = row[index - 4] if index >= 4 else 0
            up = previous[index]
            upper_left = previous[index - 4] if index >= 4 else 0
            if filter_kind == 0:
                predictor = 0
            elif filter_kind == 1:
                predictor = left
            elif filter_kind == 2:
                predictor = up
            elif filter_kind == 3:
                predictor = (left + up) // 2
            elif filter_kind == 4:
                estimate = left + up - upper_left
                dl, du, dul = abs(estimate - left), abs(estimate - up), abs(estimate - upper_left)
                predictor = left if dl <= du and dl <= dul else up if du <= dul else upper_left
            else:
                raise RuntimeError(f"{path.name} has unknown PNG filter {filter_kind}")
            row[index] = (value + predictor) & 0xFF
        pixels.extend(row)
        previous = row
    return width, height, bytes(pixels)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true", help="rebuild native platform libraries first")
    parser.add_argument("--frames", type=int, default=1000, help="native host-cycle safety cap")
    parser.add_argument("--long", action="store_true", help="also follow the optional damaging-floor route")
    parser.add_argument("--keep", action="store_true", help="retain PNG review artifacts after success (the WebM is always retained)")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = root / "examples" / "doom" / "evidence"
    output.mkdir(parents=True, exist_ok=True)
    checkpoints = FAST_CHECKPOINTS + (("damaging-floor",) if args.long else ())
    video = output / ("doom-scripted-long.webm" if args.long else "doom-scripted-fast.webm")
    video.unlink(missing_ok=True)
    for checkpoint in checkpoints:
        (output / f"{checkpoint}.png").unlink(missing_ok=True)
    command = [str(root / "scripts" / "run-example.py"), str(root / "examples" / "doom" / "visual_evidence.roc")]
    if not args.build:
        command.append("--skip-platform-build")
    app_args = ["--capture-evidence"]
    if args.long:
        app_args.append("--long-evidence")
    command.extend(["--platform-mode=source", "--", *app_args, "--host-hidden", f"--host-frames={args.frames}"])
    result = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout, end="")
    if result.returncode != 0:
        return result.returncode
    records = {}
    for line in result.stdout.splitlines():
        if line.startswith('{"checkpoint"'):
            record = json.loads(line)
            records[record["checkpoint"]] = record
    try:
        if tuple(records) != checkpoints:
            raise RuntimeError(f"state checkpoints differ: got {tuple(records)}, expected {checkpoints}")
        if not video.is_file() or video.stat().st_size < 1024:
            raise RuntimeError(f"recording was not finalized: {video}")
        if video.read_bytes()[:4] != b"\x1a\x45\xdf\xa3":
            raise RuntimeError(f"{video.name} has no WebM/EBML signature")
        ffprobe = shutil.which("ffprobe")
        if ffprobe:
            probe = subprocess.run(
                [ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,width,height", "-of", "json", str(video)],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            if probe.returncode != 0:
                raise RuntimeError(f"ffprobe rejected {video.name}: {probe.stderr.strip()}")
            stream = json.loads(probe.stdout).get("streams", [{}])[0]
            if stream.get("codec_name") != "vp8" or (stream.get("width"), stream.get("height")) != (320, 200):
                raise RuntimeError(f"unexpected video stream: {stream}")
        for checkpoint in checkpoints:
            name = f"{checkpoint}.png"
            path = output / name
            if not path.is_file():
                raise RuntimeError(f"capture did not produce {name}")
            width, height, pixels = rgba_rows(path)
            if (width, height) != (320, 200):
                raise RuntimeError(f"{name} is {width}x{height}, expected 320x200")
            colors = {pixels[index : index + 4] for index in range(0, len(pixels), 4)}
            if len(colors) < 64:
                raise RuntimeError(f"{name} is effectively blank ({len(colors)} colors)")
            record = records[checkpoint]
            if record["ceiling"] <= record["floor"] or not (0 < record["health"] <= 100):
                raise RuntimeError(f"{checkpoint} has invalid sector/player state: {record}")
            if not isinstance(record["blocking_linedef"], int):
                raise RuntimeError(f"{checkpoint} has no typed blocking-linedef state")
            if checkpoint == "spawn" and (record["sector"], record["floor"], record["ceiling"], record["health"]) != (140, 0, 128, 100):
                raise RuntimeError(f"spawn oracle changed: {record}")
            if checkpoint == "spawn":
                # Keep the floor visible on both sides of the centred weapon.
                # This caught wrapped flat UVs interpolating through the atlas's
                # unused black area at the BSP seam under the player start.
                floor_pixels = []
                for y in range(128, 160):
                    for x in (*range(0, 116), *range(204, width)):
                        offset = (y * width + x) * 4
                        floor_pixels.append(pixels[offset : offset + 3])
                visible = sum(1 for pixel in floor_pixels if sum(pixel) > 24)
                if visible * 4 < len(floor_pixels):
                    raise RuntimeError(f"start floor is mostly clear-color black ({visible}/{len(floor_pixels)} visible pixels)")
            print(f"{name}: 320x200, {len(colors)} colors")
        spawn = records["spawn"]
        facing_right_x = -math.sin(spawn["angle"] * 2 * math.pi)
        facing_right_y = math.cos(spawn["angle"] * 2 * math.pi)

        def lateral(record):
            return (record["x"] - spawn["x"]) * facing_right_x + (record["y"] - spawn["y"]) * facing_right_y
        if lateral(records["strafe-left"]) >= 0 or lateral(records["strafe-right"]) <= 0:
            raise RuntimeError("virtual A/D evidence has reversed lateral signs")
        if records["mouse-turn"]["angle"] == spawn["angle"]:
            raise RuntimeError("virtual mouse evidence did not turn the player")
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    else:
        if not args.keep:
            for checkpoint in checkpoints:
                (output / f"{checkpoint}.png").unlink(missing_ok=True)
        print(f"{video.name}: {video.stat().st_size} bytes, finalized VP8/WebM")
    print("Libre Doom native visual evidence passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
