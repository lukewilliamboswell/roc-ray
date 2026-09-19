# Freedoom assets

This directory contains a small asset subset for the RocRay Doom-style vertical
slice. It is derived from the official Freedoom 0.13.0 source release. The
upstream archive itself is deliberately not committed.

Generated files are ready for RocRay: `generated/atlas.png` is one RGBA texture,
`generated/atlas.json` gives pixel rectangles for each named image, and
`generated/audio/` contains WAV sound effects. The application should load the
directory rooted at `examples/roc-doom-e1m1/assets` and refer to these files relative to
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
texture plus every flat and thing sprite referenced by E1M1. It also extracts
the first-person weapon, combat-effect, explosion, and status-bar graphics the
level can produce during play. It also decodes the strict E1M1 gameplay sound
set from WAD DMX lumps to deterministic mono 8-bit PCM WAV files under
`generated/e1m1/sounds/`; the manifest records logical names, source lumps,
sample metadata, and source/output checksums. See
`docs/E1M1.md` for the generated schema and known scope limits. The 61 MB ZIP
and 28 MB WAD are not committed; `--archive` permits an offline rebuild.

For an offline source-atlas rebuild, download the archive named in
`source/manifest.json` and pass it to `doom_assets.py --archive`. For an offline
E1M1 WAD rebuild, use the release ZIP named in `source/e1m1_release.json` with
`doom_wad.py --archive`. Each script verifies its archive SHA-256 before
reading it. The source-atlas stage selects only its listed upstream files and
the WAD stage extracts only its declared map/gameplay set; both write their
outputs deterministically.

## Licence and attribution

Freedoom is copyright 2001–2024 by contributors to the Freedoom project and is
distributed under the modified BSD licence in `license/COPYING.adoc`. The full
upstream contributor list is retained in `attribution/CREDITS`. The atlas is a
mechanical composite. WAD samples are unchanged inside mechanically generated
WAV containers; these changes do not imply endorsement by Freedoom or its
contributors.

The source manifest records the pinned release, archive checksum, exact selected
upstream paths, and each selected file's checksum. Keep the licence, credits,
manifest, and this notice with redistributed generated assets.

Freedoom 0.13.0 supplies E1M1 as standard MIDI. The WAD stage retains the exact
MIDI and renders `generated/e1m1/music/e1m1.wav` with the project-authored,
dependency-free procedural bank in `scripts/doom_midi.py`. No soundfont or
third-party instrument samples are incorporated. The renderer validates every
used program and percussion note, supports the file's tempo, volume, pitch-bend
and pitch-sensitivity events, and writes deterministic mono 16-bit PCM suitable
for RocRay's streaming music loader. The manifest records the complete bank
requirements and both MIDI/WAV checksums. The renderer source is original
RocRay project code covered by this repository's licence; the musical
composition remains Freedoom content covered and credited above.
