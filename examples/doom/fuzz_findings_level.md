# Fuzz findings: level

Target: examples/doom/fuzz_level.roc   Campaign: see "Campaign summary" below

The target applies a command stream `{ UseLine, CrossLine, Tick }` over the real
`DoomMap.e1m1` map from `DoomLevel.initial` and checks, after every tic:
floor <= ceiling, no plane moves more than 8 units per tic, every active door
has `open >= closed`, `light_for` in [0, 255]; after every activation (and a
sampled subset of other steps) `render_changed` against a direct computation;
after the stream, determinism (second application compared through
`Str.inspect`) and quiescence (all movers finish within 2000 tics and every
plane rests at its initial height, an adjacent initial floor, or the lowest
adjacent initial ceiling - 4).

## Campaign summary

Two drivers were used because the native `roc build --fuzz` binary miscompiles
this module's state handling (Notes, N1-N3):

- libFuzzer (native): ~14 minutes total, ~400 execs, cov 751. Found B1 within
  the first minute; every later run died of memory corruption in the
  compiled code, not of a DoomLevel bug (Notes).
- Interpreter (`roc test fuzz_level.roc`, the `run_seeds` expect at the end of
  the target): LCG-seeded streams of 40 commands drawn from the same
  generator shape. 300 seeds with B1 guarded found B2 at seed 42 in 62 s.
  With B1 and B2 guarded, 400 seeds (16 000 commands, 394 s) ran clean; see
  "Properties that held". (A 1500-seed run was started but killed after
  12 minutes without finishing; the interpreter manages ~1 stream/s.)

## Bugs

### B1. Special 62 is implemented as a permanent door but its E1M1 tags name lift sectors

- Severity: fidelity + wrong-result
- Location: `examples/doom/DoomLevel.roc:151` (`62 => activate_tagged_doors(...)`)
  and the doc comment at `:139-141`
- Property violated: door `open >= closed`. `use_line` on linedef 1064 (special
  62, tag 2) from the initial state creates `{ sector: 103, closed: 264,
  open: 260 }`; the sector then "opens" *downwards* by 4 units and, because
  `stays_open` finishes immediately, rests at 260 forever.
- Minimized input (from `show`, libFuzzer crash `952a1e65...`, 3 bytes `7a 00 1a`):
  ```
  keys { blue: False, red: False, yellow: False }
  UseLine(1064) [special 62 tag 2]
  ```
  Also reproduced by the interpreter driver: `UseLine(620) [special 62 tag 2]`
  at seed 24 of the unguarded run. Linedefs 594 (tag 1), 620, 1064, 1075 (tag 2)
  all trigger it; the tagged sectors (tag 1 and tag 2) are exactly the sectors
  that specials 88 on linedefs 593/595/596/618/1078 drive as lifts.
- Root cause: in vanilla Doom linedef type 62 is "SR Lift Lower Wait Raise"
  (the switch form of the WR 88 lift), not "SR Door Open Stay" (that is 61).
  `use_line` treats it as a door, so `activate_door` computes
  `open = lowest adjacent ceiling - 4`, which is below the lift room's own
  ceiling (264 vs 264 - 4). The `floor <= ceiling` and no-snapping properties
  do not fire only because the move is 4 units in one tic.
- Confidence: high (Doom Wiki linedef type table; the tag sharing with the 88
  lines in the map data confirms the sector role).
- Suggested fix (do NOT apply): route 62 to `activate_tagged_lifts` (a lift
  that repeats on each switch use, mirroring 88), update the doc comment, and
  add a guard in `activate_door` that rejects `open < closed` instead of
  silently moving the ceiling down.

### B2. Re-using a door mid-cycle rebuilds it with `closed: current.ceiling`, so it never closes again

- Severity: wrong-result (fidelity divergence with lasting map effect)
- Location: `examples/doom/DoomLevel.roc:458-464` (`activate_door`)
- Property violated: quiescent heights. After all movers finish, door sector
  10 (linedef 55) rests at ceiling -46 instead of its initial -128; in the
  campaign, sector 34 rested at -86 (seed 42).
- Minimized input: the directed stream
  ```
  keys { blue: False, red: False, yellow: False }
  UseLine(55) [special 1 tag 0]
  Tick(233)          -- 62 tics opening, 150 waiting, 21 tics into closing
  UseLine(55) [special 1 tag 0]
  Tick(1000)
  ```
  gives `door after reuse { closed: -46, open: -4, phase: Opening }` and the
  sector rests at `{ ceiling: -46, floor: -128 }` with `doors: []`. Using the
  door while it is fully open (`UseLine(55), Tick(100), UseLine(55)`) gives
  `{ closed: -4, open: -4 }`: the door completes its cycle without moving and
  stays open permanently.
