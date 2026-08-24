# Libre Doom fidelity plan

This branch is implementing a Doom-compatible game over Freedoom data, not a
generic FPS styled with Freedoom art. Chocolate Doom is the behavioural oracle;
Freedoom 0.13.0 Phase 1 is the pinned content set. GPL source is consulted to
identify observable behaviour and constants, but code is not copied into Roc.

## Evidence matrix

| Area | Reference | Completion evidence |
| --- | --- | --- |
| Map data | Freedoom Phase 1 E1M1 WAD lumps | Checked-in deterministic extraction with source checksum; counts and cross-references validated |
| Timing | Doom 35 Hz game tic | Tests show the same command stream produces the same tic trace across different host-cycle deltas, with bounded catch-up |
| Player movement | Chocolate Doom `p_user.c`, `p_map.c`, `p_mobj.c` | Deterministic regression traces cover thrust, turning, friction, stopping, collision radius, wall sliding, and narrow-portal recovery; these are not yet cross-engine golden traces |
| Sectors | Doom linedefs, sidedefs, sectors and subsectors | E1M1 renders floor/ceiling heights, textures, offsets, sky and moving sectors; special-1 random flashes and synchronized special-12 strobes use explicit tic/RNG state, special-7 floors damage on the 32-tic cadence, and special-9 discoveries count once |
| Interaction | Chocolate Doom `p_map.c`, `p_doors.c`, `p_spec.c` | Use and crossing specials operate the corresponding E1M1 doors, switches and exit |
| Things | Doom thing types and difficulty flags | Player start, enemies, weapons, ammo, health, keys and decorations come from E1M1 data |
| Combat | Chocolate Doom `p_pspr.c`, `p_map.c`, `p_inter.c`, `info.c` | Deterministic tests cover weapon ownership, typed selection, dry-ammo fallback, cadence, ammunition, hitscan spread, damage, pain and death states; several exact weapon state chains remain incomplete |
| Enemies | Chocolate Doom `p_enemy.c`, `p_mobj.c`, `info.c` | Look, wake, chase, attack, pain and death use explicit 35 Hz durations, with deterministic sound propagation and infighting; exact per-frame state tables remain approximations |
| Presentation | Chocolate Doom screenshots and state | Native captures validate distinct, nonblank 320x200 start, combat and moving-door frames; animated lights are deterministic, while cross-engine screenshot parity and full status-face priority are not yet evidenced |
| Audio | Freedoom sounds and music | Actor alert/attack/pain/death and projectile/explosion effects use listener-relative pan and distance attenuation; activated doors, switches, and platforms use the interaction position, while player/weapon/pickup feedback stays centered. Playback is capped at 16 semantic cues per host cycle, and the reproducibly rendered Freedoom track accompanies a complete run |
| Whole level | Chocolate Doom running the same pinned WAD | The frozen `DoomReplay` ordinary-command fixture completes E1M1 and asserts route/state checkpoints; representative native frames are structurally validated, not compared with Chocolate Doom |

## Reference map

- `p_user.c`: command turning, thrust, view height and bob.
- `p_map.c`: line/thing collision, openings, hitscan and use traversal.
- `p_mobj.c`: momentum, friction, state advancement and object movement.
- `p_enemy.c`: perception, chase direction and attack decisions.
- `p_pspr.c`: weapon state machines and firing actions.
- `p_inter.c`: damage, armour, ammunition and pickups.
- `p_doors.c`, `p_floor.c`, `p_spec.c`: line specials and moving sectors.
- `r_data.c`, `r_bsp.c`, `r_segs.c`, `r_plane.c`, `r_things.c`: map-derived rendering.

## Authoritative implementation references

