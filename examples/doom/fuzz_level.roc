app [target] { fuzz: platform "/home/lbw/Documents/Github/roc-fuzz/platform/main.roc" }

import fuzz.Fuzz
import DoomMap
import DoomLevel

## One simulation command. `kind % 4`: 0 use-line, 1 cross-line, 2/3 tick.
## The linedef is usually drawn from the E1M1 special-line set (`pick`), and
## occasionally any raw index including out-of-range ones.
Cmd : { kind : U8, pick : U64, raw_line : U64, ticks : U64 }

Input := { cmds : List(Cmd), key_bits : U8, label : Str }.{
	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			cmds: Fuzz.list(
				{
					kind: Fuzz.u8_in(0, 3),
					pick: Fuzz.u64_in(0, 255),
					raw_line: Fuzz.u64_in(0, 1300),
					ticks: Fuzz.u64_in(0, 400),
				}.Fuzz,
				200,
			),
			key_bits: Fuzz.u8_in(0, 7),
			label: Fuzz.constant("fuzz"),
		}.Fuzz
	}
}

max_speed = 8

max_total_ticks = 1500

quiescence_bound = 2000

## Linedef indices whose special is one of the supported E1M1 vocabulary.
special_lines = |raw| {
	var $result = []
	for entry in List.map_with_index(raw.linedefs, |line, index| { line, index }) {
		s = entry.line.special
		if s == 1 or s == 2 or s == 11 or s == 23 or s == 26 or s == 62 or s == 88 or s == 117 {
			$result = List.append($result, entry.index)
		}
	}
	$result
}

## Guards for bugs already recorded in fuzz_findings_level.md, so the campaign
## can keep looking for the next one. Flip to False to reproduce them.
## B1: special 62 is treated as a permanent door, but its E1M1 tags name lift
## sectors, so `open` lands below `closed`.
guard_special_62 = Bool.True

## B2: re-using a door sector mid-cycle rebuilds it with `closed: current
## ceiling`, so it never closes again. Skips use-line commands while any door
## is active.
guard_door_reuse = Bool.True

## Linedef indices excluded by the active guards.
guarded_lines = |raw| {
	var $result = []
	for entry in List.map_with_index(raw.linedefs, |line, index| { line, index }) {
		if guard_special_62 and entry.line.special == 62 {
			$result = List.append($result, entry.index)
		}
	}
	$result
}

## Pick the linedef for a command. Guarded lines are redirected to an unused
## index so the command becomes a no-op.
resolve_line : List(U64), List(U64), Cmd -> U64
resolve_line = |guarded, specials, cmd| {
	line = if cmd.pick % 8 == 0 cmd.raw_line else {
		List.get(specials, cmd.pick % List.len(specials)) ?? cmd.raw_line
	}
	if List.contains(guarded, line) 5000 else line
}

## WORKAROUND for a native-codegen refcount bug (see fuzz_findings_level.md,
## Notes): a record spread update `{ ..state, field: x }` inside a callee frees
## the caller's list fields when compiled with `roc build`. DoomLevel builds
## every new `State` that way, so each call gets a fresh copy and the caller's
## value stays intact. The copy itself must be built without a spread.
## Remove once the compiler is fixed.
copy_state = |state| {
	heights: fresh(state.heights),
	incident_lines: state.incident_lines,
	doors: fresh(state.doors),
	floors: fresh(state.floors),
	lifts: fresh(state.lifts),
	tic: state.tic,
	light_rng: state.light_rng,
	light_flashes: fresh(state.light_flashes),
}

## Always allocate a new list (List.map may reuse a buffer it believes unique).
fresh = |items| {
	var $out = []
	for item in items {
		$out = List.append($out, item)
	}
	$out
}

tick = |state| DoomLevel.tick(copy_state(state))

use_line = |map, state, line, keys| DoomLevel.use_line(map, copy_state(state), line, keys)

cross_line = |map, state, line| DoomLevel.cross_line(map, copy_state(state), line)

