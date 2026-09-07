#!/usr/bin/env python3
"""Stage and serve the RocRay platform for local checks and example runs.

Bundle mode exercises the release dependency shape over localhost. Source mode
copies platform modules and links native inputs into a scratch directory.
Applications are always copied before their platform reference is rewritten;
no checked-in file is modified, including on interrupted runs.
"""

from __future__ import annotations

import atexit
import functools
import hashlib
import http.server
import os
import platform as platform_module
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path

IS_WINDOWS = platform_module.system() == "Windows"

# Scratch directories are created outside the repository so no exit path can
# dirty the working tree. The shared prefix lets a later run tidy up after one
# that was SIGKILLed.
#
# The prefix must NOT begin with "roc-": `cleanupLegacyTempDirs` in the
# compiler's src/compile/cache_cleanup.zig deletes every `roc-*` directory
# sitting in the system temp root, with no age check, on every `roc` invocation.
# A staging directory named that way is removed the moment the first `roc check`
# runs, and the symptom is a baffling "FileNotFound" for a file that was written
# a second earlier.
SCRATCH_PREFIX = "rr-local-bundles-"
STALE_SCRATCH_SECONDS = 24 * 60 * 60

# `roc` refuses a direct dependency whose transitive packages decompress to more
# than 100 MB, and a roc-ray platform bundle built by a plain `zig build` is over
# that: a Debug host archive carries the whole of `std.crypto` for the HTTP
# client's TLS, four times over, which is about 90 MB of the 125 MB bundle. The
# `-Doptimize=ReleaseFast` archives a release actually ships are around 10 MB, so
# this is a property of a locally built platform rather than of a published one.
#
# Every roc invocation that resolves a locally bundled platform therefore raises
# the limit. It is raised, not removed, so a genuine runaway dependency is still
# caught. Undocumented in `roc build --help` and `roc test --help`, but accepted
# by both.
PACKAGE_LIMIT_ARGS = ["--max-transitive-mb=512"]

# The platform reference in an app header: `app [..] { rr: platform "<ref>" }`.
# Deliberately broader than the release-flow regex in release_helpers.py so that
# an already-rewritten header (a localhost URL from an outer CI step, say) is
# still recognized and re-pointed rather than silently left alone.
PLATFORM_REF_RE = re.compile(r'platform\s+"[^"]*"')

# Kept for callers that only ever deal with the two checked-in forms.
LOCAL_PLATFORM_REF = '"../../platform/main.roc"'
RELEASE_PLATFORM_REF_RE = re.compile(
    r'"https://github\.com/lukewilliamboswell/roc-ray/releases/download/[^"]+\.tar\.zst"'
)


class LocalBundleError(RuntimeError):
    """Something went wrong bundling or serving the local packages."""


# --------------------------------------------------------------------------
# Pinned compiler
# --------------------------------------------------------------------------


def read_roc_pin(root: Path) -> str:
    """The development compiler declared by the platform header."""
    from roc_platform_abi import GlueError, read_pin
    try:
        return read_pin(root / "platform" / "main.roc").nightly
    except GlueError:
        return ""



def rewrite_compiler_pin(source: str, pin: str) -> str:
    """Rebind an application header in a development or release-candidate copy."""
    rewritten, count = re.subn(
        r'(?m)^([^#\n]*\broc\s*:\s*)"[^"\n]+"',
        lambda match: match.group(1) + '"' + pin + '"',
        source,
        count=1,
    )
    if count != 1:
        raise LocalBundleError("application header must declare one roc compiler pin")
    return rewritten


