#!/usr/bin/env python3
"""
Run all tests for the roc-ray platform.

Every app stage resolves its packages through localhost. `scripts/bundle.sh`
bundles the roc-ray-types package and the platform into a scratch directory,
`scripts/local_bundles.py` serves that directory over HTTP, and each app is
*copied* to a scratch directory with its header pointed at the served bundle.
Three things follow: every app is checked and built in the shape it ships in
rather than against the platform sources, every reference to roc-ray-types --
the platform's, the four examples that name it themselves, both halves of
test/package_interop -- resolves one freshly built artifact, and no tracked file
is ever rewritten, so an interrupted run cannot leave the working tree dirty.

This script runs:
- zig build       - Build the native host libraries
- libvpx check    - Verify the vendored encoder's per-architecture source lists
- roc check       - Type check all examples against the served platform bundle
- roc fmt --check - Verify formatting of the checked-in examples
- roc test        - Run inline tests
- roc build       - Build executables against the served platform bundle
- headless runs   - Run each built example for a few frames
- cli args        - Build and run the argv bridge probe
- model alloc     - Measure what a frame costs a large collection in the model
- package interop - Build test/package_interop with the package pinning the
                    served types URL, which is the case this all exists for
- wayland bundle  - Bundle, inspect and build the Linux-only Wayland package

Usage:
    ./scripts/all_tests.py                       # Run all tests
    ./scripts/all_tests.py --only pong,snake     # Restrict to some examples
    ./scripts/all_tests.py --skip-platform-build # Reuse existing host libraries
    ./scripts/all_tests.py --skip-roc-build      # Skip roc build
    ./scripts/all_tests.py --skip-runtime        # Skip running built examples
    ./scripts/all_tests.py --skip-roc-test       # Skip roc test
    ./scripts/all_tests.py --runtime-only        # Only build and run examples headlessly
    ./scripts/all_tests.py --skip-bundle-test    # Skip the Wayland bundle package test
    ./scripts/all_tests.py --platform-mode=source # Serve types only; use platform sources
    ./scripts/all_tests.py --copy-executables    # Also leave binaries beside each main.roc
    ./scripts/all_tests.py --verbose             # Show all output

Nothing tracked is written at any point, so `git status` stays clean however the
run ends -- including SIGKILL. Built executables and staged sources live in a
scratch directory under the system temp directory.

TODO replace me with a Roc script when basic-cli is implemented
"""

import argparse
import io
import os
import platform
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import local_bundles  # noqa: E402  (needs the sys.path entry above)

IS_WINDOWS = platform.system() == "Windows"
IS_LINUX = platform.system() == "Linux"

# Re-exported for callers that import them from here (see .github/workflows).
LOCAL_PLATFORM_REF = local_bundles.LOCAL_PLATFORM_REF
RELEASE_PLATFORM_REF_RE = local_bundles.RELEASE_PLATFORM_REF_RE
_rewrite_platform_ref = local_bundles.rewrite_platform_ref

# Examples to skip in the bundled-platform build test, mapping example name ->
# reason. Use this when a specific example can't build against the bundled
# platform yet (e.g. a known upstream issue); it is reported as SKIPPED, not
# FAILED.
#   e.g. "example": "blocked on roc-lang/roc#NNNN (record-update lowering)"
BUNDLE_TEST_SKIP: dict[str, str] = {}

# Examples to skip in native `roc build` / headless runtime checks.
# Keep these explicit so CI still exercises every example that currently
# compiles, without hiding unrelated build/runtime failures.
BUILD_RUNTIME_SKIP: dict[str, str] = {
    # TODO: Investigate why this example takes several minutes to compile in CI.
    "cave_climb": "follow-up: investigate unusually slow Roc build",
}


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
    """Find each example application's conventional entrypoint."""
    return sorted(examples_dir.glob("*/main.roc"))


def example_name(example: Path) -> str:
    return example.parent.name


