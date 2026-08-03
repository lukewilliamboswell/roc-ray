#!/usr/bin/env python3
"""Measure steady-state Roc allocations in headless example applications.

The profiler uses non-stopping GDB breakpoints on the Roc allocation ABI. It
runs each example for one frame and again for N frames, then subtracts the
one-frame result so startup allocations do not pollute the per-frame numbers.

This measures calls made through roc_alloc/roc_realloc/roc_dealloc. It does not
include allocations made internally by raylib or Zig's allocator.
"""

import argparse
import json
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


MARKER = "ROC_ALLOC_STATS "


def find_examples(root: Path, requested: list[str]) -> list[Path]:
    examples_dir = root / "examples"
    if not requested:
        return sorted(examples_dir.glob("*.roc"))

    examples: list[Path] = []
    for name in requested:
        stem = Path(name).stem
        example = examples_dir / f"{stem}.roc"
        if not example.is_file():
            raise ValueError(f"unknown example: {name}")
        examples.append(example)
    return examples


def gdb_commands(frames: int) -> str:
    return f"""\
set pagination off
set debuginfod enabled off
python
import json

stats = {{
    "alloc_calls": 0,
    "alloc_bytes": 0,
    "realloc_calls": 0,
    "dealloc_calls": 0,
    "unreadable_alloc_sizes": 0,
    "exit_code": None,
}}

class CountBreakpoint(gdb.Breakpoint):
    def __init__(self, symbol, counter, size_expression=None):
        super().__init__(symbol, internal=True)
        self.counter = counter
        self.size_expression = size_expression

    def stop(self):
        stats[self.counter] += 1
        if self.size_expression is not None:
            try:
                stats["alloc_bytes"] += int(gdb.parse_and_eval(self.size_expression))
            except gdb.error:
                stats["unreadable_alloc_sizes"] += 1
        return False

def record_exit(event):
    stats["exit_code"] = getattr(event, "exit_code", None)

CountBreakpoint("roc_alloc", "alloc_calls", "length")
CountBreakpoint("roc_realloc", "realloc_calls")
CountBreakpoint("roc_dealloc", "dealloc_calls")
gdb.events.exited.connect(record_exit)
end
run --headless --headless-frames={frames}
python print("{MARKER}" + json.dumps(stats, sort_keys=True))
"""


def profile_run(root: Path, binary: Path, frames: int) -> dict[str, int | None]:
    with tempfile.NamedTemporaryFile("w", suffix=".gdb", encoding="utf-8") as command_file:
        command_file.write(gdb_commands(frames))
        command_file.flush()
        result = subprocess.run(
            ["gdb", "-q", "-batch", "-x", command_file.name, "--args", str(binary)],
            cwd=root,
            capture_output=True,
            text=True,
        )

    for line in reversed(result.stdout.splitlines()):
        if line.startswith(MARKER):
            stats = json.loads(line[len(MARKER) :])
            if stats["exit_code"] != 0:
                raise RuntimeError(f"{binary.name} exited with code {stats['exit_code']}")
            if stats["unreadable_alloc_sizes"] != 0:
                raise RuntimeError(
                    f"could not read {stats['unreadable_alloc_sizes']} allocation sizes "
                    f"while profiling {binary.name}"
                )
            return stats

    detail = result.stderr.strip() or result.stdout.strip() or "no GDB output"
    raise RuntimeError(f"GDB did not produce allocation stats for {binary.name}:\n{detail}")


def subtract_startup(
    one_frame: dict[str, int | None], many_frames: dict[str, int | None], frames: int
) -> dict[str, float | int]:
    measured_frames = frames - 1
    result: dict[str, float | int] = {"measured_frames": measured_frames}
    for key in ("alloc_calls", "alloc_bytes", "realloc_calls", "dealloc_calls"):
        delta = int(many_frames[key]) - int(one_frame[key])
        result[key] = delta
        result[f"{key}_per_frame"] = delta / measured_frames
    return result


def build_examples(root: Path) -> None:
    result = subprocess.run(
        [
            str(root / "scripts" / "all_tests.py"),
            "--runtime-only",
            "--headless-frames=1",
        ],
        cwd=root,
    )
    if result.returncode != 0:
        raise RuntimeError("failed to build examples")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Measure steady-state Roc allocation traffic in example render loops"
    )
    parser.add_argument("examples", nargs="*", help="Example names; defaults to all examples")
    parser.add_argument(
        "--frames",
        type=int,
        default=120,
        help="Long-run frame count used to subtract startup (default: 120)",
    )
    parser.add_argument(
        "--build",
        action="store_true",
        help="Build every example against the local platform before profiling",
    )
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON")
    args = parser.parse_args()

    if args.frames < 2:
        parser.error("--frames must be at least 2")
    if platform.system() != "Linux":
        parser.error("allocation profiling currently requires Linux")
    if shutil.which("gdb") is None:
        parser.error("allocation profiling requires gdb on PATH")

    root = Path(__file__).resolve().parent.parent
    try:
        examples = find_examples(root, args.examples)
        if args.build:
            build_examples(root)

        rows = []
        for example in examples:
            binary = example.with_suffix("")
            if not binary.is_file():
                raise RuntimeError(f"missing {binary}; rerun with --build")
            one_frame = profile_run(root, binary, 1)
            many_frames = profile_run(root, binary, args.frames)
            steady = subtract_startup(one_frame, many_frames, args.frames)
            rows.append(
                {
                    "example": example.stem,
                    "one_frame": one_frame,
                    "many_frames": many_frames,
                    "steady_state": steady,
                }
            )
    except (RuntimeError, ValueError) as err:
        print(f"error: {err}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps({"frames": args.frames, "examples": rows}, indent=2, sort_keys=True))
        return 0

    print(
        f"Steady-state Roc allocation traffic "
        f"(startup subtracted; {args.frames - 1} measured frames)"
    )
    print(f"{'example':<16} {'allocs/frame':>12} {'bytes/frame':>12} {'reallocs/frame':>15}")
    for row in rows:
        steady = row["steady_state"]
        print(
            f"{row['example']:<16} "
            f"{steady['alloc_calls_per_frame']:>12.3f} "
            f"{steady['alloc_bytes_per_frame']:>12.1f} "
            f"{steady['realloc_calls_per_frame']:>15.3f}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
