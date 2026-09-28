#!/usr/bin/env python3
"""Format-check, check, test, build and headlessly run every tutorial app.

The manual includes these files verbatim (docs/tutorial/*.roc), so a snippet
that stops compiling fails here rather than in a reader's terminal, and one
`roc fmt` would change fails too, since readers copy what the manual shows.

Each file names the working-tree platform by a relative path, which is enough
for `roc check` and `roc test`. Building needs the platform's native linker
inputs, so the build uses a copy of the file pointed at the locally served
platform, as scripts/all_tests.py does for the examples. The checked-in files
are never rewritten, and they carry no compiler pin, so the nightly updater
has nothing to keep in step.

    scripts/check_tutorial.py            # every file
    scripts/check_tutorial.py step3      # only files whose name contains "step3"

Build the host libraries first (`zig build`, or `zig build hosts` with
ROC_RAY_LINK_INPUT_CANDIDATE set while the lock is being republished).
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import local_bundles  # noqa: E402  (needs the sys.path entry above)

ROOT = Path(__file__).resolve().parents[1]
TUTORIAL = ROOT / "docs" / "tutorial"
FRAMES = 60


def run(command: list[str]) -> bool:
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        print("FAILED")
        print(f"    $ {' '.join(command)}")
        for line in (result.stdout + result.stderr).strip().splitlines():
            print(f"    {line}")
        return False
    return True


def stage(app: Path, packages: local_bundles.ServedPackages) -> Path:
    """Copy `app` into its own scratch directory, pointed at the served platform."""
    dest = packages.scratch_dir / "tutorial" / app.stem
    dest.mkdir(parents=True, exist_ok=True)
    staged = dest / "main.roc"
    source, rewritten = local_bundles.rewrite_platform_ref(
        app.read_text(encoding="utf-8"), local_bundles.quote_ref(packages.ref_for(dest))
    )
    if not rewritten:
        raise local_bundles.LocalBundleError(f"no platform reference to rewrite in {app}")
    staged.write_text(source, encoding="utf-8")
    return staged


def check(app: Path, packages: local_bundles.ServedPackages, roc: str) -> bool:
    if not (run([roc, "fmt", "--check", str(app)]) and run([roc, "check", str(app)]) and run([roc, "test", str(app)])):
        return False
    staged = stage(app, packages)
    executable = staged.with_suffix(".exe" if local_bundles.IS_WINDOWS else "")
    return run([roc, "build", str(staged), f"--output={executable}", *local_bundles.PACKAGE_LIMIT_ARGS]) and run(
        [str(executable), "--host-headless", f"--host-headless-frames={FRAMES}"]
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("filter", nargs="?", default="", help="only check files whose name contains this")
    args = parser.parse_args()

    apps = [app for app in sorted(TUTORIAL.glob("*.roc")) if args.filter in app.name]
    if not apps:
        print(f"no tutorial files match {args.filter!r}", file=sys.stderr)
        return 1

    roc = os.environ.get("ROC", "roc")
    failed = []
    try:
        with local_bundles.terminating_signals(), local_bundles.serve_packages(ROOT, roc=roc) as packages:
            for note in packages.notes:
                print(f"note: {note}", file=sys.stderr)
            for app in apps:
                print(f"{app.relative_to(ROOT)} ...", end=" ", flush=True)
                if check(app, packages, roc):
                    print("ok")
                else:
                    failed.append(app.name)
    except local_bundles.LocalBundleError as err:
        print(f"error: {err}", file=sys.stderr)
        return 2

    if failed:
        print(f"\n{len(failed)} tutorial file(s) failed: {', '.join(failed)}", file=sys.stderr)
        return 1
    print(f"\nAll {len(apps)} tutorial files check, test, build and run headless.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
