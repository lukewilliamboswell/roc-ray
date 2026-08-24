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
| Player movement | Chocolate Doom `p_user.c`, `p_map.c`, `p_mobj.c` | Golden traces for thrust, turning, friction, stopping, collision radius, and wall sliding |
| Sectors | Doom linedefs, sidedefs, sectors and subsectors | E1M1 renders floor/ceiling heights, upper/lower/middle textures, offsets, light levels, sky, and moving sectors |
| Interaction | Chocolate Doom `p_map.c`, `p_doors.c`, `p_spec.c` | Use and crossing specials operate the corresponding E1M1 doors, switches and exit |
| Things | Doom thing types and difficulty flags | Player start, enemies, weapons, ammo, health, keys and decorations come from E1M1 data |
| Combat | Chocolate Doom `p_pspr.c`, `p_map.c`, `p_inter.c`, `info.c` | Deterministic weapon cadence, ammunition, hitscan spread, damage, pain and death state tests |
| Enemies | Chocolate Doom `p_enemy.c`, `p_mobj.c`, `info.c` | Look, wake, chase, attack, pain and death advance through explicit 35 Hz state durations |
| Presentation | Chocolate Doom screenshots and state | 320x200-style viewport, weapon bob, palette flashes, status bar, directional sprites and sector lighting |
| Audio | Freedoom sounds and music | Positional effects and a reproducibly rendered or natively synthesized Freedoom track accompany a complete run |
| Whole level | Chocolate Doom running the same pinned WAD | A recorded start-to-exit input trace completes E1M1; state checkpoints and representative frames are compared |

## Reference map

- `p_user.c`: command turning, thrust, view height and bob.
- `p_map.c`: line/thing collision, openings, hitscan and use traversal.
- `p_mobj.c`: momentum, friction, state advancement and object movement.
- `p_enemy.c`: perception, chase direction and attack decisions.
- `p_pspr.c`: weapon state machines and firing actions.
- `p_inter.c`: damage, armour, ammunition and pickups.
- `p_doors.c`, `p_floor.c`, `p_spec.c`: line specials and moving sectors.
- `r_data.c`, `r_bsp.c`, `r_segs.c`, `r_plane.c`, `r_things.c`: map-derived rendering.

The initial target is gameplay-compatible E1M1, not demo-byte compatibility.
Any intentional departure is recorded here with an observable reason rather
than silently becoming the new definition of Doom behaviour.
