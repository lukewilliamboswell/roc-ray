#!/usr/bin/env python3
"""Prove that app code cannot reach App's internal host transport."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from roc_platform_abi import GlueError, read_pin, verify_compiler


ROOT = Path(__file__).resolve().parent.parent
CASES = (
    (
        ROOT / "test" / "compile_fail" / "app_config_to_host.roc",
        ("MISSING METHOD", "`to_host`"),
    ),
    (
        ROOT / "test" / "compile_fail" / "app_host_config.roc",
        ("TYPE NOT EXPOSED", "`HostConfig`"),
    ),
    (
        ROOT / "test" / "compile_fail" / "app_config_module.roc",
        ("PACKAGE MODULE IS PRIVATE", "`rr.AppConfig`"),
    ),
    (
        ROOT / "test" / "compile_fail" / "file_host_module.roc",
        ("PACKAGE MODULE IS PRIVATE", "`rr.FileHost`"),
    ),
)


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

        print(f"Verified private App transport: {source.relative_to(ROOT)}")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
