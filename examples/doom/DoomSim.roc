## Deterministic Doom-style player simulation. This is a pure 35 Hz tic layer:
## host-cycle time is accumulated explicitly, commands are repeated for whole
## tics, and excess catch-up is reported rather than creating an unbounded loop.
##
## Constants and ordering are informed by Linux Doom 1.10/Chocolate Doom:
## `P_MovePlayer` applies command thrust in facing and facing-minus-90-degree
## directions, `P_XYMovement` caps momentum and applies 0xe800 friction, and
## `P_CalcHeight` derives view bob from squared horizontal momentum. The Roc
## implementation is independently written and uses world-space F32 values.
DoomSim := [].{
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
	neutral = { forward: 0, side: 0, turn: 0, fire: Bool.False }

	## Fold elapsed host-cycle time into at most `max_catch_up_tics` simulation
	## tics. A remainder smaller than one tic is retained. If the cap saturates,
	## whole excess tics are deliberately dropped and reported.
	advance : Clock, F32, Command, List(Segment) -> Advance
	advance = |clock_value, elapsed, command, blockers| {
		var $state = clock_value.state
		var $remainder = clock_value.remainder + clamp(elapsed, 0, max_elapsed)
		var $count = 0.U64
		while $remainder >= tic_seconds and $count < max_catch_up_tics {
			$state = tic($state, command, blockers)
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
	## the first blocking segment and try the tangent displacement instead. This
	## is the composable core of Doom's wall-slide behavior without map policy.
	move_with_slide : Vec2, Vec2, F32, List(Segment) -> Vec2
	move_with_slide = |position, displacement, radius, blockers| {
		candidate = add(position, displacement)
		var $result = candidate
		var $handled = Bool.False
		for blocker in blockers {
			if !($handled) and sweep_hits_segment(position, candidate, radius, blocker) {
				$handled = Bool.True
				tangent = normalize(sub(blocker.end, blocker.start))
				slide = scale(tangent, dot(displacement, tangent))
				slide_candidate = add(position, slide)
				$result = if any_penetration(slide_candidate, radius, blockers) position else slide_candidate
			}
		}
		$result
	}

	any_collision : Vec2, F32, List(Segment) -> Bool
	any_collision = |center, radius, blockers| List.any(blockers, |blocker| circle_hits_segment(center, radius, blocker))
	any_penetration : Vec2, F32, List(Segment) -> Bool
	any_penetration = |center, radius, blockers| List.any(blockers, |blocker| distance_to_segment_squared(center, blocker) < radius * radius - 0.000001)

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
		along = sub(segment.end, segment.start)
		segment_len_squared = length_squared(along)
		closest = if segment_len_squared <= 0 {
			segment.start
		} else {
			amount = clamp(dot(sub(center, segment.start), along) / segment_len_squared, 0, 1)
			add(segment.start, scale(along, amount))
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
	sqrt : F32 -> F32
	sqrt = |value| {
		if value <= 0 {
			0
		} else {
			var $guess = if value >= 1 value else 1
			for _ in List.repeat({}, 14) {
				$guess = ($guess + value / $guess) * 0.5
			}
			$guess
		}
	}

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

wrap_turn : F32 -> F32
wrap_turn = |value| if value >= 1 wrap_turn(value - 1) else if value < 0 wrap_turn(value + 1) else value

approx : F32, F32 -> Bool
approx = |a, b| F32.abs(a - b) < 0.0001

expect {
	# Exact three-tic trace for half-run forward input, including post-move friction.
	command = { ..DoomSim.neutral, forward: 25 }
	a = DoomSim.tic(DoomSim.initial(DoomSim.zero, DoomSim.Angle.from_turns(0)), command, [])
	b = DoomSim.tic(a, command, [])
	c = DoomSim.tic(b, command, [])
	approx(a.pos.x, 0.78125)
		and approx(a.momentum.x, 0.7080078)
			and approx(b.pos.x, 2.2705078)
				and approx(c.pos.x, 4.4013977)
					and c.tic == 3
}

expect {
	# The accumulator retains fractions, catches up a bounded number of tics,
	# and reports intentional overload shedding.
	clock = DoomSim.clock(DoomSim.initial(DoomSim.zero, DoomSim.Angle.from_turns(0)))
	partial = DoomSim.advance(clock, DoomSim.tic_seconds * 0.5, DoomSim.neutral, [])
	caught = DoomSim.advance(partial.clock, DoomSim.tic_seconds * 20, DoomSim.neutral, [])
	partial.tics == 0 and partial.clock.remainder > 0 and caught.tics == DoomSim.max_catch_up_tics and caught.dropped
}

expect {
	# Forward plus side command preserves Doom's faster diagonal command vector.
	command = { ..DoomSim.neutral, forward: 25, side: 24 }
	next = DoomSim.tic(DoomSim.initial(DoomSim.zero, DoomSim.Angle.from_turns(0)), command, [])
	approx(next.pos.x, 0.78125) and approx(next.pos.y, -0.75) and DoomSim.length(next.pos) > 1
}

expect {
	# With no further command, friction deterministically reaches the stop snap.
	started = DoomSim.tic(DoomSim.initial(DoomSim.zero, DoomSim.Angle.from_turns(0)), { ..DoomSim.neutral, forward: 2 }, [])
	var $stopped = started
	for _ in List.repeat({}, 20) {
		$stopped = DoomSim.tic($stopped, DoomSim.neutral, [])
	}
	$stopped.momentum == DoomSim.zero and $stopped.pos.x > started.pos.x
}

expect {
	# A diagonal move into a vertical blocker loses its normal component and
	# keeps its tangential travel.
	wall : DoomSim.Segment
	wall = { start: { x: 2, y: -10 }, end: { x: 2, y: 10 } }
	result = DoomSim.move_with_slide({ x: 1.5, y: 0 }, { x: 1, y: 1 }, 0.5, [wall])
	approx(result.x, 1.5) and approx(result.y, 1)
}
