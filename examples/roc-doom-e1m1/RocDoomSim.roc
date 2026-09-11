## Deterministic Doom-style player simulation. This is a pure 35 Hz tic layer:
## host-cycle time is accumulated explicitly, commands are repeated for whole
## tics, and excess catch-up is reported rather than creating an unbounded loop.
##
## Constants and ordering are informed by the reference Doom implementation:
## `P_MovePlayer` applies command thrust in facing and facing-minus-90-degree
## directions, `P_XYMovement` caps momentum and applies 0xe800 friction, and
## `P_CalcHeight` derives view bob from squared horizontal momentum. The Roc
## implementation is independently written and uses world-space F32 values.
RocDoomSim := [].{
	Vec2 : { x : F32, y : F32 }
	Angle :: { turns : F32 }.{
		from_turns : F32 -> Angle
		from_turns = |turns| Angle.({ turns: wrap_turn(turns) })

		turns : Angle -> F32
		turns = |Angle.(value)| value.turns

		add : Angle, F32 -> Angle
		add = |Angle.(value), delta| Angle.from_turns(value.turns + delta)

		forward : Angle -> Vec2
		forward = |Angle.(value)| {
			radians = value.turns * tau
			{ x: F32.cos(radians), y: F32.sin(radians) }
		}
	}

	Command : {

		## Doom tic-command magnitudes; normal run values are forward 50, side 40.
		forward : I16,
		side : I16,

		## Fraction of one complete turn applied this tic.
		turn : F32,
		fire : Bool,
		weapon_slot : [KeepWeapon, SelectSlot(U8)],
	}

	Segment : { start : Vec2, end : Vec2 }

	View : {
		bob : F32,
		offset : F32,
		weapon_x : F32,
		weapon_y : F32,
		weapon_phase : F32,
		weapon_kick : F32,
	}

	State : {
		pos : Vec2,
		momentum : Vec2,
		angle : Angle,
		tic : U64,
		view : View,
	}

	Clock : { state : State, remainder : F32 }
	Advance : { clock : Clock, tics : U64, dropped : Bool }

	initial : Vec2, Angle -> State
	initial = |pos, angle| {
		pos,
		momentum: zero,
		angle,
		tic: 0,
		view: { bob: 0, offset: 0, weapon_x: 0, weapon_y: 0, weapon_phase: 0, weapon_kick: 0 },
	}

	clock : State -> Clock
	clock = |state| { state, remainder: 0 }

	neutral : Command
	neutral = { forward: 0, side: 0, turn: 0, fire: Bool.False, weapon_slot: KeepWeapon }

	## Fold elapsed host-cycle time into at most `max_catch_up_tics` simulation
	## tics. A remainder smaller than one tic is retained. If the cap saturates,
	## whole excess tics are deliberately dropped and reported.
	advance : Clock, F32, Command, List(Segment) -> Advance
	advance = |clock_value, elapsed, command, blockers| advance_with(clock_value, elapsed, command, |_state| blockers)

	## Fold elapsed time like `advance`, resolving collision from the state at
	## the start of each simulation tic. Map-backed callers use this so crossing
	## a sector boundary during catch-up cannot retain the previous sector's
	## portal set for the remaining tics.
	advance_with : Clock, F32, Command, (State -> List(Segment)) -> Advance
	advance_with = |clock_value, elapsed, command, blockers_for| advance_first_with(clock_value, elapsed, command, command, blockers_for)

	## Fold elapsed time like `advance_with`, but deliver `first` to the opening
	## tic of this call and `repeat` to every catch-up tic after it. A host that
	## samples input once per frame owns exactly one delta and one edge per
	## cycle, so the frame's accumulated turn and latched presses belong to a
	## single tic; repeating them would scale input by the catch-up count.
	## `advance_with` passes the same command twice and is unchanged by this.
	advance_first_with : Clock, F32, Command, Command, (State -> List(Segment)) -> Advance
	advance_first_with = |clock_value, elapsed, first, repeat, blockers_for| {
		var $state = clock_value.state
		var $remainder = clock_value.remainder + clamp(elapsed, 0, max_elapsed)
		var $count = 0.U64
		while $remainder >= tic_seconds and $count < max_catch_up_tics {
			command = if $count == 0 first else repeat
			$state = tic($state, command, blockers_for($state))
			$remainder = $remainder - tic_seconds
			$count = $count + 1
		}
		dropped = $remainder >= tic_seconds
		if dropped {
			$remainder = 0
		}
		{ clock: { state: $state, remainder: $remainder }, tics: $count, dropped }
	}

	## One authoritative simulation tic. Thrust is accumulated, each momentum
	## component is capped, collision slides the radius along a blocker, then
	## ground friction and presentation bob are derived deterministically.
	tic : State, Command, List(Segment) -> State
	tic = |state, command, blockers| {
		angle = state.angle.add(command.turn)
		facing = angle.forward()
		right = { x: facing.y, y: 0 - facing.x }
		thrust = add(scale(facing, I16.to_f32(command.forward) * thrust_per_command), scale(right, I16.to_f32(command.side) * thrust_per_command))
		momentum0 = clamp_momentum(add(state.momentum, thrust))
		pos = move_with_slide(state.pos, momentum0, player_radius, blockers)
		phase = wrap_turn(state.view.weapon_phase + weapon_phase_per_tic)
		bob = F32.min(max_bob, length_squared(momentum0) * bob_scale)
		wave = F32.sin(phase * tau)
		view = {
			bob,
			offset: bob * 0.5 * wave,
			weapon_x: bob * 0.35 * F32.cos(phase * tau),
			weapon_y: F32.abs(bob * 0.25 * wave),
			weapon_phase: phase,
			weapon_kick: if command.fire weapon_kick else state.view.weapon_kick * friction,
		}
		{ pos, momentum: apply_friction(momentum0), angle, tic: state.tic + 1, view }
	}

	clamp_momentum : Vec2 -> Vec2
	clamp_momentum = |momentum| {
		x: clamp(momentum.x, 0 - max_move, max_move),
		y: clamp(momentum.y, 0 - max_move, max_move),
	}

	apply_friction : Vec2 -> Vec2
	apply_friction = |momentum| {
		if F32.abs(momentum.x) < stop_speed and F32.abs(momentum.y) < stop_speed {
			zero
		} else {
			scale(momentum, friction)
		}
	}

	## Try the whole displacement. On contact, remove the component normal to
	## the earliest blocking segment and try the tangent displacement instead.
	## The slide is swept too, so it cannot clip or cross a second blocker; if
	## it would, the player stays put, as in Doom's `P_SlideMove`. This is the
	## composable core of wall sliding without map policy.
	move_with_slide : Vec2, Vec2, F32, List(Segment) -> Vec2
	move_with_slide = |position, displacement, radius, blockers| {
		candidate = add(position, displacement)
		var $hit = Err(NoHit)
		var $hit_sample = collision_samples + 1
		for blocker in blockers {
			match first_hit_sample(position, candidate, radius, blocker) {
				Ok(sample) if sample < $hit_sample => {
					$hit_sample = sample
					$hit = Ok(blocker)
				}
				_ => {}
			}
		}
		match $hit {
			Err(NoHit) => candidate
			Ok(blocker) => {
				slide = along(displacement, blocker)
				slide_candidate = add(position, slide)
				# A portal can leave the player radius overlapping an adjacent closed
				# boundary (notably E1M1's narrow sector 142). Permit motion that does
				# not deepen an existing overlap anywhere along the slide, so the
				# player can slide out rather than becoming permanently pinned.
				others = List.keep_if(blockers, |other| other != blocker)
				match first_deepening_blocker(position, slide_candidate, radius, blockers) {
					Err(NoHit) => slide_candidate
					Ok(_) => match first_deepening_blocker(position, slide_candidate, radius, others) {
						Err(NoHit) => position
						Ok(second) => {
							# Like `P_SlideMove`'s retry: when the first wall's slide is
							# blocked (typically at a corner it shares with another wall),
							# slide the original move along that other wall instead, so
							# a corner is rounded rather than sticky.
							corner_candidate = add(position, along(displacement, second))
							if path_deepens_penetration(position, corner_candidate, radius, blockers) position else corner_candidate
						}
					}
				}
			}
		}
	}

	## The component of a displacement along a segment's direction.
	along : Vec2, Segment -> Vec2
	along = |displacement, segment| {
		tangent = normalize(sub(segment.end, segment.start))
		scale(tangent, dot(displacement, tangent))
	}

	## The blocker whose overlap the path deepens earliest, if any.
	first_deepening_blocker : Vec2, Vec2, F32, List(Segment) -> Try(Segment, [NoHit])
	first_deepening_blocker = |from, to, radius, blockers| {
		var $found = Err(NoHit)
		var $found_sample = collision_samples + 1
		for blocker in blockers {
			before = distance_to_segment_squared(from, blocker)
			for index in List.map_with_index(List.repeat({}, collision_samples), |_unit, index| index) {
				amount = U64.to_f32(index + 1) / U64.to_f32(collision_samples)
				after = distance_to_segment_squared(add(from, scale(sub(to, from), amount)), blocker)
				if index < $found_sample and after < radius * radius - 0.000001 and after < before - 0.000001 {
					$found_sample = index
					$found = Ok(blocker)
				}
			}
		}
		$found
	}

	any_collision : Vec2, F32, List(Segment) -> Bool
	any_collision = |center, radius, blockers| List.any(blockers, |blocker| circle_hits_segment(center, radius, blocker))
	any_penetration : Vec2, F32, List(Segment) -> Bool
	any_penetration = |center, radius, blockers| List.any(blockers, |blocker| distance_to_segment_squared(center, blocker) < radius * radius - 0.000001)

	any_deeper_penetration : Vec2, Vec2, F32, List(Segment) -> Bool
	any_deeper_penetration = |from, to, radius, blockers|
		List.any(
			blockers,
			|blocker| {
				before = distance_to_segment_squared(from, blocker)
				after = distance_to_segment_squared(to, blocker)
				after < radius * radius - 0.000001 and after < before - 0.000001
			},
		)

	## Whether any sampled point of the path overlaps a blocker more deeply
	## than the start did. Sampling the whole path, not just its end, is what
	## stops a slide from passing through a segment and coming out clear.
	path_deepens_penetration : Vec2, Vec2, F32, List(Segment) -> Bool
	path_deepens_penetration = |from, to, radius, blockers| {
		var $deepens = Bool.False
		for blocker in blockers {
			before = distance_to_segment_squared(from, blocker)
			for index in List.map_with_index(List.repeat({}, collision_samples), |_unit, index| index) {
				amount = U64.to_f32(index + 1) / U64.to_f32(collision_samples)
				after = distance_to_segment_squared(add(from, scale(sub(to, from), amount)), blocker)
				if after < radius * radius - 0.000001 and after < before - 0.000001 {
					$deepens = Bool.True
				}
			}
		}
		$deepens
	}

	## The first sample index along the sweep at which the circle touches the
	## segment, so the nearest of several blockers can be chosen.
	first_hit_sample : Vec2, Vec2, F32, Segment -> Try(U64, [NoHit])
	first_hit_sample = |from, to, radius, segment| {
		var $hit = Err(NoHit)
		for index in List.map_with_index(List.repeat({}, collision_samples), |_unit, index| index) {
			amount = U64.to_f32(index + 1) / U64.to_f32(collision_samples)
			if $hit == Err(NoHit) and circle_hits_segment(add(from, scale(sub(to, from), amount)), radius, segment) {
				$hit = Ok(index)
			}
		}
		$hit
	}

	circle_hits_segment : Vec2, F32, Segment -> Bool
	circle_hits_segment = |center, radius, segment| {
		distance_to_segment_squared(center, segment) <= radius * radius
	}

	## A fixed sample count prevents fast capped momentum tunnelling through a
	## segment while keeping collision cost explicit and deterministic.
	sweep_hits_segment : Vec2, Vec2, F32, Segment -> Bool
	sweep_hits_segment = |from, to, radius, segment| {
		var $hit = Bool.False
		for index in List.map_with_index(List.repeat({}, collision_samples), |_unit, index| index) {
			amount = U64.to_f32(index + 1) / U64.to_f32(collision_samples)
			if circle_hits_segment(add(from, scale(sub(to, from), amount)), radius, segment) {
				$hit = Bool.True
			}
		}
		$hit
	}

	distance_to_segment_squared : Vec2, Segment -> F32
	distance_to_segment_squared = |center, segment| {
		direction = sub(segment.end, segment.start)
		segment_len_squared = length_squared(direction)
		closest = if segment_len_squared <= 0 {
			segment.start
		} else {
			amount = clamp(dot(sub(center, segment.start), direction) / segment_len_squared, 0, 1)
			add(segment.start, scale(direction, amount))
		}
		distance_squared(center, closest)
	}

	zero : Vec2
	zero = { x: 0, y: 0 }
	add : Vec2, Vec2 -> Vec2
	add = |a, b| { x: a.x + b.x, y: a.y + b.y }
	sub : Vec2, Vec2 -> Vec2
	sub = |a, b| { x: a.x - b.x, y: a.y - b.y }
	scale : Vec2, F32 -> Vec2
	scale = |a, amount| { x: a.x * amount, y: a.y * amount }
	dot : Vec2, Vec2 -> F32
	dot = |a, b| a.x * b.x + a.y * b.y
	length_squared : Vec2 -> F32
	length_squared = |a| dot(a, a)
	length : Vec2 -> F32
	length = |a| sqrt(length_squared(a))
	distance_squared : Vec2, Vec2 -> F32
	distance_squared = |a, b| length_squared(sub(a, b))
	normalize : Vec2 -> Vec2
	normalize = |a| {
		magnitude = length(a)
		if magnitude <= 0 zero else scale(a, 1 / magnitude)
	}
	clamp : F32, F32, F32 -> F32
	clamp = |value, low, high| F32.max(low, F32.min(value, high))

	## Non-positive input is a length of zero; `F32.sqrt` would give NaN.
	sqrt : F32 -> F32
	sqrt = |value| if value <= 0 0 else F32.sqrt(value)

	tic_rate = 35.U64
	tic_seconds = 1 / 35
	max_catch_up_tics = 8.U64
	max_elapsed = 1

	## `cmd * 2048` in 16.16 fixed-point world units.
	thrust_per_command = 0.03125

	## Doom's `MAXMOVE` is 30 map units per tic.
	max_move = 30

	## 0xe800 in 16.16 fixed-point.
	friction = 0.90625
	stop_speed = 0.0625

	## Doom player mobj radius in map units.
	player_radius = 16
	max_bob = 16
	bob_scale = 0.25
	weapon_phase_per_tic = 0.05
	weapon_kick = 1
	collision_samples = 64.U64
	tau = 6.2831855
}

