## Pure coordinator for the fixed-tic player and actor foundations. Map policy
## enters only as explicit blocker segments; LOS, combat, pickup contact, and
## gameplay RNG remain deterministic Roc state.
import DoomSim
import DoomLevel
import DoomMap
import DoomWorld

DoomRuntime := [].{
	Advance : { world : DoomWorld.World, tics : U64, dropped : Bool, fired : Bool }

	advance : DoomWorld.World, F32, DoomSim.Command, List(DoomSim.Segment) -> Advance
	advance = |world, elapsed, command, blockers| {
		sim = DoomSim.advance(world.player.sim, elapsed, command, blockers)
		var $next = { ..world, player: { ..world.player, sim: sim.clock } }
		for _ in List.repeat({}, sim.tics) {
			$next = tic($next, command.fire, blockers)
		}
		# A held host input represents one weapon request per host cycle; actor
		# simulation still advances exactly once for each admitted 35 Hz tic.
		fired_world = if command.fire and sim.tics > 0 fire($next, blockers) else { world: $next, fired: Bool.False }
		{ world: fired_world.world, tics: sim.tics, dropped: sim.dropped, fired: fired_world.fired }
	}

	tic : DoomWorld.World, Bool, List(DoomSim.Segment) -> DoomWorld.World
	tic = |world, heard_shot, blockers| {
		player_pos = world.player.sim.state.pos
		var $rng = world.rng
		var $damage = 0.I64
		var $actors = []
		for actor in world.actors {
			facts : DoomWorld.ActorFacts
			facts = { player_pos, has_sight: line_of_sight(actor.pos, player_pos, blockers), heard_sound: heard_shot, blockers }
			turn = DoomWorld.tick_actor_with(actor, facts, $rng)
			$rng = turn.rng
			$damage = $damage + turn.player_damage
			$actors = List.append($actors, turn.actor)
		}
		player0 = DoomWorld.damage_player(world.player, $damage)
		collected = collect_nearby(player0, world.pickups)
		{ ..world, player: collected.player, actors: $actors, pickups: collected.pickups, rng: $rng }
	}

	line_of_sight : DoomSim.Vec2, DoomSim.Vec2, List(DoomSim.Segment) -> Bool
	line_of_sight = |from, to, blockers| !List.any(blockers, |blocker| segments_cross(from, to, blocker.start, blocker.end))

	## Add currently closed/too-high portals adjacent to the player's sector to
	## permanent one-sided and explicitly blocking geometry.
	blockers_for_player : DoomMap.Map, DoomLevel.State, DoomSim.Vec2 -> List(DoomSim.Segment)
	blockers_for_player = |map, level, pos| {
		permanent = List.map(map.blocking_segments(), |segment| to_segment(segment.start, segment.end))
		sector = DoomLevel.sector_at(map, { x: F32.to_f64(pos.x), y: F32.to_f64(pos.y) }) ?? return permanent
		dynamic = List.map(
			DoomLevel.collision_segments(map, level, sector),
			|segment| {
				start: { x: F64.to_f32_wrap(segment.start.x), y: F64.to_f32_wrap(segment.start.y) },
				end: { x: F64.to_f32_wrap(segment.end.x), y: F64.to_f32_wrap(segment.end.y) },
			},
		)
		List.concat(permanent, dynamic)
	}

	cross_specials : DoomMap.Map, DoomLevel.State, DoomSim.Vec2, DoomSim.Vec2 -> DoomLevel.State
	cross_specials = |map, level, from, to| {
		var $level = level
		for line in DoomLevel.crossed_lines(map, { x: F32.to_f64(from.x), y: F32.to_f64(from.y) }, { x: F32.to_f64(to.x), y: F32.to_f64(to.y) }) {
			match DoomLevel.cross_line(map, $level, line) {
				Activated(next) => {
					$level = next
				}
				_ => {}
			}
		}
		$level
	}

	use_nearest : DoomMap.Map, DoomLevel.State, DoomSim.Vec2, DoomWorld.Keys -> DoomLevel.UseResult
	use_nearest = |map, level, pos, keys| {
		raw = map.raw()
		var $line = Err(NoUsableLine)
		var $best = 64 * 64
		for candidate in List.map_with_index(raw.linedefs, |value, index| { value, index }) {
			if candidate.value.special != 0 {
				start = List.get(raw.vertices, candidate.value.start_vertex) ?? crash "validated vertex missing"
				end = List.get(raw.vertices, candidate.value.end_vertex) ?? crash "validated vertex missing"
				distance = distance_to_segment_squared(pos, to_segment(start, end))
				if distance < $best {
					$best = distance
					$line = Ok(candidate.index)
				}
			}
		}
		match $line {
			Ok(index) => DoomLevel.use_line(map, level, index, keys)
			Err(NoUsableLine) => NotUsable
		}
	}

	player_pickup_radius = 20
}

to_segment = |start, end| { start: { x: I64.to_f32(start.x), y: I64.to_f32(start.y) }, end: { x: I64.to_f32(end.x), y: I64.to_f32(end.y) } }

distance_to_segment_squared = |point, segment| {
	along = DoomSim.sub(segment.end, segment.start)
	length = DoomSim.length_squared(along)
	amount = if length <= 0 0 else F32.max(0, F32.min(1, DoomSim.dot(DoomSim.sub(point, segment.start), along) / length))
	DoomSim.distance_squared(point, DoomSim.add(segment.start, DoomSim.scale(along, amount)))
}