keys_of = |bits| { blue: bits % 2 == 1, yellow: (bits / 2) % 2 == 1, red: (bits / 4) % 2 == 1 }

## Sectors sharing a two-sided line with `sector`.
adjacent_sectors = |raw, sector| {
	var $result = []
	for line in raw.linedefs {
		match (line.left_sidedef, line.right_sidedef) {
			(Ok(l), Ok(r)) => {
				ls = (List.get(raw.sidedefs, l) ?? crash "sidedef").sector
				rs = (List.get(raw.sidedefs, r) ?? crash "sidedef").sector
				other = if ls == sector Ok(rs) else if rs == sector Ok(ls) else Err(No)
				match other {
					Ok(o) => if List.contains($result, o) {} else {
						$result = List.append($result, o)
					}
					Err(_) => {}
				}
			}
			_ => {}
		}
	}
	$result
}

## Property checks run between two consecutive states one tick apart.
check_tick = |map, before, after, step_desc| {
	for entry in List.map_with_index(after.heights, |h, index| { h, index }) {
		prev = List.get(before.heights, entry.index) ?? crash "height list shrank"
		if entry.h.floor > entry.h.ceiling {
			crash "PROPERTY: floor<=ceiling: sector ${Str.inspect(entry.index)} floor ${Str.inspect(entry.h.floor)} > ceiling ${Str.inspect(entry.h.ceiling)} at ${step_desc}"
		}
		df = I64.abs(entry.h.floor - prev.floor)
		dc = I64.abs(entry.h.ceiling - prev.ceiling)
		if df > max_speed or dc > max_speed {
			crash "PROPERTY: no-snapping: sector ${Str.inspect(entry.index)} moved floor ${Str.inspect(prev.floor)}->${Str.inspect(entry.h.floor)} ceiling ${Str.inspect(prev.ceiling)}->${Str.inspect(entry.h.ceiling)} in one tic at ${step_desc}"
		}
		# Light lookups dominate the cost (special-12 scans every linedef), so
		# sample them on a cadence coprime with the 20-tic strobe period.
		if after.tic % 7 == 0 {
			light = DoomLevel.light_for(map, after, entry.index) ?? crash "light_for range"
			if light < 0 or light > 255 {
				crash "PROPERTY: light-range: sector ${Str.inspect(entry.index)} light ${Str.inspect(light)} at ${step_desc}"
			}
		}
	}
	for door in after.doors {
		if door.open < door.closed {
			crash "PROPERTY: door-open>=closed: sector ${Str.inspect(door.sector)} open ${Str.inspect(door.open)} closed ${Str.inspect(door.closed)} at ${step_desc}"
		}
	}
}

direct_changed = |map, before, after| {
	var $changed = Bool.False
	for entry in List.map_with_index(after.heights, |h, index| { h, index }) {
		prev = List.get(before.heights, entry.index) ?? crash "height list shrank"
		lb = DoomLevel.light_for(map, before, entry.index) ?? crash "light"
		la = DoomLevel.light_for(map, after, entry.index) ?? crash "light"
		if prev != entry.h or lb != la {
			$changed = Bool.True
		}
	}
	$changed
}

check_render_changed = |map, state, step_desc| {
	if DoomLevel.render_changed(map, state, state) {
		crash "PROPERTY: render_changed(s,s) must be False at ${step_desc}"
	}
	after = tick(state)
	claimed = DoomLevel.render_changed(map, state, after)
	actual = direct_changed(map, state, after)
	if claimed != actual {
		crash "PROPERTY: render_changed: claimed ${Str.inspect(claimed)} actual ${Str.inspect(actual)} at ${step_desc} (doors ${Str.inspect(state.doors)} floors ${Str.inspect(state.floors)} lifts ${Str.inspect(state.lifts)})"
	}
}