## Reduce turns into [0, 1) without iterating: any F32 of magnitude 2^24 or
## more is a whole number of turns, and a non-finite turn is treated as none.
wrap_turn : F32 -> F32
wrap_turn = |value|
	if !(F32.is_finite(value)) or F32.abs(value) >= 16777216 {
		0
	} else {
		fraction = value - I64.to_f32(F32.to_i64_wrap(value))
		wrapped = if fraction < 0 fraction + 1 else fraction
		if wrapped >= 1 0 else wrapped
	}

approx : F32, F32 -> Bool
approx = |a, b| F32.abs(a - b) < 0.0001

expect {
	# Exact three-tic trace for half-run forward input, including post-move friction.
	command = { ..RocDoomSim.neutral, forward: 25 }
	a = RocDoomSim.tic(RocDoomSim.initial(RocDoomSim.zero, RocDoomSim.Angle.from_turns(0)), command, [])
	b = RocDoomSim.tic(a, command, [])
	c = RocDoomSim.tic(b, command, [])
	approx(a.pos.x, 0.78125)
		and approx(a.momentum.x, 0.7080078)
			and approx(b.pos.x, 2.2705078)
				and approx(c.pos.x, 4.4013977)
					and c.tic == 3
}

expect {
	# The accumulator retains fractions, catches up a bounded number of tics,
	# and reports intentional overload shedding.
	clock = RocDoomSim.clock(RocDoomSim.initial(RocDoomSim.zero, RocDoomSim.Angle.from_turns(0)))
	partial = RocDoomSim.advance(clock, RocDoomSim.tic_seconds * 0.5, RocDoomSim.neutral, [])
	caught = RocDoomSim.advance(partial.clock, RocDoomSim.tic_seconds * 20, RocDoomSim.neutral, [])
	partial.tics == 0 and partial.clock.remainder > 0 and caught.tics == RocDoomSim.max_catch_up_tics and caught.dropped
}

