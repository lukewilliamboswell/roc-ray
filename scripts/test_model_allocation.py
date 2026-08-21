#!/usr/bin/env python3
"""Measure what one frame costs a large collection held in the app's model.

The host consumes its model box on every `update_for_host` call and the platform
adapter boxes the returned model again. If nothing else referenced the old model
while `update` ran, writing to a list in it would be an in-place write and a
frame would cost nothing proportional to the list. It is not, and it does:
`test/model_inplace` writes one element of a one-million-`F32` list and the
frame allocates a whole new list, every frame.

That result is measured, not assumed, and this script is how it stays measured.
It builds the probe app, runs it headless under `ROC_RAY_ALLOC_STATS=1`, and
checks the steady-state per-frame numbers against what was observed:

    set     one full copy of the list per frame (4,000,000 bytes for 1M F32)
    append  a copy sized to the exact new length, so the per-frame cost grows
            by one element a frame -- growth is not amortized, because an
            amortized grow needs a uniquely referenced list and this is not one

Both assertions are two-sided on purpose. A frame that costs more than one copy
is a regression. A frame that costs less means somebody made the model's
collections unique again: that is the outcome everyone wants, and the fix for
this failure is to switch this check to `--require-in-place`, delete the
characterization numbers, and update the notes in `platform/main.roc` and
`platform/App.roc` that record the copying behaviour.

`--require-in-place` asserts the invariant that copying denies: steady-state
per-frame allocation under a small fixed budget. It is expected to FAIL today.
It is here so the goal is executable rather than described.

TODO: make `--require-in-place` the checked mode once the copy is gone. It is
not a platform bug to fix here. The host hands over its only box reference and
clears its own slot first, and the list's refcount at `update_for_host` entry
measures 1; it measures 3 by the time the copy is allocated, both increfs
coming from Roc-compiled code. `Box.unbox` is specified as retaining its result
and borrowing its argument, never consuming the box, so the box and the
unboxed model are both live while `update` runs and `List.set` takes its
copy-on-write path. The compiler can consume the box instead -- its `box_reuse`
rewrite does exactly that for a straight-line `unbox -> produce -> box -> ret`
-- but the adapter branches and runs effects between those points. Weighing
mutation points when choosing between a borrow and an owned move is named as
future work in the compiler's design notes.

Usage:
    scripts/test_model_allocation.py                # characterize (CI default)
    scripts/test_model_allocation.py --require-in-place   # the goal; fails today
    scripts/test_model_allocation.py --report       # print every pattern's cost
"""

import argparse
import os
import platform
import re
import statistics
import subprocess
import sys
from pathlib import Path

IS_WINDOWS = platform.system() == "Windows"

APP_DIR = Path("test") / "model_inplace"
APP_ENTRY = "main.roc"

# One element of the probe's list, and the list's length. Keep in sync with
# `point_count` in the probe app.
ELEMENT_BYTES = 4
POINT_COUNT = 1_000_000

# A frame that mutates in place still pays for the model box itself, which is
# under a hundred bytes. 16 KiB leaves room for that and for any small
# per-frame bookkeeping without leaving room for a copy of anything large.
IN_PLACE_BUDGET_BYTES = 16 * 1024

LINE_RE = re.compile(
    r"\[roc-ray-alloc\] cycle=(?P<cycle>\d+) "
    r"alloc_bytes=(?P<alloc_bytes>\d+) allocs=(?P<allocs>\d+) "
    r"frees=(?P<frees>\d+) free_bytes=(?P<free_bytes>\d+) "
    r"update_bytes=(?P<update_bytes>\d+) update_allocs=(?P<update_allocs>\d+)"
)

# Every pattern the probe app can run, with a one-line description used by
# --report. The first two are what an app would really write; the rest are the
# controls that pin down why those two cost what they do.
PATTERNS = {
    "set": "List.set one element of the model's list",
    "append": "grow a model list by one element a frame",
    "noop": "return the model untouched (the frame's floor)",
    "set_fallback": "as set, but the Err branch names model.points again",
    "set_twice": "two chained List.set calls on the model's list",
    "set_literal": "as set, rebuilding the record without ..model",
    "local_set": "List.set a list built inside update, never in the model",
    "local_boxed": "as local_set, through a Box round trip",
}


class MeasurementError(RuntimeError):
    """A run that could not be measured at all, as opposed to one that failed."""


def executable_path(root: Path) -> Path:
    suffix = ".exe" if IS_WINDOWS else ""
    return root / APP_DIR / f"main{suffix}"


def build_app(root: Path, verbose: bool) -> None:
    result = subprocess.run(
        ["roc", "build", APP_ENTRY],
        cwd=root / APP_DIR,
        capture_output=not verbose,
        text=True,
        shell=IS_WINDOWS,
    )
    if result.returncode != 0:
        if not verbose:
            sys.stdout.write(result.stdout or "")
            sys.stderr.write(result.stderr or "")
        raise MeasurementError(f"roc build {APP_DIR / APP_ENTRY} failed")