def roc_version(roc: str = "roc") -> str:
    try:
        result = subprocess.run(
            [roc, "version"], capture_output=True, text=True, timeout=60, shell=IS_WINDOWS
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def check_roc_pin(root: Path, roc: str = "roc") -> str | None:
    """Return a warning when the compiler on PATH is not the pinned nightly.

    A mismatched compiler is the usual cause of "mysterious" panics and of
    errors that look like they come from the package under test, so say so
    loudly. This is advisory rather than fatal: platform work routinely runs
    against a locally built compiler.

    A build of the pinned revision counts as a match even though it reports its
    build mode instead of the tag -- `release-fast-fb208ba` is the compiler
    `nightly-2026-08-23-fb208ba` names. `roc_platform_abi.compiler_matches_pin`
    is the shared rule; this falls back to a plain comparison if that module
    cannot parse the pin.
    """
    pinned = read_roc_pin(root)
    if not pinned:
        return None
    observed = roc_version(roc)
    if observed and _matches_pin(observed, pinned):
        return None
    return (
        f"WARNING: the Roc compiler on PATH does not match platform/main.roc ({pinned}); "
        f"found {observed or '<unknown>'}. Failures below may be the compiler, "
        "not this repository."
    )


def _matches_pin(observed: str, pinned: str) -> bool:
    try:
        import roc_platform_abi

        return roc_platform_abi.compiler_matches_pin(
            observed, roc_platform_abi.read_pin()
        )
    except Exception:  # noqa: BLE001 - never let a version hint break the run
        return pinned in observed


# --------------------------------------------------------------------------
# Header rewriting
# --------------------------------------------------------------------------


def rewrite_platform_ref(source: str, replacement: str) -> tuple[str, bool]:
    """Point an app header at `replacement` (a quoted ref, e.g. '"http://..."').

    Returns the rewritten text and whether anything changed.
    """
    rewritten, count = PLATFORM_REF_RE.subn(f"platform {replacement}", source, count=1)
    return rewritten, count > 0


def quote_ref(ref: str) -> str:
    """Quote a URL or path for use in a Roc header (forward slashes throughout)."""
    return '"' + str(ref).replace("\\", "/") + '"'


# --------------------------------------------------------------------------
# Serving
# --------------------------------------------------------------------------


def _prune_stale_scratch(extra_root: Path | None = None) -> None:
    """Remove scratch directories left behind by a SIGKILLed run."""
    cutoff = time.time() - STALE_SCRATCH_SECONDS
    candidates: list[Path] = []
    roots = [Path(tempfile.gettempdir())]
    if extra_root is not None and extra_root not in roots:
        roots.append(extra_root)
    for scratch_root in roots:
        try:
            candidates.extend(scratch_root.glob(f"{SCRATCH_PREFIX}*"))
        except OSError:
            pass
    for candidate in candidates:
        try:
            if candidate.is_dir() and candidate.stat().st_mtime < cutoff:
                shutil.rmtree(candidate, ignore_errors=True)
        except OSError:
            pass


def preferred_ports(root: Path, count: int = 8) -> list[int]:
    """Loopback ports to try before falling back to an OS-assigned one.

    Derived from the checkout's path so repeated runs in the same working tree
    reuse the same URL -- and therefore the same platform bundle hash, and
    therefore the Roc package cache entry the previous run already populated.
    Different checkouts get different candidates, and a taken port simply moves
    to the next one.
    """
    digest = hashlib.sha256(str(root).encode("utf-8")).digest()
    base = 40000 + int.from_bytes(digest[:2], "big") % 20000
    return [base + offset for offset in range(count)]


@contextmanager
def serve_directory(directory: Path, verbose: bool = False, ports: list[int] | None = None):
    """Serve `directory` over HTTP on localhost; yield the base URL.

    Each port in `ports` is tried in turn, then port 0, which lets the OS pick a
    free ephemeral port so concurrent runs and CI jobs cannot collide. Binding
    to 127.0.0.1 keeps the server off the network entirely.
    """

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):  # silence per-request logging
            if verbose:
                super().log_message(*args)

    handler = functools.partial(Handler, directory=str(directory))
    httpd: http.server.ThreadingHTTPServer | None = None
    for candidate in [*(ports or []), 0]:
        try:
            httpd = http.server.ThreadingHTTPServer(("127.0.0.1", candidate), handler)
            break
        except OSError:
            continue
    if httpd is None:  # pragma: no cover - port 0 does not realistically fail
        raise LocalBundleError("could not bind an HTTP server on 127.0.0.1")

    port = httpd.server_address[1]
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        httpd.shutdown()
        httpd.server_close()


def wait_for_url(url: str, attempts: int = 10) -> bool:
    """Return True once a served URL answers, False after `attempts` tries."""
    request = urllib.request.Request(url, method="HEAD")
    last_error: Exception | None = None
    for _ in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                if response.status == 200:
                    return True
                last_error = RuntimeError(f"HTTP {response.status}")
        except Exception as err:  # noqa: BLE001 - report whatever went wrong
            last_error = err
        time.sleep(0.2)
    print(f"  Local bundle URL was not reachable: {url}")
    if last_error is not None:
        print(f"  Last error: {last_error}")
    return False


# --------------------------------------------------------------------------
# Bundling
# --------------------------------------------------------------------------


def _created_paths(output: str) -> list[str]:
    """Every `Created: <path>` line `roc bundle` printed."""
    created = []
    for line in output.splitlines():
        if line.startswith("Created:"):
            # Git Bash reports backslash separators; take the basename either way.
            created.append(re.split(r"[\\/]", line.split(":", 1)[1].strip())[-1])
    return created


