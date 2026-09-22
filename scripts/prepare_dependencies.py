#!/usr/bin/env python3
"""Install RocRay's exact digest-locked linker inputs for local builds."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile

from dependency_artifacts import materialize

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "dependencies.lock.json"
CACHE = Path(os.environ.get("ROC_RAY_DEPENDENCY_CACHE", Path.home() / ".cache/roc-ray/dependencies"))
MACOS_INTERFACES = "macos-interfaces-macos-sysroot"


def install_macos_interfaces(destination: Path, lock: Path = LOCK, cache: Path = CACHE) -> dict:
    """Atomically replace the generated tree with the exact reviewed release."""
    with tempfile.TemporaryDirectory(prefix="roc-ray-macos-interfaces-") as temporary:
        inputs = Path(temporary) / "inputs"
        entry = materialize(lock, MACOS_INTERFACES, cache, inputs)
        manifest = json.loads((inputs / "dependency.json").read_text())
        tree = inputs / "targets/macos-sysroot"
        catalog = (tree / "interfaces.json").read_bytes()
        expected = {"targets/macos-sysroot/" + path.relative_to(tree).as_posix()
                    for path in tree.rglob("*") if path.is_file()}
        if (set(manifest["files"]) != expected
                or manifest.get("catalog_sha256") != hashlib.sha256(catalog).hexdigest()):
            raise ValueError("macOS interface release differs from its catalog or inventory")

        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=destination.parent, prefix=".macos-interfaces-") as staging:
            stage = Path(staging) / destination.name
            shutil.copytree(tree, stage)
            if destination.is_symlink():
                destination.unlink()
            elif destination.exists():
                shutil.rmtree(destination)
            stage.rename(destination)
        return entry


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=LOCK)
    parser.add_argument("--cache", type=Path, default=CACHE)
    parser.add_argument("--output", type=Path, default=ROOT / "platform/targets/macos-sysroot")
    args = parser.parse_args()
    install_macos_interfaces(args.output, args.lock, args.cache)
