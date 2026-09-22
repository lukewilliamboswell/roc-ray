import json
from pathlib import Path
import tempfile
import unittest
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_macos_interfaces
import build_macos_stubs
from dependency_artifacts import unpack_verified


class MacOSInterfaceTests(unittest.TestCase):
    def test_catalog_is_rocray_specific_and_dual_architecture(self):
        catalog = build_macos_stubs.read_catalog()
        self.assertEqual(catalog["target"], "x86_64-macos+arm64-macos")
        serialized = json.dumps(catalog).lower()
        self.assertNotIn("roc gui", serialized)
        self.assertNotIn("roc-gui", serialized)
        self.assertNotIn("gpui", serialized)
        self.assertGreater(sum(len(x["symbols"]) for x in catalog["libraries"]), 0)

    def test_generation_is_deterministic_and_binds_all_archives(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archives = root / "archives"
            archives.mkdir()
            for name in build_macos_stubs.ARCHIVES:
                (archives / name).write_bytes(name.encode())
            first = build_macos_stubs.generate(archives, root / "first")
            second = build_macos_stubs.generate(archives, root / "second")
            self.assertEqual(first, second)
            self.assertEqual(set(first["host_archives_sha256"]), set(build_macos_stubs.ARCHIVES))
            for path in (root / "first").rglob("*.tbd"):
                text = path.read_text()
                self.assertIn("x86_64-macos", text)
                self.assertIn("arm64-macos", text)

    def test_release_archive_is_deterministic_and_complete(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "a").mkdir()
            (root / "b").mkdir()
            a = build_macos_interfaces.build(root / "a")
            b = build_macos_interfaces.build(root / "b")
            self.assertEqual(a.read_bytes(), b.read_bytes())
            tree = root / "tree"
            manifest = unpack_verified(a, {"name": "macos-interfaces", "target": "macos-sysroot"}, tree)
            expected = {"targets/macos-sysroot/" + name for name in build_macos_interfaces.interface_files()}
            expected.update({"targets/macos-sysroot/interfaces.json",
                             "targets/macos-sysroot/PROVENANCE.md",
                             "targets/macos-sysroot/manifest.json"})
            self.assertEqual(set(manifest["files"]), expected)

    def test_source_tree_is_the_release_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = build_macos_interfaces.write_tree(root / "macos-sysroot")
            expected = set(build_macos_interfaces.interface_files())
            expected.update({"interfaces.json", "PROVENANCE.md", "manifest.json"})
            actual = {path.relative_to(tree).as_posix() for path in tree.rglob("*") if path.is_file()}
            self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
