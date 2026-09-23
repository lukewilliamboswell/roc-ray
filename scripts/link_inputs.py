#!/usr/bin/env python3
"""Install RocRay's locked linker inputs, verifying every byte on every use.

`link-inputs.lock.json` selects one immutable, content-addressed release with
an archive per profile. This script is the only way an ordinary build, test,
bundle, or release obtains those inputs:

1. read and validate the lock, and check its producer-input fingerprint
   against the checkout, so a stale lock fails instead of linking old bytes;
2. take the archive from the local cache, or download it on a miss;
3. check its size and SHA-256 against the lock -- a cache hit included;
4. extract it into fresh staging, rejecting links, special files, duplicate or
   escaping paths, and any inventory other than the profile's declared inputs;
5. only then copy the files into place.

Nothing here builds a linker input, and a failed check never falls back to
building one. Producing a new release is a separate, reviewed procedure; see
`dependencies/link-inputs/README.md`.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.request import urlopen

sys.path.insert(0, str(Path(__file__).resolve().parent))

import link_input_release as release  # noqa: E402

ROOT = release.ROOT
LOCK = ROOT / "link-inputs.lock.json"
HEX256 = re.compile(r"[0-9a-f]{64}")
HEX160 = re.compile(r"[0-9a-f]{40}")
MAX_ARCHIVE_BYTES = 256 * 1024 * 1024
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_MEMBERS = 256
DEFAULT_PROFILES = ("x64mac", "arm64mac", "x64glibc-x11", "x64win")


class LinkInputError(ValueError):
    """A locked linker input is unavailable, stale, or not the reviewed bytes."""


def default_cache() -> Path:
    configured = os.environ.get("ROC_RAY_LINK_INPUT_CACHE")
    return Path(configured) if configured else Path.home() / ".cache" / "roc-ray" / "link-inputs"


def read_lock(path: Path = LOCK, root: Path = ROOT, check_fingerprint: bool = True) -> dict:
    if not path.is_file():
        raise LinkInputError(
            f"{path.name} is missing; linker inputs come from a published release. "
            "See dependencies/link-inputs/README.md")
    lock = json.loads(path.read_text())
    if (not isinstance(lock, dict)
            or set(lock) != {"schema_version", "kind", "repository", "release", "manifest", "source", "targets"}
            or lock["schema_version"] != 1 or lock["kind"] != release.KIND
            or lock["repository"] != release.REPOSITORY):
        raise LinkInputError("unsupported linker-input lock")
    if (not isinstance(lock["release"], str)
            or not re.fullmatch(r"link-inputs-sha256-[0-9a-f]{64}", lock["release"])
            or lock["manifest"] != {"asset": "build-input-release.json", "sha256": lock["release"][-64:]}):
        raise LinkInputError("invalid linker-input release identity")
    source = lock["source"]
    if (not isinstance(source, dict)
            or set(source) != {"repository", "sha", "ref", "workflow", "input_fingerprint"}
            or source["repository"] != release.REPOSITORY
            or not HEX160.fullmatch(source["sha"])
            or not isinstance(source["ref"], str) or not source["ref"].startswith("refs/heads/")
            or source["workflow"] != release.WORKFLOW
            or not HEX256.fullmatch(source["input_fingerprint"])):
        raise LinkInputError("invalid linker-input source identity")
    if not isinstance(lock["targets"], dict) or set(lock["targets"]) != set(release.PROFILES):
        raise LinkInputError("linker-input lock must select every profile exactly once")
    for profile, record in lock["targets"].items():
        if (not isinstance(record, dict) or set(record) != {"asset", "sha256", "size"}
                or record["asset"] != f"link-inputs-{profile}.tar"
                or not HEX256.fullmatch(record["sha256"])
                or type(record["size"]) is not int or not 0 < record["size"] <= MAX_ARCHIVE_BYTES):
            raise LinkInputError(f"invalid linker-input record for {profile}")
    if check_fingerprint:
        current = release.input_fingerprint(root)
        if source["input_fingerprint"] != current:
            raise LinkInputError(
                "link-inputs.lock.json is stale: the linker-input recipes or vendored inputs "
                "changed since its release was produced. Publish a new release from this "
                "branch (dependencies/link-inputs/README.md); an ordinary build never "
                "rebuilds linker inputs.")
    return lock


def asset_url(lock: dict, asset: str) -> str:
    return f"https://github.com/{lock['repository']}/releases/download/{lock['release']}/{asset}"


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def verify_file(path: Path, size: int | None, digest: str) -> None:
    if (path.is_symlink() or not path.is_file()
            or (size is not None and path.stat().st_size != size) or file_sha256(path) != digest):
        raise LinkInputError(f"{path.name} differs from its locked size or SHA-256")


def download(url: str, destination: Path, size: int | None, limit: int) -> None:
    with destination.open("wb") as output, urlopen(url, timeout=60) as response:
        written = 0
        while chunk := response.read(1024 * 1024):
            written += len(chunk)
            if written > (size if size is not None else limit):
                raise LinkInputError(f"download exceeds its locked size: {url}")
            output.write(chunk)
    if size is not None and written != size:
        raise LinkInputError(f"truncated download: {url}")


def fetch(lock: dict, asset: str, digest: str, size: int | None, cache: Path,
          limit: int = MAX_ARCHIVE_BYTES) -> Path:
    """Return the cached asset, downloading only on a miss; always rehash it."""
    cache.mkdir(parents=True, exist_ok=True)
    cached = cache / f"{digest}-{asset}"
    if cached.exists() or cached.is_symlink():
        try:
            verify_file(cached, size, digest)
        except LinkInputError:
            # A poisoned or truncated cache entry is never used. Remove it so
            # a rerun downloads the locked bytes, but fail this run: a cache
            # that returned wrong bytes is worth someone's attention.
            cached.unlink()
            raise LinkInputError(f"cached {asset} failed verification and was removed; rerun to download it")
        return cached
    with tempfile.NamedTemporaryFile(dir=cache, prefix=".download-", delete=False) as pending:
        temporary = Path(pending.name)
    try:
        download(asset_url(lock, asset), temporary, size, limit)
        verify_file(temporary, size, digest)
        os.replace(temporary, cached)
    finally:
        temporary.unlink(missing_ok=True)
    verify_file(cached, size, digest)
    return cached


def fetch_profile(lock: dict, profile: str, cache: Path) -> Path:
    record = lock["targets"][profile]
    return fetch(lock, record["asset"], record["sha256"], record["size"], cache)


def unpack(archive: Path, profile: str, lock: dict, stage: Path, root: Path = ROOT) -> None:
    """Extract a verified archive into an empty stage after checking all of it."""
    expected = release.inventory(profile, root)
    with tarfile.open(archive, "r:") as packed:
        members: dict[str, tarfile.TarInfo] = {}
        total = 0
        for member in packed:
            path = PurePosixPath(member.name)
            if (not member.isfile() or path.is_absolute() or ".." in path.parts or "\\" in member.name
                    or str(path) != member.name or member.name in members):
                raise LinkInputError(f"unsafe or duplicate archive member: {member.name!r}")
            members[member.name] = member
            total += member.size
            if len(members) > MAX_MEMBERS or total > MAX_ARCHIVE_BYTES:
                raise LinkInputError("linker-input archive exceeds extraction limits")
        info = members.get(release.MANIFEST)
        if info is None or info.size > MAX_MANIFEST_BYTES:
            raise LinkInputError("linker-input archive has no manifest")
        manifest = json.load(packed.extractfile(info))
        if (not isinstance(manifest, dict) or manifest.get("schema_version") != 1
                or manifest.get("kind") != release.KIND or manifest.get("profile") != profile
                or manifest.get("target") != release.PROFILES[profile]
                or manifest.get("input_fingerprint") != lock["source"]["input_fingerprint"]):
            raise LinkInputError(f"archive manifest does not identify the locked {profile} profile")
        files = manifest.get("files")
        if not isinstance(files, dict) or set(files) != set(members) - {release.MANIFEST}:
            raise LinkInputError("archive manifest inventory differs from its members")
        if set(files) != expected:
            missing, extra = sorted(expected - set(files)), sorted(set(files) - expected)
            raise LinkInputError(f"{profile} archive does not match the platform header: "
                                 f"missing {missing}, undeclared {extra}")
        stage.mkdir(parents=True)
        for name in sorted(files):
            record = files[name]
            if (not isinstance(record, dict) or set(record) != {"sha256", "size"}
                    or record["size"] != members[name].size):
                raise LinkInputError(f"invalid inventory record: {name}")
            destination = stage / PurePosixPath(name)
            destination.parent.mkdir(parents=True, exist_ok=True)
            with packed.extractfile(members[name]) as source, destination.open("xb") as output:
                shutil.copyfileobj(source, output)
            verify_file(destination, record["size"], record["sha256"])


def install(profiles, destination: Path, *, lock_path: Path = LOCK, cache: Path | None = None,
            targets_only: bool = False, root: Path = ROOT) -> dict:
    """Install the locked profiles under `destination` (targets/ and licenses/)."""
    lock = read_lock(lock_path, root)
    install_selected(lock, profiles, destination, cache or default_cache(), targets_only, root)
    return lock


def install_candidate(candidate: Path, profiles, destination: Path, *, targets_only: bool = False,
                      root: Path = ROOT) -> None:
    """Install from an unpublished producer candidate, for producer validation.

    The candidate's own `build-input-release.json` stands in for the lock, so
    the archives pass exactly the checks a locked release does. It is never a
    substitute for the lock in an ordinary build.
    """
    manifest_bytes = (candidate / "build-input-release.json").read_bytes()
    manifest = json.loads(manifest_bytes)
    digest = hashlib.sha256(manifest_bytes).hexdigest()
    if manifest.get("source", {}).get("input_fingerprint") != release.input_fingerprint(root):
        raise LinkInputError("candidate was produced from different linker-input sources")
    lock = {"repository": release.REPOSITORY, "release": f"link-inputs-sha256-{digest}",
            "source": manifest["source"], "targets": manifest["assets"]}
    with tempfile.TemporaryDirectory(prefix="roc-ray-link-input-candidate-") as cache_name:
        cache = Path(cache_name)
        for record in manifest["assets"].values():
            shutil.copyfile(candidate / record["asset"], cache / f"{record['sha256']}-{record['asset']}")
        install_selected(lock, profiles, destination, cache, targets_only, root)


def install_selected(lock: dict, profiles, destination: Path, cache: Path, targets_only: bool,
                     root: Path) -> None:
    roc_targets = [release.PROFILES[profile] for profile in profiles]
    if len(set(roc_targets)) != len(roc_targets):
        # X11 and Wayland both install into targets/x64glibc; one tree may hold
        # only one of them, or one would silently overwrite the other.
        raise LinkInputError("profiles sharing a Roc target cannot be installed together")
    with tempfile.TemporaryDirectory(prefix="roc-ray-link-inputs-") as temporary:
        staged = []
        for profile in profiles:
            stage = Path(temporary) / profile
            unpack(fetch_profile(lock, profile, cache), profile, lock, stage, root)
            staged.append(stage)
        for stage in staged:
            for path in sorted(stage.rglob("*")):
                if path.is_dir():
                    continue
                relative = path.relative_to(stage)
                if targets_only and relative.parts[0] != "targets":
                    continue
                target = destination / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                pending = target.with_name(f".{target.name}.link-input")
                shutil.copyfile(path, pending)
                os.replace(pending, target)


def verify_attestations(lock_path: Path = LOCK, cache: Path | None = None, root: Path = ROOT) -> None:
    """Check GitHub build provenance for the manifest and every locked archive."""
    lock = read_lock(lock_path, root)
    cache = cache or default_cache()
    source = lock["source"]
    subjects = [fetch(lock, lock["manifest"]["asset"], lock["manifest"]["sha256"], None, cache,
                      limit=MAX_MANIFEST_BYTES)]
    manifest = json.loads(subjects[0].read_text())
    if manifest.get("source") != source or manifest.get("assets") != lock["targets"]:
        raise LinkInputError("release manifest differs from link-inputs.lock.json")
    subjects += [fetch_profile(lock, profile, cache) for profile in sorted(lock["targets"])]
    for subject in subjects:
        subprocess.run([
            "gh", "attestation", "verify", str(subject),
            "--repo", lock["repository"],
            "--signer-workflow", source["workflow"],
            "--source-digest", source["sha"],
            "--source-ref", source["ref"],
        ], check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--lock", type=Path, default=LOCK)
    parser.add_argument("--cache", type=Path, default=None,
                        help="archive cache (default: $ROC_RAY_LINK_INPUT_CACHE or ~/.cache/roc-ray/link-inputs)")
    commands = parser.add_subparsers(dest="command", required=True)
    install_parser = commands.add_parser("install", help="install locked profiles under a directory")
    install_parser.add_argument("--profile", action="append", choices=sorted(release.PROFILES),
                                help="repeatable; defaults to every profile of the default package")
    install_parser.add_argument("--destination", type=Path, required=True)
    install_parser.add_argument("--targets-only", action="store_true", help="skip licenses/")
    install_parser.add_argument("--candidate", type=Path,
                                help="producer validation only: install an unpublished candidate directory")
    commands.add_parser("verify-attestations", help="verify GitHub build provenance of the locked release")
    args = parser.parse_args()
    try:
        if args.command == "install" and args.candidate:
            install_candidate(args.candidate, args.profile or DEFAULT_PROFILES, args.destination,
                              targets_only=args.targets_only)
        elif args.command == "install":
            install(args.profile or DEFAULT_PROFILES, args.destination, lock_path=args.lock,
                    cache=args.cache, targets_only=args.targets_only)
        else:
            verify_attestations(args.lock, args.cache)
    except (LinkInputError, OSError, tarfile.TarError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
