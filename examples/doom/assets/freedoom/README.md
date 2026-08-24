# Freedoom assets

This directory contains a small asset subset for the RocRay Doom-style vertical
slice. It is derived from the official Freedoom 0.13.0 source release. The
upstream archive itself is deliberately not committed.

Generated files are ready for RocRay: `generated/atlas.png` is one RGBA texture,
`generated/atlas.json` gives pixel rectangles for each named image, and
`generated/audio/` contains WAV sound effects. The application should load the
directory rooted at `examples/doom/assets` and refer to these files relative to
that root.

The atlas includes walls, doors, switch and exit decorations, floor and ceiling
flats, pickups and animated keycards, HUD elements, the pistol, and a complete
eight-angle walk/attack/pain set plus death animation for one enemy. The older
short names (`enemy_walk_0`, for example) remain aliases by content for the
initial renderer; names ending in `_1` through `_8` follow Doom's viewing-angle
convention.

Regenerate from the repository root with Python 3 and the pinned Pillow version:

```sh
python3 -m pip install -r scripts/doom_assets_requirements.txt
python3 scripts/doom_assets.py
python3 scripts/doom_assets.py --check
```

The genuine Phase 1 E1M1 extraction is a separate reproducible stage:

```sh
python3 scripts/doom_wad.py
python3 scripts/doom_wad.py --check
```

It downloads the official binary release, verifies both the ZIP and embedded
`freedoom1.wad`, parses the classic Doom map lumps, and composes every wall
texture plus every flat and thing sprite referenced by E1M1. See
`docs/E1M1.md` for the generated schema and known scope limits. The 61 MB ZIP
and 28 MB WAD are not committed; `--archive` permits an offline rebuild.

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

Freedoom 0.13.0 supplies its music as MIDI files. RocRay's music loader does not
load MIDI, and reproducible rendering would require pinning a synthesizer and a
separately licensed soundfont. This pipeline therefore deliberately includes no
music rather than adding a heavyweight or legally ambiguous conversion step.