expect {
	# Passing the same command twice is exactly the old single-command fold, so
	# the per-tic contract the partition oracles pin is unchanged.
	clock = RocDoomSim.clock(RocDoomSim.initial(RocDoomSim.zero, RocDoomSim.Angle.from_turns(0)))
	command = { ..RocDoomSim.neutral, forward: 50, turn: 0.01 }
	shared = RocDoomSim.advance_with(clock, RocDoomSim.tic_seconds * 3, command, |_state| [])
	split = RocDoomSim.advance_first_with(clock, RocDoomSim.tic_seconds * 3, command, command, |_state| [])
	shared.tics == split.tics
		and shared.clock.state.pos == split.clock.state.pos
			and shared.clock.state.angle.turns() == split.clock.state.angle.turns()
}

expect {
	# One frame's accumulated turn lands exactly once however many tics the
	# frame spends. This is the regression test for the view snapping when a
	# slow frame replayed the same mouse delta on every catch-up tic.
	clock = RocDoomSim.clock(RocDoomSim.initial(RocDoomSim.zero, RocDoomSim.Angle.from_turns(0)))
	flick = { ..RocDoomSim.neutral, turn: 0.125 }
	one = RocDoomSim.advance_first_with(clock, RocDoomSim.tic_seconds, flick, RocDoomSim.neutral, |_state| [])
	many = RocDoomSim.advance_first_with(clock, RocDoomSim.tic_seconds * 5, flick, RocDoomSim.neutral, |_state| [])
	one.tics == 1
		and many.tics == 5
			and approx(one.clock.state.angle.turns(), 0.125)
				and approx(many.clock.state.angle.turns(), 0.125)
}

