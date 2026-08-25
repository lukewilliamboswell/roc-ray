## Frozen, project-authored Baby E1M1 completion replay. The compact RLE is
## ordinary DoomSim input; playback uses the same pure runtime, collision,
## specials, thing population, and level motion as the interactive example.
import DoomLevel
import DoomMap
import DoomRuntime
import DoomSim
import DoomWorld

DoomReplay := [].{
	CommandRun : { count : U64, command : DoomSim.Command }
	Result : { world : DoomRuntime.World, level : DoomLevel.State, tics : U64, sector : U64, checkpoints : List(U64), checksum : U64, used_line : Try(U64, [NoUsableLine]) }

	fixture : Str
	fixture = "18:50,0,0,1,2;3:50,-40,0,1,2;2:0,-40,0,1,2;5:50,0,0,1,2;10:50,40,0,1,2;1:50,0,0,1,2;1:50,-40,0,1,2;3:50,0,0,1,2;1:50,-40,0.015625,1,2;1:50,-40,0,1,2;3:50,20,0.015625,0,-;3:50,-40,-0.015625,1,2;3:50,-40,0,1,2;1:50,0,0,1,2;10:50,40,0,1,2;1:50,0,0,1,2;5:50,-40,0,1,2;1:50,20,0.015625,0,-;3:50,20,-0.015625,0,-;2:50,20,0,0,-;3:50,20,0.015625,0,-;2:50,-20,0.015625,0,-;2:50,-20,0,0,-;12:50,-20,-0.015625,0,-;3:50,20,-0.015625,0,-;2:50,20,0,0,-;4:50,20,0.015625,0,-;6:0,20,0.015625,0,-;1:50,20,0.015625,0,-;2:50,-20,0.015625,0,-;14:50,-20,0,0,-;12:50,20,0,0,-;1:50,20,0.015625,0,-;1:50,20,0,0,-;2:50,20,0.015625,0,-;3:50,-20,0.015625,0,-;2:50,-40,0.015625,1,2;1:50,-40,0,1,2;1:50,-40,0.015625,1,2;3:50,-40,0,1,2;1:0,-40,0,1,2;3:50,0,0,1,2;5:50,40,0,1,2;2:50,0,0,1,2;1:50,0,0.015625,0,2;10:50,20,0.015625,0,-;5:50,-20,0.015625,0,-;3:50,-20,0,0,-;4:50,-20,-0.015625,0,-;4:0,-20,-0.015625,0,-;4:0,20,-0.015625,0,-;10:50,20,-0.015625,0,-;2:50,20,0.015625,0,-;11:0,-20,0.015625,0,-;5:50,-20,0.015625,0,-;2:50,20,0.015625,0,-;1:50,20,0,0,-;2:50,20,-0.015625,0,-;8:0,20,-0.015625,0,-;3:50,20,-0.015625,0,-;3:50,-20,-0.015625,0,-;1:50,-20,0,0,-;12:50,-20,0.015625,0,-;1:50,40,0,1,2;1:50,40,0.015625,1,2;1:50,40,0,1,2;1:50,40,0.015625,1,2;3:50,40,0.015625,1,3;8:50,40,0.015625,0,3;1:0,40,0.015625,0,3;3:50,40,0,0,3;1:50,40,0,0,2;1:0,40,0.015625,0,2;2:50,40,0.015625,0,2;3:0,40,0.015625,0,2;6:-50,40,0.015625,0,2;1:0,20,-0.015625,0,-;3:50,20,-0.015625,0,-;1:50,20,0.015625,0,-;3:50,20,0,0,-;1:50,20,0.015625,0,-;3:50,20,0,0,-;1:50,20,-0.015625,0,-;1:50,20,0,0,-;2:50,20,-0.015625,0,-;3:50,-20,-0.015625,0,-;3:50,40,0,0,-;6:-50,-40,0,0,-;4:-50,-40,0,0,2;6:50,40,0,0,2;5:-50,-40,0,0,2;4:50,40,0,0,2;3:-50,-40,0,0,2;2:50,40,0,0,2;2:-50,-40,0,0,2;9:-50,40,0.015625,0,2;1:-50,40,0.015625,1,2;2:0,40,0.015625,1,2;1:50,40,0,1,2;1:50,40,0.015625,1,2;3:50,40,0,1,2;3:50,20,-0.015625,0,-;6:0,20,-0.015625,0,-;2:0,40,0.015625,0,2;11:-50,40,0.015625,0,2;3:-50,0,0.015625,0,2;7:-50,-40,0.015625,0,2;2:0,20,0.015625,0,-;2:50,-40,0.015625,0,2;3:50,-40,0.015625,1,2;1:50,-40,0,1,2;2:50,-40,-0.015625,1,2;1:50,-40,0,1,2;1:50,-40,-0.015625,1,2;7:50,-40,0,1,2;6:50,-40,-0.015625,0,2;3:0,-40,-0.015625,0,2;1:-50,-40,-0.015625,0,2;3:0,20,0.015625,0,-;2:0,20,-0.015625,0,-;1:50,40,0.015625,0,2;5:0,40,0.015625,0,2;4:-50,40,0.015625,0,2;11:0,-20,-0.015625,0,-;2:50,-20,-0.015625,0,-;10:50,20,-0.015625,0,-;3:50,20,0,0,-;3:50,0,0.015625,0,2;1:50,40,0.015625,0,2;1:50,40,0.015625,1,2;2:50,-20,-0.015625,0,-;2:0,40,0.015625,0,2;10:0,-20,-0.015625,0,-;7:0,20,-0.015625,0,-;9:50,20,-0.015625,0,-;13:50,-20,-0.015625,0,-;3:50,-20,0,0,-;1:50,20,0,0,-;1:50,20,-0.015625,0,-;6:50,20,0,0,-;2:50,0,-0.015625,0,2;10:50,-40,-0.015625,0,2;3:0,-40,-0.015625,0,2;1:-50,-40,-0.015625,0,2;4:0,-20,0.015625,0,-;1:0,-20,-0.015625,0,-;1:0,40,0.015625,0,2;5:0,-40,0.015625,0,2;2:-50,-40,0.015625,0,2;8:50,-40,0.015625,0,2;2:0,-40,0.015625,0,2;8:-50,-40,0.015625,0,2;2:0,-40,0.015625,0,2;3:50,-40,0.015625,0,2;1:50,0,0.015625,0,2;2:-50,0,0.015625,1,2;6:-50,0,0,1,2;7:-50,40,0,1,2;1:-50,0,0.015625,1,2;1:50,40,0.015625,1,2;4:50,40,0,1,2;7:50,-40,0,1,2;6:50,40,0,1,2;1:50,40,0.015625,1,2;1:50,40,0,1,2;4:50,20,-0.015625,0,-;8:50,20,0,0,-;3:0,20,0.015625,0,-;5:0,-20,0.015625,0,-;6:50,-20,0.015625,0,-;3:0,-20,-0.015625,0,-;2:50,-20,-0.015625,0,-;3:50,20,-0.015625,0,-;2:50,20,0.015625,0,-;2:50,20,0,0,-;1:50,20,0.015625,0,-;3:50,20,0,0,-;1:50,20,0.015625,0,-;4:0,20,0.015625,0,-;4:0,-20,0.015625,0,-;12:50,-20,0.015625,0,-;1:50,20,0.015625,0,-;4:50,20,0,0,-;1:50,20,0.015625,0,-;1:0,20,-0.015625,0,-;2:50,20,0.015625,0,-;7:0,20,-0.015625,0,-;10:0,-20,-0.015625,0,-;6:50,-20,-0.015625,0,-;5:50,20,-0.015625,0,-;2:50,20,0.015625,0,-;9:0,20,0.015625,0,-;8:50,-20,0.015625,0,-;1:50,-20,-0.015625,0,-;7:0,-20,-0.015625,0,-;2:0,20,-0.015625,0,-;7:50,20,-0.015625,0,-;1:50,20,0.015625,0,-;6:0,20,0.015625,0,-;2:0,-20,0.015625,0,-;7:50,-20,0.015625,0,-;1:50,-20,-0.015625,0,-;6:0,-20,-0.015625,0,-;2:0,20,-0.015625,0,-;11:50,20,-0.015625,0,-;3:50,20,0,0,-;2:50,-20,0,0,-;1:50,-20,-0.015625,0,-;1:50,-20,0,0,-;1:50,-20,-0.015625,0,-;"

	runs : List(CommandRun)
	runs = parse_fixture(fixture)

	command_at : U64 -> Try(DoomSim.Command, [ReplayFinished])
	command_at = |tic| command_in_runs(runs, tic, 0)

	initial : {} -> Result
	initial = |_unit| {
		map = DoomMap.e1m1
		start = map.player_start() ?? crash "validated E1M1 player start missing"
		spawned = DoomWorld.spawn(map.raw().things, Baby)
		player = DoomWorld.player({ x: I64.to_f32(start.position.x), y: I64.to_f32(start.position.y) }, DoomSim.Angle.from_turns(I64.to_f32(start.angle) / 360))
		doom : DoomWorld.World
		doom = { player, actors: spawned.actors, pickups: spawned.pickups, rng: DoomWorld.Rng.seed(0) }
		world = DoomRuntime.initial_for_skill(doom, Baby)
		{ world, level: DoomLevel.initial(map), tics: 0, sector: 140, checkpoints: [140], checksum: checksum_step(2166136261, world, DoomLevel.initial(map), 140), used_line: Err(NoUsableLine) }
	}

	## Replay every fixed command, splitting each simulation tic across the
	## supplied host-frame fractions. Fractions must total at least one tic and
	## less than two, matching DoomRuntime's fixed-step accumulator contract.
	replay : List(F32) -> Result
	replay = |partitions| replay_runs(initial({}), runs, partitions, decoration_segments(DoomWorld.spawn(DoomMap.e1m1.raw().things, Baby).decorations), 0)

	# Regenerated with author_replay.roc after the fuzz-driven fixes to door
	# re-use, special 62, wall sliding and pickups (FUZZ_FINDINGS.md), which
	# made the previous 883-tic route diverge; the same 20 checkpoints hold.
	golden_checksum = 3911183262.U64
}

