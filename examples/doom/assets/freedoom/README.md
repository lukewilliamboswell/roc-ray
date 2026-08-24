# Freedoom assets

This directory contains a small asset subset for the RocRay Doom-style vertical
slice. It is derived from the official Freedoom 0.13.0 source release. The
upstream archive itself is deliberately not committed.

Generated files are ready for RocRay: `generated/atlas.png` is one RGBA texture,
`generated/atlas.json` gives pixel rectangles for each named image, and
`generated/audio/` contains WAV sound effects. The application should load the
directory rooted at `examples/doom/assets` and refer to these files relative to
that root.

Regenerate from the repository root with Python 3 and Pillow 10 or newer:

```sh
python3 scripts/doom_assets.py
python3 scripts/doom_assets.py --check
```

For an offline rebuild, download the archive named in `source/manifest.json`
and pass `--archive /path/to/freedoom-v0.13.0.tar.gz`. The script verifies its
SHA-256 before reading it. It selects only the listed upstream files, performs
no lossy conversion, and writes PNG output deterministically with a fixed atlas
layout.

## Licence and attribution

Freedoom is copyright 2001–2024 by contributors to the Freedoom project and is
distributed under the modified BSD licence in `license/COPYING.adoc`. The full
upstream contributor list is retained in `attribution/CREDITS`. The atlas is a
mechanical composite and the renamed WAV files are byte-for-byte copies; these
changes do not imply endorsement by Freedoom or its contributors.

The source manifest records the pinned release, archive checksum, exact selected
upstream paths, and each selected file's checksum. Keep the licence, credits,
manifest, and this notice with redistributed generated assets.