expect {
	# Saturated catch-up consumes the opening command exactly once, so a stalled
	# frame neither loses nor multiplies the latched input it drained.
	clock = RocDoomSim.clock(RocDoomSim.initial(RocDoomSim.zero, RocDoomSim.Angle.from_turns(0)))
	flick = { ..RocDoomSim.neutral, turn: 0.125 }
	saturated = RocDoomSim.advance_first_with(clock, RocDoomSim.tic_seconds * 40, flick, RocDoomSim.neutral, |_state| [])
	saturated.dropped
		and saturated.tics == RocDoomSim.max_catch_up_tics
			and approx(saturated.clock.state.angle.turns(), 0.125)
}

expect {
	# Forward plus side command preserves Doom's faster diagonal command vector.
	command = { ..RocDoomSim.neutral, forward: 25, side: 24 }
	next = RocDoomSim.tic(RocDoomSim.initial(RocDoomSim.zero, RocDoomSim.Angle.from_turns(0)), command, [])
	approx(next.pos.x, 0.78125) and approx(next.pos.y, -0.75) and RocDoomSim.length(next.pos) > 1
}

expect {
	# With no further command, friction deterministically reaches the stop snap.
	started = RocDoomSim.tic(RocDoomSim.initial(RocDoomSim.zero, RocDoomSim.Angle.from_turns(0)), { ..RocDoomSim.neutral, forward: 2 }, [])
	var $stopped = started
	for _ in List.repeat({}, 20) {
		$stopped = RocDoomSim.tic($stopped, RocDoomSim.neutral, [])
	}
	$stopped.momentum == RocDoomSim.zero and $stopped.pos.x > started.pos.x
}

