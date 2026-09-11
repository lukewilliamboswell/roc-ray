app [target] { fuzz: platform "../../../roc-fuzz/platform/main.roc" }

import fuzz.Fuzz
import RocDoomSim

# Fuzz target for the pure RocDoomSim tic layer. Every property crashes with a
# "PROPERTY: <name>" message so the runner captures it. The bugs this target
# found (FUZZ_FINDINGS.md S1-S4) are fixed; every property now runs
# unconditionally.

## Grazes shallower than this many map units are tolerated by the path check;
## the sim samples the sweep at 64 points, so exact contact is not detectable.
graze_depth : F32
graze_depth = 2

## Partition drift is expected F32 behaviour; report it only when asked.
report_partition_drift = Bool.False

Vec2 : { x : F32, y : F32 }

Input := {
	turn_bits : U64,
	wild_elapsed_bits : U64,
	sqrt_bits : U64,
	elapsed_seq : List(U64),
	parts : U64,
	pos : Vec2,
	momentum : Vec2,
	angle_turns : F32,
	forward : I16,
	side : I16,
	turn : F32,
	fire : Bool,
	blockers : List(RocDoomSim.Segment),
}.{
	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			turn_bits: Fuzz.u64,
			wild_elapsed_bits: Fuzz.u64,
			sqrt_bits: Fuzz.u64,
			elapsed_seq: Fuzz.list(Fuzz.u64_in(0, 8000), 24),
			parts: Fuzz.u64_in(1, 64),
			pos: vec2_gen,
			momentum: momentum_gen,
			angle_turns: unit_gen,
			forward: i16_gen,
			side: i16_gen,
			turn: signed_unit_gen,
			fire: Fuzz.map(Fuzz.u8_in(0, 1), |v| v == 1),
			blockers: Fuzz.list(segment_gen, 6),
		}.Fuzz
	}
}

coord_gen : Fuzz.Generator(F32)
coord_gen = Fuzz.map(Fuzz.u64_in(0, 400), |v| U64.to_f32(v) - 200)

vec2_gen : Fuzz.Generator(Vec2)
vec2_gen = Fuzz.map2(coord_gen, coord_gen, |x, y| { x, y })

segment_gen : Fuzz.Generator(RocDoomSim.Segment)
segment_gen = Fuzz.map2(vec2_gen, vec2_gen, |start, end| { start, end })

## Momentum in [-40, 40] in tenths, so some inputs start above the cap.
momentum_coord_gen : Fuzz.Generator(F32)
momentum_coord_gen = Fuzz.map(Fuzz.u64_in(0, 800), |v| (U64.to_f32(v) - 400) / 10)

momentum_gen : Fuzz.Generator(Vec2)
momentum_gen = Fuzz.map2(momentum_coord_gen, momentum_coord_gen, |x, y| { x, y })

unit_gen : Fuzz.Generator(F32)
unit_gen = Fuzz.map(Fuzz.u64_in(0, 999), |v| U64.to_f32(v) / 1000)

signed_unit_gen : Fuzz.Generator(F32)
signed_unit_gen = Fuzz.map(Fuzz.u64_in(0, 2000), |v| (U64.to_f32(v) - 1000) / 1000)

i16_gen : Fuzz.Generator(I16)
i16_gen = Fuzz.map(Fuzz.u64_in(0, 200), |v| U64.to_i16_wrap(v) - 100)

bits_to_f32 : U64 -> F32
bits_to_f32 = |bits| F32.from_bits(U64.to_u32_wrap(bits))

radius : F32
radius = 16

eps : F32
eps = 0.001

two_pow_24 : F32
two_pow_24 = 16777216

test : Input -> Fuzz.Outcome
test = |input| {
	check_angle(input)
	check_sqrt(input)
	state0 = { ..RocDoomSim.initial(input.pos, RocDoomSim.Angle.from_turns(input.angle_turns)), momentum: input.momentum }
	command = { forward: input.forward, side: input.side, turn: input.turn, fire: input.fire, weapon_slot: KeepWeapon }
	check_tic(state0, command, input.blockers)
	check_neutral(state0, input.blockers)
	check_collision(state0, command, input.blockers)
	check_advance_sequence(state0, command, input.blockers, input.elapsed_seq)
	check_wild_elapsed(state0, command, input.blockers, input.wild_elapsed_bits)
	check_partition(state0, command, input.blockers, input.parts)
	Fuzz.keep
}

