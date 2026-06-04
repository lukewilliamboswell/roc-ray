#!/usr/bin/env python3
"""
Run all tests for the roc-ray platform.

This script runs:
- zig build      - Build the native host libraries
- roc check      - Type check all examples
- roc fmt --check - Verify formatting
- roc test       - Run inline tests
- roc build      - Build executables

Usage:
    ./ci/all_tests.py              # Run all tests
    ./ci/all_tests.py --skip-build # Skip roc build
    ./ci/all_tests.py --verbose    # Show all output

TODO replace me with a Roc script when basic-cli is implemented
"""

import argparse
import os
import platform
import subprocess
import sys
from pathlib import Path

IS_WINDOWS = platform.system() == "Windows"


def run_cmd(
    cmd: list[str], desc: str, verbose: bool = False, env: dict | None = None, cwd: Path | None = None
) -> bool:
    """Run a command and return True if successful."""
    if verbose:
        print(f"  Running: {' '.join(cmd)}" + (f" (in {cwd})" if cwd else ""))

    merged_env = {**os.environ, **(env or {})}

    # On Windows, use shell=True so subprocess can find executables in PATH
    result = subprocess.run(
        cmd,
        capture_output=not verbose,
        text=True,
        env=merged_env,
        cwd=cwd,
        shell=IS_WINDOWS,
    )

    if result.returncode != 0:
        if not verbose:
            # Show output on failure
            if result.stdout:
                print(result.stdout)
            if result.stderr:
                print(result.stderr, file=sys.stderr)
        return False
    return True


def find_examples(examples_dir: Path) -> list[Path]:
    """Find all .roc files in examples directory."""
    return sorted(examples_dir.glob("*.roc"))


def main() -> int:
    parser = argparse.ArgumentParser(description="Run all roc-ray tests")
    parser.add_argument("--skip-build", action="store_true", help="Skip roc build")
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="Show all command output"
    )
    args = parser.parse_args()

    # Find project root (parent of ci/)
    root = Path(__file__).resolve().parent.parent
    examples_dir = root / "examples"

    examples = find_examples(examples_dir)
    if not examples:
        print("Error: No .roc files found in examples/")
        return 1

    print(f"Found {len(examples)} example(s): {', '.join(e.stem for e in examples)}")

    failed = []

    # Build platform (ensures fresh host, not cached)
    print("\nBuilding platform (zig build)...")
    if not run_cmd(["zig", "build"], "zig build", args.verbose, cwd=root):
        print("  FAILED")
        failed.append("zig build")
    else:
        print("  ok")

    # roc check
    print("\nRunning roc check...")
    for example in examples:
        print(f"  Checking {example.name}...", end=" ", flush=True)
        if run_cmd(["roc", "check", str(example)], f"check {example.name}", args.verbose):
            print("ok")
        else:
            print("FAILED")
            failed.append(f"roc check {example.name}")

    # roc fmt --check
    print("\nRunning roc fmt --check...")
    for example in examples:
        print(f"  Formatting {example.name}...", end=" ", flush=True)
        if run_cmd(
            ["roc", "fmt", "--check", str(example)], f"fmt {example.name}", args.verbose
        ):
            print("ok")
        else:
            print("FAILED")
            failed.append(f"roc fmt {example.name}")

    # roc test
    print("\nRunning roc test...")
    for example in examples:
        print(f"  Testing {example.name}...", end=" ", flush=True)
        if run_cmd(["roc", "test", str(example)], f"test {example.name}", args.verbose):
            print("ok")
        else:
            print("FAILED")
            failed.append(f"roc test {example.name}")

    # roc build (run from examples dir so executables are created there)
    if args.skip_build:
        print("\nSkipping roc build (--skip-build)")
    else:
        print("\nRunning roc build...")
        for example in examples:
            print(f"  Building {example.name}...", end=" ", flush=True)
            if run_cmd(
                ["roc", "build", example.name], f"build {example.name}", args.verbose, cwd=examples_dir
            ):
                print("ok")
            else:
                print("FAILED")
                failed.append(f"roc build {example.name}")

    # Summary
    print("\n" + "=" * 50)
    if failed:
        print(f"FAILED: {len(failed)} test(s)")
        for f in failed:
            print(f"  - {f}")
        return 1
    else:
        print("All tests passed!")
        return 0


if __name__ == "__main__":
    sys.exit(main())
