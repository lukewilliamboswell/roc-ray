# Third-party licences

RocRay itself is licensed under the Universal Permissive License v1.0; see
[`LICENSE`](LICENSE). That grant covers only code and data authored by this
project. It does **not** cover the third-party components listed below, each of
which keeps its own licence and its own copyright holders.

This file is a register, not a replacement. Several of these licences require
that their notice travel with the code or assets they cover, so the licence
texts stay next to the files they apply to. This page exists so you can find
them all from one place; the linked files remain authoritative.

## How to use this file

- Adding a vendored library or an asset pack means adding a row here **and**
  keeping the upstream licence text inside the vendored directory.
- Do not delete an in-tree `LICENSE`, `COPYING`, `CREDITS`, or `PATENTS` file
  to tidy the tree. For the BSD-, OFL-, and zlib-licensed components below,
  retaining that notice is a condition of redistribution.
- When a component is re-vendored at a new version, re-check its licence text;
  upstream projects do relicense.

## Platform and host components

| Component | Version | Licence | Text |
| --- | --- | --- | --- |
| [raylib](https://github.com/raysan5/raylib) | 6.0 | zlib/libpng | [`vendor/raylib/LICENSE`](vendor/raylib/LICENSE) |
| [libvpx](https://github.com/webmproject/libvpx) | vendored | BSD 3-Clause + [additional patent grant](vendor/libvpx/PATENTS) | [`vendor/libvpx/LICENSE`](vendor/libvpx/LICENSE) |
| [SQLite](https://sqlite.org) | vendored amalgamation | Public domain | [`vendor/sqlite/sqlite3.h`](vendor/sqlite/sqlite3.h) (header notice) |
| [msf_gif](https://github.com/notnullnotvoid/msf_gif) | vendored | Dual: MIT **or** Unlicense (public domain), at your option | [`vendor/msf_gif/msf_gif.h`](vendor/msf_gif/msf_gif.h) (end of file) |
| [zio](https://github.com/lalinsky/zio) | v0.17.0 | Confirm upstream before release | Build-time dependency fetched by `build.zig.zon`; not vendored or redistributed in this tree |

`vendor/raylib/` ships prebuilt static libraries for four targets. The zlib
licence permits static linking into closed-source software and does not require
attribution for binary redistribution, but the notice is retained regardless.

## Example assets

| Asset set | Used by | Licence | Text |
| --- | --- | --- | --- |
| [Freedoom](https://github.com/freedoom/freedoom) 0.13.0 Phase 1 | `examples/roc-doom-e1m1` | Modified BSD (3-clause) | [`COPYING.adoc`](examples/roc-doom-e1m1/assets/freedoom/license/COPYING.adoc) |
| Kenney — New Platformer Pack 1.0 | `examples/cave_climb` | CC0 1.0 | [`License.txt`](examples/cave_climb/assets/kenney-platformer/License.txt) |
| Kenney — Top-down pack | `examples/top_down` | CC0 1.0 | [`LICENSE.txt`](examples/top_down/assets/kenney-topdown/LICENSE.txt) |
| Kenney — Impact sounds | `examples/top_down` | CC0 1.0 | [`LICENSE-impact-sounds.txt`](examples/top_down/assets/kenney-audio/LICENSE-impact-sounds.txt) |
| Kenney — Music jingles | `examples/top_down` | CC0 1.0 | [`LICENSE-music-jingles.txt`](examples/top_down/assets/kenney-audio/LICENSE-music-jingles.txt) |
| Liberation Sans | `examples/live_plot` | SIL Open Font License 1.1 | [`LICENSE.txt`](examples/live_plot/assets/fonts/LICENSE.txt) |

Liberation Sans is embedded into the built `live_plot` binary as a byte list.
The OFL permits this; the Reserved Font Names must not be used for a modified
version of the font.

## Freedoom assets in detail

The Doom example redistributes a generated subset of Freedoom 0.13.0 Phase 1:
one texture atlas, per-level graphics, decoded sound effects, and the E1M1 MIDI.
Freedoom is copyright 2001–2024 by contributors to the Freedoom project and is
distributed under the modified BSD licence linked above.

Retained alongside the assets, and required to travel with any redistribution:

- [`license/COPYING.adoc`](examples/roc-doom-e1m1/assets/freedoom/license/COPYING.adoc) — the licence text.
- [`attribution/CREDITS`](examples/roc-doom-e1m1/assets/freedoom/attribution/CREDITS) and
  [`attribution/CREDITS-MUSIC`](examples/roc-doom-e1m1/assets/freedoom/attribution/CREDITS-MUSIC) — the upstream contributor list.
- `source/manifest.json` and `source/e1m1_release.json` — the pinned release, archive
  checksum, exact selected upstream paths, and each file's checksum.

The upstream ZIP and WAD are deliberately not committed; the generation scripts
download and verify them by SHA-256. Original commercial Doom data from id
Software is never an input to any stage, and none is redistributed here.

The BSD licence's third clause means the Freedoom name must not be used to
endorse or promote this project. Nothing here implies endorsement by Freedoom or
its contributors. The generated atlas and WAV containers are mechanical
composites of unchanged Freedoom samples.

`scripts/doom_midi.py` renders the Freedoom E1M1 MIDI to WAV using a
project-authored, dependency-free procedural instrument bank. No soundfont or
third-party instrument samples are incorporated: the renderer is RocRay code
under this repository's licence, while the musical composition remains Freedoom
content credited above.

## Behavioural references

The Doom example implements a Doom-compatible engine. Its observable rules and
constants were identified from the [Doom Wiki](https://doomwiki.org) and from
the pinned Freedoom data, and validated against
[Chocolate Doom](https://github.com/chocolate-doom/chocolate-doom) as a runtime
oracle — running the same WAD and command stream and comparing outputs.

Chocolate Doom is GPL-2.0-or-later and is **not** vendored, linked, or
redistributed here. No code, tables, identifiers, or comments from it appear in
this repository. Facts about how the engine behaves are not themselves covered
by its licence; the implementation is original Roc under this repository's
licence.