command_in_runs = |runs, tic, index|
	match List.get(runs, index) {
		Err(_) => Err(ReplayFinished)
		Ok(run) => if tic < run.count Ok(run.command) else command_in_runs(runs, tic - run.count, index + 1)
	}

replay_runs = |run, runs, partitions, decorations, index|
	match List.get(runs, index) {
		Err(_) => run
		Ok(command_run) => replay_runs(repeat_command(run, command_run.command, command_run.count, partitions, decorations), runs, partitions, decorations, index + 1)
	}

repeat_command = |run, command, remaining, partitions, decorations|
	if remaining == 0 or run.world.phase != Playing run else repeat_command(run_parts(run, command, partitions, decorations, 0), command, remaining - 1, partitions, decorations)

run_parts = |run, command, partitions, decorations, index|
	match List.get(partitions, index) {
		Err(_) => run
		Ok(fraction) => {
			map = DoomMap.e1m1
			before = run.world.doom.player.sim.state.pos
			advanced = DoomRuntime.advance_in_map(run.world, DoomSim.tic_seconds * fraction, command, decorations, map, run.level)
			after = advanced.world.doom.player.sim.state.pos
			crossed = DoomRuntime.cross_specials(map, run.level, before, after)
			# The fixture has no use button. A usable line is pressed when it first
			# comes into reach, like the game's edge-triggered E key, and pressed
			# again only once no door is moving, so a door in motion is never
			# reversed but a door that closed again is reopened.
			ahead = DoomRuntime.usable_line_ahead(map, after, advanced.world.doom.player.sim.state.angle)
			use_result = match ahead {
				Ok(line) if ahead != run.used_line or List.is_empty(crossed.level.doors) => DoomLevel.use_line(map, crossed.level, line, advanced.world.doom.player.keys)
				_ => NotUsable
			}
			level0 = match use_result {
				Activated(next) => next
				_ => crossed.level
			}
			exited = crossed.exited or match use_result {
				Exit => Bool.True
				_ => Bool.False
			}
			world = if exited { ..advanced.world, phase: Exited } else advanced.world
			level = advance_level(level0, advanced.tics)
			sector = DoomLevel.sector_at(map, { x: F32.to_f64(after.x), y: F32.to_f64(after.y) }) ?? crash "replay player left E1M1"
			checkpoints = record_checkpoint(run.checkpoints, sector)
			checksum = if advanced.tics == 0 run.checksum else checksum_step(run.checksum, world, level, sector)
			next = { world, level, tics: run.tics + advanced.tics, sector, checkpoints, checksum, used_line: ahead }
			run_parts(next, command, partitions, decorations, index + 1)
		}
	}

