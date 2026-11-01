#!/usr/bin/env python3
"""Run a release's examples archive before it is published.

The archive is what roc-automation's nightly compatibility workflow runs
against each new nightly once it is published, so it is tested here the same
way first: extracted unchanged into a fresh directory with an empty package
cache, every app in its `spec.json` checked and built, and every case run from
the archive root with stdout, stderr and the exit code compared exactly. The
only difference is where the bundle comes from: the release URL in each header
is replaced, for each command, by the same bundle served on loopback.

    scripts/test_examples_archive.py --archive roc-ray-examples-0.11.0.zip \\
        --bundle dist/<hash>.tar.zst
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_bundle_artifact import check_bundle_url, serve_dir  # noqa: E402

IS_WINDOWS = platform.system() == "Windows"
COMPILE_TIMEOUT = 300
CASE_TIMEOUT = 10


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--archive", required=True, help="roc-ray-examples-<tag>.zip")
    parser.add_argument("--bundle", required=True, help="the default bundle the archive names")
    parser.add_argument("--roc", default="roc")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()

    archive = Path(args.archive).resolve()
    bundle = Path(args.bundle).resolve()
    with tempfile.TemporaryDirectory(prefix="rr_examples_") as temporary:
        work = Path(temporary)
        root = extract(archive, work / "suite")
        spec = json.loads((root / "spec.json").read_text(encoding="utf-8"))
        [release_url] = spec["dependencies"]
        if not release_url.endswith("/" + bundle.name):
            raise SystemExit(f"error: the archive names {release_url}, not the bundle {bundle.name}")

        served = work / "served"
        served.mkdir()
        shutil.copy2(bundle, served / bundle.name)
        httpd, port = serve_dir(served, args.port)
        try:
            local_url = f"http://127.0.0.1:{port}/{bundle.name}"
            check_bundle_url(local_url)
            env = dict(os.environ, ROC_CACHE_DIR=str(work / "roc-cache"))
            failures = run_suite(args.roc, root, spec, release_url, local_url, work / "bin", env)
        finally:
            httpd.shutdown()

    if failures:
        print(f"\nFAILED: {len(failures)} of the archive's checks")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(f"\nThe {spec['release']} examples archive passes as published.")
    return 0


def extract(archive: Path, destination: Path) -> Path:
    """Unpack the archive and return its single root folder."""
    with zipfile.ZipFile(archive) as zipped:
        roots = {name.split("/", 1)[0] for name in zipped.namelist()}
        if roots != {archive.stem}:
            raise SystemExit(f"error: {archive.name} must hold one folder named {archive.stem}, found {sorted(roots)}")
        # roc-automation's runner admits only regular files and directories,
        # and reads an entry's type from its Unix mode.
        for entry in zipped.infolist():
            kind = stat.S_IFMT(entry.external_attr >> 16)
            if entry.create_system == 3 and kind != (stat.S_IFDIR if entry.is_dir() else stat.S_IFREG):
                raise SystemExit(f"error: {entry.filename} is not a regular file or directory in {archive.name}")
        zipped.extractall(destination)
    return destination / archive.stem


def run_suite(roc: str, root: Path, spec: dict, release_url: str, local_url: str,
              bin_dir: Path, env: dict[str, str]) -> list[str]:
    bin_dir.mkdir()
    replace = ["--replace-dep", release_url, local_url]
    failures: list[str] = []
    apps = spec["apps"]
    for position, app in enumerate(apps, start=1):
        path = app["path"]
        name = Path(path).parent.name
        executable = bin_dir / (name + (".exe" if IS_WINDOWS else ""))
        print(f"[{position}/{len(apps)}] {path}")
        built = True
        for argv in (
            [roc, "check", path, "--no-cache", *replace],
            [roc, "build", path, "--no-cache", "--opt=dev", f"--output={executable}", *replace],
        ):
            ran = run(argv, root, env, b"", COMPILE_TIMEOUT)
            if ran is None or ran.returncode != 0:
                built = False
                failures.append(f"{path}: `{' '.join(argv[1:3])}` {describe(ran)}")
                if ran is not None:
                    sys.stdout.write(ran.stdout.decode("utf-8", "replace"))
                    sys.stdout.write(ran.stderr.decode("utf-8", "replace"))
                break
        for case in app["cases"]:
            label = f"{path} [{case['name']}]"
            if "skip" in case:
                failures.append(f"{label}: skipped ({case['skip']['reason']})")
                continue
            if not built:
                continue
            started = time.monotonic()
            ran = run([str(executable), *case["args"]], root, env, case["stdin"].encode("utf-8"), CASE_TIMEOUT)
            elapsed = int((time.monotonic() - started) * 1000)
            problems = compare(case, ran)
            print(f"  {case['name']}: {'ok' if not problems else 'FAILED'} ({elapsed} ms)")
            for problem in problems:
                print(f"    {problem}")
            if problems:
                failures.append(f"{label}: {'; '.join(problems)}")
    return failures


def run(argv: list[str], cwd: Path, env: dict[str, str], stdin: bytes,
        timeout: int) -> subprocess.CompletedProcess[bytes] | None:
    try:
        return subprocess.run(argv, cwd=cwd, env=env, input=stdin, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None


def describe(ran: subprocess.CompletedProcess[bytes] | None) -> str:
    return "timed out" if ran is None else f"exited with {ran.returncode}"


def compare(case: dict, ran: subprocess.CompletedProcess[bytes] | None) -> list[str]:
    if ran is None:
        return [f"timed out after {CASE_TIMEOUT} s"]
    problems = []
    if ran.returncode != case["exit_code"]:
        problems.append(f"exit code {ran.returncode}, expected {case['exit_code']}")
    for stream in ("stdout", "stderr"):
        actual = getattr(ran, stream).decode("utf-8", "replace")
        if actual != case[stream]:
            problems.append(f"{stream} was {actual!r}, expected {case[stream]!r}")
    return problems


if __name__ == "__main__":
    sys.exit(main())
