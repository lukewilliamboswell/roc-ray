#!/usr/bin/env python3
"""Publish tested macOS interfaces and a consumer-lock candidate."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from dependency_artifacts import read_lock, sha256, unpack_verified, verify_archive

REPOSITORY = "lukewilliamboswell/roc-ray"
NAME = "macos-interfaces"
TARGET = "macos-sysroot"
ASSET = f"{NAME}-{TARGET}.tar"
WORKFLOW = f"{REPOSITORY}/.github/workflows/macos-interface-dependencies.yml"


def prepare(directory: Path, tag: str, environment: dict[str, str]) -> list[Path]:
    if (environment.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
            or environment.get("GITHUB_REF") != "refs/heads/main"
            or environment.get("GITHUB_REPOSITORY") != REPOSITORY):
        raise ValueError("macOS interface publication requires an explicit main dispatch")
    source = environment.get("GITHUB_SHA", "")
    if (not re.fullmatch(r"[0-9a-f]{40}", source)
            or not re.fullmatch(r"deps-macos-interfaces-[0-9][A-Za-z0-9.-]*", tag)):
        raise ValueError("invalid macOS interface release identity")
    if subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip() != source:
        raise ValueError("release checkout differs from tested source")
    archive = directory / ASSET
    entry = {
        "name": NAME, "target": TARGET, "repository": REPOSITORY,
        "release": tag, "asset": ASSET, "sha256": sha256(archive),
        "size": archive.stat().st_size, "source_sha": source,
        "source_ref": "refs/heads/main", "signer_workflow": WORKFLOW,
    }
    verify_archive(archive, entry)
    with tempfile.TemporaryDirectory(prefix="roc-ray-macos-release-") as temporary:
        manifest = unpack_verified(archive, entry, Path(temporary) / "contents")
    identity = {key: value for key, value in manifest.items() if key != "files"}
    entry["input_fingerprint"] = hashlib.sha256(
        json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    lock = directory / "dependencies.lock.json"
    lock.write_text(json.dumps({"schema_version": 1, "artifacts": {
        f"{NAME}-{TARGET}": entry,
    }}, indent=2) + "\n", encoding="utf-8")
    read_lock(lock)
    return [archive, lock]


def publish(directory: Path, tag: str) -> None:
    assets = prepare(directory, tag, os.environ)
    existing = json.loads(subprocess.check_output([
        "gh", "api", f"repos/{REPOSITORY}/git/matching-refs/tags/{tag}"
    ], text=True))
    if any(item["ref"] == "refs/tags/" + tag for item in existing):
        raise ValueError("release tag already exists; published inputs are immutable")
    notes = directory / "release-notes.md"
    notes.write_text(
        "Project-authored macOS linker interfaces generated and tested from "
        f"RocRay commit `{os.environ['GITHUB_SHA']}`. The archive contains its "
        "reviewed catalog, provenance statement, generator identity, and exact "
        "file hashes. GitHub build provenance binds the archive digest to the "
        "producer workflow. Adopt the attached lock in a separate review.\n",
        encoding="utf-8",
    )
    subprocess.run([
        "gh", "release", "create", tag, *map(str, assets), "--repo", REPOSITORY,
        "--target", os.environ["GITHUB_SHA"], "--latest=false", "--draft",
        "--title", f"macOS linker interfaces {tag}", "--notes-file", str(notes),
    ], check=True)
    subprocess.run(["gh", "release", "edit", tag, "--repo", REPOSITORY, "--draft=false"], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    publish(args.directory, args.tag)
