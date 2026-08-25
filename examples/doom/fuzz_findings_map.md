# Fuzz findings: map

Target: `examples/doom/fuzz_map.roc` (structural maps through `DoomMap.validate` + every `Map` method and `DoomLevel` query) and `examples/doom/fuzz_map_decode.roc` (parser robustness of `DoomMap.decode`).
Campaign: - `fuzz_map`: ~1,230 s of wall-clock fuzzing over 7 runs (60 s unguarded, 2 x 120 s adding guards, one 600 s sliced run, one 120 s final slice, plus fork-mode/corpus-replay attempts that were discarded); ~715,000 executions in the runs whose counters were captured (7,712 + 95,369 + 366,880 + 244,993 + uncounted early runs); peak coverage 1,885 edges / 4,718 features.
- `fuzz_map_decode`: 150 s, 1,759,764 executions, peak coverage 3,873 edges / 9,130 features, no failures.
- libFuzzer `--timeout=10` throughout; every failure was replayed in a fresh process and only reproducible ones are reported below (see Notes for why that matters).

The core property under test: **anything `DoomMap.validate` accepts is safe to query**. The generator builds a small `DoomMap.Raw` directly (<=6 vertices/linedefs/sidedefs/segs, <=4 sectors/things, <=3 subsectors/nodes/polygons) with mostly-consistent cross references (indices resolved modulo the referenced list, two-sided flag kept in sync with the left sidedef, convex CCW rectangles/triangles for polygons) and a 1-in-8 perturbation on every reference so that validation's error paths are also exercised. The runner does not report rejection rates; qualitatively, validated maps are common enough that every bug below was found within the first minute of its campaign.

## Bugs

### B1. Cyclic BSP node graph passes validation and hangs `DoomLevel.sector_at`
- Severity: hang
- Location: `examples/doom/DoomMap.roc:203` (`validate_nodes`) / `examples/doom/DoomMap.roc:212` (`validate_child`); hang in `examples/doom/DoomLevel.roc:188` (`descend`)
- Property violated: validated map must be safe to query (`sector_at` must terminate for any point)
- Minimized input (from `show`, found in <10 s, libFuzzer `--timeout=10`):
  ```
  raw = { format: "doom", map: "FUZZ", vertices: [], linedefs: [], sidedefs: [], sectors: [], things: [], segs: [], subsectors: [],
          nodes: [{ x: -8, y: -8, dx: -8, dy: -8, right_bbox: ..., left_bbox: ...,
                    right_child: { kind: "node", index: 0 }, left_child: { kind: "node", index: 0 } }],
          subsector_polygon_bounds: ..., subsector_polygons: [] }
  query point = { x: NaN, y: 0 }   (any point hangs)
  ```
- Root cause: `validate_child` only bounds-checks `child.index`; nothing checks that `"node"` children form a DAG rooted at the last node. `descend` recurses on `child.index` unconditionally, so a self-loop (or any cycle) never reaches a subsector. Note the map also has zero subsectors and zero polygons, which validation accepts; even an acyclic node graph with no subsectors would be rejected by `validate_child` only because `List.len(raw.subsectors) == 0`, so the cycle is the only way to get here, but it is enough.
- Confidence: high (deterministic; reproduced by replay; root cause read from the code)
- Suggested fix (do NOT apply): in `validate_nodes` require `"node"` children to have `child.index < node_index` (the classic Doom BSP is built bottom-up with the root last, so this is exactly the invariant `sector_at` relies on with `root = len - 1`), or run an explicit cycle check with a visited set.
- Guard added to the target: `guard_node_cycles` rejects maps with a `"node"` child whose index is >= its parent's.

