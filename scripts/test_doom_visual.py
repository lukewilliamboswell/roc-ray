#!/usr/bin/env python3
"""Capture and validate representative native Libre Doom frames."""

from __future__ import annotations

import argparse
import hashlib
import struct
import subprocess
import sys
import zlib
from pathlib import Path


EXPECTED = ("start.png", "movement.png", "combat.png", "moving-door.png")


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
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = root / "examples" / "doom" / "evidence"
    output.mkdir(parents=True, exist_ok=True)
    for name in EXPECTED:
        (output / name).unlink(missing_ok=True)
    command = [str(root / "scripts" / "run-example.py"), str(root / "examples" / "doom" / "visual_evidence.roc")]
    if not args.build:
        command.append("--skip-platform-build")
    command.extend(["--platform-mode=source", "--", "--capture-evidence", "--host-hidden", f"--host-frames={args.frames}"])
    result = subprocess.run(command, cwd=root)
    if result.returncode != 0:
        return result.returncode
    hashes: set[str] = set()
    try:
        for name in EXPECTED:
            path = output / name
            if not path.is_file():
                raise RuntimeError(f"capture did not produce {name}")
            width, height, pixels = rgba_rows(path)
            if (width, height) != (320, 200):
                raise RuntimeError(f"{name} is {width}x{height}, expected 320x200")
            colors = {pixels[index : index + 4] for index in range(0, len(pixels), 4)}
            if len(colors) < 128:
                raise RuntimeError(f"{name} is effectively blank ({len(colors)} colors)")
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            hashes.add(digest)
            if name == "start.png":
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
            print(f"{name}: 320x200, {len(colors)} colors, sha256 {digest}")
        if len(hashes) != len(EXPECTED):
            raise RuntimeError("representative captures are not distinct")
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    finally:
        for name in EXPECTED:
            (output / name).unlink(missing_ok=True)
        try:
            output.rmdir()
        except OSError:
            pass
    print("Libre Doom native visual evidence passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
