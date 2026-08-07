#!/usr/bin/env python3
"""
Run all tests for the roc-ray platform.

Source checks temporarily point checked-in examples at platform/main.roc,
then restore their release URLs. Roc is always resolved from PATH.

This script runs:
- zig build      - Build the native host libraries
- roc check      - Type check all examples
- roc fmt --check - Verify formatting
- roc test       - Run inline tests
- roc build      - Build executables
- bundle test    - Bundle the platform, host it on localhost, build apps from the URL

Usage:
    ./scripts/all_tests.py                   # Run all tests
    ./scripts/all_tests.py --skip-platform-build # Reuse existing host libraries
    ./scripts/all_tests.py --skip-roc-build  # Skip roc build
    ./scripts/all_tests.py --skip-runtime    # Skip running built examples
    ./scripts/all_tests.py --skip-roc-test   # Skip roc test
    ./scripts/all_tests.py --runtime-only    # Only build and run examples headlessly
    ./scripts/all_tests.py --skip-bundle-test # Skip the bundle test
    ./scripts/all_tests.py --verbose         # Show all output

TODO replace me with a Roc script when basic-cli is implemented
"""

import argparse
import functools
import http.server
import io
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import threading
import time
import urllib.request
from contextlib import contextmanager
from pathlib import Path

IS_WINDOWS = platform.system() == "Windows"
IS_LINUX = platform.system() == "Linux"

# Platform references used by examples. Bundle tests temporarily rewrite one of
# these to the localhost bundle URL.
LOCAL_PLATFORM_REF = '"../platform/main.roc"'
RELEASE_PLATFORM_REF_RE = re.compile(
    r'"https://github\.com/lukewilliamboswell/roc-ray/releases/download/[^"]+\.tar\.zst"'
)

# Examples to skip in the bundled-platform build test, mapping filename -> reason.
# Use this when a specific example can't build against the bundled platform yet
# (e.g. a known upstream issue); it is reported as SKIPPED, not FAILED.
#   e.g. "example.roc": "blocked on roc-lang/roc#NNNN (record-update lowering)"
BUNDLE_TEST_SKIP: dict[str, str] = {}

# Examples to skip in native `roc build` / headless runtime checks.
# Keep these explicit so CI still exercises every example that currently
# compiles, without hiding unrelated build/runtime failures.
BUILD_RUNTIME_SKIP: dict[str, str] = {}


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


def executable_for_example(root: Path, example: Path) -> Path:
    """Return the executable path produced by `roc build examples/<name>.roc`."""
    suffix = ".exe" if IS_WINDOWS else ""
    return root / "examples" / f"{example.stem}{suffix}"


def run_headless_examples(
    root: Path, examples: list[Path], frames: int, verbose: bool
) -> list[str]:
    """Run each already-built example executable in bounded headless mode."""
    failed: list[str] = []

    print(f"\nRunning built examples headlessly ({frames} frame(s))...")
    for example in examples:
        executable = executable_for_example(root, example)
        print(f"  Running {example.stem}...", end=" ", flush=True)
        if not executable.is_file():
            print("FAILED (missing executable)")
            failed.append(f"headless run {example.name} (missing executable)")
            continue

        ok = run_cmd(
            [
                str(executable),
                "--headless",
                f"--headless-frames={frames}",
            ],
            f"headless run {example.name}",
            verbose,
            cwd=root,
        )
        if ok:
            print("ok")
        else:
            print("FAILED")
            failed.append(f"headless run {example.name}")

    return failed


def _serve_dir(directory: Path, verbose: bool) -> tuple[http.server.ThreadingHTTPServer, int]:
    """Start a background HTTP server rooted at `directory`. Returns (server, port)."""

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):  # silence per-request logging
            if verbose:
                super().log_message(*args)

    handler = functools.partial(Handler, directory=str(directory))
    # Port 0 -> OS picks a free ephemeral port.
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, port


