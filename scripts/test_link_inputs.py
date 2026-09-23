"""Admission tests for the locked linker-input producer and consumer."""

import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import link_input_release as release  # noqa: E402
import link_inputs  # noqa: E402

FINGERPRINT = "f" * 64


def producer_tree(root: Path) -> Path:
    """A fake `zig build link-inputs` output: distinct bytes per profile and file."""
    tree = root / "tree"
    for profile in release.PROFILES:
        for name in release.inventory(profile):
            path = tree / profile / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(f"{profile}:{name}".encode())
    return tree


def compose(root: Path, name: str = "candidate") -> dict:
    source = {"repository": release.REPOSITORY, "sha": "a" * 40, "ref": "refs/heads/link-inputs",
              "workflow": release.WORKFLOW, "input_fingerprint": FINGERPRINT}
    return release.compose(producer_tree(root), root / name, source)


def lock_for(root: Path, manifest: dict) -> Path:
    digest = hashlib.sha256((root / "candidate/build-input-release.json").read_bytes()).hexdigest()
    lock = {
        "schema_version": 1, "kind": release.KIND, "repository": release.REPOSITORY,
        "release": f"link-inputs-sha256-{digest}",
        "manifest": {"asset": "build-input-release.json", "sha256": digest},
        "source": manifest["source"], "targets": manifest["assets"],
    }
    path = root / "link-inputs.lock.json"
    path.write_text(json.dumps(lock))
    return path


class FakeRelease:
    """Serves the candidate directory as the release; counts every request."""

    def __init__(self, directory: Path):
        self.directory = directory
        self.requests = []

    def __call__(self, url, timeout):
        self.requests.append(url)
        return io.BytesIO((self.directory / url.rsplit("/", 1)[1]).read_bytes())


def retar(source: Path, output: Path, edit) -> None:
    """Rewrite an archive's members through `edit(list of (TarInfo, bytes))`."""
    with tarfile.open(source) as packed:
        members = [(m, packed.extractfile(m).read()) for m in packed]
    with tarfile.open(output, "w", format=tarfile.USTAR_FORMAT) as packed:
        for member, data in edit(members):
            packed.addfile(member, io.BytesIO(data) if member.isfile() else None)


