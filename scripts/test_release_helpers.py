#!/usr/bin/env python3
"""Focused tests for the release workflow helpers."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import os
import unittest
import unittest.mock
import zipfile
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "release_helpers", Path(__file__).with_name("release_helpers.py")
)
assert SPEC and SPEC.loader
helpers = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = helpers
SPEC.loader.exec_module(helpers)

BUNDLE_URL = "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.9.0/roc-ray-0.9.0.tar.zst"
NEXT_URL = "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0/roc-ray-0.10.0.tar.zst"

APP_HEADER = 'app [init!, render!] {{ rr: platform "{ref}" }}\n\nmain = 1\n'


def git(root: Path, *arguments: str) -> None:
    subprocess.run(["git", *arguments], cwd=root, check=True, capture_output=True, text=True)


class PackageExamplesTests(unittest.TestCase):
    def run_cli(self, *arguments: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(Path(__file__).with_name("release_helpers.py")), *arguments],
            text=True,
            capture_output=True,
            check=False,
            cwd=cwd,
        )

    def make_repo(self, root: Path) -> Path:
        """A miniature repository with two examples, an asset, and junk to exclude."""
        examples = root / "examples"
        (examples / "pong" / "assets").mkdir(parents=True)
        (examples / "snake").mkdir(parents=True)
        (examples / "README.md").write_text("# Example gallery\n", encoding="utf-8")
        (examples / "pong" / "main.roc").write_text(
            APP_HEADER.format(ref="../../platform/main.roc"), encoding="utf-8"
        )
        (examples / "pong" / "assets" / "ball.png").write_bytes(b"\x89PNG ball")
        (examples / "snake" / "main.roc").write_text(
            APP_HEADER.format(ref=BUNDLE_URL), encoding="utf-8"
        )
        (examples / "snake" / "Board.roc").write_text("module []\n", encoding="utf-8")

        git(root, "init", "-q")
        git(root, "config", "user.email", "test@example.com")
        git(root, "config", "user.name", "Test")
        git(root, "add", "examples")
        git(root, "commit", "-qm", "examples")

        # Untracked build output and capture junk must not reach the archive.
        (examples / "pong" / "main").write_bytes(b"ELF")
        (examples / "snake" / "captures").mkdir()
        (examples / "snake" / "captures" / "run.gif").write_bytes(b"GIF")
        return examples

    def package(self, root: Path, output: Path, url: str = NEXT_URL, tag: str = "0.10.0"):
        return self.run_cli(
            "package-examples",
            "--bundle-url",
            url,
            "--tag",
            tag,
            "--examples-dir",
            "examples",
            "--output",
            str(output),
            cwd=root,
        )

    def test_zip_holds_tracked_files_with_rewritten_headers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repo(root)
            output = root / "out" / "examples-0.10.0.zip"

            # The helper reads the working tree it is run from, so the scratch
            # repository stands in for a release checkout.
            result = self.run_cli(
                "package-examples",
                "--bundle-url",
                NEXT_URL,
                "--tag",
                "0.10.0",
                "--output",
                str(output),
                cwd=root,
            )
            self.assertEqual(0, result.returncode, result.stderr)

            with zipfile.ZipFile(output) as archive:
                names = sorted(archive.namelist())
                pong = archive.read("examples/pong/main.roc").decode("utf-8")
                snake = archive.read("examples/snake/main.roc").decode("utf-8")
                ball = archive.read("examples/pong/assets/ball.png")
                stamps = {info.date_time for info in archive.infolist()}

            self.assertEqual(
                [
                    "examples/README.md",
                    "examples/pong/assets/ball.png",
                    "examples/pong/main.roc",
                    "examples/snake/Board.roc",
                    "examples/snake/main.roc",
                ],
                names,
            )
            self.assertIn(f'platform "{NEXT_URL}"', pong)
            self.assertIn(f'platform "{NEXT_URL}"', snake)
            self.assertNotIn("../../platform/main.roc", pong)
            self.assertNotIn(BUNDLE_URL, snake)
            self.assertEqual(b"\x89PNG ball", ball)
            self.assertEqual({(1980, 1, 1, 0, 0, 0)}, stamps)

    def test_default_output_name_uses_the_tag(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repo(root)
            result = self.run_cli(
                "package-examples",
                "--bundle-url",
                NEXT_URL,
                "--tag",
                "0.10.0",
                "--output-dir",
                str(root / ".release"),
                cwd=root,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertTrue((root / ".release" / "examples-0.10.0.zip").is_file())

    def test_unrecognized_header_fails_loudly(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            examples = self.make_repo(root)
            (examples / "snake" / "main.roc").write_text(
                APP_HEADER.format(ref="https://example.com/other.tar.zst"), encoding="utf-8"
            )
            output = root / "examples-0.10.0.zip"
            result = self.package(root, output)
            self.assertEqual(1, result.returncode)
            self.assertIn("examples/snake/main.roc", result.stderr)
            self.assertIn("found 0", result.stderr)

    def test_example_directory_without_a_main_roc_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            examples = self.make_repo(root)
            (examples / "orphan").mkdir()
            (examples / "orphan" / "Notes.roc").write_text("module []\n", encoding="utf-8")
            git(root, "add", "examples")
            git(root, "commit", "-qm", "orphan")

            output = root / "examples-0.10.0.zip"
            result = self.package(root, output)
            self.assertEqual(1, result.returncode)
            self.assertIn("orphan", result.stderr)
            self.assertFalse(output.exists())

    def test_bundle_url_is_validated(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repo(root)
            result = self.package(root, root / "out.zip", url="http://example.com/not-a-bundle")
            self.assertEqual(1, result.returncode)
            self.assertIn("invalid previous release URL", result.stderr)

    def test_url_is_resolved_from_release_bundle_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repo(root)
            bundles = root / "release-bundles.json"
            bundles.write_text(
                json.dumps(
                    [
                        {"name": "default", "artifact_file": "roc-ray-0.10.0.tar.zst"},
                        {"name": "wayland", "artifact_file": "roc-ray-wayland-0.10.0.tar.zst"},
                    ]
                ),
                encoding="utf-8",
            )
            output = root / "examples-0.10.0.zip"
            result = self.run_cli(
                "package-examples",
                "--release-version",
                "0.10.0",
                "--release-bundles",
                str(bundles),
                "--repo",
                "lukewilliamboswell/roc-ray",
                "--output",
                str(output),
                cwd=root,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            with zipfile.ZipFile(output) as archive:
                pong = archive.read("examples/pong/main.roc").decode("utf-8")
            self.assertIn(f'platform "{NEXT_URL}"', pong)


class ResolveDefaultBundleUrlTests(unittest.TestCase):
    def test_explicit_url_wins(self) -> None:
        self.assertEqual(
            NEXT_URL, helpers.resolve_default_bundle_url(NEXT_URL, "", "", "")
        )

    def test_missing_version_is_reported(self) -> None:
        # CI exports RELEASE_VERSION, which the helper falls back to; clear it
        # so the test sees the same environment everywhere.
        with unittest.mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(RuntimeError):
                helpers.resolve_default_bundle_url("", "", "bundles.json", "owner/repo")


if __name__ == "__main__":
    unittest.main()
