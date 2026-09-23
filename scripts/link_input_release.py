#!/usr/bin/env python3
"""Compose RocRay's linker-input release candidate from a producer build.

This is the producer side of `link-inputs.lock.json`. It packs each profile
built by `zig build link-inputs` into one deterministic archive and writes the
`build-input-release.json` manifest that roc-automation's trusted publisher
admits. Ordinary builds never run it; see `scripts/link_inputs.py` for the
consumer and `dependencies/link-inputs/README.md` for the procedure.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "lukewilliamboswell/roc-ray"
WORKFLOW = f"{REPOSITORY}/.github/workflows/link-inputs.yml"
KIND = "roc-ray-link-inputs"
MANIFEST = "link-inputs.json"

# Profile -> Roc target directory. X11 and Wayland share Roc's `x64glibc`
# target but not their bytes, so they are separate profiles with separate
# archives, and each archive's manifest names its profile.
PROFILES = {
    "x64mac": "x64mac",
    "arm64mac": "arm64mac",
    "x64glibc-x11": "x64glibc",
    "x64glibc-wayland": "x64glibc",
    "x64win": "x64win",
}

# Which platform header each profile serves. The inventory a profile must
# contain is derived from that header's `targets` block, so a linker input
# added there without a matching release fails rather than going unnoticed.
PLATFORM_HEADERS = {
    "x64mac": "platform/main.roc",
    "arm64mac": "platform/main.roc",
    "x64glibc-x11": "platform/main.roc",
    "x64glibc-wayland": "platform/main-wayland.roc",
    "x64win": "platform/main.roc",
}

# Host outputs are built from the checkout on every build, never released here.
HOST_OUTPUTS = {"libhost.a", "host.lib"}

LICENSES = ("LICENSE.libvpx", "PATENTS.libvpx", "AUTHORS.libvpx")

# Every committed path that can change a profile's bytes. Their git tree
# records form the producer-input fingerprint, which a consumer recomputes to
# tell whether the locked release still matches the checkout. The Zig version
# is pinned by the producer workflow, which is itself listed.
SOURCE_PATHS = (
    "link_inputs.zig",
    "vendor/raylib",
    "vendor/msf_gif",
    "vendor/libvpx",
    "vendor/sqlite",
    "platform/targets/x64glibc/Scrt1.o",
    "platform/targets/x64glibc/crti.o",
    "platform/targets/x64glibc/crtn.o",
    "platform/targets/x64glibc/libc_stub.s",
    "platform/targets/x64glibc/libm_stub.s",
    "platform/targets/windows-def",
    "scripts/link_input_release.py",
    ".github/workflows/link-inputs.yml",
)


def input_fingerprint(root: Path = ROOT) -> str:
    """Hash the committed tree records of every producer input.

    Uncommitted edits to those paths are refused: the fingerprint names a
    commit's inputs, and a working-tree change is not one.
    """
    changed = subprocess.run(["git", "diff", "--quiet", "HEAD", "--", *SOURCE_PATHS], cwd=root).returncode
    untracked = subprocess.check_output(
        ["git", "ls-files", "--others", "--exclude-standard", "-z", "--", *SOURCE_PATHS], cwd=root)
    if changed or untracked:
        raise ValueError(
            "linker-input producer inputs have uncommitted changes; commit them, then run "
            "the linker-input producer (see dependencies/link-inputs/README.md)")
    tree = subprocess.check_output(
        ["git", "ls-tree", "-r", "-z", "--full-tree", "HEAD", "--", *SOURCE_PATHS], cwd=root)
    if not tree:
        raise ValueError("linker-input source inventory is empty")
    return hashlib.sha256(tree).hexdigest()


def declared_inputs(profile: str, root: Path = ROOT) -> list[str]:
    """The linker inputs the platform header names for this profile's target."""
    header = (root / PLATFORM_HEADERS[profile]).read_text()
    target = PROFILES[profile]
    match = re.search(rf"^\s*{target}:\s*\{{\s*inputs:\s*\[(.*?)\]", header, re.MULTILINE)
    if match is None:
        raise ValueError(f"{PLATFORM_HEADERS[profile]} declares no {target} inputs")
    names = re.findall(r'"([^"]+)"', match.group(1))
    return sorted(name for name in names if name not in HOST_OUTPUTS)


def inventory(profile: str, root: Path = ROOT) -> set[str]:
    """Every file a profile archive must contain, besides its manifest."""
    target = PROFILES[profile]
    return ({f"targets/{target}/{name}" for name in declared_inputs(profile, root)}
            | {f"licenses/{name}" for name in LICENSES})


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_archive(output: Path, manifest: dict, files: dict[str, bytes]) -> None:
    """Write a byte-reproducible ustar archive: sorted, fixed mode, zero mtime."""
    payload = dict(files)
    payload[MANIFEST] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name in sorted(payload):
            member = tarfile.TarInfo(name)
            member.size = len(payload[name])
            member.mode = 0o644
            member.mtime = 0
            archive.addfile(member, io.BytesIO(payload[name]))
    output.write_bytes(buffer.getvalue())


def compose_profile(profile: str, tree: Path, output: Path, fingerprint: str, root: Path = ROOT) -> Path:
    built = tree / profile
    expected = inventory(profile, root)
    present = {path.relative_to(built).as_posix() for path in built.rglob("*") if not path.is_dir()}
    if present != expected:
        missing, extra = sorted(expected - present), sorted(present - expected)
        raise ValueError(f"{profile} build differs from its declared inputs: missing {missing}, extra {extra}")
    files = {}
    for name in sorted(expected):
        path = built / PurePosixPath(name)
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"{profile} input is not a regular file: {name}")
        files[name] = path.read_bytes()
    manifest = {
        "schema_version": 1,
        "kind": KIND,
        "profile": profile,
        "target": PROFILES[profile],
        "input_fingerprint": fingerprint,
        "files": {name: {"sha256": sha256(data), "size": len(data)} for name, data in files.items()},
    }
    archive = output / f"link-inputs-{profile}.tar"
    write_archive(archive, manifest, files)
    return archive


def compose(tree: Path, output: Path, source: dict | None = None, root: Path = ROOT) -> dict:
    """Pack every profile and write the publisher's release manifest."""
    output.mkdir(parents=True, exist_ok=False)
    fingerprint = input_fingerprint(root)
    archives = {profile: compose_profile(profile, tree, output, fingerprint, root) for profile in PROFILES}
    source = source or {
        "repository": os.environ.get("GITHUB_REPOSITORY", REPOSITORY),
        "sha": os.environ.get("GITHUB_SHA") or subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "ref": os.environ.get("GITHUB_REF", "refs/heads/local"),
        "workflow": WORKFLOW,
        "input_fingerprint": fingerprint,
    }
    manifest = {
        "schema_version": 1,
        "kind": KIND,
        "source": source,
        "assets": {
            profile: {"asset": path.name, "sha256": sha256(path.read_bytes()), "size": path.stat().st_size}
            for profile, path in archives.items()
        },
    }
    (output / "build-input-release.json").write_text(
        json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tree", type=Path, default=ROOT / "zig-out/link-inputs",
                        help="output of `zig build link-inputs`")
    parser.add_argument("--output", type=Path, required=True, help="new directory for the candidate")
    args = parser.parse_args()
    manifest = compose(args.tree, args.output)
    for profile, asset in manifest["assets"].items():
        print(f"{profile}: {asset['asset']} {asset['sha256']} {asset['size']}")


if __name__ == "__main__":
    main()
