# Fuzz findings: sim

Target: examples/doom/fuzz_sim.roc   Campaign: ~1080 s total over 6 runs (60 + 60 + 300 + 300 + 300 + 60), ~5.7 M execs, cov 355 edges (final guarded run: 3,985,247 execs / 300 s, DONE, no failures)

Every property crashes with `PROPERTY: <name>` so the runner captures it. Guards are
compile-time flags at the top of the target and are listed per finding. Minimization was
not used: the runner's `minimize` is bounded to 600 s and made no progress in that time,
so the unminimized `show` output is recorded and each case was reduced by hand in the
root-cause text.

## Bugs

### B1. `Angle.from_turns` hangs for |turns| >= 2^24, and passes NaN through
- Severity: hang (and wrong-result for NaN)
- Location: `examples/doom/DoomSim.roc:272` (`wrap_turn`), reached from `DoomSim.roc:14` (`Angle.from_turns`) and `:20` (`Angle.add`)
- Property violated: `angle_range` — `from_turns(t).turns()` must terminate and be in [0, 1) for every F32.
- Minimized input (from `show`, libFuzzer timeout artifact after 5 s):
  `{ ..., turn_bits: 3675212096, ... }` = `F32.from_bits(3675212096)` = `-4.033e16`
- Root cause: `wrap_turn` recurses by `value - 1` / `value + 1` until the value lands in
  [0, 1). Above 2^24 the F32 ulp is >= 2, so `value - 1 == value` and the recursion never
  makes progress (infinite loop / stack growth). Between ~2^20 and 2^24 it terminates but
  costs millions of recursive calls per angle. `+Inf`/`-Inf` never terminate for the
  same reason. `NaN` fails both comparisons and is returned unchanged, so `Angle` can
  hold NaN, after which `forward()` and therefore `pos` become NaN (not exercised by the
  target because the tic properties use turn in [-1, 1]; same hole, not filed separately).
  The public `Command.turn` field feeds `Angle.add` directly, so any host/replay source
  that produces a large or non-finite turn (e.g. a mouse delta scaled by a bad
  sensitivity, or a corrupt replay file) hangs the game.
- Confidence: high (reproduced deterministically; the arithmetic is exact)
- Suggested fix (do NOT apply): `wrap_turn = |v| v - F32.floor(v)` (or `v - F32.to_f32(floor_to_i64)`),
  with `if !(F32.is_finite(v)) 0 else ...`; and clamp/reject non-finite `Command.turn`.
- Guard in target: `guard_angle_hang = Bool.True` excludes non-finite and |t| >= 2^24 from P1.

### B2. `DoomSim.sqrt` is wrong outside roughly [1e-7, 1e7]
- Severity: wrong-result (fidelity)
- Location: `examples/doom/DoomSim.roc:233-244` (`sqrt`), consumers `length` (:222) and `normalize` (:226)
- Property violated: `sqrt_accuracy` — `DoomSim.sqrt(v)` within 1e-4 relative of `F32.sqrt(v)` for finite v in (0, 1e8].
- Minimized input (from `show`): `{ ..., sqrt_bits: 1, ... }` = `F32.from_bits(1)` = `1e-45`;
  runner message: `DoomSim.sqrt(1e-45) = 6.1035156e-5, F32.sqrt = 3.743392e-23, rel_err = 1.6e18`.
  Large side, verified by hand in F32 arithmetic: `sqrt(1.6e7) = 4002.2` (true 4000, 0.05%),
  `sqrt(1e8) = 10784.6` (true 10000, 7.8%), `sqrt(1e9) = 66401` (true 31623, 110%).
- Root cause: Newton's method with a fixed 14 iterations starting from `value` (or 1 for
  value < 1). Each early iteration only halves the guess, so it needs ~log2(sqrt(v))
  iterations before quadratic convergence starts; 14 is only enough for
  sqrt(v) in about [3e-4, 3200]. The result always overshoots, so `normalize` returns a
  vector shorter than unit length.
  Impact: E1M1's longest linedef is 1216 units, so wall-slide tangents (`move_with_slide`)
  are fine. But `normalize(viewer - actor_pos)` in `DoomSprites.roc:54,82`,
  `DoomPresentation.roc:107` and `DoomRuntime.roc:127` is fed map-scale distances — the
  E1M1 bounding-box diagonal is 5213 units (length_squared 2.7e7), where sqrt is already
  off — so distant sprite billboarding / chase directions are slightly mis-scaled. `main.roc:568`
  uses `length` directly.