def _wait_for_url(url: str) -> bool:
    """Return True once a local test URL is reachable."""
    last_error: Exception | None = None
    request = urllib.request.Request(url, method="HEAD")
    for _ in range(10):
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                if response.status == 200:
                    return True
                last_error = RuntimeError(f"HTTP {response.status}")
        except Exception as err:
            last_error = err
            time.sleep(0.5)

    print(f"  Bundle URL was not accessible: {url}")
    if last_error is not None:
        print(f"  Last error: {last_error}")
    return False


def _bundle_name_from_output(output: str) -> str | None:
    """Extract the generated bundle filename from bundle.sh output."""
    for line in output.splitlines():
        if line.startswith("Created:"):
            return Path(line.split(maxsplit=1)[1].strip()).name
    return None


def _types_bundle_name_from_output(output: str) -> str | None:
    """Extract the roc-ray-types bundle filename from bundle.sh output."""
    for line in output.splitlines():
        if line.startswith("Types package bundle:"):
            return line.split(":", 1)[1].strip()
    return None


def _rewrite_platform_ref(source: str, replacement: str) -> tuple[str, bool]:
    """Rewrite an example's recognized local or release platform reference."""
    if LOCAL_PLATFORM_REF in source:
        return source.replace(LOCAL_PLATFORM_REF, replacement), True

    rewritten, count = RELEASE_PLATFORM_REF_RE.subn(replacement, source)
    return rewritten, count > 0


@contextmanager
def _temporary_platform_refs(examples: list[Path], replacement: str):
    """Temporarily rewrite example platform references and always restore them."""
    originals: dict[Path, str] = {}
    try:
        for example in examples:
            original = example.read_text()
            rewritten, did_rewrite = _rewrite_platform_ref(original, replacement)
            if did_rewrite and rewritten != original:
                originals[example] = original
                example.write_text(rewritten)
        yield len(originals)
    finally:
        for example, original in originals.items():
            example.write_text(original)


def _read_tar_zst(bundle_path: Path) -> tarfile.TarFile:
    """Read a .tar.zst Roc bundle into a TarFile for content assertions."""
    zstd = shutil.which("zstd")
    if zstd is None:
        raise RuntimeError("zstd executable not found; cannot inspect bundle contents")

    zstd_proc = subprocess.run(
        [zstd, "-dc", str(bundle_path)],
        capture_output=True,
    )
    if zstd_proc.returncode != 0:
        stderr = zstd_proc.stderr.decode(errors="replace")
        raise RuntimeError(f"failed to decompress {bundle_path.name}: {stderr}")

    return tarfile.open(fileobj=io.BytesIO(zstd_proc.stdout), mode="r:")