def select_examples(examples: list[Path], only: list[str]) -> list[Path]:
    """Restrict `examples` to the names in `only`."""
    if not only:
        return examples

    wanted: list[str] = []
    for entry in only:
        wanted.extend(part.strip() for part in entry.split(",") if part.strip())

    by_name = {example_name(example): example for example in examples}
    selected: list[Path] = []
    unknown: list[str] = []
    for name in wanted:
        example = by_name.get(name.rstrip("/"))
        if example is None:
            unknown.append(name)
        elif example not in selected:
            selected.append(example)

    if unknown:
        available = ", ".join(sorted(by_name))
        raise SystemExit(
            f"error: unknown example(s): {', '.join(unknown)}\navailable: {available}"
        )
    return selected


def executable_for(entry: Path) -> Path:
    """Return the executable `roc build` produces beside an app's `main.roc`."""
    suffix = ".exe" if IS_WINDOWS else ""
    return entry.with_name(f"{entry.stem}{suffix}")


def run_headless_examples(
    root: Path, built: list[tuple[Path, Path]], frames: int, verbose: bool
) -> list[str]:
    """Run each already-built example executable in bounded headless mode.

    `built` pairs the checked-in entrypoint with the staged copy that was built.
    The executables live in the scratch directory but are run from the
    repository root, because the examples load their assets from
    `examples/<name>/assets/...` relative to the working directory.
    """
    failed: list[str] = []

    print(f"\nRunning built examples headlessly ({frames} frame(s))...")
    for example, staged in built:
        executable = executable_for(staged)
        name = example_name(example)
        print(f"  Running {name}...", end=" ", flush=True)
        if not executable.is_file():
            print("FAILED (missing executable)")
            failed.append(f"headless run {name} (missing executable)")
            continue

        ok = run_cmd(
            [
                str(executable),
                "--host-headless",
                f"--host-headless-frames={frames}",
            ],
            f"headless run {name}",
            verbose,
            cwd=root,
        )
        if ok:
            print("ok")
        else:
            print("FAILED")
            failed.append(f"headless run {name}")

    return failed


def run_cli_args_integration(
    root: Path, packages: local_bundles.ServedPackages, verbose: bool
) -> list[str]:
    """Build and run the argv bridge probe against the served platform."""
    fixture = root / "test" / "cli_args" / "main.roc"
    if not fixture.is_file():
        return []

    print("\nRunning CLI argument integration probe...", end=" ", flush=True)
    staged = local_bundles.stage_app(fixture, packages, packages.scratch_dir / "cli_args")
    if not run_cmd(
        ["roc", "build", staged.name], "build CLI argument probe", verbose, cwd=staged.parent
    ):
        print("FAILED")
        return ["build CLI argument probe"]

    ok = run_cmd(
        [
            str(executable_for(staged)),
            "--host-headless",
            "--host-headless-frames=3",
            "--cli-args-config",
            "--headless",
        ],
        "run CLI argument probe",
        verbose,
        cwd=root,
    )
    print("ok" if ok else "FAILED")
    return [] if ok else ["run CLI argument probe"]


def run_model_allocation_check(
    root: Path, packages: local_bundles.ServedPackages, verbose: bool
) -> list[str]:
    """Measure what one frame costs a large collection held in the app's model.

    Writing one element of a million-element list in the model allocates a whole
    new list, every frame: the model is not uniquely referenced while `update`
    runs, so the write is copy-on-write rather than in place. That is measured
    behaviour, and this keeps it measured -- the check fails if a frame starts
    costing more than one copy, and equally if it starts costing less.

    The probe is a Roc app like any other, so it is built from a staged copy
    against the served platform rather than from its committed relative
    reference. `test_model_allocation.py` looks for the executable beside the
    checked-in `main.roc`, so the build is copied there (gitignored) and the
    script is asked to skip its own build.
    """
    probe = root / "scripts" / "test_model_allocation.py"
    entry = root / "test" / "model_inplace" / "main.roc"
    if not probe.is_file() or not entry.is_file():
        return []

    print("\nMeasuring model collection allocation per frame...", end=" ", flush=True)
    staged = local_bundles.stage_app(entry, packages, packages.scratch_dir / "model_inplace")
    if not run_cmd(
        ["roc", "build", staged.name], "build model allocation probe", verbose, cwd=staged.parent
    ):
        print("FAILED (build)")
        return ["model allocation probe build"]

    destination = executable_for(entry)
    shutil.copyfile(executable_for(staged), destination)
    destination.chmod(0o755)

    result = subprocess.run(
        [sys.executable, str(probe), "--skip-build"],
        capture_output=True,
        text=True,
        cwd=root,
        shell=IS_WINDOWS,
    )
    ok = result.returncode == 0
    print("ok" if ok else "FAILED")
    # The numbers are the point of this step, so print them either way.
    for line in (result.stdout or "").splitlines():
        print(f"  {line}")
    if not ok or verbose:
        sys.stderr.write(result.stderr or "")
    return [] if ok else ["model allocation check"]


