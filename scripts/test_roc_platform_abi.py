#!/usr/bin/env python3
"""Focused tests for reading the compiler pin and checking a compiler against it."""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import roc_platform_abi as abi
import local_bundles


class RocPlatformAbiTests(unittest.TestCase):
    def test_reads_header_pin_without_confusing_documented_app_pin(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            pin_file = Path(temporary_name) / "main.roc"
            pin_file.write_text(
                '## app [] { roc: "nightly-2026-08-01-abcdef0" }\nplatform "" packages { roc: "nightly-2026-08-12-606470f" }\n', encoding="utf-8"
            )
            self.assertEqual(
                abi.read_pin(pin_file),
                abi.RocPin(
                    nightly="nightly-2026-08-12-606470f",
                    commit="606470f",
                ),
            )

            pin_file.write_text(
                'platform "" packages { roc: "nightly-2026-August-03-94cbed3", roc: "nightly-2026-08-01-abcdef0" }\n', encoding="utf-8"
            )
            with self.assertRaisesRegex(abi.GlueError, "exactly one"):
                abi.read_pin(pin_file)

    def test_staging_rebinds_the_app_pin_without_rewriting_module_docs(self) -> None:
        source = '## app [] { roc: "nightly-2026-08-23-fb208ba" }\napp [] { roc: "nightly-2026-08-23-fb208ba" }\n'
        rebound = local_bundles.rewrite_compiler_pin(source, "nightly-2026-09-18-1d982dc")
        self.assertEqual(source.splitlines()[0], rebound.splitlines()[0])
        self.assertIn('roc: "nightly-2026-09-18-1d982dc"', rebound.splitlines()[1])
        with self.assertRaises(local_bundles.LocalBundleError):
            local_bundles.rewrite_compiler_pin('app [] {}', "nightly-2026-09-18-1d982dc")

    def test_rejects_compiler_from_a_different_nightly(self) -> None:
        pin = abi.RocPin(
            nightly="nightly-2026-August-03-94cbed3", commit="94cbed3"
        )
        version_result = subprocess.CompletedProcess(
            args=["roc", "version"],
            returncode=0,
            stdout="Roc compiler version nightly-2026-August-04-deadbee\n",
            stderr="",
        )
        with (
            mock.patch.object(
                abi, "resolve_program", return_value=Path("/test/bin/roc")
            ),
            mock.patch.object(abi, "_run_checked", return_value=version_result),
            self.assertRaisesRegex(abi.GlueError, "does not match platform/main.roc"),
        ):
            abi.verify_compiler("roc", pin)


if __name__ == "__main__":
    unittest.main()