# ---------------------------------------------------------------------------
# P1: Angle.from_turns terminates and lands in [0, 1) for any F32.

check_angle : Input -> {}
check_angle = |input| {
	t = bits_to_f32(input.turn_bits)
	{
		r = RocDoomSim.Angle.from_turns(t).turns()
		if !(F32.is_finite(r)) or r < 0 or r >= 1 {
			crash "PROPERTY: angle_range: from_turns(${Str.inspect(t)}) -> ${Str.inspect(r)}"
		}
		added = RocDoomSim.Angle.from_turns(0.5).add(t).turns()
		if !(F32.is_finite(added)) or added < 0 or added >= 1 {
			crash "PROPERTY: angle_add_range: add(0.5, ${Str.inspect(t)}) -> ${Str.inspect(added)}"
		}
	}
}

# ---------------------------------------------------------------------------
# P6: RocDoomSim.sqrt agrees with F32.sqrt on the squared-length domain.

check_sqrt : Input -> {}
check_sqrt = |input| {
	v = bits_to_f32(input.sqrt_bits)
	in_domain = F32.is_finite(v) and v > 0 and v <= 100000000
	if in_domain {
		got = RocDoomSim.sqrt(v)
		want = F32.sqrt(v)
		rel = F32.abs(got - want) / want
		if !(F32.is_finite(got)) or rel > 0.0001 {
			crash "PROPERTY: sqrt_accuracy: RocDoomSim.sqrt(${Str.inspect(v)}) = ${Str.inspect(got)}, F32.sqrt = ${Str.inspect(want)}, rel_err = ${Str.inspect(rel)}"
		}
	}
}

# ---------------------------------------------------------------------------
# P3: tic output invariants.

check_state : Str, RocDoomSim.State -> {}
check_state = |label, s| {
	if !(F32.is_finite(s.pos.x) and F32.is_finite(s.pos.y)) {
		crash "PROPERTY: ${label}: non-finite pos ${Str.inspect(s.pos)}"
	}
	if !(F32.is_finite(s.momentum.x) and F32.is_finite(s.momentum.y)) or F32.abs(s.momentum.x) > RocDoomSim.max_move or F32.abs(s.momentum.y) > RocDoomSim.max_move {
		crash "PROPERTY: ${label}: momentum out of range ${Str.inspect(s.momentum)}"
	}
	turns = s.angle.turns()
	if !(F32.is_finite(turns)) or turns < 0 or turns >= 1 {
		crash "PROPERTY: ${label}: angle turns out of range ${Str.inspect(turns)}"
	}
	view = s.view
	if !(F32.is_finite(view.bob)) or view.bob < 0 or view.bob > RocDoomSim.max_bob {
		crash "PROPERTY: ${label}: bob out of range ${Str.inspect(view.bob)}"
	}
	if !(F32.is_finite(view.offset) and F32.is_finite(view.weapon_x) and F32.is_finite(view.weapon_y) and F32.is_finite(view.weapon_kick)) {
		crash "PROPERTY: ${label}: non-finite view ${Str.inspect(view)}"
	}
	if !(F32.is_finite(view.weapon_phase)) or view.weapon_phase < 0 or view.weapon_phase >= 1 {
		crash "PROPERTY: ${label}: weapon_phase out of range ${Str.inspect(view.weapon_phase)}"
	}
}

check_tic : RocDoomSim.State, RocDoomSim.Command, List(RocDoomSim.Segment) -> {}
check_tic = |state0, command, blockers| {
	s1 = RocDoomSim.tic(state0, command, blockers)
	check_state("tic_invariants", s1)
	if s1.tic != state0.tic + 1 {
		crash "PROPERTY: tic_counter: ${Str.inspect(s1.tic)}"
	}
}

# ---------------------------------------------------------------------------
# P7: a neutral command with zero momentum never moves the player.

check_neutral : RocDoomSim.State, List(RocDoomSim.Segment) -> {}
check_neutral = |state0, blockers| {
	resting = { ..state0, momentum: RocDoomSim.zero }
	s1 = RocDoomSim.tic(resting, RocDoomSim.neutral, blockers)
	if s1.pos != resting.pos or s1.momentum != RocDoomSim.zero {
		crash "PROPERTY: neutral_rest: pos ${Str.inspect(resting.pos)} -> ${Str.inspect(s1.pos)}, momentum ${Str.inspect(s1.momentum)}"
	}
}