### B2. Tagged specials (2/23/62/88) crash when the tagged sector has no two-sided line
- Severity: crash
- Location: `examples/doom/DoomLevel.roc:425` (`lowest_adjacent_ceiling`: `crash "door sector has no adjacent sector"`) and `examples/doom/DoomLevel.roc:445` (`lowest_adjacent_floor`: `crash "floor sector has no adjacent sector"`); reached from `use_line` (23, 62) and `cross_line` (2, 88) via `activate_tagged_doors` / `activate_tagged_floors` / `activate_tagged_lifts`
- Property violated: validated map must be safe to query (`use_line`/`cross_line` for any linedef must not crash)
- Input (from `show`; the fuzzer found it within 30 s; `minimize` did not converge in the time given, but the shape is minimal by inspection):
  ```
  linedefs: [{ start_vertex: 1, end_vertex: 0, flags: 4, special: 2, tag: 1, right_sidedef: Ok(2), left_sidedef: Ok(2) }]
  sidedefs: four sidedefs, all sector: 2
  sectors: [ {tag: 2}, {tag: 2}, {tag: 2}, { ..., tag: 1 } ]   (sector 3 is tagged 1 but no linedef touches it)
  crossing linedef 0 (special 2, tag 1) -> activate_tagged_doors -> activate_door(sector 3) -> crash
  ```
