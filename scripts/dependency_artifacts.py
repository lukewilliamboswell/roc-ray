#!/usr/bin/env python3
"""Fetch digest-locked dependency releases and extract reviewed contents safely."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
import tempfile
from urllib.request import urlopen

MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
MAX_FILES = 2048
HEX256 = re.compile(r"[0-9a-f]{64}")
HEX160 = re.compile(r"[0-9a-f]{40}")
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")


def sha256(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def read_lock(path: Path) -> dict:
    lock = json.loads(path.read_text())
    if set(lock) != {"schema_version", "artifacts"} or lock["schema_version"] != 1:
        raise ValueError("unsupported dependency lock")
    if not isinstance(lock["artifacts"], dict) or not lock["artifacts"]:
        raise ValueError("dependency lock must contain artifacts")
    for identity, entry in lock["artifacts"].items():
        required = {"name", "target", "repository", "release", "asset", "sha256", "size",
                    "source_sha", "source_ref", "signer_workflow", "input_fingerprint"}
        if not IDENTIFIER.fullmatch(identity) or set(entry) != required:
            raise ValueError("invalid dependency lock entry")
        for field in ("name", "target", "release", "asset"):
            if not isinstance(entry[field], str) or not IDENTIFIER.fullmatch(entry[field]):
                raise ValueError(f"invalid dependency {field}")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", entry["repository"]):
            raise ValueError("invalid dependency repository")
        if not HEX256.fullmatch(entry["sha256"]) or not HEX256.fullmatch(entry["input_fingerprint"]):
            raise ValueError("invalid dependency digest")
        if not HEX160.fullmatch(entry["source_sha"]):
            raise ValueError("invalid dependency source commit")
        if type(entry["size"]) is not int or not 0 < entry["size"] <= MAX_ARCHIVE_BYTES:
            raise ValueError("invalid dependency archive size")
        if entry["source_ref"] != "refs/heads/main":
            raise ValueError("dependency provenance must identify trusted main")
        prefix = entry["repository"] + "/.github/workflows/"
        if not entry["signer_workflow"].startswith(prefix):
            raise ValueError("invalid dependency signer workflow")
    return lock


def verify_archive(path: Path, entry: dict) -> None:
    if path.is_symlink() or path.stat().st_size != entry["size"] or sha256(path) != entry["sha256"]:
        raise ValueError("dependency archive differs from locked digest or size")


def fetch(entry: dict, cache: Path) -> Path:
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / (entry["sha256"] + ".tar")
    if not archive.exists():
        url = (f"https://github.com/{entry['repository']}/releases/download/"
               f"{entry['release']}/{entry['asset']}")
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as pending:
            temporary = Path(pending.name)
        try:
            with temporary.open("wb") as output, urlopen(url, timeout=60) as response:
                remaining = entry["size"]
                while remaining:
                    chunk = response.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise ValueError("truncated dependency download")
                    output.write(chunk)
                    remaining -= len(chunk)
                if response.read(1):
                    raise ValueError("dependency download exceeds locked size")
            verify_archive(temporary, entry)
            try:
                os.link(temporary, archive)
            except FileExistsError:
                pass
        finally:
            temporary.unlink(missing_ok=True)
    verify_archive(archive, entry)
    return archive


def unpack_verified(archive: Path, entry: dict, destination: Path) -> dict:
    if destination.exists() or destination.is_symlink():
        raise ValueError("dependency extraction destination already exists")
    with tarfile.open(archive, "r:") as packed:
        members = {}
        total = 0
        for member in packed:
            path = PurePosixPath(member.name)
            if (not member.isfile() or path.is_absolute() or ".." in path.parts
                    or str(path) != member.name or "\\" in member.name or member.name in members):
                raise ValueError("unsafe or duplicate dependency archive member")
            members[member.name] = member
            total += member.size
            if len(members) > MAX_FILES or total > MAX_ARCHIVE_BYTES:
                raise ValueError("dependency archive exceeds extraction limits")
        metadata = members.get("dependency.json")
        if metadata is None or metadata.size > 1024 * 1024:
            raise ValueError("missing or oversized dependency manifest")
        manifest = json.load(packed.extractfile(metadata))
        if (manifest.get("schema_version") != 1 or manifest.get("name") != entry["name"]
                or manifest.get("target") != entry["target"]):
            raise ValueError("dependency manifest identity mismatch")
        files = manifest.get("files")
        if not isinstance(files, dict) or set(files) != set(members) - {"dependency.json"}:
            raise ValueError("dependency file inventory differs from archive")
        for name, record in files.items():
            if (not name.startswith(f"targets/{entry['target']}/")
                    or set(record) != {"size", "sha256"}
                    or record["size"] != members[name].size
                    or not HEX256.fullmatch(record["sha256"])):
                raise ValueError("invalid dependency file record")
            with packed.extractfile(members[name]) as source:
                if hashlib.file_digest(source, "sha256").hexdigest() != record["sha256"]:
                    raise ValueError("dependency file digest mismatch")
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=destination.parent, prefix=".dependency-") as temporary:
            stage = Path(temporary) / "contents"
            stage.mkdir()
            for name, member in members.items():
                path = stage / name
                path.parent.mkdir(parents=True, exist_ok=True)
                with packed.extractfile(member) as source, path.open("xb") as output:
                    shutil.copyfileobj(source, output)
            stage.rename(destination)
    return manifest


def materialize(lock_path: Path, identity: str, cache: Path, output: Path) -> dict:
    entry = read_lock(lock_path)["artifacts"][identity]
    archive = fetch(entry, cache)
    unpack_verified(archive, entry, output)
    return entry


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--artifact", required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    materialize(args.lock, args.artifact, args.cache, args.output)