record_checkpoint = |visited, sector| {
	next_index = List.len(visited)
	match List.get(route_checkpoints, next_index) {
		Ok(expected) => if sector == expected List.append(visited, sector) else visited
		Err(_) => visited
	}
}

advance_level = |level, count| if count == 0 level else advance_level(DoomLevel.tick(level), count - 1)

parse_fixture = |text| parse_entries(Str.split_on(text, ";"), 0, [])

parse_entries = |entries, index, runs|
	match List.get(entries, index) {
		Err(_) => runs
		Ok("") => parse_entries(entries, index + 1, runs)
		Ok(entry) => {
			count_and_command = Str.split_on(entry, ":")
			count = parse_u64(List.get(count_and_command, 0) ?? crash "replay count missing")
			fields = Str.split_on(List.get(count_and_command, 1) ?? crash "replay command missing", ",")
			command = {
				forward: parse_axis(List.get(fields, 0) ?? crash "replay forward missing"),
				side: parse_axis(List.get(fields, 1) ?? crash "replay side missing"),
				turn: parse_turn(List.get(fields, 2) ?? crash "replay turn missing"),
				fire: (List.get(fields, 3) ?? crash "replay fire missing") == "1",
				weapon_slot: match List.get(fields, 4) {
					Ok("-") => KeepWeapon
					Ok(slot) => SelectSlot(U64.to_u8_wrap(parse_u64(slot)))
					Err(_) => crash "replay weapon slot missing"
				},
			}
			parse_entries(entries, index + 1, List.append(runs, { count, command }))
		}
	}

