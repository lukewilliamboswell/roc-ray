## Pure coordinator for the fixed-tic player and actor foundations. Map policy
## enters only as explicit blocker segments; LOS, combat, pickup contact, and
## gameplay RNG remain deterministic Roc state.
import DoomSim
import DoomLevel
import DoomMap
import DoomSound
import DoomWorld

DoomRuntime := [].{
	Phase := [Playing, Dead, Exited].{
		is_eq : _
	}
	Projectile : { id : U64, owner : U64, target : U64, pos : DoomSim.Vec2, momentum : DoomSim.Vec2, damage : I64, remaining : U64 }
	Aggro : { hunter : U64, target : U64 }
	Explosion : { pos : DoomSim.Vec2, remaining : U64 }
	WeaponState : { cooldown : U64, phase : U64 }
	World : { doom : DoomWorld.World, projectiles : List(Projectile), explosions : List(Explosion), sound_origins : List(DoomSim.Vec2), aggro : List(Aggro), next_projectile_id : U64, weapon : WeaponState, phase : Phase }
	Advance : { world : World, tics : U64, dropped : Bool, fired : Bool, projectile_saturated : Bool }

	initial : DoomWorld.World -> World
	initial = |doom| { doom, projectiles: [], explosions: [], sound_origins: [], aggro: [], next_projectile_id: 0, weapon: { cooldown: 0, phase: 0 }, phase: if doom.player.health <= 0 Dead else Playing }

	advance : World, F32, DoomSim.Command, List(DoomSim.Segment) -> Advance
	advance = |world, elapsed, command, blockers| {
		if world.phase != Playing {
			{ world, tics: 0, dropped: Bool.False, fired: Bool.False, projectile_saturated: Bool.False }
		} else {
			actor_blockers = actor_segments(world.doom.actors)
			all_blockers = List.concat(blockers, actor_blockers)
			sim = DoomSim.advance(world.doom.player.sim, elapsed, command, all_blockers)
			var $next = { ..world, doom: { ..world.doom, player: { ..world.doom.player, sim: sim.clock } } }
			var $saturated = Bool.False
			var $fired = Bool.False
			for _ in List.repeat({}, sim.tics) {
				result = tic($next, command.fire, blockers)
				$next = result.world
				$saturated = $saturated or result.projectile_saturated
				$fired = $fired or result.fired
			}
			phase = if $next.doom.player.health <= 0 Dead else $next.phase
			{ world: { ..$next, phase }, tics: sim.tics, dropped: sim.dropped, fired: $fired, projectile_saturated: $saturated }
		}
	}

	advance_in_map : World, F32, DoomSim.Command, List(DoomSim.Segment), DoomMap.Map -> Advance
	advance_in_map = |world, elapsed, command, blockers, map| {
		if world.phase != Playing {
			{ world, tics: 0, dropped: Bool.False, fired: Bool.False, projectile_saturated: Bool.False }
		} else {
			all_blockers = List.concat(blockers, actor_segments(world.doom.actors))
			sim = DoomSim.advance(world.doom.player.sim, elapsed, command, all_blockers)
			var $next = { ..world, doom: { ..world.doom, player: { ..world.doom.player, sim: sim.clock } } }
			var $saturated = Bool.False
			var $fired = Bool.False
			for _ in List.repeat({}, sim.tics) {
				will_fire = command.fire and $next.weapon.cooldown == 0 and player_can_fire($next.doom.player)
				sources = if will_fire List.append($next.sound_origins, $next.doom.player.sim.state.pos) else $next.sound_origins
				heard0 = heard_actor_ids(map, sources, $next.doom.actors)
				heard = if will_fire List.append(heard0, player_sound_id) else heard0
				result = tic_hearing($next, heard, blockers)
				$next = result.world
				$saturated = $saturated or result.projectile_saturated
				$fired = $fired or result.fired
			}
			phase = if $next.doom.player.health <= 0 Dead else $next.phase
			{ world: { ..$next, phase }, tics: sim.tics, dropped: sim.dropped, fired: $fired, projectile_saturated: $saturated }
		}
	}

	tic : World, Bool, List(DoomSim.Segment) -> { world : World, projectile_saturated : Bool, fired : Bool }
	tic = |world, heard_shot, blockers| {
		heard = if heard_shot List.append(List.map(world.doom.actors, |actor| actor.id), player_sound_id) else []
		tic_hearing(world, heard, blockers)
	}

	tic_hearing : World, List(U64), List(DoomSim.Segment) -> { world : World, projectile_saturated : Bool, fired : Bool }
	tic_hearing = |world, heard_actors, blockers| {
		player_pos = world.doom.player.sim.state.pos
		var $rng = world.doom.rng
		var $damage = 0.I64
		var $actors = []
		var $projectiles = world.projectiles
		var $next_id = world.next_projectile_id
		var $saturated = Bool.False
		var $sound_origins = []
		var $actor_hits = []
		for actor in world.doom.actors {
			target = aggro_target(world.aggro, actor.id, world.doom.actors)
			target_pos = match target {
				Ok(value) => value.pos
				Err(PlayerTarget) => player_pos
			}
			facts : DoomWorld.ActorFacts
			facts = { player_pos: target_pos, has_sight: line_of_sight(actor.pos, target_pos, blockers), heard_sound: List.contains(heard_actors, actor.id), blockers }
			turn = DoomWorld.tick_actor_with(actor, facts, $rng)
			$rng = turn.rng
			actor1 = if actor_overlaps(turn.actor, world.doom.actors) { ..turn.actor, pos: actor.pos } else turn.actor
			if turn.attack_kind == ProjectileAttack {
				if List.len($projectiles) < max_projectiles {
					direction = DoomSim.normalize(DoomSim.sub(target_pos, actor1.pos))
					target_id = match target {
						Ok(value) => value.id
						Err(PlayerTarget) => player_sound_id
					}
					$projectiles = List.append($projectiles, { id: $next_id, owner: actor1.id, target: target_id, pos: actor1.pos, momentum: DoomSim.scale(direction, projectile_speed), damage: turn.player_damage, remaining: projectile_lifetime })
					$next_id = $next_id + 1
				} else {
					$saturated = Bool.True
				}
			} else {
				match target {
					Ok(target_actor) => {
						if turn.player_damage > 0 {
							$actor_hits = List.append($actor_hits, { source: actor1.id, target: target_actor.id, damage: turn.player_damage })
						}
					}
					Err(PlayerTarget) => {
						$damage = $damage + turn.player_damage
					}
				}
			}
			if turn.attack_kind != NoAttack and List.len($sound_origins) < max_sound_origins {
				$sound_origins = List.append($sound_origins, actor1.pos)
			}
			$actors = List.append($actors, actor1)
		}
		projectile_step = advance_projectiles($projectiles, player_pos, $actors, blockers)
		all_hits = List.concat($actor_hits, projectile_step.actor_hits)
		hit_result = apply_actor_hits($actors, all_hits, $rng, world.aggro)
		$actors = hit_result.actors
		$rng = hit_result.rng
		var $explosions = advance_explosions(world.explosions)
		for impact in projectile_step.impacts {
			if List.len($explosions) < max_explosions {
				$explosions = List.append($explosions, { pos: impact, remaining: explosion_lifetime })
			} else {
				$saturated = Bool.True
			}
		}
		player0 = DoomWorld.damage_player(DoomWorld.tick_player_powers(world.doom.player), $damage + projectile_step.damage)
		collected = collect_nearby(player0, world.doom.pickups)
		doom = { ..world.doom, player: collected.player, actors: $actors, pickups: collected.pickups, rng: $rng }
		world0 = { ..world, doom, projectiles: projectile_step.projectiles, explosions: $explosions, sound_origins: $sound_origins, aggro: hit_result.aggro, next_projectile_id: $next_id, phase: if doom.player.health <= 0 Dead else world.phase }
		firing = List.contains(heard_actors, player_sound_id)
		fired_result = if firing and world.weapon.cooldown == 0 and doom.player.health > 0 fire(world0, blockers) else { world: world0, fired: Bool.False }
		cooldown = if fired_result.fired weapon_cadence(doom.player.weapon) - 1 else if world.weapon.cooldown > 0 world.weapon.cooldown - 1 else 0
		phase = if fired_result.fired 1 else if cooldown > 0 world.weapon.phase + 1 else 0
		{ world: { ..fired_result.world, weapon: { cooldown, phase } }, projectile_saturated: $saturated, fired: fired_result.fired }
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

	cross_specials : DoomMap.Map, DoomLevel.State, DoomSim.Vec2, DoomSim.Vec2 -> { level : DoomLevel.State, exited : Bool }
	cross_specials = |map, level, from, to| {
		var $level = level
		var $exited = Bool.False
		for line in DoomLevel.crossed_lines(map, { x: F32.to_f64(from.x), y: F32.to_f64(from.y) }, { x: F32.to_f64(to.x), y: F32.to_f64(to.y) }) {
			match DoomLevel.cross_line(map, $level, line) {
				Activated(next) => {
					$level = next
				}
				Exit => {
					$exited = Bool.True
				}
				_ => {}
			}
		}
		{ level: $level, exited: $exited }
	}

	use_forward : DoomMap.Map, DoomLevel.State, DoomSim.Vec2, DoomSim.Angle, DoomWorld.Keys -> DoomLevel.UseResult
	use_forward = |map, level, pos, angle, keys| {
		raw = map.raw()
		end = DoomSim.add(pos, DoomSim.scale(angle.forward(), use_distance))
		var $line = Err(NoUsableLine)
		var $best = use_distance * use_distance
		for candidate in List.map_with_index(raw.linedefs, |value, index| { value, index }) {
			if candidate.value.special != 0 {
				start = List.get(raw.vertices, candidate.value.start_vertex) ?? crash "validated vertex missing"
				line_end = List.get(raw.vertices, candidate.value.end_vertex) ?? crash "validated vertex missing"
				segment = to_segment(start, line_end)
				distance = distance_to_segment_squared(pos, segment)
				if segments_cross(pos, end, segment.start, segment.end) and distance < $best {
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
	max_projectiles = 64.U64
	max_explosions = 64.U64
	max_sound_origins = 16.U64
	player_sound_id = 18446744073709551615.U64
	explosion_lifetime = 15.U64
	use_distance = 64
}

heard_actor_ids = |map, sources, actors| {
	var $ids = []
	for actor in actors {
		if !(actor.ambush) and List.any(sources, |source| DoomSound.can_hear(map, source, actor.pos)) {
			$ids = List.append($ids, actor.id)
		}
	}
	$ids
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

actor_segments = |actors| {
	var $segments = []
	for actor in actors {
		if actor.state.mode != Dead {
			r = 20
			a = { x: actor.pos.x - r, y: actor.pos.y - r }
			b = { x: actor.pos.x + r, y: actor.pos.y - r }
			c = { x: actor.pos.x + r, y: actor.pos.y + r }
			d = { x: actor.pos.x - r, y: actor.pos.y + r }
			$segments = List.concat($segments, [{ start: a, end: b }, { start: b, end: c }, { start: c, end: d }, { start: d, end: a }])
		}
	}
	$segments
}

actor_overlaps = |actor, actors|
	actor.state.mode != Dead and List.any(actors, |other| other.id != actor.id and other.state.mode != Dead and DoomSim.distance_squared(actor.pos, other.pos) < 40 * 40)

advance_projectiles = |projectiles, player_pos, actors, blockers| {
	var $next = []
	var $damage = 0.I64
	var $impacts = []
	var $actor_hits = []
	for projectile in projectiles {
		candidate = DoomSim.add(projectile.pos, projectile.momentum)
		path : DoomSim.Segment
		path = { start: projectile.pos, end: candidate }
		hits_wall = List.any(blockers, |blocker| DoomSim.sweep_hits_segment(projectile.pos, candidate, projectile_radius, blocker))
		hits_player = projectile.target == DoomRuntime.player_sound_id and DoomSim.distance_to_segment_squared(player_pos, path) <= (DoomSim.player_radius + projectile_radius) * (DoomSim.player_radius + projectile_radius)
		target_actor = List.first(List.keep_if(actors, |actor| actor.id == projectile.target and actor.state.mode != Dead))
		hits_actor = match target_actor {
			Ok(actor) => DoomSim.distance_to_segment_squared(actor.pos, path) <= (DoomWorld.actor_radius + projectile_radius) * (DoomWorld.actor_radius + projectile_radius)
			Err(_) => Bool.False
		}
		if hits_player {
			$damage = $damage + projectile.damage
			$impacts = List.append($impacts, candidate)
		} else if hits_actor {
			$actor_hits = List.append($actor_hits, { source: projectile.owner, target: projectile.target, damage: projectile.damage })
			$impacts = List.append($impacts, candidate)
		} else if hits_wall {
			$impacts = List.append($impacts, candidate)
		} else if !(hits_wall) and projectile.remaining > 1 {
			$next = List.append($next, { ..projectile, pos: candidate, remaining: projectile.remaining - 1 })
		}
	}
	{ projectiles: $next, damage: $damage, impacts: $impacts, actor_hits: $actor_hits }
}

aggro_target = |aggro, hunter, actors| {
	match List.first(List.keep_if(aggro, |value| value.hunter == hunter)) {
		Err(_) => Err(PlayerTarget)
		Ok(entry) =>
			match List.first(List.keep_if(actors, |actor| actor.id == entry.target and actor.state.mode != Dead)) {
				Ok(actor) => Ok(actor)
				Err(_) => Err(PlayerTarget)
			}
		}
}

apply_actor_hits = |actors, hits, rng, aggro| {
	var $actors = actors
	var $rng = rng
	var $aggro = aggro
	for hit in hits {
		var $next = []
		for actor in $actors {
			if actor.id == hit.target and actor.state.mode != Dead {
				result = DoomWorld.damage_actor_random(actor, hit.damage, $rng)
				$rng = result.rng
				$next = List.append($next, result.actor)
			} else {
				$next = List.append($next, actor)
			}
		}
		$actors = $next
		$aggro = set_aggro($aggro, hit.target, hit.source, List.len(actors))
	}
	{ actors: $actors, rng: $rng, aggro: $aggro }
}

set_aggro = |aggro, hunter, target, capacity| {
	without = List.keep_if(aggro, |value| value.hunter != hunter)
	if List.len(without) < capacity List.append(without, { hunter, target }) else without
}

advance_explosions = |explosions|
	List.keep_oks(explosions, |explosion| if explosion.remaining > 1 Ok({ ..explosion, remaining: explosion.remaining - 1 }) else Err(Expired))

projectile_speed = 10

projectile_radius = 6

projectile_lifetime = 140.U64

fire = |world, blockers| {
	available = match world.doom.player.weapon {
		Pistol => world.doom.player.ammo.bullets
		Shotgun => world.doom.player.ammo.shells
		Chaingun => world.doom.player.ammo.bullets
		RocketLauncher => world.doom.player.ammo.rockets
		PlasmaRifle => world.doom.player.ammo.cells
		Chainsaw => 1
	}
	if available <= 0 or world.doom.player.health <= 0 {
		{ world, fired: Bool.False }
	} else {
		shot = DoomWorld.hitscan(world.doom.rng, world.doom.player.weapon)
		player = spend_ammo(world.doom.player)
		target = target_actor(world.doom.actors, player.sim.state.pos, player.sim.state.angle, shot.spread_turns, blockers)
		match target {
			Err(NoTarget) => { world: { ..world, doom: { ..world.doom, player, rng: shot.rng } }, fired: Bool.True }
			Ok(id) => {
				var $rng = shot.rng
				var $actors = []
				for actor in world.doom.actors {
					if actor.id == id {
						result = DoomWorld.damage_actor_random(actor, shot.damage, $rng)
						$rng = result.rng
						$actors = List.append($actors, result.actor)
					} else {
						$actors = List.append($actors, actor)
					}
				}
				aggro = set_aggro(world.aggro, id, DoomRuntime.player_sound_id, List.len($actors))
				{ world: { ..world, doom: { ..world.doom, player, actors: $actors, rng: $rng }, aggro }, fired: Bool.True }
			}
		}
	}
}

player_can_fire = |player|
	player.health > 0 and match player.weapon {
		Pistol => player.ammo.bullets > 0
		Shotgun => player.ammo.shells > 0
		Chaingun => player.ammo.bullets > 0
		RocketLauncher => player.ammo.rockets > 0
		PlasmaRifle => player.ammo.cells > 0
		Chainsaw => Bool.True
	}

spend_ammo = |player|
	match player.weapon {
		Pistol => { ..player, ammo: { ..player.ammo, bullets: I64.max(0, player.ammo.bullets - 1) } }
		Shotgun => { ..player, ammo: { ..player.ammo, shells: I64.max(0, player.ammo.shells - 1) } }
		Chaingun => { ..player, ammo: { ..player.ammo, bullets: I64.max(0, player.ammo.bullets - 1) } }
		RocketLauncher => { ..player, ammo: { ..player.ammo, rockets: I64.max(0, player.ammo.rockets - 1) } }
		PlasmaRifle => { ..player, ammo: { ..player.ammo, cells: I64.max(0, player.ammo.cells - 1) } }
		Chainsaw => player
	}

weapon_cadence = |weapon|
	match weapon {
		Pistol => 7
		Shotgun => 35
		Chaingun => 4
		RocketLauncher => 28
		PlasmaRifle => 3
		Chainsaw => 4
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
	advanced = DoomRuntime.advance(DoomRuntime.initial(world), DoomSim.tic_seconds, { ..DoomSim.neutral, fire: Bool.True }, [])
	hit = List.get(advanced.world.doom.actors, 0) ?? actor
	advanced.tics == 1 and advanced.fired and advanced.world.doom.player.ammo.bullets == 49 and hit.health < actor.health
}

expect {
	player = { ..DoomWorld.player({ x: 0, y: 0 }, DoomSim.Angle.from_turns(0)), health: 50 }
	pickup : DoomWorld.Pickup
	pickup = { id: 0, kind: StimpackPickup, pos: { x: 8, y: 0 }, taken: Bool.False }
	world : DoomWorld.World
	world = { player, actors: [], pickups: [pickup], rng: DoomWorld.Rng.seed(0) }
	next = DoomRuntime.tic(DoomRuntime.initial(world), Bool.False, []).world
	item = List.get(next.doom.pickups, 0) ?? pickup
	next.doom.player.health == 60 and item.taken
}

expect {
	player = DoomWorld.player({ x: 256, y: 0 }, DoomSim.Angle.from_turns(0.5))
	imp0 = DoomWorld.actor(1, Imp, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	imp = { ..imp0, state: { mode: Attack, remaining: 1 } }
	doom : DoomWorld.World
	doom = { player, actors: [imp], pickups: [], rng: DoomWorld.Rng.seed(0) }
	spawned = DoomRuntime.tic(DoomRuntime.initial(doom), Bool.False, []).world
	projectile = List.get(spawned.projectiles, 0) ?? crash "Imp projectile missing"
	wall : DoomSim.Segment
	wall = { start: { x: projectile.pos.x + 4, y: -32 }, end: { x: projectile.pos.x + 4, y: 32 } }
	blocked = DoomRuntime.tic(spawned, Bool.False, [wall]).world
	List.len(spawned.projectiles) == 1 and List.is_empty(blocked.projectiles) and blocked.doom.player.health == 100
}

expect {
	map = DoomMap.e1m1
	level = DoomLevel.initial(map)
	forward = DoomRuntime.use_forward(map, level, { x: 832, y: 512 }, DoomSim.Angle.from_turns(0.25), { blue: Bool.False, yellow: Bool.False, red: Bool.False })
	backward = DoomRuntime.use_forward(map, level, { x: 832, y: 512 }, DoomSim.Angle.from_turns(0.75), { blue: Bool.False, yellow: Bool.False, red: Bool.False })
	match forward {
		Activated(_) => Bool.True
		_ => Bool.False
	} and match backward {
		NotUsable => Bool.True
		_ => Bool.False
	}
}

expect {
	player = DoomWorld.player({ x: 256, y: 0 }, DoomSim.Angle.from_turns(0.5))
	imp0 = DoomWorld.actor(1, Imp, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	imp = { ..imp0, state: { mode: Attack, remaining: 1 } }
	doom : DoomWorld.World
	doom = { player, actors: [imp], pickups: [], rng: DoomWorld.Rng.seed(0) }
	fixture : DoomRuntime.Projectile
	fixture = { id: 0, owner: 99, target: DoomRuntime.player_sound_id, pos: { x: -1000, y: -1000 }, momentum: { x: 0, y: 0 }, damage: 1, remaining: 10 }
	full = { ..DoomRuntime.initial(doom), projectiles: List.repeat(fixture, DoomRuntime.max_projectiles) }
	result = DoomRuntime.tic(full, Bool.False, [])
	result.projectile_saturated and List.len(result.world.projectiles) == DoomRuntime.max_projectiles
}

expect {
	player = DoomWorld.player({ x: 100, y: 0 }, DoomSim.Angle.from_turns(0.5))
	a0 = DoomWorld.actor(1, ZombieMan, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	a = { ..a0, state: { mode: Chase, remaining: 1 } }
	b = DoomWorld.actor(2, ZombieMan, { x: 24, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	doom : DoomWorld.World
	doom = { player, actors: [a, b], pickups: [], rng: DoomWorld.Rng.seed(0) }
	next = DoomRuntime.tic(DoomRuntime.initial(doom), Bool.False, []).world
	moved = List.get(next.doom.actors, 0) ?? a
	moved.pos == a.pos
}

expect {
	player = DoomWorld.player({ x: 0, y: 0 }, DoomSim.Angle.from_turns(0))
	actor = DoomWorld.actor(1, ZombieMan, { x: 48, y: 0 }, DoomSim.Angle.from_turns(0.5), Bool.False)
	doom : DoomWorld.World
	doom = { player, actors: [actor], pickups: [], rng: DoomWorld.Rng.seed(0) }
	advanced = DoomRuntime.advance(DoomRuntime.initial(doom), DoomSim.tic_seconds * 8, { ..DoomSim.neutral, forward: 50 }, [])
	advanced.world.doom.player.sim.state.pos.x < 12
}

expect {
	player = { ..DoomWorld.player({ x: 0, y: 0 }, DoomSim.Angle.from_turns(0)), health: 1 }
	zombie0 = DoomWorld.actor(1, ZombieMan, { x: 64, y: 0 }, DoomSim.Angle.from_turns(0.5), Bool.False)
	zombie = { ..zombie0, state: { mode: Attack, remaining: 1 } }
	doom : DoomWorld.World
	doom = { player, actors: [zombie], pickups: [], rng: DoomWorld.Rng.seed(0) }
	next = DoomRuntime.tic(DoomRuntime.initial(doom), Bool.False, []).world
	next.phase == Dead and next.doom.player.health == 0
}

expect {
	start = DoomMap.e1m1.player_start() ?? crash "E1M1 player start missing"
	pos = { x: I64.to_f32(start.position.x), y: I64.to_f32(start.position.y) }
	normal = DoomWorld.actor(1, ZombieMan, pos, DoomSim.Angle.from_turns(0), Bool.False)
	ambush = DoomWorld.actor(2, ZombieMan, pos, DoomSim.Angle.from_turns(0), Bool.True)
	heard = heard_actor_ids(DoomMap.e1m1, [pos], [normal, ambush])
	List.contains(heard, normal.id) and !(List.contains(heard, ambush.id))
}

expect {
	player = DoomWorld.player({ x: 512, y: 0 }, DoomSim.Angle.from_turns(0.5))
	attacker0 = DoomWorld.actor(1, ZombieMan, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	attacker = { ..attacker0, state: { mode: Attack, remaining: 1 } }
	victim = DoomWorld.actor(2, Imp, { x: 32, y: 0 }, DoomSim.Angle.from_turns(0.5), Bool.False)
	doom : DoomWorld.World
	doom = { player, actors: [attacker, victim], pickups: [], rng: DoomWorld.Rng.seed(0) }
	world = { ..DoomRuntime.initial(doom), aggro: [{ hunter: attacker.id, target: victim.id }] }
	next = DoomRuntime.tic_hearing(world, [], []).world
	victim1 = List.get(next.doom.actors, 1) ?? victim
	retaliates = List.any(next.aggro, |entry| entry.hunter == victim.id and entry.target == attacker.id)
	victim1.health < victim.health and retaliates and next.doom.player.health == player.health
}

expect {
	player = DoomWorld.player({ x: 512, y: 0 }, DoomSim.Angle.from_turns(0.5))
	owner = DoomWorld.actor(1, Imp, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	victim = DoomWorld.actor(2, ZombieMan, { x: 24, y: 0 }, DoomSim.Angle.from_turns(0.5), Bool.False)
	projectile : DoomRuntime.Projectile
	projectile = { id: 0, owner: owner.id, target: victim.id, pos: { x: 0, y: 0 }, momentum: { x: 16, y: 0 }, damage: 12, remaining: 4 }
	step = advance_projectiles([projectile], player.sim.state.pos, [owner, victim], [])
	hit = List.get(step.actor_hits, 0) ?? crash "owned projectile missed actor"
	hit.source == owner.id and hit.target == victim.id and hit.damage == 12 and List.is_empty(step.projectiles)
}

expect {
	entries = set_aggro([], 1, 2, 1)
	saturated = set_aggro(entries, 3, 4, 1)
	List.len(saturated) == 1 and List.contains(saturated, { hunter: 1, target: 2 })
}

expect {
	# Real E1M1 connector regression: sector 142 is only 16 units wide, so a
	# radius-16 player overlaps its blocked southern boundary while leaving
	# east through the valid portal at linedef 1084. The overlap must not pin it.
	map = DoomMap.e1m1
	level = DoomLevel.initial(map)
	var $state = DoomSim.initial({ x: 196.56944, y: 310.7271 }, DoomSim.Angle.from_turns(0))
	for _ in List.repeat({}, 16) {
		blockers = DoomRuntime.blockers_for_player(map, level, $state.pos)
		$state = DoomSim.tic($state, { ..DoomSim.neutral, forward: 50 }, blockers)
	}
	sector = DoomLevel.sector_at(map, { x: F32.to_f64($state.pos.x), y: F32.to_f64($state.pos.y) })
	$state.pos.x > 208 and sector == Ok(17)
}

expect {
	player = DoomWorld.player({ x: 0, y: 0 }, DoomSim.Angle.from_turns(0))
	doom : DoomWorld.World
	doom = { player, actors: [], pickups: [], rng: DoomWorld.Rng.seed(7) }
	command = { ..DoomSim.neutral, fire: Bool.True }
	whole = DoomRuntime.advance(DoomRuntime.initial(doom), DoomSim.tic_seconds * 8, command, []).world
	first = DoomRuntime.advance(DoomRuntime.initial(doom), DoomSim.tic_seconds * 3, command, []).world
	partitioned = DoomRuntime.advance(first, DoomSim.tic_seconds * 5, command, []).world
	whole.doom.player.ammo == partitioned.doom.player.ammo
		and whole.doom.rng.index() == partitioned.doom.rng.index()
			and whole.weapon == partitioned.weapon
				and whole.doom.player.sim.state.tic == partitioned.doom.player.sim.state.tic
}