- Root cause: `DoomMap.validate` never relates `linedef.tag` to sector tags or sector tags to geometry, so a tagged sector can have no adjacent sector. `lowest_adjacent_ceiling`/`lowest_adjacent_floor` treat "no adjacent sector" as impossible (`found ?? crash`). E1M1 happens to satisfy the assumption. Suspect 2 of the brief confirmed for 2/23/62/88. Specials 1/26/117 (`activate_local_door`) cannot reach the crash: the activating line is itself two-sided and adjacent to the chosen sector, so `found` is always `Ok` — refuted for those.
- Confidence: high (reproduced by replay; the code path is unconditional)
- Suggested fix (do NOT apply): either validate in `DoomMap.validate` that every sector referenced by a tag used by special 2/23/62/88 has at least one two-sided line, or make `activate_door`/`add_floor_movers`/`add_lifts` return `NotUsable` (or use the sector's own height) when there is no adjacent sector.
- Guard added to the target: `guard_orphan_tagged_sectors` rejects maps where a tagged special's tag reaches a sector with no two-sided line.

### B3. Duplicate vertex coordinates produce zero-length blocking/collision segments
- Severity: domain-gap (wrong-result downstream)
- Location: `examples/doom/DoomMap.roc:125` (`validate_linedefs` checks `start_vertex == end_vertex` by index only); consumers `blocking_segments` (`DoomMap.roc:247`) and `collision_segments` (`DoomLevel.roc:255`)
- Property violated: `blocking_segments` must not contain a segment with `start == end`
- Minimized input (from `show`):
  ```
  vertices: [{ x: -32, y: -32 }, { x: -32, y: -32 }]
  linedefs: [{ start_vertex: 0, end_vertex: 1, flags: 507, special: 2, tag: 3, right_sidedef: Ok(0), left_sidedef: Err(Null) }]
  sidedefs: [{ sector: 0, ... }], sectors: [one sector]
  ```
- Root cause: the degenerate-linedef check compares vertex indices, not coordinates; the same applies to `validate_segs`. A zero-length segment has no direction, so any downstream normal/projection math (collision response in DoomSim, wall span rendering with a zero-width quad, seg angles) divides by zero or produces NaN. `crossed_lines` returns nonsense for such lines but does not crash. Whether this is "out of documented domain" is arguable — the module comment promises validation of "every structural invariant used by the derived helpers", and E1M1's exporter will never emit it — so it is filed as a domain gap, not a crash.
- Confidence: high that validation accepts it; medium that it is harmful (I did not fuzz DoomSim's collision response here — that belongs to the sim target).
- Suggested fix (do NOT apply): reject linedefs/segs whose two vertices have equal coordinates (`DegenerateLinedef`), or at least drop them from `blocking_segments`/`collision_segments`.
- Guard added to the target: `guard_zero_length_lines`.

### B4. Compiled `DoomLevel.dynamic_sectors` returns garbage sector indices for a validated 2-sector map
- Severity: wrong-result (very likely a compiler/codegen bug, not a DoomLevel logic bug — see confidence)
- Location: `examples/doom/DoomLevel.roc:132` (`dynamic_sectors`) / `DoomLevel.roc:338` (`dynamic_sectors_from`) / `DoomLevel.roc:355` (`local_door_sectors`)
- Property violated: every index returned by `dynamic_sectors` is `< List.len(sectors)`
- Input (from `show`; reproducible under `replay` in a fresh process):
  ```
  vertices: [{ x: -16, y: 0 }, { x: -8, y: -8 }]
  linedefs: [{ start_vertex: 0, end_vertex: 1, flags: 316, special: 1, tag: 0, right_sidedef: Ok(2), left_sidedef: Ok(0) }]
  sidedefs: [ {sector: 1, upper: Ok(""), lower: Err(Null), middle: Ok("")}, {sector: 0, all Err(Null)},
              {sector: 0, all Ok("DOOR")}, {sector: 0, all Ok("DOOR")} ]
  sectors: [ { floor: -197, ceiling: 186, light: 59, special: 1, tag: 3 }, { floor: -191, ceiling: 132, light: 59, special: 12, tag: 0 } ]
  things: 3 non-player things; segs/subsectors/nodes/polygons: []
  ```
  Observed in the fuzz binary: `dynamic_sectors` = `[6436860225072878160, 7596835273554796602]` (the bytes look like the inline `"FLOOR"`/`"CEIL"` small strings of a `Sector` record) with 2 sectors.
- Cross-checks performed:
  - The same map as a literal in a `roc test` expect (interpreter) gives `[1, 0]`, which is the correct answer by hand (`local_door_sectors` picks the left sector 1 because its opening is smaller, then the special-1/12 loop appends 0).
  - The same literal in a separate compiled fuzz probe gives `[0, 1]` — a different *order* from the interpreter, so the compiled build already disagrees with the interpreter on which branch `right.ceiling - right.floor <= left.ceiling - left.floor` takes, even when the values are in range.
  - On E1M1 the compiled `dynamic_sectors` returns 27 in-range sectors, and a compiled `List.map_with_index(sectors, |sector, index| { sector, index })` gives correct indices, so it is not simply that pattern.
- Root cause: unknown; the interpreter and the compiled build disagree on a pure function of a plain record, and the compiled fuzz run yields values that are clearly bytes from a neighbouring `Str`. Most likely a native codegen layout/refcount bug in the 2026-08-23 nightly in the `{ sector, index }` record-of-record-with-Str iteration in `dynamic_sectors`, or in `local_door_sectors`'s `List.get(state.heights, ...)`. It is also plausible that this is the same memory-safety problem described under Notes (heap corruption inside a single execution).
- Confidence: medium that it is a real user-visible problem (the shipped game is a compiled build, so `render_changed`/`dynamic_sectors` may be operating on garbage indices for some maps), low that DoomLevel's source is at fault.
- Suggested fix (do NOT apply): reduce with the literal map above in a compiled (`roc build`) app vs. `roc test`, and report upstream; in DoomLevel, `append_unique` could defensively drop out-of-range indices, but that hides the codegen bug.
- Guard added to the target: `guard_dynamic_sectors` disables the range assertion so the campaign can continue.

### Suspects refuted
- Suspect 3 (`polygon_for_subsector` crash on a subsector with no polygon): refuted. `validate_polygons` checks every polygon's subsector index is in range, rejects duplicates, and requires `count == len(subsectors)`; by pigeonhole that is an identity check. The fuzzer never reached `crash "validated BSP polygon missing"`.
- Suspect 5 (`resolve_sector_heights` with equal-length heights): held — `wall_spans_at(initial heights) == wall_spans()` for every validated map.
- Collinear polygons: rejected by validation (`polygon_is_convex` uses a strict `cross > 0`, so three collinear points fail). Fuzzer confirmed no polygon-related crash.
- NaN/Inf/huge query points: `sector_at`, `crossed_lines` return `Err(OutsideMap)`/`[]` without crashing.

## Properties that held
All of the following held for every validated map over the full `fuzz_map` campaign (with guards `guard_node_cycles`, `guard_zero_length_lines`, `guard_orphan_tagged_sectors`, `guard_dynamic_sectors` applied after each corresponding bug was found):
- `wall_spans`: every span has `top > bottom`, an in-range `sector`, an in-range `linedef`. No crash from `side_spans`/`texture_span` for any combination of one-/two-sided lines, pegging flags, `Ok("")` textures, or inverted floor/ceiling heights.
- `wall_spans_at(initial(map).heights) == wall_spans()` (suspect 5, equal-length path of `resolve_sector_heights`).
- `surface_polygons`: exactly `2 * len(subsector_polygons)` surfaces, each with an in-range sector and >= 3 vertices.
- `blocking_segments`: every linedef index in range (zero-length segments excluded by guard, see B3).
- `player_start` never crashes (0, 1, or several type-1 things).
- `sector_at` for finite, NaN, +/-Inf, arbitrary-bit-pattern and exact-vertex points: either `Err(OutsideMap)` or an in-range sector; never a crash once node cycles are excluded (suspect 3 refuted, see above).
- `crossed_lines` returns only in-range indices of lines with `special != 0`, for any pair of points including NaN/Inf.
- `portal` for every (linedef, sector) pair in the map, including out-of-range and non-incident pairs: always a `Try`, never a crash.
- `collision_segments(map, state, s)` for every sector, before and after activations and up to 40 ticks: every returned linedef is in `state.incident_lines[s]`.
- `use_line` (all 8 key combinations) and `cross_line` over every linedef, followed by up to 40 `tick`s, `render_changed`, `light_for`, `heights_for`, and `wall_spans_at(ticked.heights)`: heights cardinality is preserved and nothing crashes (once B2's orphan-tag case is excluded). Includes special-1/26/117 doors whose two sides are the same sector (validation allows `right_sidedef == left_sidedef`), where `lowest_adjacent_ceiling` finds the sector itself; the door then has `open = closed - 4` and finishes on its first tick -- harmless, but odd.
- `dynamic_sectors` has no duplicates (range assertion disabled after B4).
- `DoomMap.decode` on 1.76 M inputs (arbitrary `Fuzz.str` and byte-spliced mutations of a valid map JSON): always `Ok`/`Err`, never a crash or hang; every `Ok` map also survived `wall_spans`/`surface_polygons`/`blocking_segments`/`player_start`.

## Notes
- **The 2026-08-23 nightly's compiled output is not memory-safe on this target.** Three distinct symptoms, all absent under the interpreter (`roc test` on the same literal maps passes):
  1. B5-style reproducible segfault inside `roc_llvm_rc_decref_*` (see B5 below).
  2. Cross-input heap corruption: replaying a specific 27-input sequence from the corpus in one process (`fuzz_map replay <dir>`) segfaults inside libFuzzer's `InputCorpus::AddToCorpus` (`this=0x1`), while every one of those inputs replays cleanly on its own. Reduced with a delta-debugging script; the sequence is in the scratchpad (`.../scratchpad/seq`). Partial targets (validate only; validate + span/surface derivations; validate + DoomLevel queries; validate + activation loop; validate + `wall_spans_at` equality) each replay the same sequence cleanly -- only the full test corrupts, so it is an accumulation effect rather than one function. gdb/valgrind give no earlier invalid access (static musl binary, so memcheck cannot intercept the allocator).
  3. libFuzzer's "fuzz target overwrites its const input" and a spurious "Integer multiplication overflowed" -- both non-reproducible under replay; consistent with a dangling write.
  Consequence for this campaign: any long single-process run eventually dies spuriously, and fork mode is useless (each job re-executes the poisoned corpus and dies immediately: 140 bogus artifacts in 20 s). I ran 75-90 s slices with a fresh corpus directory each and replayed every artifact in a fresh process, discarding non-reproducible ones. Execution counts above are therefore a lower bound on what a healthy toolchain would have achieved. This should be reported upstream with `fuzz_map.roc` as the reproducer; B4 is probably the same bug seen from the Roc side.
- `Fuzz.target` with a one-field record builder (`{ seed: Fuzz.u8 }.Fuzz`) fails at runtime with a bare "runtime error" on every input; two or more fields work. Worth a compile-time diagnostic in roc-fuzz.
- The runner prints `minimize INPUT OUTPUT` but the OUTPUT file is written progressively; when the minimizer is interrupted by a timeout the OUTPUT can contain a non-crashing intermediate. Minimization of B2 did not converge in 150 s; the input shown is the un-minimized one.
- `roc build --fuzz` writes the executable into the current working directory, not next to the source file; the brief's "next to the file" assumption only holds when cwd is `examples/doom`.
- Platform path: from this worktree (`.claude/worktrees/<agent>/examples/doom`) the brief's `../../../roc-fuzz/platform/main.roc` resolves to `.claude/worktrees/roc-fuzz`, which does not exist. The committed targets use the brief's path (correct from the main checkout); during development I used `../../../../../../roc-fuzz/platform/main.roc`.
- No float generator: query points are built from `U64` via scaling and `F64.from_bits` (NaN/Inf/subnormal coverage came from the bit-pattern mode).
- Acceptance rate: not measurable with this runner (no rejection statistics). Coverage of the validated path grew steadily and each bug surfaced in well under a minute, which is the practical signal that the two-stage generator accepts a useful fraction.
- Deleted before commit: probe targets used to bisect B4/B5 and two `roc test` reproducer modules (`repro_dyn.roc`, `repro_segv.roc`); their contents are reproduced in B4/B5 above.

### B5. Compiled build segfaults in refcount decref for a validated map (interpreter is fine)
- Severity: crash (toolchain; reproducible in a fresh process)
- Location: not in Doom source -- `roc_llvm_rc_decref_120_single_thread` <- `roc_llvm_rc_decref_122_single_thread` <- `roc.proc_92a0` <- ... <- `roc_fuzz_run` (gdb). Under `roc test` the same map passes every query in `fuzz_map`'s test.
- Property violated: none of Doom's; the compiled program crashes with SIGSEGV.
- Input (from `show`; artifact base64 `ACnJycnJyT0AAP/JyQD8KS4uLi4uLjAuLi4uLi4uLi4uLi4uLi4uLi4uLi4uLi4uOzs7Oy4uLi4uLi4uLi4uLi7/PU7//2NjY2NjY2Nj6fv/ATtb//9N6QH/+wEJyQAJyc3JyT1O/////GNjY2NjY2NjY2NjY2NjACnp+/8BAQkCTjoAAv+c`):
  ```
  vertices: [{ x: -16, y: -32 }, { x: 0, y: 16 }, { x: -16, y: -32 }]
  linedefs: [{ start_vertex: 1, end_vertex: 0, flags: 489, special: 23, tag: 0, right_sidedef: Ok(0), left_sidedef: Err(Null) }]
  sidedefs: [{ x_offset: 9, y_offset: 9, upper/lower/middle: Ok(""), sector: 1 }]
  sectors: [{ floor: -28, ceiling: 196, light: 91, special: 9, tag: 1 }, { floor: -63, ceiling: 1, light: 129, special: 11, tag: 3 }]
  things: [{ x: 32, y: 8, angle: 234, type: 3, flags: 27 }]
  segs: [{ start_vertex: 0, end_vertex: 2, angle: 59747, linedef: 0, direction: 0, offset: 34 }]
  subsectors: 3 x { seg_count: 1, first_seg: 0 }
  nodes: [{ x: -24, y: -24, dx: -24, dy: -24, children: subsector 2 / subsector 2 }, { x: -24, y: 8, dx: 8, dy: 8, children: subsector 2 / subsector 2 }]
  subsector_polygons: three CCW triangles at (-24,-24), all sector 0, subsectors 0/1/2
  query = { keys: 0, line: 0, sector: 0, ticks: 0, qmode: 0 (NaN x), ... }
  ```
- Root cause: unknown; a refcount decrement on a bad pointer in compiled code. Likely the same defect as B4 and the cross-input corruption in Notes.
- Confidence: high that it reproduces (fresh-process replay segfaults every time); low on attribution beyond "compiler".
- Suggested fix (do NOT apply): report upstream with the artifact; keep `roc test` (interpreter) as the oracle for these modules until fixed.
- Artifacts for the other bugs (base64 of the libFuzzer unit, replay with `./fuzz_map replay <file>`):
  - B1: `AQAA////////////AQAAAAAAAAAC`
  - B2: `AE0U/hT/////AADSAAAAUVFRUU0PEgD/////1tbW1tYFAAAAAAAABdbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tbW1tZNDwAAAAEPACgAAAJN`
  - B3: `ERHDAAAAAMMBANDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQw8PDw8PDAAQRAAAAAAAAAP/+////////////////ASsBz8/Pz8///w==`
  - B4: `//////8LCwsLCwtcXFxcJlxcXFwmXFz//1FcXFxcjo6Ojo6Ojo7Ojo6Ojo6Ojo6Ojo6OXFxcXFxcXFwLCwsLJAsLCytbC1xcXDI0MjgLC1xc//9VXDP/`
  Note: artifacts decode through the *current* generator; if `fuzz_map.roc`'s generator changes they stop meaning the same map.