def run_package_interop_test(
    root: Path, packages: local_bundles.ServedPackages, verbose: bool
) -> list[str]:
    """Build `test/package_interop` with the *package* pinning types by URL.

    This is the arrangement the served bundles exist for: `input_adapter` is a
    package depending only on roc-ray-types, and the app depends on both it and
    the platform, so three separate references have to describe one package.
    Staging points every `rrt:` entry in the tree at the served URL, and this
    asserts the result still compiles and runs -- which is the property the
    README says the whole types-package split rests on.
    """
    entry = root / "test" / "package_interop" / "app.roc"
    if not entry.is_file():
        print("\nSkipping package interop test (test/package_interop is absent)")
        return []

    print("\nRunning package interop test (package and platform share a types URL)...")
    staged = local_bundles.stage_app(entry, packages, packages.scratch_dir / "package_interop")

    failed: list[str] = []
    for command in ("check", "build"):
        print(f"  {command.capitalize()}ing {entry.name}...", end=" ", flush=True)
        if run_cmd(["roc", command, staged.name], f"interop {command}", verbose, cwd=staged.parent):
            print("ok")
        else:
            print("FAILED")
            failed.append(f"package interop roc {command}")
            return failed

    print(f"  Running {entry.name} headlessly...", end=" ", flush=True)
    if run_cmd(
        [str(executable_for(staged)), "--host-headless", "--host-headless-frames=3"],
        "interop headless run",
        verbose,
        cwd=root,
    ):
        print("ok")
    else:
        print("FAILED")
        failed.append("package interop headless run")

    return failed


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


def run_wayland_bundle_test(root: Path, example: Path, verbose: bool) -> list[str]:
    """Build and inspect the Wayland platform package bundle.

    The default package is already exercised by every other stage, which builds
    the examples straight from its served bundle. This checks the *other*
    package: that it carries only the Linux target, drops the X11 stub, and
    still builds an app.
    """
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

    try:
        with local_bundles.serve_packages(
            root, package="wayland", mode="bundle", verbose=verbose
        ) as packages:
            bundle_path = packages.served_dir / Path(packages.platform_url or "").name
            print(f"  Bundled Wayland platform: {bundle_path.name}")

            failed.extend(_inspect_wayland_bundle(bundle_path))
            if failed:
                return failed

            name = example_name(example)
            staged = local_bundles.stage_app(
                example, packages, packages.scratch_dir / "wayland-example"
            )
            command = "build" if IS_LINUX else "check"
            ok = run_cmd(
                ["roc", command, staged.name],
                f"wayland bundle {command} {name}",
                verbose,
                cwd=staged.parent,
            )
            label = f"  {command.capitalize()}ing {name} against Wayland bundle URL..."
            if ok:
                print(f"{label} ok")
            else:
                print(f"{label} FAILED")
                failed.append(f"wayland bundle {command} {name}")
    except local_bundles.LocalBundleError as err:
        print(f"  Wayland bundle FAILED: {err}")
        failed.append("wayland bundle")
    finally:
        if created_archive:
            wayland_archive.unlink(missing_ok=True)
        for created_dir in created_archive_dirs:
            try:
                created_dir.rmdir()
            except OSError:
                pass

    return failed


def _inspect_wayland_bundle(bundle_path: Path) -> list[str]:
    """Assert the Wayland bundle carries the Linux target and nothing else."""
    failed: list[str] = []

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

    return failed


