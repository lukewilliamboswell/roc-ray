import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import prepare_dependencies


class PrepareDependenciesTests(unittest.TestCase):
    def test_installs_only_the_release_inventory_and_replaces_an_old_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "installed"
            destination.mkdir()
            (destination / "old").write_text("old")

            catalog = b'{"schema_version":1}\n'
            files = {
                "interfaces.json": catalog,
                "manifest.json": b"{}\n",
                "PROVENANCE.md": b"reviewed\n",
                "usr/lib/libSystem.tbd": b"--- !tapi-tbd\n",
            }

            def materialize(_lock, identity, _cache, output):
                self.assertEqual(identity, prepare_dependencies.MACOS_INTERFACES)
                tree = output / "targets/macos-sysroot"
                for name, data in files.items():
                    path = tree / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(data)
                inventory = {"targets/macos-sysroot/" + name: {} for name in files}
                (output / "dependency.json").write_text(json.dumps({
                    "files": inventory,
                    "catalog_sha256": hashlib.sha256(catalog).hexdigest(),
                }))
                return {"sha256": "a" * 64}

            with patch.object(prepare_dependencies, "materialize", side_effect=materialize):
                receipt = prepare_dependencies.install_macos_interfaces(
                    destination, root / "lock.json", root / "cache"
                )

            self.assertEqual(receipt, {"sha256": "a" * 64})
            self.assertFalse((destination / "old").exists())
            self.assertEqual(
                {path.relative_to(destination).as_posix() for path in destination.rglob("*") if path.is_file()},
                set(files),
            )

    def test_rejects_an_inventory_that_does_not_match_extracted_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            def materialize(_lock, _identity, _cache, output):
                tree = output / "targets/macos-sysroot"
                tree.mkdir(parents=True)
                catalog = b"{}"
                (tree / "interfaces.json").write_bytes(catalog)
                (output / "dependency.json").write_text(json.dumps({
                    "files": {},
                    "catalog_sha256": hashlib.sha256(catalog).hexdigest(),
                }))
                return {}

            with patch.object(prepare_dependencies, "materialize", side_effect=materialize), \
                    self.assertRaisesRegex(ValueError, "inventory"):
                prepare_dependencies.install_macos_interfaces(root / "installed", root / "lock", root / "cache")


if __name__ == "__main__":
    unittest.main()
