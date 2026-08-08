#!/usr/bin/env python3
"""Focused tests for reproducible Roc glue generation."""

from __future__ import annotations

import contextlib
import io
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import roc_platform_abi as abi


def run_git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        # Signing off: this repository is a scratch fixture, and a developer
        # whose global config signs every commit would otherwise fail here on
        # a pinentry prompt that has no terminal to appear on.
        ["git", "-C", str(repo), "-c", "commit.gpgsign=false", *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


class RocPlatformAbiTests(unittest.TestCase):
    def test_reads_commit_from_single_line_nightly_pin(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            pin_file = Path(temporary_name) / ".roc-version"
            pin_file.write_text(
                "nightly-2026-August-03-94cbed3\n", encoding="utf-8"
            )
            self.assertEqual(
                abi.read_pin(pin_file),
                abi.RocPin(
                    nightly="nightly-2026-August-03-94cbed3",
                    commit="94cbed3",
                ),
            )

            pin_file.write_text(
                "nightly-2026-August-03-94cbed3\nextra\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(abi.GlueError, "exactly one"):
                abi.read_pin(pin_file)

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
            self.assertRaisesRegex(abi.GlueError, "does not match .roc-version"),
        ):
            abi.verify_compiler("roc", pin)

    def test_extracts_committed_glue_without_reading_dirty_worktree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            temporary = Path(temporary_name)
            repo = temporary / "roc"
            repo.mkdir()
            run_git(repo, "init", "--quiet")
            run_git(repo, "config", "user.name", "Glue Test")
            run_git(repo, "config", "user.email", "glue@example.invalid")

            glue = repo / "src" / "glue" / "src" / "ZigGlue.roc"
            glue.parent.mkdir(parents=True)
            glue.write_text("committed glue\n", encoding="utf-8")
            run_git(repo, "add", "src/glue/src/ZigGlue.roc")
            run_git(repo, "commit", "--quiet", "-m", "Add glue")
            commit = run_git(repo, "rev-parse", "HEAD")
            pin = abi.RocPin(
                nightly=f"nightly-2026-August-03-{commit[:7]}",
                commit=commit[:7],
            )

            glue.write_text("dirty glue\n", encoding="utf-8")
            status_before = run_git(repo, "status", "--short")
            resolved = abi.resolve_pinned_commit(repo, pin)
            extraction = temporary / "extraction"
            extraction.mkdir()
            extracted = abi.extract_glue(repo, resolved, extraction)

            self.assertEqual(extracted.read_text(encoding="utf-8"), "committed glue\n")
            self.assertEqual(run_git(repo, "status", "--short"), status_before)

            glue.write_text("tagged elsewhere\n", encoding="utf-8")
            run_git(repo, "add", "src/glue/src/ZigGlue.roc")
            run_git(repo, "commit", "--quiet", "-m", "Move nightly tag")
            run_git(repo, "tag", pin.nightly)
            with self.assertRaisesRegex(abi.GlueError, "embedded hash"):
                abi.resolve_pinned_commit(repo, pin)

    def test_check_reports_diff_without_modifying_destination(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            temporary = Path(temporary_name)
            checked_in = temporary / "roc_platform_abi.zig"
            generated = temporary / "generated.zig"
            checked_in.write_text("const old = 1;\n", encoding="utf-8")
            generated.write_text("const new = 2;\n", encoding="utf-8")

            diagnostics = io.StringIO()
            with (
                contextlib.redirect_stderr(diagnostics),
                self.assertRaisesRegex(abi.GlueError, "not reproducible"),
            ):
                abi.install_or_check(generated, checked_in, check=True)

            self.assertEqual(checked_in.read_text(encoding="utf-8"), "const old = 1;\n")
            self.assertIn("-const old = 1;", diagnostics.getvalue())
            self.assertIn("+const new = 2;", diagnostics.getvalue())

    def test_update_is_atomic_and_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            temporary = Path(temporary_name)
            checked_in = temporary / "roc_platform_abi.zig"
            generated = temporary / "generated.zig"
            checked_in.write_text("old\n", encoding="utf-8")
            generated.write_text("new\n", encoding="utf-8")

            self.assertTrue(abi.install_or_check(generated, checked_in, check=False))
            self.assertEqual(checked_in.read_text(encoding="utf-8"), "new\n")
            self.assertFalse(abi.install_or_check(generated, checked_in, check=False))


if __name__ == "__main__":
    unittest.main()
