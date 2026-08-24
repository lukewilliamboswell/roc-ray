#!/usr/bin/env python3
"""Enforce bounded per-cycle allocation for the native Doom vertical slice."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

LINE = re.compile(r"\[roc-ray-alloc\] cycle=(\d+) alloc_bytes=(\d+).+update_bytes=(\d+)")
MAX_CYCLE_BYTES = 28 * 1024 * 1024
AVERAGE_CYCLE_BYTES = 16 * 1024 * 1024
IDLE_UPDATE_BYTES = 1024 * 1024
MIN_CYCLES_PER_SECOND = 30.0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frames", type=int, default=120)
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    binary = root / "examples" / "doom" / "main"
    if not args.skip_build:
        build = subprocess.run(
            [str(root / "scripts" / "run-example.py"), "examples/doom/main.roc", "--skip-platform-build", "--platform-mode=source", "--", "--host-headless", "--host-headless-frames=1"],
            cwd=root,
        )
        if build.returncode != 0:
            return build.returncode
    env = {**os.environ, "ROC_RAY_ALLOC_STATS": "1"}
    started = time.monotonic()
    result = subprocess.run(
        [str(binary), "--host-headless", f"--host-headless-frames={args.frames}"],
        cwd=root,
        env=env,
        capture_output=True,
        text=True,
    )
    elapsed = time.monotonic() - started
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        return result.returncode
    rows = [(int(cycle), int(total), int(update)) for cycle, total, update in LINE.findall(result.stderr)]
    if len(rows) != args.frames:
        print(f"error: measured {len(rows)} cycles, expected {args.frames}", file=sys.stderr)
        return 1
    maximum = max(total for _, total, _ in rows)
    idle = min(update for _, _, update in rows[2:])
    average = sum(total for _, total, _ in rows) // len(rows)
    rate = len(rows) / elapsed
    print(f"Doom native: {rate:.1f} cycles/s, max={maximum} B, average={average} B, idle-update={idle} B")
    if maximum > MAX_CYCLE_BYTES:
        print(f"error: cycle exceeds {MAX_CYCLE_BYTES} byte bound", file=sys.stderr)
        return 1
    if average > AVERAGE_CYCLE_BYTES:
        print(f"error: average exceeds {AVERAGE_CYCLE_BYTES} byte bound", file=sys.stderr)
        return 1
    if idle > IDLE_UPDATE_BYTES:
        print(f"error: retained idle update exceeds {IDLE_UPDATE_BYTES} byte bound", file=sys.stderr)
        return 1
    if rate < MIN_CYCLES_PER_SECOND:
        print(f"error: {rate:.1f} cycles/s is below {MIN_CYCLES_PER_SECOND:.1f} headless floor", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
