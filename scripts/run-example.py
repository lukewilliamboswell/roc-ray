#!/usr/bin/env python3
"""Run a checked-in example against the local platform source."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path


LOCAL_PLATFORM_REF = '"../../platform/main.roc"'
RELEASE_PLATFORM_REF_RE = re.compile(
    r'"https://github\.com/lukewilliamboswell/roc-ray/releases/download/[^"]+\.tar\.zst"'
)


@contextmanager
def local_platform_ref(example: Path):
    original = example.read_text()
    rewritten, count = RELEASE_PLATFORM_REF_RE.subn(LOCAL_PLATFORM_REF, original)

    if count == 0:
        if LOCAL_PLATFORM_REF in original:
            yield
            return
        raise RuntimeError(f"{example} does not contain a recognized RocRay platform reference")

    example.write_text(rewritten)
    try:
        yield
    finally:
        example.write_text(original)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run a RocRay example against platform/main.roc"
    )
    parser.add_argument("example", type=Path, help="Example directory or entrypoint, e.g. examples/cave_climb")
    parser.add_argument(
        "--skip-platform-build",
        action="store_true",
        help="Reuse existing host libraries instead of running zig build first",
    )
    parser.add_argument(
        "app_args",
        nargs=argparse.REMAINDER,
        help="Arguments after -- are passed to the Roc application",
    )
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    example = args.example if args.example.is_absolute() else root / args.example
    example = example.resolve()

    if example.is_dir():
        example = example / "main.roc"

    if not example.is_file():
        parser.error(f"example does not exist: {example}")

    try:
        example.relative_to(root / "examples")
    except ValueError:
        parser.error(f"example must be inside {root / 'examples'}")

    if not args.skip_platform_build:
        build = subprocess.run(["zig", "build"], cwd=root)
        if build.returncode != 0:
            return build.returncode

    command = [os.environ.get("ROC", "roc"), str(example)]
    app_args = args.app_args
    if app_args and app_args[0] == "--":
        app_args = app_args[1:]
    if app_args:
        command.extend(["--", *app_args])

    try:
        with local_platform_ref(example):
            return subprocess.run(command, cwd=root).returncode
    except RuntimeError as err:
        print(f"error: {err}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
