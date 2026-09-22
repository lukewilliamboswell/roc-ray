"""Write deterministic dependency archives."""

import hashlib
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_archive(output: Path, metadata: dict, files: dict[str, bytes]) -> Path:
    if "dependency.json" in files or "files" in metadata:
        raise ValueError("dependency manifest and inventory are generated")
    manifest = dict(metadata, files={
        name: {"sha256": digest(data), "size": len(data)}
        for name, data in sorted(files.items())
    })
    payload = dict(files, **{
        "dependency.json": (json.dumps(manifest, indent=2) + "\n").encode()
    })
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as pending:
        temporary = Path(pending.name)
    try:
        with tarfile.open(temporary, "w", format=tarfile.USTAR_FORMAT) as archive:
            for name, data in sorted(payload.items()):
                member = tarfile.TarInfo(name)
                member.size = len(data)
                member.mode = 0o644
                archive.addfile(member, io.BytesIO(data))
        os.link(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    return output