# ---------------------------------------------------------------------------
# P4: no tunnelling. Starting clear of every blocker, the path the centre
# actually takes in one tic must stay clear of every blocker, and the end
# position must not penetrate one.

sub : Vec2, Vec2 -> Vec2
sub = |a, b| { x: a.x - b.x, y: a.y - b.y }

cross : Vec2, Vec2 -> F32
cross = |a, b| a.x * b.y - a.y * b.x

## Strict proper crossing of segment p0-p1 with segment s (both interiors).
segments_cross : Vec2, Vec2, RocDoomSim.Segment -> Bool
segments_cross = |p0, p1, s| {
	d = sub(p1, p0)
	e = sub(s.end, s.start)
	o1 = cross(d, sub(s.start, p0))
	o2 = cross(d, sub(s.end, p0))
	o3 = cross(e, sub(p0, s.start))
	o4 = cross(e, sub(p1, s.start))
	((o1 > 0 and o2 < 0) or (o1 < 0 and o2 > 0)) and ((o3 > 0 and o4 < 0) or (o3 < 0 and o4 > 0))
}

## Sample the centre path like the sim does and look for any penetration.
path_penetrates : Vec2, Vec2, RocDoomSim.Segment -> Bool
path_penetrates = |p0, p1, s| {
	d = sub(p1, p0)
	var $hit = Bool.False
	var $i = 1.U64
	while $i < 64 {
		amount = U64.to_f32($i) / 64
		p = { x: p0.x + d.x * amount, y: p0.y + d.y * amount }
		if RocDoomSim.distance_to_segment_squared(p, s) < (radius - graze_depth) * (radius - graze_depth) {
			$hit = Bool.True
		}
		$i = $i + 1
	}
	$hit
}

check_collision : RocDoomSim.State, RocDoomSim.Command, List(RocDoomSim.Segment) -> {}
check_collision = |state0, command, blockers| {
	start_clear = !(RocDoomSim.any_collision(state0.pos, radius, blockers))
	if start_clear {
		s1 = RocDoomSim.tic(state0, command, blockers)
		for b in blockers {
			d2 = RocDoomSim.distance_to_segment_squared(s1.pos, b)
			if d2 < radius * radius - eps {
				crash "PROPERTY: end_penetration: from ${Str.inspect(state0.pos)} momentum ${Str.inspect(state0.momentum)} to ${Str.inspect(s1.pos)} penetrates ${Str.inspect(b)} (d2 = ${Str.inspect(d2)})"
			}
			if segments_cross(state0.pos, s1.pos, b) {
				crash "PROPERTY: tunnel_cross: centre path ${Str.inspect(state0.pos)} -> ${Str.inspect(s1.pos)} crosses ${Str.inspect(b)}"
			}
			if path_penetrates(state0.pos, s1.pos, b) {
				crash "PROPERTY: tunnel_graze: centre path ${Str.inspect(state0.pos)} -> ${Str.inspect(s1.pos)} passes through ${Str.inspect(b)}"
			}
		}
	}
}

# ---------------------------------------------------------------------------
# P2: advance accounting over a sequence of ordinary host frames.

check_advance_result : Str, RocDoomSim.Advance -> {}
check_advance_result = |label, result| {
	rem = result.clock.remainder
	if !(F32.is_finite(rem)) or rem < 0 or rem >= RocDoomSim.tic_seconds {
		crash "PROPERTY: ${label}: remainder out of range ${Str.inspect(rem)}"
	}
	if result.tics > RocDoomSim.max_catch_up_tics {
		crash "PROPERTY: ${label}: tics ${Str.inspect(result.tics)} exceeds cap"
	}
	# A zero-tic advance returns the input state, which may start out of domain.
	if result.tics > 0 {
		check_state(label, result.clock.state)
	}
}

