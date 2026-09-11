## Project-authored deterministic E1M1 oracle. This records observable Roc game
## state only; no external engine trace, table, or GPL data is embedded here.
import RocDoomLevel
import RocDoomMap
import RocDoomRuntime
import RocDoomSim
import RocDoomWorld

RocDoomTrace := [].{
	Snapshot : {
		tic : U64,
		pos : RocDoomSim.Vec2,
		angle_turns : F32,
		sector : U64,
		moving_height_sum : I64,
		doors : U64,
		floors : U64,
		lifts : U64,
		actors : U64,
		projectiles : U64,
		explosions : U64,
		health : I64,
		bullets : I64,
		rng : U8,
		weapon_cooldown : U64,
		weapon_phase : U64,
		phase : RocDoomRuntime.Phase,
	}
	Run : { world : RocDoomRuntime.World, level : RocDoomLevel.State, trace : List(Snapshot) }

	commands : List(RocDoomSim.Command)
	commands = List.concat(
		List.repeat({ ..RocDoomSim.neutral, forward: 50 }, 8),
		List.concat(
			List.repeat({ ..RocDoomSim.neutral, turn: 0.015625 }, 4),
			List.concat(List.repeat({ ..RocDoomSim.neutral, forward: 50, side: 20 }, 8), List.repeat({ ..RocDoomSim.neutral, fire: Bool.True }, 4)),
		),
	)

	initial : {} -> Run
	initial = |_unit| {
		map = RocDoomMap.e1m1
		start = map.player_start() ?? crash "validated E1M1 player start missing"
		spawned = RocDoomWorld.spawn(map.raw().things, Medium)
		player = RocDoomWorld.player({ x: I64.to_f32(start.position.x), y: I64.to_f32(start.position.y) }, RocDoomSim.Angle.from_turns(I64.to_f32(start.angle) / 360))
		doom : RocDoomWorld.World
		doom = { player, actors: spawned.actors, pickups: spawned.pickups, rng: spawned.rng }
		{ world: RocDoomRuntime.initial_for_skill(doom, Medium), level: RocDoomLevel.initial(map), trace: [] }
	}

	## Run the command script with each tic split into the supplied fractions of
	## one host frame. Fractions must sum to at least one and less than two.
	run : List(F32) -> Run
	run = |partitions| run_commands(initial({}), commands, partitions, 0)

	checksum : List(Snapshot) -> U64
	checksum = |trace| checksum_from(trace, 0, 2166136261)

	golden_checksum = 157266671.U64
}

run_commands = |run, commands, partitions, index|
	match List.get(commands, index) {
		Err(_) => run
		Ok(command) => {
			next = run_parts(run, command, partitions, 0)
			run_commands(next, commands, partitions, index + 1)
		}
	}

run_parts = |run, command, partitions, index|
	match List.get(partitions, index) {
		Err(_) => run
		Ok(fraction) => {
			map = RocDoomMap.e1m1
			before = run.world.doom.player.sim.state.pos
			blockers = RocDoomRuntime.blockers_for_player(map, run.level, before)
			advanced = RocDoomRuntime.advance(run.world, RocDoomSim.tic_seconds * fraction, command, blockers)
			crossed = RocDoomRuntime.cross_specials(map, run.level, before, advanced.world.doom.player.sim.state.pos)
			level = advance_level(crossed.level, advanced.tics)
			trace = if advanced.tics == 0 run.trace else List.append(run.trace, snapshot(advanced.world, level))
			run_parts({ world: advanced.world, level, trace }, command, partitions, index + 1)
		}
	}

advance_level = |level, count| if count == 0 level else advance_level(RocDoomLevel.tick(level), count - 1)

snapshot = |world, level| {
	state = world.doom.player.sim.state
	sector = RocDoomLevel.sector_at(RocDoomMap.e1m1, { x: F32.to_f64(state.pos.x), y: F32.to_f64(state.pos.y) }) ?? crash "trace player left E1M1"
	{
		tic: state.tic,
		pos: state.pos,
		angle_turns: state.angle.turns(),
		sector,
		moving_height_sum: moving_height_sum(level, RocDoomLevel.dynamic_sectors(RocDoomMap.e1m1), 0, 0),
		doors: List.len(level.doors),
		floors: List.len(level.floors),
		lifts: List.len(level.lifts),
		actors: List.len(world.doom.actors),
		projectiles: List.len(world.projectiles),
		explosions: List.len(world.explosions),
		health: world.doom.player.health,
		bullets: world.doom.player.ammo.bullets,
		rng: world.doom.rng.index(),
		weapon_cooldown: world.weapon.cooldown,
		weapon_phase: world.weapon.phase,
		phase: world.phase,
	}
}

moving_height_sum = |level, sectors, index, total|
	match List.get(sectors, index) {
		Err(_) => total
		Ok(sector) => {
			heights = RocDoomLevel.heights_for(level, sector) ?? crash "dynamic sector missing"
			moving_height_sum(level, sectors, index + 1, total + heights.floor + heights.ceiling)
		}
	}

checksum_from = |trace, index, hash|
	match List.get(trace, index) {
		Err(_) => hash
		Ok(value) => checksum_from(trace, index + 1, (hash * 16777619 + snapshot_value(value)) % 4294967291)
	}

snapshot_value = |value| {
	modulus = 4294967291
	x = I64.to_u64_wrap(F32.to_i64_wrap(value.pos.x * 1000)) % modulus
	y = I64.to_u64_wrap(F32.to_i64_wrap(value.pos.y * 1000)) % modulus
	angle = I64.to_u64_wrap(F32.to_i64_wrap(value.angle_turns * 1000000)) % modulus
	heights = I64.to_u64_wrap(value.moving_height_sum) % modulus
	phase = match value.phase {
		Playing => 1
		Dead => 2
		Exited => 3
	}
	(value.tic * 31 + x * 37 + y * 41 + angle * 43 + value.sector * 47 + heights * 53 + value.actors * 59 + value.projectiles * 61 + value.explosions * 67 + I64.to_u64_wrap(value.health) * 71 + I64.to_u64_wrap(value.bullets) * 73 + U8.to_u64(value.rng) * 79 + value.weapon_cooldown * 83 + value.weapon_phase * 89 + phase * 97) % modulus
}

expect {
	a = RocDoomTrace.run([1.0001])
	b = RocDoomTrace.run([1.0001])
	a.trace == b.trace and RocDoomTrace.checksum(a.trace) == RocDoomTrace.checksum(b.trace) and List.len(a.trace) == List.len(RocDoomTrace.commands)
}

expect {
	whole = RocDoomTrace.run([1.0001])
	partitioned = RocDoomTrace.run([0.5, 0.5001])
	whole.trace == partitioned.trace and RocDoomTrace.checksum(whole.trace) == RocDoomTrace.checksum(partitioned.trace)
}

expect {
	first = RocDoomTrace.run([1.0001])
	restarted = RocDoomTrace.run([1.0001])
	initial = RocDoomTrace.initial({})
	first.trace == restarted.trace
		and initial.world.doom.player.sim.state.tic == 0
		and initial.world.doom.rng.index() == 210
				and List.is_empty(initial.level.doors)
					and List.is_empty(initial.level.floors)
						and List.is_empty(initial.level.lifts)
}

expect {
	# Golden checksum for this repository-authored 24-tic command stream.
	golden = RocDoomTrace.checksum(RocDoomTrace.run([1.0001]).trace)
	golden == RocDoomTrace.golden_checksum
}