def run_bundle_test(root: Path, examples: list[Path], verbose: bool) -> list[str]:
    """Bundle the platform, host it on localhost, and build each example against
    that bundle URL (mirrors the template's release check). Returns failures.

    Steps: `scripts/bundle.sh` -> HTTP server on localhost -> rewrite each example's
    platform reference to the bundle URL -> `roc build`. Examples listed in
    BUNDLE_TEST_SKIP are reported as skipped, not failed.
    """
    examples_dir = root / "examples"
    failed: list[str] = []

    print("\nRunning bundle test (build platform package, host locally, build apps from URL)...")

    # The platform depends on the roc-ray-types package by relative path, which
    # cannot survive bundling, so bundle.sh needs the URL the package bundle
    # will be served from. Start the server first so that URL is known, then
    # bundle both into the directory it is already serving.
    httpd, port = _serve_dir(root, verbose)
    base_url = f"http://127.0.0.1:{port}"
    bundle_path: Path | None = None
    types_path: Path | None = None
    try:
        # bundle.sh is a bash script; on Windows (without bash) skip the whole step.
        bundle_proc = subprocess.run(
            ["bash", "scripts/bundle.sh", "--types-url-base", base_url],
            capture_output=True,
            text=True,
            cwd=root,
        )
        if bundle_proc.returncode != 0:
            print(bundle_proc.stdout)
            print(bundle_proc.stderr, file=sys.stderr)
            print("  bundle.sh FAILED")
            return ["bundle.sh"]

        # bundle.sh prints "Created: /abs/path/<hash>.tar.zst"
        bundle_name = _bundle_name_from_output(bundle_proc.stdout)
        if not bundle_name:
            print(bundle_proc.stdout)
            print("  Could not determine bundle filename from bundle.sh output")
            return ["bundle.sh (no Created: line)"]

        bundle_path = root / bundle_name
        types_name = _types_bundle_name_from_output(bundle_proc.stdout)
        if types_name:
            types_path = root / types_name
            print(f"  Bundled roc-ray-types: {types_name}")
        print(f"  Bundled platform: {bundle_name}")

        bundle_url = f"{base_url}/{bundle_name}"
        url = f'"{bundle_url}"'
        if not _wait_for_url(bundle_url):
            return ["bundle URL unavailable"]

        for example in examples:
            if example.name in BUNDLE_TEST_SKIP:
                print(f"  Building {example.name} (URL)... SKIPPED ({BUNDLE_TEST_SKIP[example.name]})")
                continue

            print(f"  Building {example.name} (URL)...", end=" ", flush=True)
            original = example.read_text()
            rewritten, did_rewrite = _rewrite_platform_ref(original, url)
            if not did_rewrite:
                print("SKIPPED (no platform reference to rewrite)")
                continue

            example.write_text(rewritten)
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
        if bundle_path is not None:
            bundle_path.unlink(missing_ok=True)
        if types_path is not None:
            types_path.unlink(missing_ok=True)

    return failed


