#!/usr/bin/env python3
"""
Run all tests for the roc-ray platform.

Every app stage resolves its packages through localhost. `scripts/bundle.sh`
bundles the roc-ray-types package and the platform into a scratch directory,
`scripts/local_bundles.py` serves that directory over HTTP, and each app is
*copied* to a scratch directory with its header pointed at the served bundle.
Three things follow: every app is checked and built in the shape it ships in
rather than against the platform sources, every reference to roc-ray-types --
the platform's and both halves of test/package_interop, which is all of them
now that the platform re-exports the types an app needs to name -- resolves one
freshly built artifact, and no tracked file is ever rewritten, so an
interrupted run cannot leave the working tree dirty.

This script runs:
- zig build       - Build the native host libraries
- libvpx check    - Verify the vendored encoder's per-architecture source lists
- roc check       - Type check all examples against the served platform bundle
- roc fmt --check - Verify formatting of the checked-in examples
- roc test        - Run inline tests
- roc build       - Build executables against the served platform bundle
- headless runs   - Run each built example for a few frames
- windowed sweep  - Run the cases in `scripts/test_spec.json` against the real
                    raylib backend, with a real (hidden) window, so the window,
                    GL, texture, font, audio and capture paths `--host-headless`
                    stubs out actually execute on every OS. Cases can script
                    keys and typed text, and assert output, exit code and files
                    written. Pixels are not compared; `zig build
                    graphical-smoke` is the pixel-level test.
- cli args        - Build and run the argv bridge probe
- model alloc     - Measure what a frame costs a large collection in the model
- task delivery   - Spawn one task per Msg variant and assert every message
                    arrives with the right tag and payload (test/task_delivery).
- task cap        - Spawn a hundred tasks against the host's cap of 32 and
                    assert every one of them still answers (test/task_cap).
- observatory     - Record an annotated headless run and query its metadata,
                    cycle, annotation, gap and recorder-health tables.
- file write      - Write files from a task, read them back, and compare
                    (test/file_write).
- udp sockets     - Send datagrams between two loopback sockets and assert the
                    bytes, the sender address, and that a parked receive lets
                    the frame loop keep running (test/udp).
- virtual keys    - Script a keyboard and typed text and assert the edges and
                    codepoints the next cycle is handed (test/virtual_keys).
- subprocess      - Run six commands through the machine's own shell from a
                    task and assert the output, the deadline, the output caps,
                    the error naming, and that the frame loop kept going
                    (test/cmd).
- http client     - Serve a known file on localhost, fetch it from a task, and
                    check the response, the size cap, and the timeout
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
    ./scripts/all_tests.py --runtime-only        # Only build and run examples
    ./scripts/all_tests.py --skip-windowed       # Skip the windowed sweep (needs a display)
    ./scripts/all_tests.py --windowed-dll-dir=DIR # Copy DIR/*.dll beside each binary first
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
import json
import os
import platform
import re
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import local_bundles  # noqa: E402  (needs the sys.path entry above)
import test_http_client  # noqa: E402  (needs the sys.path entry above)

IS_WINDOWS = platform.system() == "Windows"
IS_LINUX = platform.system() == "Linux"

# Re-exported for callers that import them from here (see .github/workflows).
LOCAL_PLATFORM_REF = local_bundles.LOCAL_PLATFORM_REF
RELEASE_PLATFORM_REF_RE = local_bundles.RELEASE_PLATFORM_REF_RE
_rewrite_platform_ref = local_bundles.rewrite_platform_ref
# See `local_bundles.PACKAGE_LIMIT_ARGS`: a locally built platform bundle is
# bigger than roc's default transitive-dependency budget.
LIMITS = local_bundles.PACKAGE_LIMIT_ARGS

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


TEST_SPEC_PATH = Path(__file__).resolve().parent / "test_spec.json"

# Lines that mean a windowed run went wrong even though the process exited 0.
# raylib logs its own failures at ERROR/WARNING level rather than failing the
# process, so a missing texture or a dead GL context is only visible here.
_CRASH_MARKER = "[ROC CRASHED]"
_RAYLIB_ERROR_RE = re.compile(r"^\s*ERROR:", re.MULTILINE)
_RAYLIB_WARNING_FAILED_RE = re.compile(r"^\s*WARNING:.*failed", re.MULTILINE | re.IGNORECASE)

_PLATFORM_KEY = "windows" if IS_WINDOWS else ("linux" if IS_LINUX else "darwin")


def load_test_spec(root: Path) -> dict:
    """Load scripts/test_spec.json and check it names every example exactly once.

    The spec is validated against the whole `examples/` directory even when
    `--only` narrowed this run, so a new example cannot be added without a case.
    """
    spec = json.loads(TEST_SPEC_PATH.read_text())
    listed: list[str] = []
    for app in spec["apps"]:
        listed.append(Path(app["path"]).name)
    duplicates = sorted({name for name in listed if listed.count(name) > 1})
    if duplicates:
        raise SystemExit(f"error: {TEST_SPEC_PATH.name} lists {', '.join(duplicates)} more than once")

    on_disk = {example_name(example) for example in find_examples(root / "examples")}
    missing = sorted(on_disk - set(listed))
    extra = sorted(set(listed) - on_disk)
    if missing or extra:
        problems = []
        if missing:
            problems.append(f"missing: {', '.join(missing)}")
        if extra:
            problems.append(f"not an example: {', '.join(extra)}")
        raise SystemExit(f"error: {TEST_SPEC_PATH.name} does not match examples/ ({'; '.join(problems)})")
    return spec


def has_display() -> bool:
    """Can a real window be opened here?

    macOS and Windows always have a window server; X11/Wayland is the case that
    can genuinely be absent, and a run without one has to say so rather than
    fail with a raylib GLFW error.
    """
    if not IS_LINUX:
        return True
    return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))


def _png_dimensions(path: Path) -> tuple[int, int] | None:
    """Width and height from a PNG's IHDR, or None if it is not a PNG."""
    header = path.read_bytes()[:24]
    if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return int.from_bytes(header[16:20], "big"), int.from_bytes(header[20:24], "big")