def _bundle_env(output_dir: Path) -> dict[str, str]:
    """Environment that keeps Roc's temporary archive on the output volume."""
    env = os.environ.copy()
    if IS_WINDOWS:
        # Different Windows runtimes consult different members of this family.
        # Set all three because Roc creates the archive through a temporary file
        # before atomically renaming it into --output-dir; a rename across the
        # runner's C: and D: volumes fails with CrossDevice.
        bundle_temp = str(output_dir.resolve())
        env["TEMP"] = bundle_temp
        env["TMP"] = bundle_temp
        env["TMPDIR"] = bundle_temp
    return env


def find_bash() -> str | None:
    """Locate bash, including the Git Bash that Windows runners ship.

    `bundle.sh` is the only thing here that needs a shell, and on Windows it is
    reachable through Git's bash even when PATH lookup misses it.
    """
    found = shutil.which("bash")
    if found:
        return found
    if not IS_WINDOWS:
        return None
    for candidate in (
        Path(os.environ.get("PROGRAMFILES", r"C:\Program Files")) / "Git" / "bin" / "bash.exe",
        Path(os.environ.get("PROGRAMFILES(X86)", r"C:\Program Files (x86)"))
        / "Git"
        / "bin"
        / "bash.exe",
    ):
        if candidate.is_file():
            return str(candidate)
    return None