tick_checked = |map, state, count, step_desc, checked| {
	var $state = state
	var $n = 0
	while $n < count {
		next = tick($state)
		if checked {
			check_tick(map, $state, next, "${step_desc} tic ${Str.inspect($n)}")
		}
		$state = next
		$n = $n + 1
	}
	$state
}

## Apply the stream and return the final state. `checked` enables the per-tick
## property checks; the determinism re-run skips them (they are pure anyway).
## `render_changed` is expensive (it rebuilds the dynamic-sector set), so it is
## checked on every activation plus a sampled subset of the other steps.
run_stream = |map, guarded, specials, input, checked| {
	keys = keys_of(input.key_bits)
	var $state = DoomLevel.initial(map)
	var $total = 0
	var $step = 0
	for cmd in input.cmds {
		line = resolve_line(guarded, specials, cmd)
		desc = "${input.label} step ${Str.inspect($step)}"
		prev = $state
		if cmd.kind == 0 and guard_door_reuse and !(List.is_empty(prev.doors)) {
			{}
		} else if cmd.kind == 0 {
			match use_line(map, prev, line, keys) {
				Activated(next) => {
					$state = next
					if checked {
						check_tick(map, prev, $state, "${desc} use ${Str.inspect(line)} (activation)")
						check_render_changed(map, $state, "${desc} after use ${Str.inspect(line)}")
					}
				}
				_ => if checked and $step % 16 == 0 check_render_changed(map, $state, "${desc} after use ${Str.inspect(line)}") else {}
			}
		} else if cmd.kind == 1 {
			match cross_line(map, prev, line) {
				Activated(next) => {
					$state = next
					if checked {
						check_tick(map, prev, $state, "${desc} cross ${Str.inspect(line)} (activation)")
						check_render_changed(map, $state, "${desc} after cross ${Str.inspect(line)}")
					}
				}
				_ => if checked and $step % 16 == 0 check_render_changed(map, $state, "${desc} after cross ${Str.inspect(line)}") else {}
			}
		} else {
			n = U64.min(cmd.ticks, max_total_ticks - U64.min($total, max_total_ticks))
			$state = tick_checked(map, $state, n, "${desc} tick", checked)
			$total = $total + n
		}
		$step = $step + 1
	}
	$state
}

check_quiescence = |map, raw, initial, state, label| {
	var $state = state
	var $n = 0
	while $n < quiescence_bound and !(List.is_empty($state.doors) and List.is_empty($state.floors) and List.is_empty($state.lifts)) {
		next = tick($state)
		check_tick(map, $state, next, "${label} quiescence tic ${Str.inspect($n)}")
		$state = next
		$n = $n + 1
	}
	if !(List.is_empty($state.doors) and List.is_empty($state.floors) and List.is_empty($state.lifts)) {
		crash "PROPERTY: quiescence-hang (${label}): movers still active after ${Str.inspect(quiescence_bound)} tics: doors ${Str.inspect($state.doors)} floors ${Str.inspect($state.floors)} lifts ${Str.inspect($state.lifts)}"
	}
	for entry in List.map_with_index($state.heights, |h, index| { h, index }) {
		init = List.get(initial.heights, entry.index) ?? crash "initial height missing"
		if init != entry.h {
			adj = adjacent_sectors(raw, entry.index)
			adj_floors = List.map(adj, |s| (List.get(initial.heights, s) ?? crash "adj").floor)
			adj_ceils = List.map(adj, |s| (List.get(initial.heights, s) ?? crash "adj").ceiling)
			lowest_ceiling = List.fold(adj_ceils, I64.highest, |acc, c| I64.min(acc, c))
			floor_ok = entry.h.floor == init.floor or List.contains(adj_floors, entry.h.floor)
			ceiling_ok = entry.h.ceiling == init.ceiling or entry.h.ceiling == lowest_ceiling - 4
			if !(floor_ok and ceiling_ok) {
				crash "PROPERTY: quiescent-heights (${label}): sector ${Str.inspect(entry.index)} rests at ${Str.inspect(entry.h)} but initial ${Str.inspect(init)}, adjacent initial floors ${Str.inspect(adj_floors)}, lowest adjacent initial ceiling ${Str.inspect(lowest_ceiling)}"
			}
		}
	}
	$state
}

