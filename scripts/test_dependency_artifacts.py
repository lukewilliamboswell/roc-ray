import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import dependency_artifacts as deps


def archive(path: Path, manifest: dict, files: dict[str, bytes]) -> None:
    payload = dict(files, **{"dependency.json": json.dumps(manifest).encode()})
    with tarfile.open(path, "w:") as packed:
        for name, data in payload.items():
            member = tarfile.TarInfo(name)
            member.size = len(data)
            packed.addfile(member, io.BytesIO(data))


class DependencyArtifactTests(unittest.TestCase):
    def test_unpack_requires_exact_safe_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data = b"interface"
            name = "targets/macos-sysroot/usr/lib/libSystem.tbd"
            manifest = {"schema_version": 1, "name": "macos-interfaces",
                        "target": "macos-sysroot", "files": {
                            name: {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                        }}
            packed = root / "input.tar"
            archive(packed, manifest, {name: data})
            result = deps.unpack_verified(packed, manifest, root / "out")
            self.assertEqual(result, manifest)
            self.assertEqual((root / "out" / name).read_bytes(), data)

    def test_unpack_rejects_links_and_escaping_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for bad in ("../escape", "/absolute"):
                with self.subTest(bad=bad):
                    packed = root / (bad.replace("/", "_") + ".tar")
                    with tarfile.open(packed, "w:") as output:
                        member = tarfile.TarInfo(bad)
                        member.size = 1
                        output.addfile(member, io.BytesIO(b"x"))
                    with self.assertRaisesRegex(ValueError, "unsafe"):
                        deps.unpack_verified(packed, {"name": "x", "target": "y"}, root / "out")

    def test_verify_archive_rechecks_cache_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "input.tar"
            path.write_bytes(b"right")
            entry = {"size": 5, "sha256": hashlib.sha256(b"right").hexdigest()}
            deps.verify_archive(path, entry)
            path.write_bytes(b"wrong")
            with self.assertRaisesRegex(ValueError, "locked digest"):
                deps.verify_archive(path, entry)


if __name__ == "__main__":
    unittest.main()