def bundle_platform(
    root: Path,
    output_dir: Path,
    package: str = "default",
    roc: str = "roc",
) -> str:
    """Bundle the platform into `output_dir` via `scripts/bundle.sh`.

    `bundle.sh` owns the modules, native inputs, and notices in the archive.
    Return the platform bundle filename.
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    env = {**_bundle_env(output_dir), "ROC": roc}
    bash = find_bash()
    if bash is None:
        raise LocalBundleError("bash was not found, and scripts/bundle.sh needs it")
    try:
        result = subprocess.run(
            [
                bash,
                str(root / "scripts" / "bundle.sh"),
                "--platform",
                package,
                "--output-dir",
                str(output_dir),
            ],
            cwd=root,
            capture_output=True,
            text=True,
            env=env,
        )
    except OSError as err:
        raise LocalBundleError(f"could not run scripts/bundle.sh: {err}") from err

    if result.returncode != 0:
        raise LocalBundleError(
            "scripts/bundle.sh failed:\n"
            + (result.stdout.strip() + "\n" + result.stderr.strip()).strip()
        )

    created = _created_paths(result.stdout)
    if not created:
        raise LocalBundleError(
            "could not determine the platform bundle filename from:\n" + result.stdout
        )

    return created[-1]


def stage_platform_source(root: Path, dest: Path) -> Path:
    """Copy the platform's `.roc` files to `dest`, preserving module paths.

    `targets/` is linked (or copied when links are unavailable) so the header's
    `inputs_dir: "targets/"` still resolves. Returns the staged `main.roc`.
    """
    dest.mkdir(parents=True, exist_ok=True)
    for module in sorted((root / "platform").rglob("*.roc")):
        relative = module.relative_to(root / "platform")
        if relative.parts[0] == "targets":
            continue
        target = dest / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(module, target)
    staged_main = dest / "main.roc"

    targets_src = root / "platform" / "targets"
    targets_dest = dest / "targets"
    if not targets_dest.exists():
        try:
            targets_dest.symlink_to(targets_src, target_is_directory=True)
        except (OSError, NotImplementedError):
            # Windows without developer mode, or a filesystem with no links.
            shutil.copytree(targets_src, targets_dest)
    return staged_main


# --------------------------------------------------------------------------
# The whole flow
# --------------------------------------------------------------------------


@dataclass
class ServedPackages:
    """Where an example should look for the platform."""

    mode: str  # "bundle" or "source"
    base_url: str
    platform_url: str | None  # set in "bundle" mode
    platform_source: Path | None  # staged main.roc, set in "source" mode
    served_dir: Path
    scratch_dir: Path
    compiler_pin: str = ""
    notes: list[str] = field(default_factory=list)

    @property
    def platform_ref(self) -> str:
        """A human-readable description of what the platform resolves to."""
        return self.platform_url or str(self.platform_source)

    def ref_for(self, staged_dir: Path) -> str:
        """The `platform "..."` value for an app staged in `staged_dir`.

        In source mode this has to be *relative*: `roc check` and `roc build`
        accept an absolute platform path, but `roc run` rejects it outright with
        "Absolute paths are not allowed for platform specifications", so an
        absolute ref works right up until someone runs the example.
        """
        if self.platform_url is not None:
            return self.platform_url
        if self.platform_source is None:  # pragma: no cover - constructor invariant
            raise LocalBundleError("no platform reference is available")
        return os.path.relpath(self.platform_source, staged_dir).replace("\\", "/")


@contextmanager
def serve_packages(
    root: Path,
    package: str = "default",
    mode: str = "auto",
    verbose: bool = False,
    roc: str = "roc",
    stable_port: bool = True,
):
    """Bundle and serve roc-ray's packages; yield a `ServedPackages`.

    `mode` is "auto" (bundle the platform if possible, else stage its source),
    "bundle" (fail if the platform cannot be bundled) or "source".
    `stable_port` prefers this checkout's derived port so the bundle hashes --
    and the Roc package cache entries behind them -- stay put between runs.

    Everything lives in a scratch directory outside the repository, so no exit
    path -- including SIGKILL -- can dirty the working tree.
    """
    if mode not in ("auto", "bundle", "source"):
        raise LocalBundleError(f"unknown platform mode: {mode!r}")

    windows_scratch_root = root.parent if IS_WINDOWS else None
    _prune_stale_scratch(windows_scratch_root)
    # Roc's Windows bundler currently creates its internal temporary archive on
    # the source volume even when TEMP/TMP/TMPDIR point elsewhere. Put our
    # scratch output beside (but outside) the checkout so its final atomic
    # rename cannot cross from the runner's D: workspace to its C: system temp.
    scratch = Path(tempfile.mkdtemp(prefix=SCRATCH_PREFIX, dir=windows_scratch_root))

    # A last-ditch cleanup for exits that skip the finally block below. Register
    # a closure so unregistering removes this one rather than every rmtree any
    # caller happens to have registered.
    def _cleanup_scratch() -> None:
        shutil.rmtree(scratch, ignore_errors=True)

    atexit.register(_cleanup_scratch)
    served = scratch / "served"
    served.mkdir(parents=True, exist_ok=True)
    notes: list[str] = []
    ports = preferred_ports(root) if stable_port else None

    try:
        with serve_directory(served, verbose, ports) as base_url:
            platform_url: str | None = None
            resolved_mode = mode
            if mode in ("auto", "bundle"):
                try:
                    platform_name = bundle_platform(
                        root, served, package=package, roc=roc
                    )
                    platform_url = f"{base_url}/{platform_name}"
                    if not wait_for_url(platform_url):
                        raise LocalBundleError(
                            f"platform bundle not reachable at {platform_url}"
                        )
                    resolved_mode = "bundle"
                except LocalBundleError as err:
                    if mode == "bundle":
                        raise
                    notes.append(f"platform bundling unavailable, using source: {err}")
                    resolved_mode = "source"

            platform_source: Path | None = None
            if resolved_mode != "bundle":
                platform_source = stage_platform_source(
                    root, scratch / "platform-src"
                )
                platform_url = None
                resolved_mode = "source"

            yield ServedPackages(
                mode=resolved_mode,
                base_url=base_url,
                platform_url=platform_url,
                platform_source=platform_source,
                served_dir=served,
                scratch_dir=scratch,
                compiler_pin=read_roc_pin(root),
                notes=notes,
            )
    finally:
        _cleanup_scratch()
        atexit.unregister(_cleanup_scratch)


def stage_app(entry: Path, packages: "ServedPackages", dest: Path) -> Path:
    """Copy the app rooted at `entry.parent` to `dest`, pinned to the served packages.

    Every `.roc` file under the app directory comes along, because an app is a
    directory here: `cave_climb` has a sibling `Cave.roc`, and
    local application modules may sit in nested directories.

    Assets are otherwise left where they are: they are opened at runtime through
    an `Assets.Store`, and the built executable is run from the repository root
    so `examples/<name>/assets/...` still resolves. The exception is a file
    embedded at *compile* time -- `import "assets/fonts/X.ttf" as bytes` -- which
    the compiler resolves relative to the source file, and so has to exist beside
    the staged copy. Those are found by `embedded_paths` and copied too.

    The entrypoint's `platform "..."` is pointed at the served platform. Other
    package dependencies are preserved. Checked-in headers are never touched,
    so a killed run leaves nothing to restore.

    Returns the staged entrypoint.
    """
    source_dir = entry.parent
    dest.mkdir(parents=True, exist_ok=True)
    for module in sorted(source_dir.rglob("*.roc")):
        target = dest / module.relative_to(source_dir)
        target.parent.mkdir(parents=True, exist_ok=True)
        source_text = module.read_text(encoding="utf-8")
        target.write_text(source_text, encoding="utf-8")
        stage_embedded(module, source_text, source_dir, dest)

    staged_entry = dest / entry.name
    quoted = quote_ref(packages.ref_for(dest))
    rewritten, did_rewrite = rewrite_platform_ref(
        staged_entry.read_text(encoding="utf-8"), quoted
    )
    if not did_rewrite:
        raise LocalBundleError(f"no platform reference to rewrite in {entry}")
    rewritten = rewrite_compiler_pin(rewritten, packages.compiler_pin)
    staged_entry.write_text(rewritten, encoding="utf-8")
    return staged_entry


EMBEDDED_IMPORT = re.compile(r'^\s*import\s+"([^"]+)"', re.MULTILINE)


def embedded_paths(text: str) -> list[str]:
    """The file paths a module embeds at compile time, in source order.

    `import "assets/fonts/X.ttf" as bytes : List(U8)` reads the file while the
    module is being compiled, so unlike an `Assets.Store` path it is resolved
    relative to the source file rather than the working directory.
    """
    return EMBEDDED_IMPORT.findall(text)


def stage_embedded(module: Path, text: str, source_dir: Path, dest: Path) -> None:
    """Copy whatever `module` embeds at compile time next to its staged copy.

    Paths are resolved relative to the importing module, and refused if they
    reach outside the app directory: staging is a copy of one directory, and a
    module that reaches past it would compile here and not from a bundle.
    """
    for relative in embedded_paths(text):
        embedded = (module.parent / relative).resolve()
        try:
            within = embedded.relative_to(source_dir.resolve())
        except ValueError:
            raise LocalBundleError(
                f"{module} embeds {relative}, which is outside {source_dir}"
            ) from None
        if not embedded.is_file():
            raise LocalBundleError(f"{module} embeds {relative}, which does not exist")
        target = dest / within
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(embedded, target)


def stage_apps(
    entries: list[Path], packages: "ServedPackages", dest_root: Path
) -> dict[Path, Path]:
    """Stage several apps under `dest_root`, one directory each.

    Returns {original entrypoint: staged entrypoint}.
    """
    staged: dict[Path, Path] = {}
    for entry in entries:
        staged[entry] = stage_app(entry, packages, dest_root / entry.parent.name)
    return staged


@contextmanager
def terminating_signals():
    """Turn SIGTERM/SIGINT into SystemExit so `finally` cleanup still runs.

    Nothing tracked is ever mutated, so this is about releasing the port and the
    scratch directory promptly rather than about repository safety. SIGKILL
    cannot be caught -- which is exactly why the tree is never mutated.
    """
    previous: dict[int, object] = {}

    def handler(signum, _frame):
        raise SystemExit(128 + signum)

    for signame in ("SIGTERM", "SIGINT", "SIGHUP"):
        signum = getattr(signal, signame, None)
        if signum is None:
            continue
        try:
            previous[signum] = signal.signal(signum, handler)
        except (OSError, ValueError):
            pass
    try:
        yield
    finally:
        for signum, old in previous.items():
            try:
                signal.signal(signum, old)  # type: ignore[arg-type]
            except (OSError, ValueError):
                pass


def _main(argv: list[str]) -> int:
    """Serve the packages and print their URLs; useful for manual debugging."""
    import argparse

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--package", default="default", choices=["default", "wayland"])
    parser.add_argument("--mode", default="auto", choices=["auto", "bundle", "source"])
    parser.add_argument("--verbose", "-v", action="store_true")
    parser.add_argument(
        "--ephemeral-port",
        action="store_true",
        help="Always let the OS pick the port instead of this checkout's stable one",
    )
    parser.add_argument(
        "--serve",
        action="store_true",
        help="Keep serving until interrupted instead of exiting immediately",
    )
    args = parser.parse_args(argv)

    root = Path(__file__).resolve().parent.parent
    warning = check_roc_pin(root)
    if warning:
        print(warning, file=sys.stderr)

    with terminating_signals(), serve_packages(
        root,
        package=args.package,
        mode=args.mode,
        verbose=args.verbose,
        stable_port=not args.ephemeral_port,
    ) as packages:
        print(f"mode:     {packages.mode}")
        print(f"platform: {packages.platform_ref}")
        for note in packages.notes:
            print(f"note:     {note}")
        if args.serve:
            print("Serving; press Ctrl-C to stop.")
            try:
                while True:
                    time.sleep(3600)
            except (KeyboardInterrupt, SystemExit):
                pass
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
