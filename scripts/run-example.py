#!/usr/bin/env python3
"""Run a checked-in example against the local platform source.

The example is *copied* to a scratch directory with its header pointed at the
locally served packages, so the checked-in files are never rewritten and an
interrupted run cannot leave a stale platform reference behind. See
scripts/local_bundles.py for why the packages are served over localhost rather
than referenced by path.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import local_bundles  # noqa: E402  (needs the sys.path entry above)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run a RocRay example against platform/main.roc"
    )
    parser.add_argument(
        "example", type=Path, help="Example directory or entrypoint, e.g. examples/cave_climb"
    )
    parser.add_argument(
        "--skip-platform-build",
        action="store_true",
        help="Reuse existing host libraries instead of running zig build first",
    )
    parser.add_argument(
        "--platform-mode",
        choices=["auto", "bundle", "source"],
        default="source",
        help=(
            "How the example reaches the platform. 'source' (default) serves only "
            "the types package and builds against a staged copy of platform/, which "
            "is what you want while editing the platform. 'bundle' serves a platform "
            "bundle instead, matching a release"
        ),
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

    warning = local_bundles.check_roc_pin(root)
    if warning:
        print(warning, file=sys.stderr)

    if not args.skip_platform_build:
        build = subprocess.run(["zig", "build"], cwd=root)
        if build.returncode != 0:
            return build.returncode

    app_args = args.app_args
    if app_args and app_args[0] == "--":
        app_args = app_args[1:]

    roc = os.environ.get("ROC", "roc")
    try:
        with local_bundles.terminating_signals(), local_bundles.serve_packages(
            root, mode=args.platform_mode, roc=roc
        ) as packages:
            for note in packages.notes:
                print(f"note: {note}", file=sys.stderr)
            staged = local_bundles.stage_app(
                example, packages, packages.scratch_dir / example.parent.name
            )

            command = [roc, str(staged), *local_bundles.PACKAGE_LIMIT_ARGS]
            if app_args:
                command.extend(["--", *app_args])
            # Run from the repository root: the examples load their assets from
            # `examples/<name>/assets/...` relative to the working directory.
            return subprocess.run(command, cwd=root).returncode
    except local_bundles.LocalBundleError as err:
        print(f"error: {err}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
