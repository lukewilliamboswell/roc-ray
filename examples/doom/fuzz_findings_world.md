# Fuzz findings: world

Target: examples/doom/fuzz_world.roc (DoomWorld inventory/combat) and
examples/doom/fuzz_trace.roc (DoomTrace partition invariance).
Campaign: fuzz_world ~1000 s total across guard iterations, final clean run
300 s / 3,029,229 execs, cov 692 (ft 4326); fuzz_trace ~1000 s total, final
clean runs 300 s / 3,850 execs + 300 s / 3,620 execs, cov 810 (ft 3079) — one
`DoomTrace.run` costs ~40 ms and every input runs it 2-3 times.

Neither target was able to crash a Doom module; every finding below is a
property/fidelity violation.

## Bugs

### B1. Weapon pickups always report `collected` even when owned and ammo is full
- Severity: fidelity (and a contract violation of `collect`'s `collected` flag)
- Location: `examples/doom/DoomWorld.roc:566-577` (`acquire_weapon`), reached
  from `apply_pickup` for `ShotgunPickup`, `ChaingunPickup`,
  `RocketLauncherPickup`, `PlasmaRiflePickup`, `ChainsawPickup`
- Property violated: `collected` is True iff the player state changed;
  vanilla `P_TouchSpecialThing` -> `P_GiveWeapon` returns false when the weapon
  is owned and `P_GiveAmmo` gave nothing, so the item stays on the map.
- Minimized input (from `show`): `pickups: [0 x 20]` (twenty ShotgunPickups),
  everything else zero. Failure at pickup #7: before =
  `{ ammo: { bullets: 50, shells: 50 }, weapons.shotgun: True }`,
  `collected = True`, player unchanged.
- Root cause: `acquire_weapon` hard-codes `collected: Bool.True` and ignores
  both `already_owned` and the `collected` result of the preceding
  `give_*` call (the call sites discard it via `.player`). A second
  `ChainsawPickup` is likewise always "collected" although nothing changes.
- Confidence: high (read the code; vanilla rule checked against p_inter.c).
- Suggested fix (do NOT apply): `collected: !(already_owned) or ammo_result.collected`,
  threading the `give_*` result into `acquire_weapon`.

### B2. Stimpack / Medikit / Berserk lower health above 100 back down to 100
- Severity: wrong-result
- Location: `examples/doom/DoomWorld.roc:533-534` (`StimpackPickup`,
  `MedikitPickup`), `:556` (`BerserkPickup`), via `give_health` at `:612-615`
- Property violated: a pickup never lowers health; vanilla refuses
  stimpack/medikit at health >= 100 (`if (player->health >= MAXHEALTH) return false`)
  and berserk only raises health (`if (player->health < 100) player->health = 100`).
- Minimized input (from `show`): `backpack_first: 1`? not needed; the 4-byte
  crash input decoded to `pickups: [HealthBonusPickup, StimpackPickup]`
  after a health bonus took health to 101. Crash text:
  `collected=False but changed=True after pickup #1 StimpackPickup before={ health: 101, ... }`.
  Any soulsphere (health 200) followed by a medikit drops the player to 100.
- Root cause: `give_health` computes `next = I64.min(cap, health + amount)`
  and applies it unconditionally, so when `health > cap` the clamp *reduces*
  health. It then reports `collected: next > health` = False while still
  writing the reduced value, so the item also stays on the map and re-applies
  every touch (harmless second time, but the first touch already cost up to
  100 HP).
- Confidence: high.
- Suggested fix (do NOT apply): `if health >= cap { player, collected: False } else { ...min(cap, health+amount)... }`;
  Berserk should use `I64.max(health, 100)`.

### B3. SoulSphere / HealthBonus are refused at health 200; vanilla always takes them
- Severity: fidelity (minor)
- Location: `examples/doom/DoomWorld.roc:535` (`HealthBonusPickup`), `:555`
  (`SoulSpherePickup`), via `give_health`
- Property violated: vanilla `P_TouchSpecialThing` has no `return false` path
  for `SPR_BON1`/`SPR_SOUL` (they are always picked up and removed, health
  clamped at 200); the module leaves them on the map when health == 200.
- Minimized input: 4 bytes -> `pickups: [SoulSpherePickup, SoulSpherePickup]`
  (first takes health to 200, second reports `collected=False`).
- Root cause: `give_health`'s `collected: next > health` conflates "state
  changed" with "item consumed"; the two coincide for medikits but not for
  bonuses/spheres.
- Confidence: high on the vanilla rule, medium on whether the project wants
  vanilla behaviour here (`FIDELITY.md` does not mention it).
- Suggested fix (do NOT apply): give `apply_pickup` an explicit
  `collected: Bool.True` for those two kinds.

### B4. `damage_actor(actor, amount <= 0)` restarts the Pain state
- Severity: domain-gap (low)
- Location: `examples/doom/DoomWorld.roc:334-338`
- Property violated: non-positive damage should be a no-op (the function
  already clamps the amount to 0 for the health arithmetic, so it clearly
  intends to accept it). Instead every call with `amount <= 0` on a live actor
  sets `state: state(Pain)`, resetting its Attack/Chase countdown.
- Minimized input: crash text
  `non-positive damage entered pain 0 tic 6 kind=Imp prev={ mode: Chase, remaining: 3 }`
  (damage value 0 from `damages` list).
- Root cause: the `else` branch is unconditional; `damage_actor_random` at
  least rolls the pain chance, but `damage_actor` (used by `damage_first_live`
  for every hitscan hit) always enters Pain. Not reachable from `hitscan`
  today (min pellet damage is 5), hence low severity.
- Confidence: high on behaviour, low on whether anyone cares.
- Suggested fix (do NOT apply): early-return when `amount <= 0`.

### B5. DoomTrace partition invariance holds only away from exact tic boundaries (domain characterisation, not a bug)
- Severity: domain-gap (documentation)
- Location: `examples/doom/DoomSim.roc:82-96` (`advance`) as driven by
  `examples/doom/DoomTrace.roc:64-78` (`run_parts`)
- What was observed: with fractions k/64 whose per-command total T/64 is in
  [1, 2), the snapshot tic sequence matches the exact-rational model
  `floor(cum/64)` *except* at cumulative times that land exactly on a tic
  boundary (`cum % 64 == 0`). There the F32 remainder in `DoomSim.advance` is
  a few ulps below `tic_seconds` and the tic is deferred to the next part.
  Because the next part usually belongs to the next command, that tic is then
  simulated with a different `Command`, and every later snapshot legitimately
  differs. Example partition lists that diverge from their exact model:
  - `[90, 12, 14]/64` (T=116): expected `..., 28, 29, 30, ...`, actual
    `..., 28, 30, ...` — tic 29 (end of command 16, 16*116 = 29*64) deferred
    into command 17's first part, which then ticks twice.
  - `[10, 95, 2, 2, 2, 2, 2, 6]/64` (T=121): expected `28, 30(exact), 31`,
    actual `28, 29, 30, 31` — the 95/64 part stopped one tic short of the
    exact boundary at 30 and a 2/64 part picked it up.
  - `[14, 56, 2]/64` vs `[72]/64` (T=72): both produce a snapshot at tic 9
    (8*72 = 9*64), but in the partitioned run tic 9 was simulated with the
    turn command (`angle_turns: 0.015625`) and in the single-part run with the
    forward command (`angle_turns: 0`). Same tic sequence, different
    simulation: tic-count comparisons cannot detect this class.
  All three were confirmed to be F32 remainder accumulation (the per-part
  products `tic_seconds * k/64` are inexact once `k` needs more than a few
  mantissa bits, e.g. 90, 95), not simulation divergence: away from exact
  boundaries, no partition ever changed a snapshot (property T4 below).
- Exact-sum partitions DO NOT under-tick: `[1.0]`, `[0.25 x 4]`, `[0.5, 0.5]`,
  `[1/64, 63/64]`, `[63/64, 1/64]`, `[21, 21, 22]/64`, `[1/3 x 3]`, `[0.1 x 10]`,
  `[0.7, 0.3]`, `[0.2, 0.8]`, `[0.6, 0.4]`, `[0.9, 0.1]`, `[0.3, 0.3, 0.4]` all
  yield exactly 24 tics and the golden checksum. The `1.0001` epsilon in the
  existing expects is therefore not needed for these shapes; the observed
  deficit for total == 64/64 was 0 tics over all fuzzed splits (T2 never
  fired for T in 64..66). The fragility only shows up at T > 64 where the
  rounding of `tic_seconds * k/64` for large odd `k` accumulates across
  commands.
- Confidence: high.
- Suggested change (do NOT apply): none required in the modules; if the
  oracle should be split-invariant for arbitrary totals, `DoomSim.advance`
  would need an integer (e.g. 1/64-tic or microsecond) accumulator instead of
  an F32 remainder. At minimum the `run` doc comment could state that
  invariance is only promised for totals in [1, 1 + 1/24).

## Properties that held
fuzz_world (final campaign 300 s, 3,029,229 execs, no failure):
- ammo within `max_*` (x2 with backpack), health in [0,200], armor in [0,200],
  `armor_kind == NoArmor` iff `armor == 0`, pistol never lost, current weapon
  always owned — over random sequences of <= 64 pickups with/without a leading
  backpack. Guards: B1 (weapon/Berserk/LightAmp skip the collected-iff-changed
  check), B2 (health > 100 with stimpack/medikit/berserk), B3 (health 200 with
  soulsphere/health bonus), ArmorBonus at 200 armor (contract-only: reports
  collected with no change, which matches vanilla).
- `collected` iff state changed, and `collected` == vanilla
  `P_TouchSpecialThing` accept rule, for all non-guarded kinds (ammo, armor,
  keys, backpack, computer map).
- A taken pickup is never collected again and never changes the player.
- `collect_for_skill` makes the same accept decision as `collect` for all
  five skills and keeps the caps (Baby/Nightmare double ammo).
- Second backpack: `backpack` stays True and ammo is `min(2*cap, ammo + n)`
  — caps double exactly once.
- `damage_player` never raises health/armor, never underflows, keeps
  `armor_kind` consistent, and is a no-op for damage <= 0 (including
  `I64.min_value` wrap cases from random U64s).
- `world_tic` with `fire: True` for up to 255 tics from random ammo/weapon:
  ammo changes by at most one unit per tic, never negative, actor health never
  rises, dead actors never revive.
- `tick_actor_with` over <= 200 tics, random `ActorFacts` (position,
  sight/sound bits, optional wall) and all six actor kinds: health never
  rises, `Dead` absorbing, `remaining >= 1` while alive, `player_damage >= 0`
  and non-zero only on the terminal Attack tic with `attack_kind != NoAttack`,
  `Rng` consumed iff an attack fired, identical results for an identical seed
  (determinism).
- `damage_actor` / `damage_actor_random` agree on health, never go negative,
  `health == 0` iff `Dead`, `entered_pain` implies Pain state, dead actors
  never enter pain, a random byte is always consumed.
- A property I wrote was wrong and was removed: "Barrel (pain_chance 255)
  always enters pain" — the module uses `byte < pain_chance`, so byte 255
  misses, which is the vanilla `P_Random() < painchance` semantics. (Vanilla
  MT_BARREL actually has painchance 0; the module's 255 is a documented
  design choice for barrel flashing, not a bug I am claiming.)

fuzz_trace (final campaigns 2 x 300 s, ~3,850 execs each, no failure):
- T1: snapshot tic sequence equals the exact-rational model for every
  partition of 1..8 parts of k/64 with total in [64,127]/64, allowing
  deferral only at exact boundaries (see B5 for the two deferral shapes).
  Guard: the two exact-boundary deferral shapes are accepted by the walker.
- With a 1/4096 epsilon on one part, no exact boundary was ever deferred.
- T2: every partition with total in 64..66 sixty-fourths reproduces the
  golden trace and `golden_checksum` exactly (including total == 64, i.e. an
  exact frame with no epsilon).
- T3: single-part runs are deterministic.
- T4: for the same total, a multi-part run and the single-part run produce
  identical snapshots for every tic before the first exact boundary of either
  schedule.

## Notes
- Compiler crash: `List.map2(a, b, |x, y| { x, y })` where `x`/`y` are
  `DoomWorld.Actor` records segfaulted `roc build --fuzz` (nightly
  2026-08-23-fb208ba, SIGSEGV after ~0.2 s, "stack tracing is disabled").
  `roc check` passed. Replaced with an index loop. Not reduced further.
- F32 has no `==`/`!=` in this nightly ("type does not support equality"),
  and the opaque `DoomSim.Angle`/`DoomWorld.Rng` have no `is_eq`, so
  structural comparison of `Player`/`ActorTic` needed hand-written
  `same_player`/`same_turn` helpers using `F32.to_bits` and `.index()`.
  Oddly, `DoomTrace.Snapshot` (which contains F32 fields) compares fine with
  `==` — the failure seems specific to records containing the opaque types.
- `minimize` on the first crash ran for > 2 minutes without finishing on a
  2-byte input (libFuzzer `-minimize_crash` loops); the raw crashes were
  already tiny so I used `show` on them directly.
- Both targets share `examples/doom/.roc-fuzz/` by default; a second target
  picks up the first target's corpus (1,415 files) as seeds. Passing an
  explicit corpus dir (`run .roc-fuzz/trace-corpus`) avoids that.
- The worktree is two levels deeper than the main checkout, so the platform
  path in the target headers is `../../../../../../roc-fuzz/platform/main.roc`
  rather than the `../../../roc-fuzz/...` in the brief; adjust when merging.
- roc-fuzz: a `Fuzz.f32`/`Fuzz.f32_in` generator would be welcome; also a
  documented way to memoise an expensive reference value (`golden` here is a
  top-level constant and appears to be evaluated once, which made each
  `DoomTrace` input cost 2-3 runs instead of 3-4).