def measure(root: Path, pattern: str, frames: int, warmup: int) -> list[dict[str, int]]:
    """Run the probe headless and return one dict per steady-state frame."""
    binary = executable_path(root)
    if not binary.is_file():
        raise MeasurementError(f"missing {binary}; run without --skip-build")

    env = {
        **os.environ,
        "ROC_RAY_ALLOC_STATS": "1",
        "ROC_RAY_MODEL_PATTERN": pattern,
    }
    result = subprocess.run(
        [str(binary), "--host-headless", f"--host-headless-frames={frames}"],
        cwd=root,
        capture_output=True,
        text=True,
        env=env,
        # This is an explicit executable path, so no Windows shell lookup is
        # needed. Going through cmd.exe changes sequence-argument handling and
        # can prevent the host from receiving the headless probe flags.
        shell=False,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr or "")
        raise MeasurementError(f"{binary.name} ({pattern}) exited with {result.returncode}")

    rows = [
        {key: int(value) for key, value in match.groupdict().items()}
        for match in (LINE_RE.match(line.strip()) for line in result.stderr.splitlines())
        if match is not None
    ]
    if not rows:
        raise MeasurementError(
            f"no per-frame allocator lines for pattern {pattern}; "
            "is the host built from this working tree?"
        )
    steady = [row for row in rows if row["cycle"] >= warmup]
    if len(steady) < 8:
        raise MeasurementError(
            f"only {len(steady)} steady-state frame(s) for pattern {pattern}; "
            "raise --frames or lower --warmup"
        )
    return steady


def steady_update_bytes(rows: list[dict[str, int]]) -> int:
    return int(statistics.median(row["update_bytes"] for row in rows))


def check_set_copies_once(rows: list[dict[str, int]]) -> list[str]:
    """One copy of the list per frame: no more (regression), no less (fixed)."""
    measured = steady_update_bytes(rows)
    one_copy = POINT_COUNT * ELEMENT_BYTES
    if measured > one_copy * 3 // 2:
        return [
            f"set: {measured} bytes per frame is more than one copy of the list "
            f"({one_copy}); something now copies the model more than once a frame"
        ]
    if measured < one_copy // 2:
        return [
            f"set: {measured} bytes per frame is less than one copy of the list "
            f"({one_copy}). The model's collections may be unique again -- if so, "
            "rerun with --require-in-place, make that the checked contract, and "
            "update the notes in platform/main.roc and platform/App.roc"
        ]
    return []


def check_append_regrows_exactly(rows: list[dict[str, int]]) -> list[str]:
    """Appending copies into an exact-sized allocation, so cost grows linearly.

    An amortized grow would keep most frames flat and spike on a doubling. A
    per-frame rise of exactly one element is the copy-on-write path instead.
    """
    first, last = rows[0], rows[-1]
    span = last["cycle"] - first["cycle"]
    growth = last["update_bytes"] - first["update_bytes"]
    expected = span * ELEMENT_BYTES
    if growth != expected:
        return [
            f"append: cost grew {growth} bytes over {span} frames, expected "
            f"{expected} (one element a frame). Appending no longer reallocates "
            "to the exact new length every frame -- if growth is amortized now, "
            "this check needs rewriting around the new behaviour"
        ]
    return []


def check_in_place(rows: list[dict[str, int]], pattern: str) -> list[str]:
    measured = steady_update_bytes(rows)
    if measured > IN_PLACE_BUDGET_BYTES:
        return [
            f"{pattern}: {measured} bytes allocated per frame exceeds the "
            f"in-place budget of {IN_PLACE_BUDGET_BYTES} bytes"
        ]
    return []


def report(root: Path, frames: int, warmup: int) -> None:
    print(f"{'pattern':<14} {'bytes/frame':>12} {'allocs/frame':>13}  description")
    for pattern, description in PATTERNS.items():
        rows = measure(root, pattern, frames, warmup)
        allocs = statistics.median(row["update_allocs"] for row in rows)
        print(
            f"{pattern:<14} {steady_update_bytes(rows):>12} {allocs:>13.0f}  {description}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Measure the per-frame allocation cost of a collection in the model"
    )
    parser.add_argument("--frames", type=int, default=120, help="Frames to run (default: 120)")
    parser.add_argument(
        "--warmup",
        type=int,
        default=10,
        help="Leading frames excluded from the steady state (default: 10)",
    )
    parser.add_argument(
        "--skip-build", action="store_true", help="Reuse the probe executable already built"
    )
    parser.add_argument(
        "--require-in-place",
        action="store_true",
        help="Assert the invariant this repo does not currently hold: steady-state "
        f"per-frame allocation under {IN_PLACE_BUDGET_BYTES} bytes. Expected to FAIL.",
    )
    parser.add_argument("--report", action="store_true", help="Print every pattern's cost")
    parser.add_argument("--verbose", "-v", action="store_true", help="Show build output")
    args = parser.parse_args()

    if args.frames <= args.warmup:
        parser.error("--frames must exceed --warmup")

    root = Path(__file__).resolve().parent.parent

    try:
        if not args.skip_build:
            build_app(root, args.verbose)

        if args.report:
            report(root, args.frames, args.warmup)
            return 0

        set_rows = measure(root, "set", args.frames, args.warmup)
        append_rows = measure(root, "append", args.frames, args.warmup)
    except MeasurementError as err:
        print(f"error: {err}", file=sys.stderr)
        return 1

    set_bytes = steady_update_bytes(set_rows)
    append_bytes = steady_update_bytes(append_rows)
    print(
        f"steady-state update allocation: set={set_bytes} bytes/frame "
        f"({set_bytes / (POINT_COUNT * ELEMENT_BYTES):.2f} copies of the list), "
        f"append={append_bytes} bytes/frame"
    )

    if args.require_in_place:
        failures = check_in_place(set_rows, "set") + check_in_place(append_rows, "append")
    else:
        failures = check_set_copies_once(set_rows) + check_append_regrows_exactly(append_rows)
        # Always say where the invariant stands, so the gap between what is
        # checked and what is wanted never has to be rediscovered.
        outstanding = check_in_place(set_rows, "set")
        if outstanding:
            print(f"XFAIL (known, not a regression): {outstanding[0]}")

    for failure in failures:
        print(f"FAILED: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
