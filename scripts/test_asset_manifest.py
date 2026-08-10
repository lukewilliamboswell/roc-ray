#!/usr/bin/env python3
"""Focused tests for the deterministic asset manifest generator."""

from __future__ import annotations

import importlib.util
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
            with self.assertRaisesRegex(assets.ManifestError, "case-colliding"):
                assets.inventory(root)

    def test_symlinks_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "data.bin").write_bytes(b"data")
            (root / "linked.bin").symlink_to(root / "data.bin")
            with self.assertRaisesRegex(assets.ManifestError, "symlinks"):
                assets.inventory(root)


if __name__ == "__main__":
    unittest.main()