- Confidence: high for the numeric fact; medium for visible in-game impact (few percent
  error at >3200 units, which is beyond most sightlines).
- Suggested fix (do NOT apply): use the builtin `F32.sqrt`; or seed Newton with a
  scaled guess / iterate until `|g*g - v| <= eps*v`.
- Guard in target: `guard_sqrt = Bool.True` restricts P6 to v in [1e-7, 1e7].

### B3. Wall slide is not swept against the other blockers: corners get clipped
- Severity: wrong-result
- Location: `examples/doom/DoomSim.roc:141-160` (`move_with_slide`), specifically the
  `$result = if any_deeper_penetration(...) position else slide_candidate` at :156
- Property violated: `tunnel_graze` — starting clear of all blockers, no point on the
  centre path taken in one tic may be closer than `player_radius` to any blocker (the
  sim's own `sweep_hits_segment` enforces exactly this for the *unslid* path).
- Minimized input (from `show`, second, deeper instance; first instance grazed by 0.2 units):
  ```
  pos: { x: 73, y: 95 }, momentum: { x: 31.5, y: 31.5 }, angle_turns: 0.934, turn: 0.927,
  forward: -38, side: -38,
  blockers: [ { start: { x: 39, y: -28 }, end: { x: -28, y: -28 } },
              { start: { x: -180, y: -198 }, end: { x: 95, y: 95 } },
              { start: { x: 95, y: 100 }, end: { x: -62, y: -200 } }, ... zero-length segments ]
  ```
  runner message: `centre path { 73, 95 } -> { 102.02, 125.92 } passes through { start: { 95, 100 }, end: { -62, -200 } }`.
  Midway (t = 0.5) the centre is 12.9 units from the corner at (95, 100): 3.1 units of penetration.
- Root cause: on the first sweep hit (list order, not nearest), the displacement is
  projected onto that blocker's tangent and the slide candidate is accepted unless it
  *ends* closer to some blocker than it *started* (`any_deeper_penetration` compares
  before/after distances only). The slide path itself is never swept, so it may pass
  through a second segment's end-cap and come out the far side clear. With in-game
  momentum (<= ~21 units/tic) the clip depth is bounded by a few units; it lets the player
  cut corners that Doom's `P_TryMove` would block.
- Confidence: high (reproduced, geometry verified by hand)
- Suggested fix (do NOT apply): sweep the slide candidate with `sweep_hits_segment`
  against every blocker (and pick the nearest hit, not the first in list order); if the
  slide also hits, fall back to `position` (Doom's `P_SlideMove` tries the slide, then stops).
- Guard in target: `graze_depth = 2` (ignore < 2-unit grazes), then `guard_graze = Bool.True`.

### B4. A slide can tunnel completely through a second blocker
- Severity: wrong-result (tunnelling)
- Location: `examples/doom/DoomSim.roc:141-160` (`move_with_slide`), same code path as B3
- Property violated: `tunnel_cross` — the centre path of one tic must not properly cross
  any blocker segment when the tic started clear of all blockers.
- Minimized input (from `show`):
  ```
  pos: { x: -146, y: 118 }, momentum: { x: 36.6, y: 36.6 }, angle_turns: 0, turn: -0.617,
  forward: -67, side: -100,
  blockers: [ { start: { x: -177, y: -200 }, end: { x: -104, y: 142 } },
              { start: { x: -197, y: 171 }, end: { x: 118, y: -36 } },
              { start: { x: -111, y: 167 }, end: { x: 122, y: -161 } } ]
  ```
  runner message: `centre path { -146, 118 } -> { -138.57, 152.82 } crosses { start: { -197, 171 }, end: { 118, -36 } }`.
  Start distance to blocker 2 is 16.3 (just clear); the slide along blocker 1's tangent has
  a 33.2-unit component along blocker 2's normal, so the tic ends 16.9 units on the far
  side — not penetrating, so `any_deeper_penetration` accepts it.
- Root cause: as B3. A full crossing needs a slide with > 2 x radius normal component,
  i.e. > 32 units; that requires near-cap momentum (`max_move` 30 per component, ~42
  diagonal). Player thrust plus 0xe800 friction saturates around 15-21 units/tic, so the
  *player* cannot normally reach this, but nothing in the type prevents it: `State.momentum`
  is a plain record field, `clamp_momentum` allows 30/30, and `DoomWorld.chase_move`
  (`DoomWorld.roc:709`) passes its own displacements (speeds 8-10, so safe today).
- Confidence: high that the code does this; medium that it is reachable in the shipped
  game without an external momentum source (it is reachable at exactly the documented cap).
- Suggested fix (do NOT apply): same as B3 — sweep the slide candidate; that fixes both.
- Guard in target: `guard_multi_blocker = Bool.True` limits P4 to single-blocker inputs.

## Properties that held
All figures are from the final guarded campaign (300 s, 3,985,247 execs, 13.2 k exec/s,
cov 355, `DONE` without an artifact) unless noted.

- P1 `angle_range` / `angle_add_range` (finite |t| < 2^24): held. Guard: `guard_angle_hang`.
- P2 `advance_sequence` (up to 24 frames each <= 8/35 s): remainder finite and in
  [0, tic_seconds), tics <= 8, `dropped` never set, `state.tic` advances by exactly `tics`,
  and total tics == floor(sum elapsed x 35) within +-1: held over the whole campaign.
- P2b `advance_wild` (any F32 bits as elapsed, including NaN, +-Inf, negative, subnormal, huge):
  remainder finite and in range, tics <= 8, tic counter consistent, and elapsed >= 1 always
  saturates (8 tics + dropped): held with NO guard (`guard_wild_elapsed` stayed False).
  `clamp(NaN, 0, 1)` therefore resolves to a finite value on this compiler — worth a
  unit test since it relies on `F32.min/max` NaN semantics rather than an explicit check.
- P3 `tic_invariants` (after any tic: finite pos, |momentum| <= max_move per axis, angle in
  [0,1), bob in [0, max_bob], weapon_phase in [0,1), finite view): held for commands with
  turn in [-1, 1] and forward/side in [-100, 100], momentum start in [-40, 40].
- P4 `end_penetration` (end position never penetrates any blocker by > 0.001^2): held
  for all runs, including the unguarded multi-blocker runs (~600 s) — the two failures
  were both path failures, never end-position failures.
- P4 `tunnel_cross` / `tunnel_graze` with a single blocker: held (300 s).
- P5 `partition_whole` (one `tic_seconds` gives exactly 1 tic, remainder 0), `partition_over`
  (k parts never give > 1 tic), `partition_state` (when k parts do give 1 tic the state is
  bit-identical to the single advance), `partition_deferred` (when they give 0 tics the
  remainder is within 1e-5 of `tic_seconds`): all held for k in 1..64.
  Drift distribution (computed exactly in F32 arithmetic, k in 1..64): the k-way split
  sums to *less* than `tic_seconds` and defers the tic for
  k in {15, 20, 23, 27, 28, 33, 37, 38, 40, 41, 42, 44, 45, 46, 47, 49, 50, 53, 57, 58}
  (20 of 64); it never over-counts. The deferred tic is delivered on the next frame, so the
  sim is conservative rather than lossy; this is inherent to the F32 accumulator and is
  not filed as a bug.
- P7 `neutral_rest` (zero momentum + neutral command never moves the player, even when
  starting inside a blocker): held.
- P6 `sqrt_accuracy` inside [1e-7, 1e7]: held. Guard: `guard_sqrt`.

## Notes
- Worktree depth: the brief's header path `../../../roc-fuzz/platform/main.roc` is correct
  for the main checkout but not from `.claude/worktrees/<agent>/examples/doom`
  (six levels). The committed file uses the brief's path; during the campaign it was built
  with `../../../../../../roc-fuzz/platform/main.roc`.
- `*.md` is gitignored at the repo root (only listed docs are allowed), so the findings file
  had to be added with `git add -f`.
- `minimize` never completed: the runner runs `-minimize_crash_internal_step=1` with
  `-max_total_time=600` and sat at 0% CPU for the full 600 s on a 17-byte crash. Manual
  reduction from `show` was quicker. A `--time` option on `minimize` would help.
- No float generator: F32 values were built from `Fuzz.u64_in` scaled, and full-domain
  values from `F32.from_bits(U64.to_u32_wrap(Fuzz.u64))`. That works well; a `Fuzz.f32`
  helper that biases toward NaN/Inf/subnormal/huge would save every target re-deriving it.
- `advance` returns the *input* state unchanged when it performs zero tics, so invariants
  on the output state must be gated on `tics > 0` when the generator starts out of domain
  (first false positive of the campaign, fixed in the target).
- A single-target design with compile-time guard flags worked, but the runner cannot
  select a property from the command line, so each guard change costs a rebuild (~1 s here,
  fine). Deprecated `0.0f64` literal syntax: use `0.0.F64`.
