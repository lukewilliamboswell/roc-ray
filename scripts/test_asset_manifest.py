#!/usr/bin/env python3
"""Focused tests for the deterministic asset manifest generator."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location("asset_manifest", Path(__file__).with_name("asset_manifest.py"))
assert SPEC and SPEC.loader
assets = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = assets
SPEC.loader.exec_module(assets)


class AssetManifestTests(unittest.TestCase):
    def run_cli(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(Path(__file__).with_name("asset_manifest.py")), *arguments],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_digest_is_sorted_and_manifest_is_excluded(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "z.txt").write_bytes(b"z")
            (root / "nested").mkdir()
            (root / "nested" / "a.bin").write_bytes(b"a" * (assets.CHUNK + 3))
            digest_before = assets.root_sha256(assets.inventory(root))
            assets.write_atomic(root / assets.MANIFEST, assets.manifest_text("demo", 1, 4, digest_before))
            self.assertEqual(digest_before, assets.root_sha256(assets.inventory(root)))
            self.assertEqual(["nested/a.bin", "z.txt"], [entry.path for entry in assets.inventory(root)])

    def test_case_collisions_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Texture.png").write_bytes(b"one")
            (root / "texture.png").write_bytes(b"two")
            if (root / "Texture.png").samefile(root / "texture.png"):
                self.skipTest("filesystem is case-insensitive")
            with self.assertRaisesRegex(assets.ManifestError, "case-colliding"):
                assets.inventory(root)

    def test_symlinks_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "data.bin").write_bytes(b"data")
            (root / "linked.bin").symlink_to(root / "data.bin")
            with self.assertRaisesRegex(assets.ManifestError, "symlinks"):
                assets.inventory(root)

    def test_cli_detects_stale_file_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            asset = root / "data.bin"
            asset.write_bytes(b"before")
            write = self.run_cli(
                "write", str(root), "--asset-set", "demo", "--schema", "1", "--content-version", "4"
            )
            self.assertEqual(0, write.returncode, write.stderr)
            digest_before = assets.root_sha256(assets.inventory(root))

            asset.write_bytes(b"after")
            digest_after = assets.root_sha256(assets.inventory(root))
            self.assertNotEqual(digest_before, digest_after)
            check = self.run_cli(
                "check", str(root), "--asset-set", "demo", "--schema", "1", "--content-version", "4"
            )
            self.assertEqual(1, check.returncode)
            self.assertIn("stale", check.stdout)

    def test_cli_rejects_values_outside_u32(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = self.run_cli(
                "write", temporary, "--asset-set", "demo", "--schema", str(assets.MAX_U32 + 1), "--content-version", "0"
            )
            self.assertEqual(1, result.returncode)
            self.assertIn("fit U32", result.stderr)


if __name__ == "__main__":
    unittest.main()