@mock.patch.object(release, "input_fingerprint", return_value=FINGERPRINT)
class LinkInputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_every_platform_input_except_host_and_app_is_released(self, _):
        for header in ("platform/main.roc", "platform/main-wayland.roc"):
            text = (release.ROOT / header).read_text()
            self.assertIn('"libhost.a"', text)
        self.assertEqual(release.declared_inputs("x64glibc-x11"), sorted(
            ["Scrt1.o", "crti.o", "libraylib.a", "libmsf_gif.a", "libvpx.a", "libsqlite3.a",
             "libm.so", "libX11.so", "libc.so", "crtn.o"]))
        self.assertNotIn("libX11.so", release.declared_inputs("x64glibc-wayland"))
        self.assertIn("bcryptprimitives.lib", release.declared_inputs("x64win"))
        self.assertNotIn("host.lib", release.declared_inputs("x64win"))

    def test_candidate_is_byte_reproducible(self, _):
        first = compose(self.root, "first")
        second = compose(self.root, "second")
        self.assertEqual(first, second)
        for asset in first["assets"].values():
            self.assertEqual((self.root / "first" / asset["asset"]).read_bytes(),
                             (self.root / "second" / asset["asset"]).read_bytes())

    def test_install_downloads_once_then_rehashes_cache_without_network(self, _):
        lock = lock_for(self.root, compose(self.root))
        cache = self.root / "cache"
        server = FakeRelease(self.root / "candidate")
        with mock.patch.object(link_inputs, "urlopen", server):
            link_inputs.install(["x64glibc-x11"], self.root / "one", lock_path=lock, cache=cache)
        self.assertEqual(len(server.requests), 1)

        def offline(*_args, **_kwargs):
            raise AssertionError("a verified cache hit must not reach the network")

        with mock.patch.object(link_inputs, "urlopen", offline), \
                mock.patch.object(link_inputs, "file_sha256", wraps=link_inputs.file_sha256) as hashed:
            link_inputs.install(["x64glibc-x11"], self.root / "two", lock_path=lock, cache=cache)
        cached = cache / f"{json.loads(lock.read_text())['targets']['x64glibc-x11']['sha256']}-link-inputs-x64glibc-x11.tar"
        self.assertIn(mock.call(cached), hashed.call_args_list)
        installed = self.root / "two/targets/x64glibc/libX11.so"
        self.assertEqual(installed.read_bytes(), b"x64glibc-x11:targets/x64glibc/libX11.so")
        self.assertTrue((self.root / "two/licenses/LICENSE.libvpx").is_file())

    def test_poisoned_cache_entry_is_removed_and_fails(self, _):
        lock_path = lock_for(self.root, compose(self.root))
        lock = json.loads(lock_path.read_text())
        cache = self.root / "cache"
        cache.mkdir()
        record = lock["targets"]["x64win"]
        poisoned = cache / f"{record['sha256']}-{record['asset']}"
        poisoned.write_bytes(b"x" * record["size"])
        with mock.patch.object(link_inputs, "urlopen", side_effect=AssertionError("no fallback download")):
            with self.assertRaisesRegex(link_inputs.LinkInputError, "failed verification"):
                link_inputs.install(["x64win"], self.root / "out", lock_path=lock_path, cache=cache)
        self.assertFalse(poisoned.exists())
        self.assertFalse((self.root / "out").exists())

    def test_wrong_download_is_rejected(self, _):
        lock_path = lock_for(self.root, compose(self.root))
        (self.root / "candidate/link-inputs-x64mac.tar").write_bytes(b"not the reviewed bytes")
        with mock.patch.object(link_inputs, "urlopen", FakeRelease(self.root / "candidate")):
            with self.assertRaisesRegex(link_inputs.LinkInputError, "truncated|differs"):
                link_inputs.install(["x64mac"], self.root / "out", lock_path=lock_path, cache=self.root / "cache")
        self.assertEqual(list((self.root / "cache").glob("*.tar")), [])

    def _unpack_modified(self, profile, edit):
        if not (self.root / "candidate").exists():
            lock_for(self.root, compose(self.root))
        lock = json.loads((self.root / "link-inputs.lock.json").read_text())
        archive = self.root / "candidate" / lock["targets"][profile]["asset"]
        modified = self.root / "modified.tar"
        retar(archive, modified, edit)
        link_inputs.unpack(modified, profile, lock, self.root / "stage")

    def test_extraction_rejects_unsafe_members(self, _):
        def symlink(members):
            link = tarfile.TarInfo("targets/x64mac/libvpx.a")
            link.type, link.linkname = tarfile.SYMTYPE, "/etc/passwd"
            return [(m, d) for m, d in members if m.name != link.name] + [(link, b"")]

        def traversal(members):
            escape = tarfile.TarInfo("../escape")
            escape.size = 1
            return members + [(escape, b"x")]

        def duplicate(members):
            return members + [members[0]]

        def device(members):
            node = tarfile.TarInfo("targets/x64mac/dev")
            node.type = tarfile.CHRTYPE
            return members + [(node, b"")]

        for edit in (symlink, traversal, duplicate, device):
            with self.subTest(edit=edit.__name__):
                with self.assertRaisesRegex(link_inputs.LinkInputError, "unsafe or duplicate"):
                    self._unpack_modified("x64mac", edit)
                self.assertFalse((self.root / "stage").exists())

    def test_extraction_rejects_undeclared_files(self, _):
        def extra(members):
            info = json.loads(dict((m.name, d) for m, d in members)[release.MANIFEST])
            info["files"]["targets/x64mac/extra.a"] = {"sha256": hashlib.sha256(b"x").hexdigest(), "size": 1}
            data = json.dumps(info).encode()
            manifest = tarfile.TarInfo(release.MANIFEST)
            manifest.size = len(data)
            member = tarfile.TarInfo("targets/x64mac/extra.a")
            member.size = 1
            return [(m, d) for m, d in members if m.name != release.MANIFEST] + [(manifest, data), (member, b"x")]

        with self.assertRaisesRegex(link_inputs.LinkInputError, "undeclared"):
            self._unpack_modified("x64mac", extra)

    def test_wayland_archive_cannot_stand_in_for_x11(self, _):
        manifest = compose(self.root)
        lock = json.loads(lock_for(self.root, manifest).read_text())
        wayland = self.root / "candidate" / manifest["assets"]["x64glibc-wayland"]["asset"]
        with self.assertRaisesRegex(link_inputs.LinkInputError, "x64glibc-x11 profile"):
            link_inputs.unpack(wayland, "x64glibc-x11", lock, self.root / "stage")
        with self.assertRaisesRegex(link_inputs.LinkInputError, "cannot be installed together"):
            link_inputs.install(["x64glibc-x11", "x64glibc-wayland"], self.root / "out",
                                lock_path=self.root / "link-inputs.lock.json", cache=self.root / "cache")

    def test_stale_lock_fails_instead_of_rebuilding(self, fingerprint):
        lock = lock_for(self.root, compose(self.root))
        fingerprint.return_value = "0" * 64
        with self.assertRaisesRegex(link_inputs.LinkInputError, "stale"):
            link_inputs.install(["x64mac"], self.root / "out", lock_path=lock, cache=self.root / "cache")

    def test_lock_must_select_every_profile(self, _):
        lock_path = lock_for(self.root, compose(self.root))
        lock = json.loads(lock_path.read_text())
        del lock["targets"]["x64glibc-wayland"]
        lock_path.write_text(json.dumps(lock))
        with self.assertRaisesRegex(link_inputs.LinkInputError, "every profile"):
            link_inputs.read_lock(lock_path)

    def test_producer_rejects_a_build_that_misses_a_declared_input(self, _):
        tree = producer_tree(self.root)
        (tree / "x64win/targets/x64win/ws2_32.lib").unlink()
        with self.assertRaisesRegex(ValueError, "ws2_32.lib"):
            release.compose(tree, self.root / "candidate", {"input_fingerprint": FINGERPRINT})


if __name__ == "__main__":
    unittest.main()
