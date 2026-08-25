# Doom fuzz findings

Bugs collected by property-based fuzzing of the pure Doom modules with
[roc-fuzz](https://github.com/lukewilliamboswell/roc-fuzz) on 2026-08-25.
**Nothing here has been fixed**; this file is the backlog. Each entry names the
property that failed, the minimal input, the root cause, and a suggested fix.

Targets live beside the modules and build with the pinned nightly
(`nightly-2026-08-23-fb208ba`) against a sibling checkout of roc-fuzz:

```sh
cd examples/doom
roc build --fuzz fuzz_sim.roc && ./fuzz_sim run --time=120
```

| Target | Module(s) | Driver | Campaign |
|---|---|---|---|
| `fuzz_sim.roc` | DoomSim | libFuzzer | ~1080 s, 5.7 M execs, cov 355 |
| `fuzz_map.roc`, `fuzz_map_decode.roc` | DoomMap validate/derive, DoomLevel queries over generated maps | libFuzzer | ~1230 s / 715 k execs (map); 150 s / 1.76 M execs (decode) |
| `fuzz_level.roc` | DoomLevel movers over E1M1 | `roc test` seeded streams (see T1) | 400 seeds × 40 commands, 394 s |
| `fuzz_world.roc`, `fuzz_trace.roc` | DoomWorld inventory/combat; DoomTrace partitions | libFuzzer | 300 s / 3.0 M execs (world); 2 × 300 s / ~3.7 k execs (trace) |

Each target carries `guard_*` flags at the top that exclude an already-recorded
bug so a campaign can keep looking for the next one; flip a guard off to
reproduce the corresponding entry. libFuzzer artifacts decode through the
*current* generator, so they stop meaning the same input if a generator changes.

Severity key: **hang**, **crash**, **wrong-result** (observable in-game
divergence), **fidelity** (differs from vanilla Doom, arguably by design),
**domain-gap** (validation admits something downstream cannot handle).

---

## DoomSim

### S1. `Angle.from_turns` hangs for |turns| ≥ 2^24 or ±Inf, and passes NaN through
- Severity: hang
- Location: `DoomSim.roc:272` (`wrap_turn`), via `Angle.from_turns` (:14) and `Angle.add` (:20)
- Property: `from_turns(t).turns()` terminates and is in [0, 1) for every F32.
- Input: `turn = F32.from_bits(3675212096)` = −4.03e16 → libFuzzer timeout.
- Root cause: `wrap_turn` recurses by ±1. Above 2^24 the F32 ulp is ≥ 2 so
  `value - 1 == value` and it never progresses; between ~2^20 and 2^24 it
  terminates but costs millions of calls. NaN fails both comparisons and is
  returned unchanged, after which `forward()` and `pos` become NaN and
  `DoomLevel.sector_at` fails. `Command.turn` feeds this directly, so a bad
  sensitivity scale or a corrupt replay hangs the game.
- Confidence: high.
- Suggested fix: `wrap_turn = |v| v - F32.floor(v)` with a non-finite guard;
  clamp/reject non-finite `Command.turn` at the input boundary.

### S2. `DoomSim.sqrt` is inaccurate outside roughly [1e-7, 1e7]
- Severity: wrong-result (fidelity)
- Location: `DoomSim.roc:233-244` (`sqrt`); consumers `length` (:222), `normalize` (:226)
- Property: within 1e-4 relative of `F32.sqrt` for finite v in (0, 1e8].
- Input: `sqrt(1e-45)` = 6.1e-5 (true 3.7e-23); by hand `sqrt(1e8)` = 10784
  (true 10000, 7.8 %), `sqrt(1e9)` = 66401 (true 31623).
- Root cause: 14 fixed Newton iterations seeded at `value`; early iterations
  only halve the guess, so convergence needs ~log2(sqrt(v)) steps first. The
  result always overshoots, so `normalize` returns a sub-unit vector. E1M1's
  longest linedef (1216) is fine, but `normalize(viewer - actor)` in
  `DoomSprites.roc:54,82`, `DoomPresentation.roc:107`, `DoomRuntime.roc:127`
  sees map-scale distances (E1M1 diagonal 5213 → length² 2.7e7).
- Confidence: high on the numbers; medium on visible impact (few % beyond 3200 units).
- Suggested fix: use the builtin `F32.sqrt`.

### S3. Wall slide is not swept against other blockers: corners get clipped
- Severity: wrong-result
- Location: `DoomSim.roc:141-160` (`move_with_slide`), the
  `any_deeper_penetration` acceptance at :156
- Property: starting clear of all blockers, no point on the centre path of one
  tic is closer than `player_radius` to any blocker (what `sweep_hits_segment`
  already enforces for the *unslid* path).
- Input:
  ```
  pos { 73, 95 }, momentum { 31.5, 31.5 }, angle 0.934, turn 0.927, forward -38, side -38
  blockers: [{ 39,-28 → -28,-28 }, { -180,-198 → 95,95 }, { 95,100 → -62,-200 }]
  ```
  Midway the centre is 12.9 units from the corner at (95, 100): 3.1 units of penetration.
- Root cause: on the first hit (list order, not nearest) the displacement is
  projected onto that blocker's tangent and accepted unless it *ends* closer
  to some blocker than it started. The slide path itself is never swept, so
  it passes through a second segment's end-cap. With in-game momentum
  (≤ ~21/tic) the clip is a few units; it lets the player cut corners that
  `P_TryMove` would block.
- Confidence: high.
- Suggested fix: sweep the slide candidate with `sweep_hits_segment` against
  every blocker (pick the nearest hit); if the slide also hits, stay put
  (Doom's `P_SlideMove` tries the slide then stops).

### S4. A slide can tunnel completely through a second blocker
- Severity: wrong-result (tunnelling)
- Location: as S3.
- Property: the centre path of one tic never properly crosses a blocker when the tic started clear.
- Input:
  ```
  pos { -146, 118 }, momentum { 36.6, 36.6 }, angle 0, turn -0.617, forward -67, side -100
  blockers: [{ -177,-200 → -104,142 }, { -197,171 → 118,-36 }, { -111,167 → 122,-161 }]
  ```
  Start is 16.3 units before blocker 2; the slide along blocker 1 has a
  33.2-unit component along blocker 2's normal; the tic ends 16.9 units on the
  far side — not penetrating, so accepted.
- Root cause: as S3. A full crossing needs > 2 × radius of normal slide, i.e.
  near-cap momentum (`max_move` 30 per component). Player thrust + friction
  saturates around 15–21/tic, so the player cannot normally reach this, but
  `State.momentum` is a plain field and `clamp_momentum` allows 30/30.
- Confidence: high that the code does it; medium on in-game reachability.
- Suggested fix: same as S3.

### Held (DoomSim)
Angle range for finite |t| < 2^24; `advance` accounting (remainder finite and
in [0, tic_seconds), tics ≤ 8, never `dropped` for ≤ 8-tic frames, tic
conservation ±1) — including NaN/±Inf/negative `elapsed`, which resolve to a
finite remainder with **no guard needed** (relies on `F32.min/max` NaN
semantics; worth a unit test); tic invariants (momentum cap, finite pos, bob
and phase ranges); end position never penetrates a blocker; single-blocker
no-tunnelling; neutral command at rest never moves; k-way partitions of one
tic never over-count and are bit-identical when they deliver the tic. 20 of
k = 1..64 (15, 20, 23, 27, 28, 33, …) under-sum in F32 and defer the tic one
frame — conservative, not lossy, and not filed as a bug.

---

## DoomMap validation and DoomLevel spatial queries (generated maps)

Core property: **anything `DoomMap.validate` accepts is safe to query.**

### M1. Cyclic BSP node graphs pass validation and hang `DoomLevel.sector_at`
- Severity: hang
- Location: `DoomMap.roc:208-223` (`validate_nodes`/`validate_child`); hang in `DoomLevel.roc:193` (`descend`)
- Input (found in < 10 s): a single node whose `right_child` and `left_child`
  are both `{ kind: "node", index: 0 }`; any query point hangs.
  Artifact: `AQAA////////////AQAAAAAAAAAC`
- Root cause: `validate_child` only bounds-checks the index; nothing requires
  the node graph to be a DAG rooted at the last node.
- Confidence: high.
- Suggested fix: require `"node"` children to satisfy `child.index < node_index`
  (classic Doom BSPs are built bottom-up with the root last — exactly the
  invariant `sector_at` already relies on with `root = len - 1`).

### M2. Tagged specials 2/23/62/88 crash when the tagged sector has no two-sided line
- Severity: crash
- Location: `DoomLevel.roc:466` (`lowest_adjacent_ceiling`: `crash "door sector has no adjacent sector"`)
  and `:485` (`lowest_adjacent_floor`), via `activate_tagged_doors/floors/lifts`
- Input: one two-sided linedef (special 2, tag 1) whose sidedefs both name
  sector 2; sector 3 carries tag 1 but no linedef touches it; crossing the
  line → `activate_door(3)` → crash.
  Artifact: `AE0U/hT/////AADSAAAAUVFRUU0PEgD/////1tbW1tYFAAAAAAAABdbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tZNDwAAAAEPACgAAAJN`
- Root cause: `validate` never relates linedef tags to sector tags or sector
  tags to geometry; the mover code treats "no adjacent sector" as impossible.
  Specials 1/26/117 (`activate_local_door`) cannot reach it — the activating
  line is itself adjacent — so the brief's suspect is refuted for those.
- Confidence: high.
- Suggested fix: return `NotUsable` (vanilla: the sector simply does not move)
  instead of crashing, or validate tag → geometry in `DoomMap.validate`.

### M3. Coordinate-equal vertices yield zero-length blocking/collision segments
- Severity: domain-gap
- Location: `DoomMap.roc:147` (`validate_linedefs` compares vertex *indices*); same in `validate_segs` (:187)
- Input: `vertices: [{-32,-32}, {-32,-32}]`, one one-sided linedef 0→1.
  Artifact: `ERHDAAAAAMMBANDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQw8PDw8PDAAQRAAAAAAAAAP/+////////////////ASsBz8/Pz8///w==`
- Root cause: the degenerate check is by index, so a zero-length segment
  reaches `blocking_segments`/`collision_segments`. `DoomSim.distance_to_segment_squared`
  handles zero length, but wall spans (zero-width quads), seg angles and any
  normal math do not. E1M1's exporter never emits it.
- Confidence: high that it is accepted; medium that it is harmful.
- Suggested fix: reject equal-coordinate endpoints (`DegenerateLinedef`), or drop them from the derived lists.

### M4. Same-sector two-sided doors get `open = closed - 4` (odd, harmless)
- Severity: fidelity (note only)
- `validate` allows `right_sidedef == left_sidedef`; a special-1/26/117 door on
  such a line finds the sector itself as "adjacent", so the door finishes on
  its first tick 4 units lower. Related to L1's `open < closed` gap.

### Held (map)
`wall_spans` (top > bottom, in-range sector/linedef, all pegging/texture
combinations, inverted heights); `wall_spans_at(initial heights) == wall_spans()`;
`surface_polygons` exactly 2 × polygons; `player_start` for 0/1/many starts;
`sector_at`/`crossed_lines`/`portal` for finite, NaN, ±Inf and arbitrary-bit
points and any linedef/sector pair; `collision_segments` ⊆ `incident_lines`;
`use_line` × 8 key sets and `cross_line` over every linedef followed by 40
ticks, `render_changed`, `light_for`, `heights_for`; `dynamic_sectors` has no
duplicates; `polygon_for_subsector` cannot crash (count + duplicate + range
checks are an identity check by pigeonhole — suspect refuted); collinear
polygons rejected by strict `cross > 0`. `DoomMap.decode` on 1.76 M arbitrary
and JSON-spliced strings: always `Ok`/`Err`, never crash or hang.

---

## DoomLevel movers over E1M1

### L1. Special 62 is implemented as a permanent door; on E1M1 its tags name the lift sectors
- Severity: fidelity + wrong-result
- Location: `DoomLevel.roc:151` (`62 => activate_tagged_doors(...)`) and the doc comment at :139-141
- Property: every active door has `open >= closed`.
- Input: `UseLine(1064)` (special 62, tag 2) from the initial state creates
  `{ sector: 103, closed: 264, open: 260 }`; the ceiling moves *down* 4 units
  and, because `stays_open` finishes immediately, rests there forever.
  Linedefs 594 (tag 1), 620, 1064, 1075 (tag 2) all trigger it; those tags are
  exactly the sectors that the special-88 lines 593/595/596/618/1078 drive as lifts.
- Root cause: vanilla linedef type 62 is "SR Lift Lower Wait Raise" (switch
  form of WR 88); "SR Door Open Stay" is 61. `activate_door` then computes
  `open = lowest adjacent ceiling - 4`, below the room's own ceiling. The
  `floor <= ceiling` and no-snapping properties don't fire only because the
  move is 4 units.
- Confidence: high.
- Suggested fix: route 62 to `activate_tagged_lifts`; make `activate_door`
  reject `open < closed` instead of silently lowering the ceiling.

### L2. Re-using a door mid-cycle rebuilds it with `closed: current.ceiling`, so it never closes again
- Severity: wrong-result (lasting map effect)
- Location: `DoomLevel.roc:458-464` (`activate_door`)
- Property: after all movers finish, every plane rests at its initial height
  or a legitimate open/target height.
- Input: `UseLine(55), Tick(233), UseLine(55), Tick(1000)` — 233 tics is 62
  opening + 150 waiting + 21 into closing. Result: door
  `{ closed: -46, open: -4 }`, sector 10 rests at ceiling −46 instead of −128.
  Using a door while fully open (`UseLine(55), Tick(100), UseLine(55)`) gives
  `{ closed: -4, open: -4 }`: permanently open. Campaign hit: sector 34 at −86 (seed 42).
- Root cause: `activate_door` always sets `closed: current.ceiling` and the
  `List.keep_if` replacement discards the original. Vanilla reopens a closing
  door from its current height (that part matches) but keeps the closed
  height, and using an open/waiting door starts it *closing*.
- Confidence: high.
- Suggested fix: when a door is already active on the sector keep its
  `closed`/`open` and only flip phase (Closing → Opening; Opening/Waiting →
  Closing for non-`stays_open`); for a fresh door use the sector floor as `closed`.

### Held (level)
Over 400 seeded streams with L1/L2 guarded: `floor <= ceiling`; no plane moves
more than 8/tic; `open >= closed`; `light_for` in [0, 255]; `render_changed`
matches a direct all-sector comparison; determinism; quiescence within 2000
tics with every resting height explained; out-of-range/special-0/locked lines
leave state unchanged. Floor movers and lifts never fought on E1M1 because
specials 23 and 88 tag disjoint sectors — the door/lift fight on tags 1 and 2
*is* L1. The L2 guard (no use-line while a door is active) also hides the
suspected live-height sector swap in `activate_local_door`; not reached.

---

## DoomWorld inventory and combat

### W1. Stimpack / Medikit / Berserk *lower* health above 100 back to 100
- Severity: wrong-result
- Location: `DoomWorld.roc:533-534, 556` via `give_health` at :615
- Property: a pickup never lowers health; vanilla refuses stimpack/medikit at
  `health >= 100` and berserk only raises (`if health < 100 then 100`).
- Input: `[HealthBonusPickup, StimpackPickup]` — 101 → 100, reported
  `collected: False` while mutating. Soulsphere then medikit costs 100 HP.
- Root cause: `next = I64.min(cap, health + amount)` applied unconditionally,
  so `health > cap` is clamped *down*; `collected: next > health` is then
  False, so the item also stays on the map.
- Confidence: high.
- Suggested fix: early-return `{ player, collected: False }` when
  `health >= cap`; Berserk uses `I64.max(health, 100)`.

### W2. Weapon pickups always report `collected`, even when owned with full ammo
- Severity: fidelity (contract violation of the `collected` flag)
- Location: `DoomWorld.roc:568-579` (`acquire_weapon`), all five weapon kinds
- Input: 20 × `ShotgunPickup`; at #7 the player is unchanged (shotgun owned,
  shells 50) yet `collected = True`, so the item is removed.
- Root cause: `collected: Bool.True` is hard-coded; `already_owned` and the
  `give_*` result are discarded at the call sites (`.player`). Vanilla
  `P_GiveWeapon` returns false when owned and no ammo was given.
- Confidence: high.
- Suggested fix: `collected: !already_owned or ammo_given`.

### W3. SoulSphere / HealthBonus are refused at health 200
- Severity: fidelity (minor)
- Location: `DoomWorld.roc:535, 555` via `give_health`
- Input: `[SoulSpherePickup, SoulSpherePickup]` — second reports `collected: False`.
- Root cause: `collected: next > health` conflates "state changed" with
  "item consumed"; vanilla always takes `BON1`/`SOUL`.
- Confidence: high on vanilla; medium on whether it is wanted (`FIDELITY.md` silent).
- Suggested fix: explicit `collected: Bool.True` for those two kinds.

### W4. `damage_actor(actor, amount <= 0)` restarts the Pain state
- Severity: domain-gap (low)
- Location: `DoomWorld.roc:334-338`
- Input: damage 0 on a chasing Imp → `{ mode: Pain }`, resetting its countdown.
- Root cause: the `else` branch is unconditional; the amount is already
  clamped to 0 for the health arithmetic, so non-positive input is clearly
  intended to be accepted. Unreachable from `hitscan` today (min damage 5).
- Confidence: high on behaviour; low on impact.
- Suggested fix: early-return when `amount <= 0`.

### Held (world)
Ammo/health/armor caps (×2 once with backpack, second backpack does not
re-double); `armor_kind == NoArmor` iff `armor == 0`; pistol never lost; current
weapon always owned; `collected` iff changed *and* equal to the vanilla accept
rule for all non-guarded kinds; taken pickups inert; `collect_for_skill`
consistent across skills; `damage_player` monotone and a no-op for ≤ 0
(including wrap cases); firing never goes negative; actor state machine
(health monotone, Dead absorbing, `remaining >= 1`, damage only on the
terminal Attack tic, rng consumed iff attack, deterministic);
`damage_actor`/`damage_actor_random` agree. One property was wrong and
withdrawn: Barrel `pain_chance 255` misses on byte 255 — that is vanilla
`P_Random() < painchance` semantics.

---

## DoomTrace partition invariance (characterisation, not a bug)

- Location: `DoomSim.roc:82-96` (`advance`) as driven by `DoomTrace.roc:71-84` (`run_parts`)
- **Exact sums of 1.0 do not under-tick.** `[1.0]`, `[0.25 × 4]`, `[0.5, 0.5]`,
  `[1/64, 63/64]`, `[1/3 × 3]`, `[0.1 × 10]`, `[0.7, 0.3]`, … all give 24 tics
  and the golden checksum. The `1.0001` epsilon in `DoomTrace.roc`'s expects
  is unnecessary for these shapes (observed deficit: 0).
- Divergence happens only when a per-command total *exceeds* one frame and a
  cumulative time lands exactly on a tic boundary (`cum % 64 == 0` in
  64ths): the F32 remainder is a few ulps short, the tic is deferred into the
  next part — usually the next *command* — and is simulated with a different
  `Command`. Examples: `[90, 12, 14]/64`, `[10, 95, 2, 2, 2, 2, 2, 6]/64`, and
  `[14, 56, 2]/64` vs `[72]/64` (same tic sequence, different snapshot at tic
  9 — tic-count checks cannot see this class). Confirmed as F32 accumulation,
  not simulation divergence: away from exact boundaries no partition ever
  changed a snapshot.
- Suggested change (optional): document that invariance is promised only for
  totals in [1, 1 + 1/24), or switch `advance` to an integer accumulator.

---

## Toolchain findings (nightly-2026-08-23-fb208ba, `roc build --fuzz`, x64 musl)

These are not Doom bugs but they bound what the campaigns could prove and
affect the shipped example, which is also a compiled build.

### T1. Native codegen: `{ ..state, field: x }` in a callee frees the caller's list
- Standalone repro (no Doom code): a record `{ heights : List(I64), floors : List(Item), tic : U64 }`,
  a recursive `walk` ending in `{ ..state, floors: next }`, and a caller that
  keeps using `state.floors` afterwards. Compiled: the caller's `floors` holds
  garbage. Spelling the record out field by field is correct; the interpreter
  is correct in both forms. Every `DoomLevel` state-returning function uses the
  spread, so the compiled `fuzz_level` binary corrupted its own harness state
  (`sector: 4212103046473282592`, then `sector state missing`, then SIGSEGV)
  and the level campaign had to run under `roc test`.
- Also seen from the map target: `DoomLevel.dynamic_sectors` returned
  `[6436860225072878160, 7596835273554796602]` (bytes of the inline
  `"FLOOR"`/`"CEIL"` strings) for a validated 2-sector map where the
  interpreter gives `[1, 0]`; a separate compiled probe gave `[0, 1]`
  (different branch taken on the same in-range values).
  Artifact (guard `guard_dynamic_sectors` off): `//////8LCwsLCwtcXFxcJlxcXFwmXFz//1FcXFxcjo6Ojo6Ojo7Ojo6Ojo6Ojo6Ojo6OXFxcXFxcXFwLCwsLJAsLCytbC1xcXDI0MjgLC1xc//9VXDP/`

### T2. Reproducible SIGSEGV in `roc_llvm_rc_decref_*` for a validated map
- `fuzz_map replay` of artifact
  `ACnJycnJyT0AAP/JyQD8KS4uLi4uLjAuLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uOzs7Oy4uLi4uLi4uLi4uLi7/PU7//2NjY2NjY2Nj6fv/ATtb//9N6QH/+wEJyQAJyc3JyT1O/////GNjY2NjY2NjY2NjY2NjACnp+/8BAQkCTjoAAv+c`
  segfaults every time in a fresh process (independently re-confirmed from
  this checkout); the same map passes every query under `roc test`. A
  reduced 27-input corpus sequence also corrupts libFuzzer's own heap
  structures while each input alone is clean, so fork mode was unusable and
  campaigns ran as fresh-corpus slices with every artifact replayed to filter
  spurious ones. Likely the same defect as T1.

### T3. Compiler crashes/hangs hit while writing targets
- `List.map2(a, b, |x, y| { x, y })` over `DoomWorld.Actor` records segfaults `roc build --fuzz` (`roc check` passes). Worked around with an index loop.
- `roc build --fuzz` never finished (5+ min, 100 % CPU) when a helper took `raw : DoomMap.Raw` and called `List.get(raw.linedefs, line)`; `roc check` fine. Worked around by passing `List(U64)`.
- `--opt=size --specialize=no` crashes the compiler; `--opt=dev`/`interpreter` are rejected for `--fuzz`.
- F32 fields and the opaque `DoomSim.Angle`/`DoomWorld.Rng` block derived `==` on `Player`/`ActorTic` ("type does not support equality"), yet `DoomTrace.Snapshot` (which has F32 fields) compares fine — the failure seems specific to records containing the opaque types.

### T4. roc-fuzz friction
- A one-field `.Fuzz` record builder (`{ n: Fuzz.u8 }.Fuzz`) builds a binary that reports a bare `runtime error` on every input; two or more fields work.
- `minimize` sat at 0 % CPU for its full 600 s cap on a 17-byte crash and looped > 2 min on a 2-byte one; intermediate OUTPUT can hold a non-crashing input when interrupted. Findings above use hand-reduced `show` output.
- No float generator; targets build F32/F64 from `Fuzz.u64_in` and `F32.from_bits`. A `Fuzz.f32` biased toward NaN/Inf/subnormal/huge would save every target re-deriving it.
- No rejection-rate statistics, so generator acceptance is not measurable.
- `roc build --fuzz` writes the executable into the cwd, not beside the source.
- Multiple targets in one directory share `.roc-fuzz/` by default.