check_advance_sequence : RocDoomSim.State, RocDoomSim.Command, List(RocDoomSim.Segment), List(U64) -> {}
check_advance_sequence = |state0, command, blockers, elapsed_seq| {
	var $clock = RocDoomSim.clock(state0)
	var $total_tics = 0.U64
	var $total_elapsed = 0.0.F64
	for raw in elapsed_seq {
		elapsed = U64.to_f32(raw) / 35000
		result = RocDoomSim.advance($clock, elapsed, command, blockers)
		check_advance_result("advance_sequence", result)
		if result.dropped {
			crash "PROPERTY: advance_no_drop: elapsed ${Str.inspect(elapsed)} (<= 8 tics) with remainder ${Str.inspect($clock.remainder)} reported dropped tics"
		}
		if result.clock.state.tic != $clock.state.tic + result.tics {
			crash "PROPERTY: advance_tic_counter: state advanced ${Str.inspect(result.clock.state.tic - $clock.state.tic)} but reported ${Str.inspect(result.tics)}"
		}
		$clock = result.clock
		$total_tics = $total_tics + result.tics
		$total_elapsed = $total_elapsed + F32.to_f64(elapsed)
	}
	expected = F64.to_u64_wrap($total_elapsed * 35)
	diff = if expected > $total_tics expected - $total_tics else $total_tics - expected
	if diff > 1 {
		crash "PROPERTY: advance_conservation: total elapsed ${Str.inspect($total_elapsed)} expected ~${Str.inspect(expected)} tics but got ${Str.inspect($total_tics)}"
	}
}

# ---------------------------------------------------------------------------
# P2b: advance with any F32 elapsed (NaN, Inf, negative, huge).

check_wild_elapsed : RocDoomSim.State, RocDoomSim.Command, List(RocDoomSim.Segment), U64 -> {}
check_wild_elapsed = |state0, command, blockers, bits| {
	elapsed = bits_to_f32(bits)
	{
		result = RocDoomSim.advance(RocDoomSim.clock(state0), elapsed, command, blockers)
		check_advance_result("advance_wild(${Str.inspect(elapsed)})", result)
		if result.clock.state.tic != state0.tic + result.tics {
			crash "PROPERTY: advance_wild_tic_counter: elapsed ${Str.inspect(elapsed)}"
		}
		if F32.is_finite(elapsed) and elapsed >= 1 and !(result.dropped and result.tics == RocDoomSim.max_catch_up_tics) {
			crash "PROPERTY: advance_wild_saturation: elapsed ${Str.inspect(elapsed)} tics ${Str.inspect(result.tics)} dropped ${Str.inspect(result.dropped)}"
		}
	}
}

# ---------------------------------------------------------------------------
# P5: one tic delivered in k parts matches one tic delivered at once.

check_partition : RocDoomSim.State, RocDoomSim.Command, List(RocDoomSim.Segment), U64 -> {}
check_partition = |state0, command, blockers, k| {
	whole = RocDoomSim.advance(RocDoomSim.clock(state0), RocDoomSim.tic_seconds, command, blockers)
	if whole.tics != 1 or whole.clock.remainder != 0 {
		crash "PROPERTY: partition_whole: one tic_seconds gave tics ${Str.inspect(whole.tics)} remainder ${Str.inspect(whole.clock.remainder)}"
	}
	part = RocDoomSim.tic_seconds / U64.to_f32(k)
	var $clock = RocDoomSim.clock(state0)
	var $tics = 0.U64
	var $i = 0.U64
	while $i < k {
		result = RocDoomSim.advance($clock, part, command, blockers)
		check_advance_result("partition_step", result)
		$clock = result.clock
		$tics = $tics + result.tics
		$i = $i + 1
	}
	if $tics > 1 {
		crash "PROPERTY: partition_over: ${Str.inspect(k)} parts gave ${Str.inspect($tics)} tics"
	}
	if $tics == 1 {
		a = $clock.state
		b = whole.clock.state
		same = a.pos == b.pos and a.momentum == b.momentum and a.angle.turns() == b.angle.turns() and a.view == b.view and a.tic == b.tic
		if !same {
			crash "PROPERTY: partition_state: ${Str.inspect(k)} parts diverged: ${Str.inspect(a)} vs ${Str.inspect(b)}"
		}
		if $clock.remainder > 0.00001 {
			crash "PROPERTY: partition_remainder: ${Str.inspect(k)} parts left remainder ${Str.inspect($clock.remainder)}"
		}
	} else {
		# F32 accumulation fell short of tic_seconds: the tic is deferred, not lost.
		if F32.abs($clock.remainder - RocDoomSim.tic_seconds) > 0.00001 {
			crash "PROPERTY: partition_deferred: ${Str.inspect(k)} parts, 0 tics, remainder ${Str.inspect($clock.remainder)}"
		}
		if report_partition_drift {
			crash "PARTITION_DRIFT: ${Str.inspect(k)} parts of tic_seconds sum to ${Str.inspect($clock.remainder)} < tic_seconds"
		}
	}
}

target = Fuzz.target({
	name: "doom-sim",
	test,
	show: |input| Str.inspect(input),
})