- Root cause: `activate_door` always sets `closed: current.ceiling`. Vanilla
  reopens a closing door from its current height (that part matches), but the
  closed height stays the sector floor; and using a door that is open/waiting
  makes it start closing rather than restarting an open cycle. The
  `List.keep_if(... != sector)` replacement discards the original `closed`.
- Confidence: high (directed repro plus fuzz hit; behaviour is documented in
  `p_doors.c` `EV_VerticalDoor`).
- Suggested fix (do NOT apply): when a door is already active on the sector,
  keep its `closed` (and `open`) and only change the phase (Closing -> Opening;
  Opening/Waiting -> Closing for non-`stays_open` doors); for a fresh door use
  the sector floor as `closed`.

## Properties that held

All over the guarded interpreter campaign: 400 seeds x 40 commands, 394 s,
guards `guard_special_62` (B1) and `guard_door_reuse` (B2: no use-line while
any door is active; cross-line door/lift triggers and floor switches stay
enabled).

- floor <= ceiling for every sector after every tic.
- No plane moves more than 8 units per tic (doors 2/8, floors and lifts 1).
- Every active door has `open >= closed` (only violated by B1).
- `light_for` in [0, 255] for every sector, sampled every 7th tic.
- `render_changed(s, s)` is False, and `render_changed(s, tick(s))` matches a
  direct all-sector height/light comparison after every activation and every
  16th other step. The suspected live-height door-sector swap in
  `activate_local_door` (which would move a sector outside `dynamic_sectors`)
  was not reached on E1M1 with the B2 guard on.
- Determinism: two applications of the same stream give identical
  `Str.inspect` output.
- Quiescence: every mover finished within 2000 tics; no hang. Floor movers and
  lifts on the same sector (specials 23 and 88) never fought because their
  E1M1 tags (3 vs 1, 2) name disjoint sectors; the door/lift fight on tags 1
  and 2 is exactly B1.
- Out-of-range linedefs, special-0 lines, and locked special-26 doors return
  `NotUsable`/`Locked` without changing state.

## Notes

- N1. **Native codegen bug: `{ ..state, field: x }` in a callee frees the
  caller's list.** Standalone repro (no Doom code): a record
  `{ heights : List(I64), floors : List(Item), tic : U64 }`, a recursive
  `walk` that ends with `{ ..state, floors: next }`, and a caller that keeps
  using `state.floors` afterwards. Built with `roc build --fuzz`, the caller's
  `floors` shows garbage elements after the call; spelling the record out
  field by field (`{ heights: state.heights, floors: next, tic: state.tic }`)
  is correct. `roc test` (interpreter) is correct in both forms. Every
  DoomLevel function that returns a new `State` uses the spread form, so the
  compiled fuzz binary corrupts the harness state (first symptom: floors
  entries like `{ sector: 4212103046473282592, ... }`, then
  `sector state missing` crashes and SIGSEGV at end of `test`). Passing fresh
  copies into DoomLevel (the `copy_state` helper in the target) removed the
  first symptom but not the segfaults, so the interpreter driver was used for
  the real campaign. This also means the Doom example itself, built with
  `roc build`, is running on the same miscompiled construct; worth a compiler
  issue with the repro above.
- N2. Compiler hang: `roc build --fuzz` never finished (killed after 5+ min,
  100 % CPU) when `resolve_line` took `raw : DoomMap.Raw` and called a helper
  `is_special(raw, line, 62)` with `List.get(raw.linedefs, line)`; `roc
  check` was fine in 3 s. Precomputing the guarded line list and passing
  `List(U64)` instead builds in 3 s.
- N3. `Fuzz.target` inputs with a single-field record builder
  (`{ n: Fuzz.u8 }.Fuzz`) build a binary that reports `runtime error` with
  one coverage counter; two fields work.
- N4. The brief's relative platform path `../../../roc-fuzz/platform/main.roc`
  is wrong from a nested agent worktree; the target uses an absolute path.
  Change it back to the relative form when merging into the main checkout.
- N5. `roc build --fuzz` only supports the LLVM backend (`--opt=dev` and
  `--opt=interpreter` are rejected); `--opt=size --specialize=no` crashes the
  compiler ("Please report this issue").
- N6. Roc has no `>>` operator; the LCG in the target uses division.
- N7. Cost: `light_for` on a special-12 sector scans every linedef, and
  `render_changed` rebuilds `dynamic_sectors` (which calls `initial`) on every
  call, so the target samples light checks every 7th tic and render checks on
  activations plus every 16th other step; the determinism re-run skips
  checks. `Tick` totals are capped at 1500 per stream.