parse_axis = |text|
	match text {
		"-50" => -50
		"-40" => -40
		"-20" => -20
		"0" => 0
		"20" => 20
		"40" => 40
		"50" => 50
		_ => crash "invalid replay axis"
	}

parse_turn = |text|
	match text {
		"-0.015625" => -0.015625
		"0" => 0
		"0.015625" => 0.015625
		_ => crash "invalid replay turn"
	}

parse_u64 = |text| parse_digits(Str.to_utf8(text), 0, 0)

parse_digits = |bytes, index, value|
	match List.get(bytes, index) {
		Err(_) => value
		Ok(byte) => if byte < 48 or byte > 57 crash "invalid replay integer" else parse_digits(bytes, index + 1, value * 10 + U8.to_u64(byte - 48))
	}

decoration_segments = |decorations| {
	var $segments = []
	for decoration in decorations {
		if decoration.blocking {
			r = 16
			a = { x: decoration.pos.x - r, y: decoration.pos.y - r }
			b = { x: decoration.pos.x + r, y: decoration.pos.y - r }
			c = { x: decoration.pos.x + r, y: decoration.pos.y + r }
			d = { x: decoration.pos.x - r, y: decoration.pos.y + r }
			$segments = List.concat($segments, [{ start: a, end: b }, { start: b, end: c }, { start: c, end: d }, { start: d, end: a }])
		}
	}
	$segments
}

checksum_step = |hash, world, level, sector| {
	state = world.doom.player.sim.state
	modulus = 4294967291
	x = I64.to_u64_wrap(F32.to_i64_wrap(state.pos.x * 1000)) % modulus
	y = I64.to_u64_wrap(F32.to_i64_wrap(state.pos.y * 1000)) % modulus
	heights = moving_height_sum(level, DoomLevel.dynamic_sectors(DoomMap.e1m1), 0, 0)
	phase = match world.phase {
		Playing => 1
		Dead => 2
		Exited => 3
	}
	height_value = I64.to_u64_wrap(heights) % modulus
	value = (state.tic * 31 + x * 37 + y * 41 + sector * 43 + height_value * 47 + I64.to_u64_wrap(world.doom.player.health) * 53 + I64.to_u64_wrap(world.doom.player.armor) * 59 + I64.to_u64_wrap(world.doom.player.ammo.bullets) * 61 + U8.to_u64(world.doom.rng.index()) * 67 + List.len(world.doom.actors) * 71 + List.len(world.projectiles) * 73 + phase * 79) % modulus
	(hash * 16777619 + value) % modulus
}

moving_height_sum = |level, sectors, index, total|
	match List.get(sectors, index) {
		Err(_) => total
		Ok(sector) => {
			heights = DoomLevel.heights_for(level, sector) ?? crash "dynamic sector missing"
			moving_height_sum(level, sectors, index + 1, total + heights.floor + heights.ceiling)
		}
	}

route_checkpoints = [140, 141, 91, 150, 98, 142, 17, 93, 10, 9, 13, 12, 37, 34, 8, 135, 63, 64, 68, 66]

run_tic_count = |runs, index, total|
	match List.get(runs, index) {
		Err(_) => total
		Ok(run) => run_tic_count(runs, index + 1, total + run.count)
	}

expect {
	runs = DoomReplay.runs
	List.len(runs) == 210 and run_tic_count(runs, 0, 0) == 789 and List.any(runs, |run| run.command.weapon_slot == SelectSlot(2))
}

expect {
	initial = DoomReplay.initial({})
	spawned = DoomWorld.spawn(DoomMap.e1m1.raw().things, Baby)
	initial.world.phase == Playing
		and initial.world.skill == Baby
			and initial.world.doom.player.health == 100
				and initial.world.doom.player.ammo.bullets == 50
					and List.len(initial.world.doom.actors) == List.len(spawned.actors)
						and List.len(initial.world.doom.pickups) == List.len(spawned.pickups)
							and initial.tics == 0
								and List.is_empty(initial.level.doors)
}

# This intentionally performs one full 789-tic replay. DoomTrace covers fixed-
# step host partition invariance with a short script; duplicating this whole
# actor/combat route would double an already expensive compile-time oracle.
expect {
	result = DoomReplay.replay([1.0001])
	result.world.phase == Exited
		and result.tics == 789
			and result.sector == 66
				and result.world.doom.player.health == 48
					and result.world.doom.player.armor == 0
						and result.world.doom.player.ammo.bullets == 63
							and result.checkpoints == route_checkpoints
								and result.checksum == DoomReplay.golden_checksum
}