def run_wayland_bundle_test(root: Path, example: Path, verbose: bool) -> list[str]:
    """Build and inspect the Wayland platform package bundle."""
    examples_dir = root / "examples"
    failed: list[str] = []

    print("\nRunning Wayland bundle package test...")

    fixture_archive = root / "vendor/raylib/linux-x64/libraylib.a"
    wayland_archive = root / "vendor/raylib/linux-x64-wayland/libraylib.a"
    created_archive = False
    created_archive_dirs: list[Path] = []

    if not wayland_archive.is_file():
        if not fixture_archive.is_file():
            print(f"  Missing Linux raylib fixture archive: {fixture_archive}")
            return ["wayland bundle fixture"]

        parent = wayland_archive.parent
        while not parent.exists() and parent != root:
            created_archive_dirs.append(parent)
            parent = parent.parent
        wayland_archive.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(fixture_archive, wayland_archive)
        created_archive = True

    bundle_path: Path | None = None
    types_path: Path | None = None
    wayland_httpd, wayland_port = _serve_dir(root, verbose)
    wayland_base_url = f"http://127.0.0.1:{wayland_port}"
    try:
        bundle_proc = subprocess.run(
            ["bash", "scripts/bundle.sh", "--platform", "wayland",
             "--types-url-base", wayland_base_url],
            capture_output=True,
            text=True,
            cwd=root,
        )
        if bundle_proc.returncode != 0:
            print(bundle_proc.stdout)
            print(bundle_proc.stderr, file=sys.stderr)
            print("  bundle.sh --platform wayland FAILED")
            return ["bundle.sh --platform wayland"]

        bundle_name = _bundle_name_from_output(bundle_proc.stdout)
        if not bundle_name:
            print(bundle_proc.stdout)
            print("  Could not determine bundle filename from Wayland bundle output")
            return ["bundle.sh --platform wayland (no Created: line)"]

        bundle_path = root / bundle_name
        types_name = _types_bundle_name_from_output(bundle_proc.stdout)
        if types_name:
            types_path = root / types_name
        print(f"  Bundled Wayland platform: {bundle_name}")

        with _read_tar_zst(bundle_path) as bundle:
            names = set(bundle.getnames())
            main_file = bundle.extractfile("main.roc")
            if main_file is None:
                print("  Wayland bundle is missing main.roc")
                failed.append("wayland bundle missing main.roc")
            else:
                main_text = main_file.read().decode()
                forbidden_main_tokens = ["x64mac:", "arm64mac:", "x64win:", "libX11.so"]
                for token in forbidden_main_tokens:
                    if token in main_text:
                        print(f"  Wayland main.roc unexpectedly contains {token}")
                        failed.append(f"wayland main.roc contains {token}")

                expected_target = (
                    'x64glibc: { inputs: ["Scrt1.o", "crti.o", "libhost.a", '
                    '"libraylib.a", "libmsf_gif.a", "libvpx.a", "libm.so", app, '
                    '"libc.so", "crtn.o"] }'
                )
                if expected_target not in main_text:
                    print("  Wayland main.roc does not contain the expected Linux-only target")
                    failed.append("wayland main.roc target section")

            expected_files = {
                "targets/x64glibc/Scrt1.o",
                "targets/x64glibc/crti.o",
                "targets/x64glibc/crtn.o",
                "targets/x64glibc/libhost.a",
                "targets/x64glibc/libraylib.a",
                "targets/x64glibc/libmsf_gif.a",
                "targets/x64glibc/libvpx.a",
                "targets/x64glibc/libm.so",
                "targets/x64glibc/libc.so",
            }
            for expected_file in expected_files:
                if expected_file not in names:
                    print(f"  Wayland bundle is missing {expected_file}")
                    failed.append(f"wayland bundle missing {expected_file}")

            forbidden_prefixes = (
                "targets/x64mac/",
                "targets/arm64mac/",
                "targets/x64win/",
                "targets/macos-sysroot/",
            )
            for name in sorted(names):
                if name == "targets/x64glibc/libX11.so":
                    print("  Wayland bundle unexpectedly includes libX11.so")
                    failed.append("wayland bundle includes libX11.so")
                if name.startswith(forbidden_prefixes):
                    print(f"  Wayland bundle unexpectedly includes {name}")
                    failed.append(f"wayland bundle includes {name}")
                    break

        if failed:
            return failed

        httpd, port = wayland_httpd, wayland_port
        bundle_url = f"{wayland_base_url}/{bundle_name}"
        url = f'"{bundle_url}"'
        original = example.read_text()
        try:
            if not _wait_for_url(bundle_url):
                return ["wayland bundle URL unavailable"]

            rewritten, did_rewrite = _rewrite_platform_ref(original, url)
            if not did_rewrite:
                print(f"  Skipping URL import check for {example.name} (no platform ref)")
            else:
                example.write_text(rewritten)
                command = "build" if IS_LINUX else "check"
                ok = run_cmd(
                    ["roc", command, example.name],
                    f"wayland bundle {command} {example.name}",
                    verbose,
                    cwd=examples_dir,
                )
                if ok:
                    print(
                        f"  {command.capitalize()}ing {example.name} "
                        "against Wayland bundle URL... ok"
                    )
                else:
                    print(
                        f"  {command.capitalize()}ing {example.name} "
                        "against Wayland bundle URL... FAILED"
                    )
                    failed.append(f"wayland bundle {command} {example.name}")
        finally:
            example.write_text(original)
            httpd.shutdown()

        return failed
    finally:
        wayland_httpd.shutdown()
        if bundle_path is not None:
            bundle_path.unlink(missing_ok=True)
        if types_path is not None:
            types_path.unlink(missing_ok=True)
        if created_archive:
            wayland_archive.unlink(missing_ok=True)
        for created_dir in created_archive_dirs:
            try:
                created_dir.rmdir()
            except OSError:
                pass


