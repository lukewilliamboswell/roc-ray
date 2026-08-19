#!/usr/bin/env python3
"""Prove that app code cannot reach capabilities the platform withholds.

Each case must fail to compile, must fail with the expected diagnostic, and
must produce exactly one error. That last check is what stops a fixture from
passing for the wrong reason: without it, a fixture left stale by an unrelated
API change still fails, still contains the expected text somewhere, and quietly
stops testing what it was written for.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

from roc_platform_abi import GlueError, read_pin, verify_compiler


ROOT = Path(__file__).resolve().parent.parent
CASES = (
    (
        ROOT / "test" / "compile_fail" / "app_config_to_host.roc",
        ("missing method", "`to_host`"),
    ),
    (
        ROOT / "test" / "compile_fail" / "app_host_config.roc",
        ("type not exposed", "`HostConfig`"),
    ),
    (
        ROOT / "test" / "compile_fail" / "app_config_module.roc",
        ("package module is private", "`rr.AppConfig`"),
    ),
    (
        ROOT / "test" / "compile_fail" / "file_module_removed.roc",
        ("package module is private", "`rr.File`"),
    ),
    (
        ROOT / "test" / "compile_fail" / "texture_handle_manufacture.roc",
        ("cannot use opaque nominal type", "`Texture.Handle`"),
    ),
    (
        ROOT / "test" / "compile_fail" / "capture_stop_effect.roc",
        ("does not exist", "`rr.Capture.stop!`"),
    ),
)

ONE_ERROR = re.compile(r"\b1 error and \d+ warnings?\b")


def main() -> int:
    try:
        roc = verify_compiler("roc", read_pin())
    except GlueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    failed = False
    for source, expected_diagnostics in CASES:
        result = subprocess.run(
            [str(roc), "check", str(source)],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        diagnostics = result.stdout + result.stderr
        if result.returncode == 0:
            print(f"ERROR: privacy experiment unexpectedly compiled: {source}")
            failed = True
            continue

        missing = [text for text in expected_diagnostics if text not in diagnostics]
        if missing:
            print(
                f"ERROR: {source} failed without expected diagnostic(s): "
                f"{', '.join(missing)}\n{diagnostics}",
                file=sys.stderr,
            )
            failed = True
            continue

        if not ONE_ERROR.search(diagnostics):
            print(
                f"ERROR: {source} did not fail with exactly one error, so the "
                f"expected diagnostic may not be the reason it failed\n{diagnostics}",
                file=sys.stderr,
            )
            failed = True
            continue

        print(f"Verified withheld capability: {source.relative_to(ROOT)}")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