def main() -> int:
    parser = argparse.ArgumentParser(description="Run all roc-ray tests")
    parser.add_argument(
        "--only",
        action="append",
        default=[],
        metavar="NAME",
        help="Restrict to these examples (repeatable, or comma separated), e.g. --only pong,snake",
    )
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
        "--skip-wayland-bundle-test",
        dest="skip_bundle_test",
        action="store_true",
        help=(
            "Skip the Wayland bundle package test. The default package is served "
            "and built against by every other stage, so it has no separate test."
        ),
    )
    parser.add_argument(
        "--skip-interop-test",
        action="store_true",
        help=(
            "Skip building test/package_interop, which checks that a package "
            "pinning roc-ray-types by URL and the platform agree on one identity"
        ),
    )
    parser.add_argument(
        "--platform-mode",
        choices=["auto", "bundle", "source"],
        default="auto",
        help=(
            "How apps reach the platform: 'bundle' serves a platform bundle over "
            "localhost, 'source' serves only the types package and uses a staged copy "
            "of platform/ that points at it, 'auto' (default) bundles when it can"
        ),
    )
    parser.add_argument(
        "--copy-executables",
        action="store_true",
        help=(
            "Copy each built example executable back beside its main.roc. Off by "
            "default so the working tree is untouched; tools that need the "
            "binaries in place (scripts/profile-example-allocations.py) ask for it"
        ),
    )
    parser.add_argument(
        "--ephemeral-port",
        action="store_true",
        help=(
            "Always let the OS pick the HTTP port. The default prefers a port derived "
            "from this checkout so bundle hashes, and the Roc package cache entries "
            "behind them, stay stable between runs"
        ),
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

    examples = select_examples(find_examples(examples_dir), args.only)
    if not examples:
        print("Error: No examples/*/main.roc entrypoints found")
        return 1

    warning = local_bundles.check_roc_pin(root)
    if warning:
        print(warning, file=sys.stderr)

    # SIGTERM/SIGINT become SystemExit so the server and scratch directory are
    # released promptly. Repository safety does not depend on this: no tracked
    # file is ever rewritten, so even SIGKILL leaves the tree clean.
    with local_bundles.terminating_signals():
        return _run_tests(args, root, examples)


def _run_tests(args: argparse.Namespace, root: Path, examples: list[Path]) -> int:
    print(f"Found {len(examples)} example(s): {', '.join(example_name(e) for e in examples)}")

    failed = []

    if args.skip_platform_build:
        print("\nReusing existing host libraries (--skip-platform-build)")
    else:
        # Standalone runs build a fresh host. Orchestrators that already chose
        # an optimization mode must pass --skip-platform-build. The libraries
        # this produces are also what the platform bundle is built from, so it
        # has to happen before anything is served.
        print("\nBuilding platform (zig build)...")
        if not run_cmd(["zig", "build"], "zig build", args.verbose, cwd=root):
            print("  FAILED")
            failed.append("zig build")
        else:
            print("  ok")

    # The vendored libvpx's dispatch headers are pruned to match its
    # per-architecture source lists; this catches the two falling out of step.
    print("\nChecking libvpx archives...")
    if run_cmd(
        [sys.executable, str(root / "scripts" / "check_libvpx_archives.py")],
        "check_libvpx_archives",
        args.verbose,
        cwd=root,
    ):
        print("  ok")
    else:
        print("  FAILED")
        failed.append("libvpx archive check")

    # roc fmt is purely syntactic and needs no package resolution, so check the
    # files as committed rather than the rewritten copies.
    if args.runtime_only:
        print("\nSkipping roc fmt (--runtime-only)")
    else:
        print("\nRunning roc fmt --check...")
        for example in examples:
            name = example_name(example)
            print(f"  Formatting {name}...", end=" ", flush=True)
            if run_cmd(["roc", "fmt", "--check", str(example)], f"fmt {name}", args.verbose):
                print("ok")
            else:
                print("FAILED")
                failed.append(f"roc fmt {name}")

    try:
        with local_bundles.serve_packages(
            root,
            mode=args.platform_mode,
            verbose=args.verbose,
            stable_port=not args.ephemeral_port,
        ) as packages:
            print(f"\nServing packages from {packages.base_url}")
            print(f"  types:    {packages.types_url}")
            print(f"  platform: {packages.platform_ref}")
            for note in packages.notes:
                print(f"  note:     {note}")

            apps_dir = packages.scratch_dir / "examples"
            staged = local_bundles.stage_apps(examples, packages, apps_dir)
            print(f"  staged {len(staged)} example(s) in {apps_dir}")

            failed.extend(_run_example_stages(args, root, examples, staged, packages))

            if args.runtime_only:
                print("\nSkipping package interop test (--runtime-only)")
            elif args.skip_interop_test:
                print("\nSkipping package interop test (--skip-interop-test)")
            else:
                failed.extend(run_package_interop_test(root, packages, args.verbose))
    except local_bundles.LocalBundleError as err:
        print(f"\nFAILED to serve the local packages: {err}", file=sys.stderr)
        failed.append("serve local packages")

    # The default package is covered above; the Wayland package is a separate
    # artifact with a different target list, so it gets its own check.
    if args.runtime_only:
        print("\nSkipping Wayland bundle test (--runtime-only)")
    elif args.skip_bundle_test:
        print("\nSkipping Wayland bundle test (--skip-bundle-test)")
    elif IS_WINDOWS:
        print("\nSkipping Wayland bundle test (requires bash for bundle.sh; not run on Windows)")
    else:
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


def _run_example_stages(
    args: argparse.Namespace,
    root: Path,
    examples: list[Path],
    staged: dict[Path, Path],
    packages: local_bundles.ServedPackages,
) -> list[str]:
    """Check, test, build and run the staged examples against the served packages."""
    failed: list[str] = []

    if args.runtime_only:
        print("\nSkipping roc check/test (--runtime-only)")
    else:
        print("\nRunning roc check...")
        for example in examples:
            name = example_name(example)
            print(f"  Checking {name}...", end=" ", flush=True)
            if run_cmd(
                ["roc", "check", staged[example].name],
                f"check {name}",
                args.verbose,
                cwd=staged[example].parent,
            ):
                print("ok")
            else:
                print("FAILED")
                failed.append(f"roc check {name}")

        if args.skip_roc_test:
            print("\nSkipping roc test (--skip-roc-test)")
        else:
            print("\nRunning roc test...")
            for example in examples:
                name = example_name(example)
                print(f"  Testing {name}...", end=" ", flush=True)
                if run_cmd(
                    ["roc", "test", staged[example].name],
                    f"test {name}",
                    args.verbose,
                    cwd=staged[example].parent,
                ):
                    print("ok")
                else:
                    print("FAILED")
                    failed.append(f"roc test {name}")

    built: list[tuple[Path, Path]] = []
    if args.skip_roc_build:
        print("\nSkipping roc build (--skip-roc-build)")
    else:
        print("\nRunning roc build...")
        for example in examples:
            name = example_name(example)
            skip_reason = BUILD_RUNTIME_SKIP.get(name) or BUNDLE_TEST_SKIP.get(name)
            if skip_reason:
                print(f"  Building {name}... SKIPPED ({skip_reason})")
                continue

            print(f"  Building {name}...", end=" ", flush=True)
            if run_cmd(
                ["roc", "build", staged[example].name],
                f"build {name}",
                args.verbose,
                cwd=staged[example].parent,
            ):
                print("ok")
                built.append((example, staged[example]))
            else:
                print("FAILED")
                failed.append(f"roc build {name}")

    if args.copy_executables and built:
        # Executables are built in the scratch directory; some tools expect them
        # beside the checked-in main.roc. `examples/*/main` is in .gitignore, so
        # this still leaves `git status` clean.
        for example, staged_entry in built:
            destination = executable_for(example)
            shutil.copyfile(executable_for(staged_entry), destination)
            destination.chmod(0o755)
        print(f"\nCopied {len(built)} executable(s) beside their examples")

    if args.skip_runtime:
        print("\nSkipping headless runtime (--skip-runtime)")
    elif args.skip_roc_build:
        print("\nSkipping headless runtime (--skip-roc-build)")
    else:
        failed.extend(run_headless_examples(root, built, args.headless_frames, args.verbose))
        failed.extend(run_cli_args_integration(root, packages, args.verbose))
        failed.extend(run_model_allocation_check(root, packages, args.verbose))

    return failed


if __name__ == "__main__":
    sys.exit(main())