def _check_windowed_case(
    root: Path, executable: Path, case: dict, defaults: dict, verbose: bool
) -> list[str]:
    """Run one spec case against the real backend and check what it produced."""
    frames = case.get("frames", defaults["frames"])
    expected_exit = case.get("exit_code", defaults["exit_code"])
    timeout = case.get("timeout_seconds", defaults["timeout_seconds"])

    expect_png = case.get("expect_png")
    if expect_png:
        # A stale picture from an earlier run must not pass for this one's.
        for stale in root.glob(expect_png["glob"]):
            stale.unlink()

    cmd = [str(executable), "--host-hidden", f"--host-frames={frames}"]
    if "keys" in case:
        cmd.append(f"--host-keys={case['keys']}")
    if "text" in case:
        cmd.append(f"--host-text={case['text']}")
    cmd.extend(case.get("args", []))

    if verbose:
        print(f"    Running: {' '.join(cmd)}")
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            cwd=root,
            timeout=timeout,
            shell=IS_WINDOWS,
        )
    except subprocess.TimeoutExpired:
        return [f"timed out after {timeout}s"]

    output = (result.stdout or "") + (result.stderr or "")
    problems: list[str] = []
    if result.returncode != expected_exit:
        problems.append(f"exit code {result.returncode}, expected {expected_exit}")
    if _CRASH_MARKER in output:
        problems.append("output contains [ROC CRASHED]")
    if _RAYLIB_ERROR_RE.search(output):
        problems.append("output contains a raylib ERROR line")
    if _RAYLIB_WARNING_FAILED_RE.search(output):
        problems.append("output contains a raylib WARNING ... failed line")
    for needle in case.get("contains", []):
        if needle not in output:
            problems.append(f"output does not contain {needle!r}")

    if expect_png:
        written = sorted(root.glob(expect_png["glob"]))
        if not written:
            problems.append(f"no file matched {expect_png['glob']}")
        else:
            size = _png_dimensions(written[-1])
            wanted = (expect_png["width"], expect_png["height"])
            # A screenshot is framebuffer pixels, and a HighDPI window's
            # framebuffer is an integer multiple of the logical window size --
            # 2x on this Mac's Retina display. The property worth asserting is
            # the shape of the window, not the density of the monitor CI drew on.
            if size is None or size[0] % wanted[0] or size[1] % wanted[1] or (
                size[0] // wanted[0] != size[1] // wanted[1]
            ):
                problems.append(f"{written[-1].name} is {size}, expected {wanted} at some integer scale")
            for picture in written:
                picture.unlink()

    if problems and not verbose and output:
        print(output)
    return problems


def _install_runtime_dlls(dll_dir: Path, staged_dirs: set[Path]) -> None:
    """Copy loader-visible DLLs beside each built executable.

    Windows resolves a DLL from the executable's own directory first, and CI
    runners ship an `opengl32.dll` that only offers GL 1.1, so a Mesa drop-in
    has to sit beside the binary rather than anywhere on the path.
    """
    for library in sorted(dll_dir.glob("*.dll")):
        for directory in staged_dirs:
            shutil.copyfile(library, directory / library.name)


def run_windowed_examples(
    root: Path,
    built: list[tuple[Path, Path]],
    spec: dict,
    verbose: bool,
    dll_dir: Path | None = None,
) -> list[str]:
    """Run the spec's cases against the real backend, with a real hidden window.

    This is the stage that executes the raylib window, GL, texture, font, audio
    and capture paths that `--host-headless` stubs out entirely. Pixels are
    deliberately not compared -- `zig build graphical-smoke` is the pixel test;
    this one asserts that every example survives real frames on every OS.
    """
    failed: list[str] = []
    if not has_display():
        print("\nSkipping windowed runtime (no DISPLAY or WAYLAND_DISPLAY; use xvfb-run)")
        return failed

    cases_by_example = {Path(app["path"]).name: app for app in spec["apps"]}
    defaults = spec["defaults"]

    if dll_dir is not None:
        _install_runtime_dlls(dll_dir, {executable_for(staged).parent for _, staged in built})

    print("\nRunning built examples in a real hidden window...")
    for example, staged in built:
        name = example_name(example)
        app = cases_by_example[name]
        for case in app["cases"]:
            label = f"{name}/{case['name']}"
            excluded = {**app.get("platforms", {}), **case.get("platforms", {})}.get(_PLATFORM_KEY)
            if excluded is not None and not excluded.get("run", True):
                reason = case.get("reason") or app.get("reason") or "excluded by spec"
                print(f"  {label}... SKIPPED ({reason})")
                continue

            print(f"  {label}...", end=" ", flush=True)
            executable = executable_for(staged)
            if not executable.is_file():
                print("FAILED (missing executable)")
                failed.append(f"windowed run {label} (missing executable)")
                continue

            problems = _check_windowed_case(root, executable, case, defaults, verbose)
            if problems:
                print(f"FAILED ({'; '.join(problems)})")
                failed.append(f"windowed run {label}")
            else:
                print("ok")

    return failed