expect {
	# A diagonal move into a vertical blocker loses its normal component and
	# keeps its tangential travel.
	wall : RocDoomSim.Segment
	wall = { start: { x: 2, y: -10 }, end: { x: 2, y: 10 } }
	result = RocDoomSim.move_with_slide({ x: 1.5, y: 0 }, { x: 1, y: 1 }, 0.5, [wall])
	approx(result.x, 1.5) and approx(result.y, 1)
}

expect {
	# S1: turn normalisation is total. A non-finite turn never becomes a
	# non-finite angle.
	nan = RocDoomSim.Angle.from_turns(F32.from_bits(2143289344))
	positive_inf = RocDoomSim.Angle.from_turns(F32.from_bits(2139095040))
	negative_inf = RocDoomSim.Angle.from_turns(F32.from_bits(4286578688))
	huge = RocDoomSim.Angle.from_turns(-4.03e16)
	large = RocDoomSim.Angle.from_turns(1234567.75)
	tiny_negative = RocDoomSim.Angle.from_turns(-0.00000001)
	in_range = |angle| F32.is_finite(angle.turns()) and angle.turns() >= 0 and angle.turns() < 1
	in_range(nan)
		and in_range(positive_inf)
			and in_range(negative_inf)
				and in_range(huge)
					and in_range(large)
						and approx(large.turns(), 0.75)
							and in_range(tiny_negative)
								and approx(RocDoomSim.Angle.from_turns(-0.25).turns(), 0.75)
									and approx(RocDoomSim.Angle.from_turns(2.5).turns(), 0.5)
}

expect {
	# S2: square roots stay accurate at map scale and below; E1M1's bounding
	# diagonal is about 5213 units (length squared 2.7e7) and normalize sees it.
	relative = |value, expected| F32.abs(value - expected) <= expected * 0.0001
	relative(RocDoomSim.sqrt(27000000), 5196.1524)
		and relative(RocDoomSim.sqrt(100000000), 10000)
			and relative(RocDoomSim.sqrt(1000000000), 31622.777)
				and relative(RocDoomSim.sqrt(0.0000001), 0.00031622776)
					and RocDoomSim.sqrt(0) == 0
						and RocDoomSim.sqrt(-4) == 0
							and relative(RocDoomSim.length({ x: 3000, y: 4000 }), 5000)
}