References are used in this order: pinned Freedoom bytes define this level and
its presentation assets; the Doom Wiki documents the binary contract and
established terminology; Chocolate Doom is the executable behavioural oracle.
Chocolate Doom is GPL-2.0-or-later ([repository and fidelity
goal](https://github.com/chocolate-doom/chocolate-doom), [licence
text](https://github.com/chocolate-doom/chocolate-doom/blob/master/COPYING.md)).
Its source may be read to identify observable rules and constants, but no code,
tables, or comments are copied into this implementation. Tests record inputs
and independently observed outputs rather than importing GPL implementation.

- **Movement and timing.** Use the Doom Wiki's [Doom
  engine](https://doomwiki.org/wiki/Doom_engine) overview for the 35 Hz,
  fixed-point model, then check Chocolate Doom's
  [`p_user.c`](https://github.com/chocolate-doom/chocolate-doom/blob/master/src/doom/p_user.c),
  [`p_map.c`](https://github.com/chocolate-doom/chocolate-doom/blob/master/src/doom/p_map.c),
  and [`p_mobj.c`](https://github.com/chocolate-doom/chocolate-doom/blob/master/src/doom/p_mobj.c)
  for command scaling, thrust, friction, collision and wall sliding.
- **Enemies and combat.** Treat
  [`p_enemy.c`](https://github.com/chocolate-doom/chocolate-doom/blob/master/src/doom/p_enemy.c),
  [`p_pspr.c`](https://github.com/chocolate-doom/chocolate-doom/blob/master/src/doom/p_pspr.c),
  [`p_inter.c`](https://github.com/chocolate-doom/chocolate-doom/blob/master/src/doom/p_inter.c),
  and [`info.c`](https://github.com/chocolate-doom/chocolate-doom/blob/master/src/doom/info.c)
  as the oracle for state durations, perception, chase choices, attacks,
  damage, pickups and thing/editor-number mappings.
- **Level semantics.** The Doom Wiki's [Doom level
  format](https://doomwiki.org/wiki/Doom_level_format), [linedef
  types](https://doomwiki.org/wiki/Linedef_type), and [sector
  types](https://doomwiki.org/wiki/Sector_type) define lump direction and
  terminology. Resolve ambiguous specials against Chocolate Doom's
  [`p_spec.c`](https://github.com/chocolate-doom/chocolate-doom/blob/master/src/doom/p_spec.c),
  [`p_doors.c`](https://github.com/chocolate-doom/chocolate-doom/blob/master/src/doom/p_doors.c),
  and [`p_floor.c`](https://github.com/chocolate-doom/chocolate-doom/blob/master/src/doom/p_floor.c).
- **Rendering.** Use the Doom Wiki's [Doom rendering
  engine](https://doomwiki.org/wiki/Doom_rendering_engine) for BSP and column
  terminology, with Chocolate Doom's
  [`r_bsp.c`](https://github.com/chocolate-doom/chocolate-doom/blob/master/src/doom/r_bsp.c),
  [`r_segs.c`](https://github.com/chocolate-doom/chocolate-doom/blob/master/src/doom/r_segs.c),
  [`r_plane.c`](https://github.com/chocolate-doom/chocolate-doom/blob/master/src/doom/r_plane.c),
  and [`r_things.c`](https://github.com/chocolate-doom/chocolate-doom/blob/master/src/doom/r_things.c)
  only to settle observable clipping, pegging, lighting, sky and sprite-order
  questions.
- **Audio and MIDI.** Freedoom 0.13.0 and its [modified-BSD content
  licence](https://github.com/freedoom/freedoom/blob/v0.13.0/COPYING.adoc) own
  the sounds, MIDI and attribution; the checked-in WAD checksum fixes the exact
  input. `scripts/doom_midi.py` is the completed, project-authored synthesis
  path: it validates the exact programs, percussion and supported controller
  events used by E1M1, renders a deterministic procedural instrument bank, and
  writes mono 16-bit PCM WAV. It incorporates no soundfont or third-party
  samples. The generated manifest records the renderer description, bank
  requirements, sample rate, and MIDI/WAV checksums. An unrecorded system
  soundfont is intentionally not used because instrument samples would change
  both redistribution obligations and output bytes.
- **Validation.** Compare the same pinned WAD and command stream in Chocolate
  Doom, using its [`g_game.c`](https://github.com/chocolate-doom/chocolate-doom/blob/master/src/doom/g_game.c)
  demo/tic path as the definition of command ordering. Keep deterministic
  per-tic state traces, a start-to-exit replay, and representative pixel/audio
  captures. A difference is either fixed or recorded here as an intentional
  departure; visual similarity alone is not gameplay evidence.

Freedoom itself is modified-BSD content, with its source and contributor policy
described in the [official repository](https://github.com/freedoom/freedoom).
Only Freedoom assets are redistributed here; original commercial Doom data is
never an input.

The initial target is gameplay-compatible E1M1, not demo-byte compatibility.
Any intentional departure is recorded here with an observable reason rather
than silently becoming the new definition of Doom behaviour.

## Native visual and performance evidence

Run `python3 scripts/test_doom_visual.py --build` in a graphical session (or
under Xvfb). The dedicated evidence app advances the ordinary deterministic
replay through the real runtime and captures start, first combat and first
moving-door frames through the public screenshot effect. The validator decodes
the PNGs, requires exact 320x200 RGBA dimensions, at least 128 colours, and
distinct content, then removes them. SHA-256 values are reported for diagnosis
but are not portable golden values across GPU drivers. This proves the native
render path is live at representative states; it is not cross-engine parity.

`python3 scripts/test_doom_performance.py` builds and runs 120 hidden headless
cycles with host allocation metering. It enforces 28 MiB worst-cycle, 16 MiB
average-cycle and 1 MiB idle-update bounds, plus a conservative 30 cycles/second
floor on the executing machine. Retained static and dynamic batches prevent map
topology from being rebuilt by presentation frames; moving-sector batches are
rebuilt only when a rendered height or light changes. Renderer tests separately
bound an E1M1 batch to 60,000 vertices, dynamic sectors to 32, and worst-case
geometry to 180,000 vertices / 270,000 indices. These are allocation/resource
bounds, not a universal frame-time guarantee across machines or backends.

## Current verified gaps

- E1M1 weapon pickups populate explicit ownership, newly acquired weapons
  auto-equip, number-key intents select only owned weapons, and dry-fire uses a
  deterministic Doom-style fallback priority. Weapon raising/lowering remains
  instantaneous rather than using the complete psprite transition chain.
- Skill is retained in deterministic runtime state. Baby halves incoming
  damage with integer truncation, and Baby/Nightmare ammunition grants are
  doubled. Nightmare's faster actor cadence and monster respawning remain an
  intentional E1M1 vertical-slice departure: respawn bookkeeping and spawn
  occupancy policy are outside the currently modeled bounded actor lifecycle.
- Actor modes have deterministic tic durations, but they are coarser than the
  complete Doom sprite-state chains. The status face similarly provides useful
  health feedback without implementing the full original priority machine.
- Damage resolves before pickup contact each tic, and lethal damage prevents a
  same-tic health pickup from reviving the player; corpse/death-camera motion is
  not modeled beyond the terminal runtime phase.
- The checked-in trace proves partition invariance and regression stability for
  this implementation. A Chocolate Doom run of the identical command stream is
  still required before calling it a cross-engine golden comparison.