def run_graphical_observatory_probe(
    root: Path, built: list[tuple[Path, Path]], verbose: bool
) -> list[str]:
    """Verify graphical backend/presentation facts separately from headless timing."""
    if not has_display() or not built:
        return []

    staged = next(
        (entry for example, entry in built if example_name(example) == "hello_world"),
        built[0][1],
    )
    executable = executable_for(staged)
    capture = staged.parent / "graphical-observatory.rrstats"
    print("\nRunning graphical Observatory probe...", end=" ", flush=True)
    graphical_run = subprocess.run(
        [
            str(executable),
            "--host-hidden",
            "--host-frames=3",
            f"--host-stats-output={capture}",
            "--host-stats-detail=full",
        ],
        # Match the ordinary windowed sweep: example asset paths are rooted at
        # the checkout, not at the temporary directory containing the staged
        # executable. A different cwd can turn an asset lookup failure into a
        # false Observatory/runtime failure.
        cwd=root,
        stdout=None if verbose else subprocess.PIPE,
        stderr=None if verbose else subprocess.PIPE,
        text=True,
        check=False,
    )
    if graphical_run.returncode != 0:
        if not verbose:
            print(graphical_run.stdout or "")
            print(graphical_run.stderr or "", file=sys.stderr)
        diagnostic = "capture unavailable"
        try:
            failure_db = sqlite3.connect(f"file:{capture}?mode=ro", uri=True)
            try:
                outcome = failure_db.execute(
                    "SELECT value FROM metadata WHERE key='application_outcome'"
                ).fetchone()
                callbacks = failure_db.execute(
                    "SELECT cycle,phase,outcome FROM callback_summaries "
                    "WHERE outcome<>0 ORDER BY id"
                ).fetchall()
                diagnostic = f"application_outcome={outcome!r}, callback_errors={callbacks!r}"
            finally:
                failure_db.close()
        except sqlite3.Error as err:
            diagnostic = f"capture query failed: {err}"
        print("FAILED")
        return [
            f"run graphical Observatory probe (exit {graphical_run.returncode}; {diagnostic})"
        ]

    failures: list[str] = []
    try:
        db = sqlite3.connect(f"file:{capture}?mode=ro", uri=True)
        try:
            metadata = dict(db.execute("SELECT key,value FROM metadata"))
            facts = dict(
                db.execute(
                    "SELECT name,count(*) FROM gpu_facts "
                    "WHERE name IN "
                    "('render_callback','begin_drawing','host_draw_submission',"
                    "'end_drawing_including_presentation_and_pacing') GROUP BY name"
                )
            )
            render_totals = db.execute(
                "SELECT "
                "(SELECT coalesce(sum(duration_ns),0) FROM callback_summaries WHERE phase=2), "
                "(SELECT coalesce(sum(render_callback_ns),0) FROM cycles), "
                "(SELECT coalesce(sum(duration_ns),0) FROM gpu_facts WHERE name='render_callback')"
            ).fetchone()
        finally:
            db.close()
        if metadata.get("target_profile") != "native-graphical":
            failures.append("graphical Observatory target profile is not native-graphical")
        if metadata.get("backend") != "raylib_native":
            failures.append("graphical Observatory backend is not raylib_native")
        if metadata.get("clean_shutdown") != "1" or metadata.get("final_state") != "complete":
            failures.append("graphical Observatory capture is incomplete")
        expected = {
            "render_callback",
            "begin_drawing",
            "host_draw_submission",
            "end_drawing_including_presentation_and_pacing",
        }
        if set(facts) != expected or any(count < 1 for count in facts.values()):
            failures.append(f"graphical Observatory backend facts are incomplete: {facts!r}")
        if render_totals is None or render_totals[0] <= 0 or len(set(render_totals)) != 1:
            failures.append(
                "graphical Observatory render duration disagrees across callbacks, cycles, "
                f"and backend facts: {render_totals!r}"
            )
    except (OSError, sqlite3.Error) as err:
        failures.append(f"query graphical Observatory capture: {err}")

    print("ok" if not failures else "FAILED")
    return failures


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
        ["roc", "build", staged.name, *LIMITS], "build CLI argument probe", verbose, cwd=staged.parent
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


def run_task_delivery_probe(
    root: Path, packages: local_bundles.ServedPackages, verbose: bool
) -> list[str]:
    """Check that a task's message survives the trip back into `update!`.

    A headless run only asserts an exit code, so an example whose messages never
    arrive still passes every other step here. This probe spawns one task per
    `Msg` variant -- including the tag-union layouts that used to come back with
    the wrong tag -- and exits non-zero unless each message arrives with the
    right tag *and* the right payload. Exit 3 means a mismatch, exit 4 means
    something never arrived.
    """
    fixture = root / "test" / "task_delivery" / "main.roc"
    if not fixture.is_file():
        return []

    print("\nRunning task delivery probe...", end=" ", flush=True)
    staged = local_bundles.stage_app(fixture, packages, packages.scratch_dir / "task_delivery")
    if not run_cmd(
        ["roc", "build", staged.name, *LIMITS], "build task delivery probe", verbose, cwd=staged.parent
    ):
        print("FAILED")
        return ["build task delivery probe"]

    ok = run_cmd(
        [
            str(executable_for(staged)),
            "--host-headless",
            "--host-headless-frames=200",
        ],
        "run task delivery probe",
        verbose,
        cwd=root,
    )
    print("ok" if ok else "FAILED")
    return [] if ok else ["run task delivery probe"]