expect {
	# S3/S4: a tic that starts clear of every blocker never sweeps the player
	# circle through one. The first case slides into a second wall at near-cap
	# momentum, the second clips a corner mid-path.
	line_side = |a, b, p| (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
	path_clear = |from, to, blockers| {
		var $clear = Bool.True
		for step in List.map_with_index(List.repeat({}, 64), |_unit, index| index) {
			amount = U64.to_f32(step + 1) / 64
			point = RocDoomSim.add(from, RocDoomSim.scale(RocDoomSim.sub(to, from), amount))
			for blocker in blockers {
				if RocDoomSim.distance_to_segment_squared(point, blocker) < RocDoomSim.player_radius * RocDoomSim.player_radius - 0.001 {
					$clear = Bool.False
				}
			}
		}
		$clear
	}
	crossing_blockers = [
		{ start: { x: -177, y: -200 }, end: { x: -104, y: 142 } },
		{ start: { x: -197, y: 171 }, end: { x: 118, y: -36 } },
		{ start: { x: -111, y: 167 }, end: { x: 122, y: -161 } },
	]
	crossing_start = { ..RocDoomSim.initial({ x: -146, y: 118 }, RocDoomSim.Angle.from_turns(0)), momentum: { x: 36.6, y: 36.6 } }
	crossing = RocDoomSim.tic(crossing_start, { ..RocDoomSim.neutral, turn: -0.617, forward: -67, side: -100 }, crossing_blockers)
	second = List.get(crossing_blockers, 1) ?? crash "blocker missing"
	same_side = line_side(second.start, second.end, crossing_start.pos) * line_side(second.start, second.end, crossing.pos) > 0
	corner_blockers = [
		{ start: { x: 39, y: -28 }, end: { x: -28, y: -28 } },
		{ start: { x: -180, y: -198 }, end: { x: 95, y: 95 } },
		{ start: { x: 95, y: 100 }, end: { x: -62, y: -200 } },
	]
	corner_start = { ..RocDoomSim.initial({ x: 73, y: 95 }, RocDoomSim.Angle.from_turns(0.934)), momentum: { x: 31.5, y: 31.5 } }
	corner = RocDoomSim.tic(corner_start, { ..RocDoomSim.neutral, turn: 0.927, forward: -38, side: -38 }, corner_blockers)
	same_side
		and path_clear(crossing_start.pos, crossing.pos, crossing_blockers)
			and path_clear(corner_start.pos, corner.pos, corner_blockers)
}

expect {
	# Catch-up collision is a per-tic query. A boundary which becomes relevant
	# after the first tic must constrain the remaining tics in the same host
	# cycle, while the ordinary fixed-blocker entry point stays equivalent.
	clock = RocDoomSim.clock(RocDoomSim.initial({ x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0)))
	command = { ..RocDoomSim.neutral, forward: 50 }
	wall = { start: { x: 30, y: -100 }, end: { x: 30, y: 100 } }
	elapsed = 8 * RocDoomSim.tic_seconds
	dynamic = RocDoomSim.advance_with(clock, elapsed, command, |state| if state.pos.x >= 2 [wall] else [])
	fixed = RocDoomSim.advance(clock, elapsed, command, [wall])
	fixed_via_query = RocDoomSim.advance_with(clock, elapsed, command, |_state| [wall])
	dynamic.clock.state.pos.x < 14 and fixed == fixed_via_query
}

expect {
	# A corner shared by a vertical and a horizontal wall (E1M1 at (192, 1344))
	# must not pin a player approaching it diagonally: the move slides along
	# whichever wall admits it, regardless of which wall is listed first.
	vertical = { start: { x: 192, y: 1344 }, end: { x: 192, y: 1472 } }
	horizontal = { start: { x: 144, y: 1344 }, end: { x: 192, y: 1344 } }
	pos = { x: 195.7, y: 1322.4 }
	first = RocDoomSim.move_with_slide(pos, { x: 2, y: 10 }, 16, [vertical, horizontal])
	second = RocDoomSim.move_with_slide(pos, { x: 2, y: 10 }, 16, [horizontal, vertical])
	clear = |point| RocDoomSim.distance_to_segment_squared(point, vertical) >= 256 and RocDoomSim.distance_to_segment_squared(point, horizontal) >= 256
	first.x > pos.x and second.x > pos.x and clear(first) and clear(second)
}
