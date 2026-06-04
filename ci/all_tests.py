#!/usr/bin/env python3
"""
Run all tests for the roc-ray platform.

This script runs:
- zig build      - Build the native host libraries
- roc check      - Type check all examples
- roc fmt --check - Verify formatting
- roc test       - Run inline tests
- roc build      - Build executables
- bundle test    - Bundle the platform, host it on localhost, build apps from the URL

Usage:
    ./ci/all_tests.py                   # Run all tests
    ./ci/all_tests.py --skip-build      # Skip roc build
    ./ci/all_tests.py --skip-bundle-test # Skip the bundle test
    ./ci/all_tests.py --verbose         # Show all output

TODO replace me with a Roc script when basic-cli is implemented
"""

import argparse
import functools
import http.server
import os
import platform
import subprocess
import sys
import threading
from pathlib import Path

IS_WINDOWS = platform.system() == "Windows"

# The platform reference each example uses for local builds. The bundle test
# temporarily rewrites this to the localhost bundle URL.
LOCAL_PLATFORM_REF = '"../platform/main.roc"'

# Examples to skip in the bundled-platform build test, mapping filename -> reason.
# Use this when a specific example can't build against the bundled platform yet
# (e.g. a known upstream issue); it is reported as SKIPPED, not FAILED. All
# examples currently build from the bundle, so this is empty.
#   e.g. "kitchen_sink.roc": "blocked on roc-lang/roc#NNNN (record-update lowering)"
BUNDLE_TEST_SKIP: dict[str, str] = {}


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


def _serve_dir(directory: Path, verbose: bool) -> tuple[http.server.ThreadingHTTPServer, int]:
    """Start a background HTTP server rooted at `directory`. Returns (server, port)."""

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):  # silence per-request logging
            if verbose:
                super().log_message(*args)

    handler = functools.partial(Handler, directory=str(directory))
    # Port 0 -> OS picks a free ephemeral port.
    httpd = http.server.ThreadingHTTPServer(("localhost", 0), handler)
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, port


def run_bundle_test(root: Path, examples: list[Path], verbose: bool) -> list[str]:
    """Bundle the platform, host it on localhost, and build each example against
    that bundle URL (mirrors the template's release check). Returns failures.

    Steps: `./bundle.sh` -> HTTP server on localhost -> rewrite each example's
    platform reference to the bundle URL -> `roc build`. Examples listed in
    BUNDLE_TEST_SKIP are reported as skipped, not failed.
    """
    examples_dir = root / "examples"
    failed: list[str] = []

    print("\nRunning bundle test (build platform package, host locally, build apps from URL)...")

    # bundle.sh is a bash script; on Windows (without bash) skip the whole step.
    bundle_proc = subprocess.run(
        ["bash", "bundle.sh"], capture_output=True, text=True, cwd=root
    )
    if bundle_proc.returncode != 0:
        print(bundle_proc.stdout)
        print(bundle_proc.stderr, file=sys.stderr)
        print("  bundle.sh FAILED")
        return ["bundle.sh"]

    # bundle.sh prints "Created: /abs/path/<hash>.tar.zst"
    bundle_name = None
    for line in bundle_proc.stdout.splitlines():
        if line.startswith("Created:"):
            bundle_name = Path(line.split(maxsplit=1)[1].strip()).name
            break
    if not bundle_name:
        print(bundle_proc.stdout)
        print("  Could not determine bundle filename from bundle.sh output")
        return ["bundle.sh (no Created: line)"]

    bundle_path = root / bundle_name
    print(f"  Bundled platform: {bundle_name}")

    httpd, port = _serve_dir(root, verbose)
    url = f'"http://localhost:{port}/{bundle_name}"'
    try:
        for example in examples:
            if example.name in BUNDLE_TEST_SKIP:
                print(f"  Building {example.name} (URL)... SKIPPED ({BUNDLE_TEST_SKIP[example.name]})")
                continue

            print(f"  Building {example.name} (URL)...", end=" ", flush=True)
            original = example.read_text()
            if LOCAL_PLATFORM_REF not in original:
                print(f"SKIPPED (no {LOCAL_PLATFORM_REF} to rewrite)")
                continue

            example.write_text(original.replace(LOCAL_PLATFORM_REF, url))
            try:
                ok = run_cmd(
                    ["roc", "build", example.name],
                    f"bundle build {example.name}",
                    verbose,
                    cwd=examples_dir,
                )
            finally:
                example.write_text(original)  # always restore the local platform ref

            if ok:
                print("ok")
            else:
                print("FAILED")
                failed.append(f"bundle build {example.name}")
    finally:
        httpd.shutdown()
        bundle_path.unlink(missing_ok=True)

    return failed


def main() -> int:
    parser = argparse.ArgumentParser(description="Run all roc-ray tests")
    parser.add_argument("--skip-build", action="store_true", help="Skip roc build")
    parser.add_argument(
        "--skip-bundle-test",
        action="store_true",
        help="Skip the bundle test (build platform package, host locally, build apps from URL)",
    )
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

    # Bundle test: build the platform package, host it on localhost, and build
    # each example against the bundle URL (mirrors the platform-template check).
    if args.skip_bundle_test:
        print("\nSkipping bundle test (--skip-bundle-test)")
    elif IS_WINDOWS:
        print("\nSkipping bundle test (requires bash for bundle.sh; not run on Windows)")
    else:
        failed.extend(run_bundle_test(root, examples, args.verbose))

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
