#!/usr/bin/env python3
"""Write the two files the sprite_and_sound example loads.

Both files are made from nothing but the numbers in this script, so they are
original to this repository and share its licence (UPL-1.0). No third-party
art or audio is involved. Re-run it from anywhere to recreate them:

    python3 examples/sprite_and_sound/assets/make_assets.py

- blob.png  a 16x16 pixel-art blob, drawn from the character grid below
- boing.wav a 0.25-second rising tone with a quick fade in and out,
            16-bit mono at 22050 Hz

It uses only the Python standard library.
"""

import math
import struct
import wave
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent

# One character per pixel. '.' is transparent.
BLOB = [
    "................",
    "................",
    "......####......",
    "....########....",
    "...##########...",
    "..############..",
    "..###ww##ww###..",
    ".####wk##wk####.",
    ".####wk##wk####.",
    ".##############.",
    ".##hh######hh##.",
    ".######mm######.",
    ".##############.",
    "..############..",
    "...##########...",
    "................",
]

PALETTE = {
    ".": (0, 0, 0, 0),
    "#": (64, 200, 140, 255),  # body
    "w": (255, 255, 255, 255),  # eye white
    "k": (20, 28, 40, 255),  # pupil
    "h": (255, 150, 170, 255),  # cheek
    "m": (20, 28, 40, 255),  # mouth
}


def write_png(path: Path, rows: list[str]) -> None:
    width, height = len(rows[0]), len(rows)
    raw = b"".join(
        b"\x00" + b"".join(bytes(PALETTE[c]) for c in row) for row in rows
    )

    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)  # 8-bit RGBA
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.write_bytes(png)


def write_wav(path: Path) -> None:
    rate = 22050
    seconds = 0.25
    count = int(rate * seconds)
    samples = []
    phase = 0.0
    for i in range(count):
        t = i / count
        freq = 220 + 440 * t  # slide from 220 Hz up to 660 Hz
        phase += 2 * math.pi * freq / rate
        envelope = min(1.0, i / 200) * (1 - t) ** 2  # quick fade in, slower fade out
        samples.append(int(0.6 * 32767 * envelope * math.sin(phase)))
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(struct.pack(f"<{count}h", *samples))


if __name__ == "__main__":
    write_png(HERE / "blob.png", BLOB)
    write_wav(HERE / "boing.wav")
