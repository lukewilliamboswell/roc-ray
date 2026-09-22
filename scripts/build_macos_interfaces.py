#!/usr/bin/env python3
"""Build independently releasable macOS final-link interfaces."""

import argparse
import json
from pathlib import Path
import tempfile

from build_macos_stubs import CATALOG, PROVENANCE, digest, read_catalog, render
from dependency_archive import write_archive

ROOT = Path(__file__).resolve().parents[1]
NAME = "macos-interfaces"
TARGET = "macos-sysroot"
IDENTITY = NAME + "-" + TARGET


def interface_files():
    """Return the exact target-relative inventory selected by the catalog."""
    return tuple(sorted(library["path"] for library in read_catalog()["libraries"]))


def build(output, *, root=ROOT):
    """Write deterministic catalog-derived interfaces without reading host or SDK bytes."""
    catalog_path = root / CATALOG.relative_to(ROOT)
    provenance_path = root / PROVENANCE.relative_to(ROOT)
    catalog_bytes = catalog_path.read_bytes()
    provenance = provenance_path.read_bytes()
    catalog = read_catalog(catalog_path)
    generated = render(catalog)
    manifest = {
        "schema_version": 1,
        "origin": "project-generated-macos-interfaces",
        "target": catalog["target"],
        "catalog_sha256": digest(catalog_bytes),
        "generator_sha256": digest(Path(__file__).read_bytes()),
        "provenance_sha256": digest(provenance),
        "files_sha256": {name: digest(data) for name, data in sorted(generated.items())},
    }
    prefix = f"targets/{TARGET}/"
    files = {prefix + name: data for name, data in generated.items()}
    files[prefix + "interfaces.json"] = catalog_bytes
    files[prefix + "PROVENANCE.md"] = provenance
    files[prefix + "manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    archive = output / f"{NAME}-{TARGET}.tar"
    write_archive(archive, {
        "schema_version": 1,
        "name": NAME,
        "target": TARGET,
        "catalog_sha256": manifest["catalog_sha256"],
    }, files)
    return archive


def write_tree(output, *, root=ROOT):
    """Materialize the same reviewed payload used by the release archive."""
    from dependency_artifacts import unpack_verified
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent, prefix=".macos-interfaces-") as temporary:
        stage = Path(temporary)
        archive = build(stage / "archive", root=root)
        unpacked = stage / "unpacked"
        unpack_verified(archive, {"name": NAME, "target": TARGET}, unpacked)
        source = unpacked / "targets" / TARGET
        if output.exists() or output.is_symlink():
            raise FileExistsError(output)
        source.rename(output)
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    destination = parser.add_mutually_exclusive_group(required=True)
    destination.add_argument("--output", type=Path)
    destination.add_argument("--tree", type=Path)
    args = parser.parse_args()
    result = build(args.output.resolve()) if args.output else write_tree(args.tree.resolve())
    print(result)