test : Input -> Fuzz.Outcome
test = |input| {
	map = DoomMap.e1m1
	raw = map.raw()
	specials = special_lines(raw)
	guarded = guarded_lines(raw)
	initial = DoomLevel.initial(map)
	final = run_stream(map, guarded, specials, input, Bool.True)
	again = run_stream(map, guarded, specials, input, Bool.False)
	# Compared through Str.inspect: derived `==` on State is miscompiled by the
	# native backend (see Notes in the findings file).
	if Str.inspect(final) != Str.inspect(again) {
		crash "PROPERTY: determinism: two applications of the same stream differ: doors ${Str.inspect(final.doors)} / ${Str.inspect(again.doors)} floors ${Str.inspect(final.floors)} / ${Str.inspect(again.floors)} lifts ${Str.inspect(final.lifts)} / ${Str.inspect(again.lifts)} tic ${Str.inspect(final.tic)} / ${Str.inspect(again.tic)}"
	}
	_ = check_quiescence(map, raw, initial, final, input.label)
	Fuzz.keep
}

show_input = |input| {
	raw = DoomMap.e1m1.raw()
	specials = special_lines(raw)
	guarded = guarded_lines(raw)
	keys = keys_of(input.key_bits)
	lines = List.map(
		input.cmds,
		|cmd| {
			line = resolve_line(guarded, specials, cmd)
			special = match List.get(raw.linedefs, line) {
				Ok(l) => "special ${Str.inspect(l.special)} tag ${Str.inspect(l.tag)}"
				Err(_) => "out-of-range"
			}
			if cmd.kind == 0 "UseLine(${Str.inspect(line)}) [${special}]" else if cmd.kind == 1 "CrossLine(${Str.inspect(line)}) [${special}]" else "Tick(${Str.inspect(cmd.ticks)})"
		},
	)
	"keys ${Str.inspect(keys)}\n${Str.join_with(lines, "\n")}"
}

target = Fuzz.target({
	name: "doom-level-movers",
	test,
	show: show_input,
})

## Interpreter-driven pseudo-random campaign (`roc test fuzz_level.roc`). The
## native fuzz build miscompiles this module's state handling (see Notes in
## the findings file), so the same property test is also driven here from a
## deterministic LCG stream, where refcounting is correct.
lcg_stream = |seed, count| {
	var $x = seed
	var $cmds = []
	var $n = 0
	while $n < count {
		$x = U64.to_u32_wrap(U32.to_u64($x) * 1664525 + 1013904223)
		kind = U32.to_u8_wrap($x / 16777216) % 4
		pick = U32.to_u64(($x / 256) % 256)
		$x = U64.to_u32_wrap(U32.to_u64($x) * 1664525 + 1013904223)
		raw_line = U32.to_u64(($x / 256) % 1301)
		ticks = U32.to_u64($x % 401)
		$cmds = List.append($cmds, { kind, pick, raw_line, ticks })
		$n = $n + 1
	}
	$cmds
}

## Run `count` LCG-seeded streams of `len` commands each; crashes on the first
## property violation and names the seed.
run_seeds = |first_seed, count, len| {
	var $seed = first_seed
	var $ok = Bool.True
	while $seed < first_seed + count {
		input = Input.({ cmds: lcg_stream($seed, len), key_bits: U64.to_u8_wrap(U32.to_u64($seed) % 8), label: "seed ${Str.inspect($seed)}" })
		$ok = $ok and match test(input) {
			Keep => Bool.True
			Reject => Bool.False
		}
		$seed = $seed + 1
	}
	$ok
}

# Kept short for `roc test`; the recorded campaign ran `run_seeds(1, 400, 40)`.
expect run_seeds(1, 100, 40)