def main() -> int:
    parser = argparse.ArgumentParser(description="Run all roc-ray tests")
    parser.add_argument(
        "--skip-platform-build",
        action="store_true",
        help="Reuse existing host libraries instead of running zig build first",
    )
    parser.add_argument(
        "--skip-roc-build",
        "--skip-build",
        dest="skip_roc_build",
        action="store_true",
        help="Skip roc build (--skip-build is a deprecated alias)",
    )
    parser.add_argument(
        "--skip-roc-test",
        action="store_true",
        help="Skip roc test over examples",
    )
    parser.add_argument(
        "--skip-runtime",
        action="store_true",
        help="Skip running built examples in host headless mode",
    )
    parser.add_argument(
        "--runtime-only",
        action="store_true",
        help="Only build examples and run them in host headless mode",
    )
    parser.add_argument(
        "--headless-frames",
        type=int,
        default=3,
        help="Number of frames to run each example in headless mode",
    )
    parser.add_argument(
        "--skip-bundle-test",
        action="store_true",
        help="Skip the bundle test (build platform package, host locally, build apps from URL)",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="Show all command output"
    )
    args = parser.parse_args()
    if args.headless_frames < 1:
        parser.error("--headless-frames must be greater than zero")
    if args.runtime_only and args.skip_roc_build:
        parser.error("--runtime-only cannot be combined with --skip-roc-build")

    # Find project root (parent of scripts/)
    root = Path(__file__).resolve().parent.parent
    examples_dir = root / "examples"

    examples = find_examples(examples_dir)
    if not examples:
        print("Error: No .roc files found in examples/")
        return 1

    with _temporary_platform_refs(examples, LOCAL_PLATFORM_REF) as rewritten_count:
        if rewritten_count:
            print(f"Using local source platform for {rewritten_count} example(s)")
        return _run_tests(args, root, examples)


def _run_tests(args: argparse.Namespace, root: Path, examples: list[Path]) -> int:
    examples_dir = root / "examples"
    print(f"Found {len(examples)} example(s): {', '.join(e.stem for e in examples)}")

    failed = []

    if args.skip_platform_build:
        print("\nReusing existing host libraries (--skip-platform-build)")
    else:
        # Standalone runs build a fresh host. Orchestrators that already chose
        # an optimization mode must pass --skip-platform-build.
        print("\nBuilding platform (zig build)...")
        if not run_cmd(["zig", "build"], "zig build", args.verbose, cwd=root):
            print("  FAILED")
            failed.append("zig build")
        else:
            print("  ok")

    if args.runtime_only:
        print("\nSkipping roc check/fmt/test (--runtime-only)")
    else:
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

        if args.skip_roc_test:
            print("\nSkipping roc test (--skip-roc-test)")
        else:
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
    built_examples: list[Path] = []
    if args.skip_roc_build:
        print("\nSkipping roc build (--skip-roc-build)")
    else:
        print("\nRunning roc build...")
        for example in examples:
            if example.name in BUILD_RUNTIME_SKIP:
                print(f"  Building {example.name}... SKIPPED ({BUILD_RUNTIME_SKIP[example.name]})")
                continue

            print(f"  Building {example.name}...", end=" ", flush=True)
            if run_cmd(
                ["roc", "build", example.name], f"build {example.name}", args.verbose, cwd=examples_dir
            ):
                print("ok")
                built_examples.append(example)
            else:
                print("FAILED")
                failed.append(f"roc build {example.name}")

    if args.skip_runtime:
        print("\nSkipping headless runtime (--skip-runtime)")
    elif args.skip_roc_build:
        print("\nSkipping headless runtime (--skip-roc-build)")
    else:
        failed.extend(
            run_headless_examples(root, built_examples, args.headless_frames, args.verbose)
        )

    # Bundle test: build the platform package, host it on localhost, and build
    # each example against the bundle URL (mirrors the platform-template check).
    if args.runtime_only:
        print("\nSkipping bundle test (--runtime-only)")
    elif args.skip_bundle_test:
        print("\nSkipping bundle test (--skip-bundle-test)")
    elif IS_WINDOWS:
        print("\nSkipping bundle test (requires bash for bundle.sh; not run on Windows)")
    else:
        failed.extend(run_bundle_test(root, examples, args.verbose))
        failed.extend(run_wayland_bundle_test(root, examples[0], args.verbose))

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