def run_observatory_probe(
    root: Path, packages: local_bundles.ServedPackages, verbose: bool
) -> list[str]:
    """Record a headless run and verify the public Stage-1 database contract."""
    fixture = root / "test" / "observatory" / "main.roc"
    if not fixture.is_file():
        return []

    print("\nRunning Observatory capture probe...", end=" ", flush=True)
    staged = local_bundles.stage_app(fixture, packages, packages.scratch_dir / "observatory")
    if not run_cmd(
        ["roc", "build", staged.name, *LIMITS], "build Observatory probe", verbose, cwd=staged.parent
    ):
        print("FAILED")
        return ["build Observatory probe"]

    capture = staged.parent / "probe.rrstats"
    recorded_run = subprocess.run(
        [
            str(executable_for(staged)),
            "--host-headless",
            "--host-headless-frames=8",
            f"--host-stats-output={capture}",
            "--host-stats-detail=standard",
            "--host-stats-buffer-mib=1",
            "--host-stats-max-mib=16",
        ],
        cwd=staged.parent,
        stdout=None if verbose else subprocess.PIPE,
        stderr=None if verbose else subprocess.PIPE,
        text=True,
        check=False,
    )
    if recorded_run.returncode != 0:
        if not verbose:
            print(recorded_run.stdout or "")
            print(recorded_run.stderr or "", file=sys.stderr)
        print("FAILED")
        return ["run Observatory probe"]
    if not verbose and "[roc-ray-alloc]" in (recorded_run.stderr or ""):
        print("FAILED")
        return ["Observatory enabled allocation metering printed unsolicited diagnostics"]

    init_sentinel = staged.parent / "observatory-init-ran"
    if not init_sentinel.is_file():
        print("FAILED")
        return ["Observatory probe init sentinel was not created"]
    init_sentinel.unlink()
    unwritable = subprocess.run(
        [
            str(executable_for(staged)),
            "--host-headless",
            "--host-headless-frames=8",
            f"--host-stats-output={staged.parent / 'missing-parent' / 'capture.rrstats'}",
        ],
        cwd=staged.parent,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if unwritable.returncode == 0 or init_sentinel.exists():
        print("FAILED")
        return ["Observatory unwritable output did not fail before init"]

    # Recorder startup owns the destination exclusively and happens before the
    # application's init callback. A second launch must refuse the existing
    # path and leave even its SQLite bytes unchanged.
    capture_before_refusal = capture.read_bytes()
    refusal = subprocess.run(
        [
            str(executable_for(staged)),
            "--host-headless",
            "--host-headless-frames=8",
            f"--host-stats-output={capture}",
            "--host-stats-detail=standard",
        ],
        cwd=staged.parent,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if refusal.returncode == 0 or capture.read_bytes() != capture_before_refusal:
        print("FAILED")
        return ["Observatory existing output was not refused before init"]

    # Exercise the exclusive-create race itself, not only the preliminary
    # existence check: of two simultaneous starts exactly one owns the file.
    race_capture = staged.parent / "race.rrstats"
    race_command = [
        str(executable_for(staged)),
        "--host-headless",
        "--host-headless-frames=8",
        f"--host-stats-output={race_capture}",
        "--host-stats-detail=summary",
    ]
    racers = [
        subprocess.Popen(race_command, cwd=staged.parent, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for _ in range(2)
    ]
    race_codes = [process.communicate()[0] is not None and process.returncode for process in racers]
    if sorted(race_codes) != [0, 1]:
        print("FAILED")
        return [f"Observatory exclusive-create race returned {race_codes!r}"]

    failures: list[str] = []
    try:
        db = sqlite3.connect(f"file:{capture}?mode=ro", uri=True)
        try:
            metadata = dict(db.execute("SELECT key, value FROM metadata"))
            required_metadata = {
                "schema_version": "1",
                "requested_detail": "standard",
                "effective_detail": "standard",
                "clean_shutdown": "1",
                "final_state": "complete",
                "target_profile": "native-headless",
                "backend": "headless_stub",
            }
            for key, expected in required_metadata.items():
                if metadata.get(key) != expected:
                    failures.append(
                        f"Observatory metadata {key}: expected {expected!r}, got {metadata.get(key)!r}"
                    )

            measurement_status = dict(
                db.execute("SELECT name,status FROM measurement_status")
            )
            for measurement in (
                "cycle_summary", "annotations", "hosted_effects", "task_lifecycle",
                "resource_lifecycle", "queue_pressure", "draw_observations",
                "structural_latency", "backend_facts", "callback_summaries",
            ):
                if measurement_status.get(measurement) != "complete":
                    failures.append(
                        f"Observatory measurement {measurement} is not complete: "
                        f"{measurement_status.get(measurement)!r}"
                    )
            if measurement_status.get("allocation_lifecycle") != "not_recorded":
                failures.append(
                    "Observatory standard capture did not identify allocation lifecycle as not recorded"
                )
            if measurement_status.get("gpu_timing") != "unavailable":
                failures.append("Observatory did not identify GPU timing as unavailable")

            for key in (
                "host_os", "host_arch", "rocray_version", "roc_compiler_pin",
                "executable_name", "app_name", "unavailable_sources",
                "chunk_bytes", "chunk_count", "summary_reserve",
                "transaction_chunks", "max_output_bytes", "clock_source",
                "clock_resolution_ns", "utc_origin_unix_ns",
            ):
                if not metadata.get(key):
                    failures.append(f"Observatory metadata {key} is missing or empty")
            unavailable = set(metadata.get("unavailable_sources", "").split(","))
            expected_unavailable = {
                "gpu_timing", "zio_worker_queue_timing", "writer_thread_cpu_time"
            }
            if not expected_unavailable <= unavailable:
                failures.append(
                    f"Observatory unavailable_sources is incomplete: {sorted(unavailable)!r}"
                )

            cycles = db.execute(
                "SELECT count(*), min(cycle), max(cycle), min(duration_ns) FROM cycles"
            ).fetchone()
            if cycles is None or cycles[0] < 2 or cycles[1] != 0 or cycles[3] < 0:
                failures.append(f"Observatory cycle summaries are incomplete: {cycles!r}")

            presented = db.execute(
                "SELECT count(*) FROM gpu_facts WHERE name='presentation_completed'"
            ).fetchone()[0]
            nonzero_presentation = db.execute(
                "SELECT count(*) FROM draw_summaries WHERE value_b<>0"
            ).fetchone()[0]
            if presented != 0 or nonzero_presentation != 0:
                failures.append(
                    "headless Observatory capture claimed presentation: "
                    f"facts={presented}, draw_rows={nonzero_presentation}"
                )

            measured_wait = db.execute(
                "SELECT count(*) FROM hosted_effects "
                "WHERE name='Task.sleep!' AND external_ns IS NOT NULL AND external_ns>0"
            ).fetchone()[0]
            if measured_wait == 0:
                failures.append("Observatory did not persist a measured waiting-effect interval")

            callback_phases = {
                row[0] for row in db.execute("SELECT DISTINCT phase FROM callback_summaries")
            }
            # Task executor polling is host work, not an application callback.
            # Task-body activity is represented by task lifecycle events and
            # task-owned effects/zones rather than a fabricated callback row.
            if callback_phases != {0, 1, 2}:
                failures.append(
                    f"Observatory callback phase coverage is incomplete: {sorted(callback_phases)!r}"
                )

            labels = {
                row[0] for row in db.execute("SELECT DISTINCT name FROM annotations")
            }
            expected_labels = {
                "probe init",
                "probe startup wait",
                "probe update",
                "probe items",
                "load ratio",
                "probe render",
                "probe task wait",
                "probe task annotation",
                "cancel outer",
                "cancel inner",
            }
            missing = expected_labels - labels
            if missing:
                failures.append(f"Observatory annotations missing labels: {sorted(missing)!r}")

            integer_sample = db.execute(
                "SELECT integer_value, real_value FROM annotations WHERE name='probe items'"
            ).fetchone()
            real_sample = db.execute(
                "SELECT integer_value, real_value FROM annotations WHERE name='load ratio'"
            ).fetchone()
            task_zone = db.execute(
                "SELECT wall_ns,active_ns,parked_ns FROM annotations "
                "WHERE name='probe task wait' AND kind=2"
            ).fetchone()
            startup_zone = db.execute(
                "SELECT wall_ns,active_ns,parked_ns FROM annotations "
                "WHERE name='probe startup wait' AND kind=2"
            ).fetchone()
            if integer_sample != (7, None) or real_sample != (None, 0.5):
                failures.append(
                    f"Observatory scalar NULL semantics are invalid: {integer_sample!r}, {real_sample!r}"
                )
            if task_zone is None or task_zone[0] != task_zone[1] + task_zone[2] or task_zone[2] <= 0:
                failures.append(f"Observatory task wait zone timing is invalid: {task_zone!r}")
            unnamed_zone_ids = db.execute(
                "SELECT count(*) FROM annotations WHERE kind IN (1,2,5) AND integer_value IS NULL"
            ).fetchone()[0]
            if unnamed_zone_ids != 0:
                failures.append(
                    f"Observatory omitted {unnamed_zone_ids} Trace zone correlation ID(s)"
                )
            sleep_effect = db.execute(
                "SELECT duration_ns,external_ns,validation_ns,conversion_ns,worker_ns "
                "FROM hosted_effects WHERE name='Task.sleep!' ORDER BY id LIMIT 1"
            ).fetchone()
            if sleep_effect is None or sleep_effect[1] is None or sleep_effect[1] <= 0 or sleep_effect[1] > sleep_effect[0]:
                failures.append(f"Observatory sleep external interval is invalid: {sleep_effect!r}")
            elif sleep_effect[2:] != (None, None, None):
                failures.append(f"Observatory sleep invented unavailable sub-intervals: {sleep_effect!r}")
            if startup_zone is None or startup_zone[0] != startup_zone[1] + startup_zone[2] or startup_zone[2] <= 0:
                failures.append(f"Observatory startup wait zone timing is invalid: {startup_zone!r}")

            aborted = db.execute(
                "SELECT name,timestamp_ns FROM annotations "
                "WHERE kind=5 AND name IN ('cancel inner','cancel outer') ORDER BY id"
            ).fetchall()
            cancellation = db.execute(
                "SELECT timestamp_ns FROM task_events WHERE kind=7 AND name='live' ORDER BY id LIMIT 1"
            ).fetchone()
            if [row[0] for row in aborted] != ["cancel inner", "cancel outer"]:
                failures.append(f"Observatory zone abort order is invalid: {aborted!r}")
            elif cancellation is None or aborted[-1][1] > cancellation[0]:
                failures.append(
                    f"Observatory cancellation did not follow zone aborts: {aborted!r}, {cancellation!r}"
                )

            capture_bytes = capture.read_bytes()
            privacy_sentinels = (
                b"TASK_PAYLOAD_SECRET_178",
                b"INPUT_PAYLOAD_SECRET_178",
                b"FILE_PAYLOAD_SECRET_178",
                b"HTTP_PAYLOAD_SECRET_178",
                b"SQLITE_PAYLOAD_SECRET_178",
                b"CMD_PAYLOAD_SECRET_178",
                b"0x7fffdeadbeef178",
            )
            leaked = [value.decode() for value in privacy_sentinels if value in capture_bytes]
            if leaked:
                failures.append(f"Observatory capture leaked private sentinels: {leaked!r}")

            expected_detail_tables = {
                "task_events",
                "hosted_effects",
                "queue_pressure",
                "resource_lifecycle",
                "structural_latency",
                "draw_summaries",
                "allocation_events",
                "callback_summaries",
            }
            present_detail_tables = {
                row[0]
                for row in db.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            }
            missing_tables = expected_detail_tables - present_detail_tables
            if missing_tables:
                failures.append(
                    f"Observatory schema missing detail tables: {sorted(missing_tables)!r}"
                )

            health = db.execute(
                "SELECT transactions, checkpoints, queue_high_water, output_bytes, "
                "omitted_events, rows_written, writer_failed, output_limited, "
                "writer_active_wall_ns, writer_idle_wall_ns, writer_cpu_ns "
                "FROM recorder_health"
            ).fetchone()
            if health is None or health[0] < 1 or health[1] < 1 or health[3] <= 0 or health[5] < 1:
                failures.append(f"Observatory recorder health is incomplete: {health!r}")
            elif health[6] != 0 or health[7] != 0:
                failures.append(f"Observatory recorder unexpectedly stopped early: {health!r}")
            elif health[8] < 0 or health[9] < 0 or health[10] is not None:
                failures.append(f"Observatory recorder timing disclosure is invalid: {health!r}")

            # The table is required even in a loss-free capture. Its aggregate
            # must agree with the recorder's cumulative omission counter.
            gap_total = db.execute(
                "SELECT coalesce(sum(lost_count), 0) FROM recording_gaps"
            ).fetchone()[0]
            if health is not None and gap_total != health[4]:
                failures.append(
                    f"Observatory gap total {gap_total} disagrees with health omissions {health[4]}"
                )
        finally:
            db.close()
    except (OSError, sqlite3.Error) as err:
        failures.append(f"query Observatory capture: {err}")

    abrupt_fixture = root / "test" / "observatory_abrupt" / "main.roc"
    abrupt_staged = local_bundles.stage_app(
        abrupt_fixture, packages, packages.scratch_dir / "observatory-abrupt"
    )
    if not run_cmd(
        ["roc", "build", abrupt_staged.name, *LIMITS],
        "build abrupt Observatory probe",
        verbose,
        cwd=abrupt_staged.parent,
    ):
        failures.append("build abrupt Observatory probe")
    else:
        abrupt_capture = abrupt_staged.parent / "abrupt.rrstats"
        process = subprocess.Popen(
            [
                str(executable_for(abrupt_staged)),
                "--host-headless",
                "--host-headless-frames=1000000000",
                f"--host-stats-output={abrupt_capture}",
                "--host-stats-detail=summary",
            ],
            cwd=abrupt_staged.parent,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        committed = False
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and process.poll() is None:
            try:
                probe_db = sqlite3.connect(f"file:{abrupt_capture}?mode=ro", uri=True)
                try:
                    committed = probe_db.execute("SELECT count(*) FROM cycles").fetchone()[0] > 0
                finally:
                    probe_db.close()
            except sqlite3.Error:
                pass
            if committed:
                break
            time.sleep(0.01)
        process.kill()
        process.wait(timeout=5)
        try:
            killed_db = sqlite3.connect(f"file:{abrupt_capture}?mode=ro", uri=True)
            try:
                killed_metadata = dict(killed_db.execute("SELECT key,value FROM metadata"))
                killed_cycles = killed_db.execute("SELECT count(*) FROM cycles").fetchone()[0]
            finally:
                killed_db.close()
            if not committed or killed_cycles == 0:
                failures.append("abrupt Observatory capture has no recoverable committed prefix")
            if killed_metadata.get("clean_shutdown") != "0" or killed_metadata.get("final_state") != "recording":
                failures.append(
                    "abrupt Observatory capture was not left explicitly unclean: "
                    f"{killed_metadata.get('clean_shutdown')!r}, {killed_metadata.get('final_state')!r}"
                )
        except (OSError, sqlite3.Error) as err:
            failures.append(f"reopen abrupt Observatory capture: {err}")

    print("ok" if not failures else "FAILED")
    return failures


def observatory_privacy_leaks(capture: Path, sentinels: tuple[bytes, ...]) -> list[str]:
    """Return sentinels found in raw capture bytes or any SQLite TEXT cell."""
    leaked: set[str] = set()
    raw = capture.read_bytes()
    leaked.update(value.decode("utf-8", "replace") for value in sentinels if value in raw)
    db = sqlite3.connect(f"file:{capture}?mode=ro", uri=True)
    try:
        for (table,) in db.execute("SELECT name FROM sqlite_master WHERE type='table'"):
            columns = [
                row[1] for row in db.execute(f'SELECT * FROM pragma_table_info("{table}")')
                if "TEXT" in row[2].upper()
            ]
            for column in columns:
                for (value,) in db.execute(f'SELECT "{column}" FROM "{table}" WHERE "{column}" IS NOT NULL'):
                    encoded = value.encode("utf-8")
                    leaked.update(secret.decode("utf-8", "replace") for secret in sentinels if secret in encoded)
    finally:
        db.close()
    return sorted(leaked)


def run_task_cap_probe(
    root: Path, packages: local_bundles.ServedPackages, verbose: bool
) -> list[str]:
    """Check that spawning past the host's live-task cap queues rather than drops.

    A hundred tasks in one `update!`, against a cap of 32. The closures past the
    cap have to wait for a slot and still run -- `Task.spawn!` has no error to
    report, so a dropped one would simply never answer -- and the frame's phase
    has to survive the burst, since spawning hands control to the executor.
    Exit 3 means a message was lost, repeated or wrong; exit 4 means the queue
    never drained.
    """
    fixture = root / "test" / "task_cap" / "main.roc"
    if not fixture.is_file():
        return []

    print("\nRunning task cap probe...", end=" ", flush=True)
    staged = local_bundles.stage_app(fixture, packages, packages.scratch_dir / "task_cap")
    if not run_cmd(
        ["roc", "build", staged.name, *LIMITS], "build task cap probe", verbose, cwd=staged.parent
    ):
        print("FAILED")
        return ["build task cap probe"]

    ok = run_cmd(
        [
            str(executable_for(staged)),
            "--host-headless",
            "--host-headless-frames=400",
        ],
        "run task cap probe",
        verbose,
        cwd=root,
    )
    print("ok" if ok else "FAILED")
    return [] if ok else ["run task cap probe"]


def run_file_write_probe(
    root: Path, packages: local_bundles.ServedPackages, verbose: bool
) -> list[str]:
    """Check that a file written by `Files.write_*` reads back byte for byte.

    A write that wrote nothing, wrote somewhere else, appended instead of
    replacing, or left the tail of longer previous contents behind would pass
    every other stage here: nothing else in the suite reads a file the app
    wrote. The probe writes text and bytes, reads the same paths back, compares
    them, and also checks that missing parent directories are created and that
    a path whose parent is a file is refused by name.

    It runs from the staged scratch directory and only touches `probe_out/`
    beneath it, so it never writes into the tree. Exit 3 means a property did
    not hold; exit 4 means the task never answered.
    """
    fixture = root / "test" / "file_write" / "main.roc"
    if not fixture.is_file():
        return []

    print("\nRunning file write probe...", end=" ", flush=True)
    staged = local_bundles.stage_app(fixture, packages, packages.scratch_dir / "file_write")
    if not run_cmd(
        ["roc", "build", staged.name, *LIMITS], "build file write probe", verbose, cwd=staged.parent
    ):
        print("FAILED")
        return ["build file write probe"]

    ok = run_cmd(
        [
            str(executable_for(staged)),
            "--host-headless",
            "--host-headless-frames=200",
            f"--host-stats-output={staged.parent / 'file-privacy.rrstats'}",
            "--host-stats-detail=full",
        ],
        "run file write probe",
        verbose,
        cwd=staged.parent,
    )
    leaks = observatory_privacy_leaks(staged.parent / "file-privacy.rrstats", ("roc-ray file write probe\nsecond line\né✓\n".encode(),)) if ok else []
    print("ok" if ok and not leaks else "FAILED")
    return [] if ok and not leaks else [f"file privacy leak: {leaks!r}" if leaks else "run file write probe"]


def run_cmd_probe(
    root: Path, packages: local_bundles.ServedPackages, verbose: bool
) -> list[str]:
    """Check that `Cmd.run!` starts a real program, bounds it, and parks.

    Nothing else in the suite starts a subprocess, so a `run!` that captured
    nothing, ignored its deadline, confused a missing program with a failing
    one, or blocked the frame loop instead of parking its task would pass every
    other stage. The probe runs six commands through the machine's own shell --
    `/bin/sh`, or `cmd.exe` on Windows, chosen by the app itself -- and asserts
    on what came back as well as on how many frames were drawn meanwhile.

    Nothing it runs writes a file or reaches the network. Exit 3 means a
    property did not hold; exit 4 means the task never answered.
    """
    fixture = root / "test" / "cmd" / "main.roc"
    if not fixture.is_file():
        return []

    print("\nRunning subprocess probe...", end=" ", flush=True)
    staged = local_bundles.stage_app(fixture, packages, packages.scratch_dir / "cmd")
    if not run_cmd(
        ["roc", "build", staged.name, *LIMITS], "build cmd probe", verbose, cwd=staged.parent
    ):
        print("FAILED")
        return ["build cmd probe"]

    ok = run_cmd(
        [
            str(executable_for(staged)),
            "--host-headless",
            "--host-headless-frames=400",
            f"--host-stats-output={staged.parent / 'cmd-privacy.rrstats'}",
            "--host-stats-detail=full",
        ],
        "run cmd probe",
        verbose,
        cwd=staged.parent,
    )
    leaks = observatory_privacy_leaks(staged.parent / "cmd-privacy.rrstats", (b"roc-ray-cmd-probe",)) if ok else []
    print("ok" if ok and not leaks else "FAILED")
    return [] if ok and not leaks else [f"cmd privacy leak: {leaks!r}" if leaks else "run cmd probe"]


def run_udp_probe(
    root: Path, packages: local_bundles.ServedPackages, verbose: bool
) -> list[str]:
    """Check that datagrams arrive with the right bytes from the right sender.

    Three properties nothing else in the suite covers. First, a datagram sent
    from one socket reaches another and reports the address it actually came
    from -- the probe replies to that reported address rather than to the one
    it already knows, so a receive that named the wrong peer sends the pong
    into the void and the run times out. Second, `receive!` parks its task
    instead of blocking: the timeout half asserts that several frames were
    drawn while a task sat in a 200 ms receive, which a blocking implementation
    could not manage. Third, each hop is delivered within a few cycles of the
    task parking on it: a frame loop that does not poll the event loop every
    frame still completes the round trip, just several frames after the
    datagrams were ready, and only a bound on the delay catches that. The
    bound holds here but bites in a window: headless pacing sleeps the frame
    loop, which polls the event loop whatever the pump does, so a run with a
    real window is what puts the third property under load.

    Loopback only, on ephemeral ports, so it needs no network and cannot
    collide with anything else on the machine. Exit 3 means a property did not
    hold; exit 4 means nothing arrived in time.
    """
    fixture = root / "test" / "udp" / "main.roc"
    if not fixture.is_file():
        return []

    print("\nRunning UDP socket probe...", end=" ", flush=True)
    staged = local_bundles.stage_app(fixture, packages, packages.scratch_dir / "udp")
    if not run_cmd(
        ["roc", "build", staged.name, *LIMITS], "build udp probe", verbose, cwd=staged.parent
    ):
        print("FAILED")
        return ["build udp probe"]

    failures: list[str] = []
    for label, extra in (("round trip", []), ("timeout", ["--udp-expect-timeout"])):
        ok = run_cmd(
            [
                str(executable_for(staged)),
                "--host-headless",
                "--host-headless-frames=300",
                *extra,
            ],
            f"run udp probe ({label})",
            verbose,
            cwd=staged.parent,
        )
        if not ok:
            failures.append(f"run udp probe ({label})")
    print("ok" if not failures else "FAILED")
    return failures


def run_virtual_keys_probe(
    root: Path, packages: local_bundles.ServedPackages, verbose: bool
) -> list[str]:
    """Check that a scripted keyboard arrives as ordinary keyboard input.

    A headless run asserts only an exit code, so an app whose scripted keys
    never reached it would still pass every other stage. The probe installs a
    virtual source and queues text on one cycle and asserts what the next cycle
    was handed: exactly one pressed edge for a newly held key, a plain down
    while it stays held, released when the script lets go, and the codepoints
    delivered on one cycle and gone from the next. Exit 3 means a property did
    not hold; exit 4 means the script never reached its verdict.
    """
    fixture = root / "test" / "virtual_keys" / "main.roc"
    if not fixture.is_file():
        return []

    print("\nRunning virtual keyboard probe...", end=" ", flush=True)
    staged = local_bundles.stage_app(fixture, packages, packages.scratch_dir / "virtual_keys")
    if not run_cmd(
        ["roc", "build", staged.name, *LIMITS], "build virtual keys probe", verbose, cwd=staged.parent
    ):
        print("FAILED")
        return ["build virtual keys probe"]

    ok = run_cmd(
        [str(executable_for(staged)), "--host-headless", "--host-headless-frames=8", f"--host-stats-output={staged.parent / 'input-privacy.rrstats'}", "--host-stats-detail=full"],
        "run virtual keys probe",
        verbose,
        cwd=staged.parent,
    )
    leaks = observatory_privacy_leaks(staged.parent / "input-privacy.rrstats", (b"INPUT_PAYLOAD_SECRET_178",)) if ok else []
    print("ok" if ok and not leaks else "FAILED")
    return [] if ok and not leaks else [f"input privacy leak: {leaks!r}" if leaks else "run virtual keys probe"]


def run_sqlite_probe(
    root: Path, packages: local_bundles.ServedPackages, verbose: bool
) -> list[str]:
    """Check that a value written to a database comes back as itself.

    Nothing else in the suite runs a query, so a binding that bound the wrong
    column, a decoder that read the wrong cell, a payload offset off by one, or
    an error that arrived as success would pass every other stage. The probe
    writes one row holding all five `Value` kinds, reads it back, compares each
    one, reuses a prepared statement, and walks the error paths an app is most
    likely to hit.

    It runs from the staged scratch directory and only touches `probe_out/`
    beneath it, so it never writes into the tree. Exit 3 means a property did
    not hold.
    """
    fixture = root / "test" / "sqlite" / "main.roc"
    if not fixture.is_file():
        return []

    print("\nRunning sqlite probe...", end=" ", flush=True)
    staged = local_bundles.stage_app(fixture, packages, packages.scratch_dir / "sqlite")
    if not run_cmd(
        ["roc", "build", staged.name, *LIMITS], "build sqlite probe", verbose, cwd=staged.parent
    ):
        print("FAILED")
        return ["build sqlite probe"]

    ok = run_cmd(
        [
            str(executable_for(staged)),
            "--host-headless",
            "--host-headless-frames=200",
            f"--host-stats-output={staged.parent / 'sqlite-privacy.rrstats'}",
            "--host-stats-detail=full",
        ],
        "run sqlite probe",
        verbose,
        cwd=staged.parent,
    )
    leaks = observatory_privacy_leaks(staged.parent / "sqlite-privacy.rrstats", ("row one\nsecond lineé✓".encode(),)) if ok else []
    print("ok" if ok and not leaks else "FAILED")
    return [] if ok and not leaks else [f"sqlite privacy leak: {leaks!r}" if leaks else "run sqlite probe"]


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
        ["roc", "build", staged.name, *LIMITS], "build model allocation probe", verbose, cwd=staged.parent
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
        if run_cmd(["roc", command, staged.name, *LIMITS], f"interop {command}", verbose, cwd=staged.parent):
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
                ["roc", command, staged.name, *LIMITS],
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
                '"libraylib.a", "libmsf_gif.a", "libvpx.a", "libsqlite3.a", "libm.so", app, '
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
            "targets/x64glibc/libsqlite3.a",
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
        "--windowed",
        dest="windowed",
        action="store_true",
        default=True,
        help="Run the windowed sweep from scripts/test_spec.json (the default)",
    )
    parser.add_argument(
        "--skip-windowed",
        dest="windowed",
        action="store_false",
        help=(
            "Skip the windowed sweep. It opens a real (hidden) window per case, "
            "so it needs a display server; on Linux use xvfb-run"
        ),
    )
    parser.add_argument(
        "--windowed-dll-dir",
        metavar="DIR",
        default=os.environ.get("ROC_RAY_WINDOWED_DLL_DIR"),
        help=(
            "Copy every *.dll in DIR beside each built example before the "
            "windowed sweep (also settable with ROC_RAY_WINDOWED_DLL_DIR). CI "
            "uses it for the Mesa opengl32.dll a Windows runner needs"
        ),
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
        print("  Formatting platform modules...", end=" ", flush=True)
        platform_modules = sorted((root / "platform").glob("*.roc"))
        if run_cmd(
            ["roc", "fmt", "--check", *map(str, platform_modules)],
            "fmt platform",
            args.verbose,
        ):
            print("ok")
        else:
            print("FAILED")
            failed.append("roc fmt platform")
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
                ["roc", "check", staged[example].name, *LIMITS],
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
                    ["roc", "test", staged[example].name, *LIMITS],
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
                ["roc", "build", staged[example].name, *LIMITS],
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

    # The windowed sweep is its own stage rather than part of the headless
    # block: CI runs the headless stage on every runner and then the windowed
    # one under a virtual display, and each has to be selectable alone.
    if not args.windowed:
        print("\nSkipping windowed runtime (--skip-windowed)")
    elif args.skip_roc_build:
        print("\nSkipping windowed runtime (--skip-roc-build)")
    else:
        failed.extend(
            run_windowed_examples(
                root,
                built,
                load_test_spec(root),
                args.verbose,
                Path(args.windowed_dll_dir).resolve() if args.windowed_dll_dir else None,
            )
        )
        failed.extend(run_graphical_observatory_probe(root, built, args.verbose))

    if not (args.skip_runtime or args.skip_roc_build):
        failed.extend(run_cli_args_integration(root, packages, args.verbose))
        failed.extend(run_observatory_probe(root, packages, args.verbose))
        failed.extend(run_task_delivery_probe(root, packages, args.verbose))
        failed.extend(run_task_cap_probe(root, packages, args.verbose))
        failed.extend(run_file_write_probe(root, packages, args.verbose))
        failed.extend(run_udp_probe(root, packages, args.verbose))
        failed.extend(run_virtual_keys_probe(root, packages, args.verbose))
        failed.extend(run_cmd_probe(root, packages, args.verbose))
        failed.extend(run_sqlite_probe(root, packages, args.verbose))
        failed.extend(run_model_allocation_check(root, packages, args.verbose))
        failed.extend(test_http_client.run_http_client_test(packages, args.verbose))

    return failed


if __name__ == "__main__":
    sys.exit(main())