collect_nearby = |player, pickups| {
	var $player = player
	var $pickups = []
	for pickup in pickups {
		if !(pickup.taken) and DoomSim.distance_squared(player.sim.state.pos, pickup.pos) <= DoomRuntime.player_pickup_radius * DoomRuntime.player_pickup_radius {
			result = DoomWorld.collect($player, pickup)
			$player = result.player
			$pickups = List.append($pickups, result.pickup)
		} else {
			$pickups = List.append($pickups, pickup)
		}
	}
	{ player: $player, pickups: $pickups }
}

fire = |world, blockers| {
	available = match world.player.weapon {
		Pistol => world.player.ammo.bullets
		Shotgun => world.player.ammo.shells
	}
	if available <= 0 or world.player.health <= 0 {
		{ world, fired: Bool.False }
	} else {
		shot = DoomWorld.hitscan(world.rng, world.player.weapon)
		player = spend_ammo(world.player)
		target = target_actor(world.actors, player.sim.state.pos, player.sim.state.angle, shot.spread_turns, blockers)
		match target {
			Err(NoTarget) => { world: { ..world, player, rng: shot.rng }, fired: Bool.True }
			Ok(id) => {
				var $rng = shot.rng
				var $actors = []
				for actor in world.actors {
					if actor.id == id {
						result = DoomWorld.damage_actor_random(actor, shot.damage, $rng)
						$rng = result.rng
						$actors = List.append($actors, result.actor)
					} else {
						$actors = List.append($actors, actor)
					}
				}
				{ world: { ..world, player, actors: $actors, rng: $rng }, fired: Bool.True }
			}
		}
	}
}

spend_ammo = |player|
	match player.weapon {
		Pistol => { ..player, ammo: { ..player.ammo, bullets: I64.max(0, player.ammo.bullets - 1) } }
		Shotgun => { ..player, ammo: { ..player.ammo, shells: I64.max(0, player.ammo.shells - 1) } }
	}

target_actor = |actors, origin, angle, spread_turns, blockers| {
	facing0 = angle.forward()
	# Small-angle hitscan spread expressed without host trig or angle callbacks.
	perpendicular = { x: 0 - facing0.y, y: facing0.x }
	facing = DoomSim.normalize(DoomSim.add(facing0, DoomSim.scale(perpendicular, spread_turns * 6.2831855)))
	var $target = Err(NoTarget)
	var $best_distance = 2048 * 2048
	for actor in actors {
		if actor.state.mode != Dead {
			to_actor = DoomSim.sub(actor.pos, origin)
			distance = DoomSim.length_squared(to_actor)
			along = DoomSim.dot(to_actor, facing)
			across = F32.abs(to_actor.x * facing.y - to_actor.y * facing.x)
			if along > 0 and distance < $best_distance and across <= 24 and DoomRuntime.line_of_sight(origin, actor.pos, blockers) {
				$best_distance = distance
				$target = Ok(actor.id)
			}
		}
	}
	$target
}

segments_cross = |a, b, c, d| {
	ab_c = cross(a, b, c)
	ab_d = cross(a, b, d)
	cd_a = cross(c, d, a)
	cd_b = cross(c, d, b)
	# Strict crossings avoid a ray beginning exactly on a blocking line being
	# permanently blind; collision keeps the player radius away in normal play.
	((ab_c > 0 and ab_d < 0) or (ab_c < 0 and ab_d > 0)) and ((cd_a > 0 and cd_b < 0) or (cd_a < 0 and cd_b > 0))
}

cross = |a, b, p| (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)

expect {
	wall : DoomSim.Segment
	wall = { start: { x: 32, y: -32 }, end: { x: 32, y: 32 } }
	DoomRuntime.line_of_sight({ x: 0, y: 0 }, { x: 64, y: 0 }, [])
		and !(DoomRuntime.line_of_sight({ x: 0, y: 0 }, { x: 64, y: 0 }, [wall]))
}

expect {
	player = DoomWorld.player({ x: 0, y: 0 }, DoomSim.Angle.from_turns(0))
	actor = DoomWorld.actor(1, ZombieMan, { x: 96, y: 0 }, DoomSim.Angle.from_turns(0.5), Bool.False)
	world : DoomWorld.World
	world = { player, actors: [actor], pickups: [], rng: DoomWorld.Rng.seed(0) }
	advanced = DoomRuntime.advance(world, DoomSim.tic_seconds, { ..DoomSim.neutral, fire: Bool.True }, [])
	hit = List.get(advanced.world.actors, 0) ?? actor
	advanced.tics == 1 and advanced.fired and advanced.world.player.ammo.bullets == 49 and hit.health < actor.health
}

expect {
	player = { ..DoomWorld.player({ x: 0, y: 0 }, DoomSim.Angle.from_turns(0)), health: 50 }
	pickup : DoomWorld.Pickup
	pickup = { id: 0, kind: StimpackPickup, pos: { x: 8, y: 0 }, taken: Bool.False }
	world : DoomWorld.World
	world = { player, actors: [], pickups: [pickup], rng: DoomWorld.Rng.seed(0) }
	next = DoomRuntime.tic(world, Bool.False, [])
	item = List.get(next.pickups, 0) ?? pickup
	next.player.health == 60 and item.taken
}
