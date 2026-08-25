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
	World : { doom : DoomWorld.World, skill : DoomWorld.Skill, projectiles : List(Projectile), explosions : List(Explosion), sound_origins : List(DoomSim.Vec2), aggro : List(Aggro), next_projectile_id : U64, weapon : WeaponState, secrets_found : U64, visited_secret_sectors : List(U64), phase : Phase }
	Advance : { world : World, tics : U64, dropped : Bool, fired : Bool, projectile_saturated : Bool }
	MapAdvance : { world : World, level : DoomLevel.State, tics : U64, dropped : Bool, fired : Bool, projectile_saturated : Bool }

	initial : DoomWorld.World -> World
	initial = |doom| initial_for_skill(doom, Medium)

	initial_for_skill : DoomWorld.World, DoomWorld.Skill -> World
	initial_for_skill = |doom, skill| {
		actors = if skill == Nightmare List.map(doom.actors, |actor| { ..actor, reaction_time: 0 }) else doom.actors
		doom1 = { ..doom, actors }
		{ doom: doom1, skill, projectiles: [], explosions: [], sound_origins: [], aggro: [], next_projectile_id: 0, weapon: { cooldown: 0, phase: 0 }, secrets_found: 0, visited_secret_sectors: [], phase: if doom.player.health <= 0 Dead else Playing }
	}

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
				$next = prepare_weapon($next, command.weapon_slot, command.fire)
				result = tic($next, command.fire, blockers)
				$next = result.world
				$saturated = $saturated or result.projectile_saturated
				$fired = $fired or result.fired
			}
			phase = if $next.doom.player.health <= 0 Dead else $next.phase
			{ world: { ..$next, phase }, tics: sim.tics, dropped: sim.dropped, fired: $fired, projectile_saturated: $saturated }
		}
	}

	advance_in_map : World, F32, DoomSim.Command, List(DoomSim.Segment), DoomMap.Map, DoomLevel.State -> MapAdvance
	advance_in_map = |world, elapsed, command, extra_blockers, map, level| {
		if world.phase != Playing {
			{ world, level, tics: 0, dropped: Bool.False, fired: Bool.False, projectile_saturated: Bool.False }
		} else {
			actor_blockers = actor_segments(world.doom.actors)
			sim = DoomSim.advance_with(
				world.doom.player.sim,
				elapsed,
				command,
				|state| List.concat(List.concat(blockers_for_player(map, level, state.pos), extra_blockers), actor_blockers),
			)
			var $next = { ..world, doom: { ..world.doom, player: { ..world.doom.player, sim: sim.clock } } }
			var $saturated = Bool.False
			var $fired = Bool.False
			var $level = level
			var $tic = sim.clock.state.tic - sim.tics + 1
			for _ in List.repeat({}, sim.tics) {
				$next = prepare_weapon($next, command.weapon_slot, command.fire)
				door_result = activate_monster_doors($next, map, $level)
				$level = door_result.level
				will_fire = command.fire and $next.weapon.cooldown == 0 and player_can_fire($next.doom.player)
				sources = if will_fire List.append($next.sound_origins, $next.doom.player.sim.state.pos) else $next.sound_origins
				heard0 = heard_actor_ids(map, sources, $next.doom.actors)
				heard = if will_fire List.append(heard0, player_sound_id) else heard0
				intercepts = List.concat(global_map_blockers(map, $level), extra_blockers)
				result = tic_hearing_in_map_with_intercepts($next, heard, extra_blockers, map, $level, intercepts, door_result.users)
				$next = discover_secret(apply_sector_hazard(result.world, map, $tic), map)
				$tic = $tic + 1
				$saturated = $saturated or result.projectile_saturated
				$fired = $fired or result.fired
			}
			phase = if $next.doom.player.health <= 0 Dead else $next.phase
			{ world: { ..$next, phase }, level: $level, tics: sim.tics, dropped: sim.dropped, fired: $fired, projectile_saturated: $saturated }
		}
	}

	tic_hearing_in_map : World, List(U64), List(DoomSim.Segment), DoomMap.Map, DoomLevel.State -> { world : World, projectile_saturated : Bool, fired : Bool }
	tic_hearing_in_map = |world, heard_actors, extra_blockers, map, level| {
		intercepts = List.concat(global_map_blockers(map, level), extra_blockers)
		tic_hearing_in_map_with_intercepts(world, heard_actors, extra_blockers, map, level, intercepts, [])
	}

	tic_hearing_in_map_with_intercepts = |world, heard_actors, extra_blockers, map, level, intercepts, door_users|
		{
			cache = actor_blocker_cache(map, level, world.doom.actors, extra_blockers)
			tic_hearing_with(world, heard_actors, intercepts, |actor| actor_blockers_from_cache(cache, map, level, actor.pos, extra_blockers), door_users)
		}

	tic : World, Bool, List(DoomSim.Segment) -> { world : World, projectile_saturated : Bool, fired : Bool }
	tic = |world, heard_shot, blockers| {
		heard = if heard_shot List.append(List.map(world.doom.actors, |actor| actor.id), player_sound_id) else []
		tic_hearing(world, heard, blockers)
	}

	tic_hearing : World, List(U64), List(DoomSim.Segment) -> { world : World, projectile_saturated : Bool, fired : Bool }
	tic_hearing = |world, heard_actors, blockers| {
		tic_hearing_with(world, heard_actors, blockers, |_actor| blockers, [])
	}

	activate_monster_doors = |world, map, level| {
		var $level = level
		var $users = []
		for actor in world.doom.actors {
			ready = actor.state.mode == Chase and actor.state.remaining <= 1 and actor.kind != Barrel
			if ready {
				target = aggro_target(world.aggro, actor.id, world.doom.actors)
				target_pos = match target {
					Ok(value) => value.pos
					Err(PlayerTarget) => world.doom.player.sim.state.pos
				}
				candidate = DoomWorld.chase_candidate(actor, target_pos)
				match DoomLevel.sector_at(map, { x: F32.to_f64(actor.pos.x), y: F32.to_f64(actor.pos.y) }) {
					Err(_) => {}
					Ok(sector) => match List.find_first(DoomLevel.collision_segments(map, $level, sector), |entry| {
						usable = match List.get(map.raw().linedefs, entry.linedef) {
							Ok(line) => line.special == 1 and !(DoomMap.line_flags(line.flags).secret)
							Err(_) => Bool.False
						}
						usable and DoomSim.circle_hits_segment(candidate, DoomWorld.actor_radius_for(actor.kind), collision_to_segment(entry.start, entry.end))
					}) {
						Err(_) => {}
						Ok(entry) => match DoomLevel.monster_use_line(map, $level, entry.linedef) {
							Activated(next) => {
								$level = next
								$users = List.append($users, actor.id)
							}
							_ => {}
						}
					}
				}
			}
		}
		{ level: $level, users: $users }
	}

	tic_hearing_with = |world, heard_actors, intercept_blockers, actor_blockers_for, door_users| {
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
			# Only the Chase transition that actually moves reads ActorFacts.blockers.
			# Avoid deriving sector geometry for sleeping, dead, attacking, or
			# countdown actors, which form most of the map population on each tic.
			actor_blockers = if actor.state.mode == Chase and actor.state.remaining <= 1 actor_blockers_for(actor) else []
			occupied = if actor.state.mode == Chase and actor.state.remaining <= 1 List.map(List.keep_if(world.doom.actors, |other| other.id != actor.id and other.state.mode != Dead), |other| { pos: other.pos, radius: DoomWorld.actor_radius_for(other.kind) }) else []
			target = aggro_target(world.aggro, actor.id, world.doom.actors)
			target_pos = match target {
				Ok(value) => value.pos
				Err(PlayerTarget) => player_pos
			}
			# Countdown states cannot observe sight until their final tic. Avoid a
			# full traversal of the map intercepts while their result is discarded.
			has_sight = if actor_needs_sight(actor) line_of_sight(actor.pos, target_pos, intercept_blockers) else Bool.False
			facts : DoomWorld.ActorFacts
			facts = { player_pos: target_pos, has_sight, heard_sound: List.contains(heard_actors, actor.id), blockers: actor_blockers, occupied, nightmare: world.skill == Nightmare, used_door: List.contains(door_users, actor.id) }
			turn = actor_turn_for_skill(actor, facts, $rng, world.skill)
			$rng = turn.rng
			moved = turn.actor.pos != actor.pos
			actor1 = if moved and actor_overlaps(turn.actor, world.doom.actors) { ..turn.actor, pos: actor.pos } else turn.actor
			if turn.attack_kind == ProjectileAttack {
				if List.len($projectiles) < max_projectiles {
					direction = DoomSim.normalize(DoomSim.sub(target_pos, actor1.pos))
					target_id = match target {
						Ok(value) => value.id
						Err(PlayerTarget) => player_sound_id
					}
					$projectiles = List.append($projectiles, { id: $next_id, owner: actor1.id, target: target_id, pos: actor1.pos, momentum: DoomSim.scale(direction, projectile_speed_for_skill(world.skill)), damage: turn.player_damage, remaining: projectile_lifetime })
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
		projectile_step = advance_projectiles($projectiles, player_pos, $actors, intercept_blockers, $rng)
		$rng = projectile_step.rng
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
		player0 = damage_player_for_skill(DoomWorld.tick_player_powers(world.doom.player), $damage + projectile_step.damage, world.skill)
		collected = if player0.health <= 0 { player: player0, pickups: world.doom.pickups } else collect_nearby(player0, world.doom.pickups, world.skill)
		doom = { ..world.doom, player: collected.player, actors: $actors, pickups: collected.pickups, rng: $rng }
		world0 = { ..world, doom, projectiles: projectile_step.projectiles, explosions: $explosions, sound_origins: $sound_origins, aggro: hit_result.aggro, next_projectile_id: $next_id, phase: if doom.player.health <= 0 Dead else world.phase }
		firing = List.contains(heard_actors, player_sound_id)
		fired_result = if firing and world.weapon.cooldown == 0 and doom.player.health > 0 fire(world0, intercept_blockers) else { world: world0, fired: Bool.False }
		death_result = resolve_deaths(world.doom.actors, fired_result.world, intercept_blockers)
		$saturated = $saturated or death_result.saturated
		resolved_world = if world.skill == Nightmare nightmare_respawns(death_result.world, intercept_blockers) else death_result.world
		cooldown = if fired_result.fired weapon_cadence(doom.player.weapon) - 1 else if world.weapon.cooldown > 0 world.weapon.cooldown - 1 else 0
		phase = if fired_result.fired 1 else if cooldown > 0 world.weapon.phase + 1 else 0
		{ world: { ..resolved_world, weapon: { cooldown, phase }, phase: if resolved_world.doom.player.health <= 0 Dead else resolved_world.phase }, projectile_saturated: $saturated, fired: fired_result.fired }
	}

	line_of_sight : DoomSim.Vec2, DoomSim.Vec2, List(DoomSim.Segment) -> Bool
	line_of_sight = |from, to, blockers| !List.any(blockers, |blocker| segments_cross(from, to, blocker.start, blocker.end))

	actor_turn_for_skill = |actor, facts, rng, skill| {
		first = DoomWorld.tick_actor_with(actor, facts, rng)
		fast_state = (actor.kind == Demon or actor.kind == Spectre) and (actor.state.mode == Chase or actor.state.mode == Attack or actor.state.mode == Pain)
		if skill != Nightmare or !(fast_state) {
			first
		} else {
			second = DoomWorld.tick_actor_with(first.actor, facts, first.rng)
			{
				actor: second.actor,
				rng: second.rng,
				player_damage: first.player_damage + second.player_damage,
				attack_kind: if first.attack_kind != NoAttack first.attack_kind else second.attack_kind,
			}
		}
	}

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
	use_forward = |map, level, pos, angle, keys|
		match usable_line_ahead(map, pos, angle) {
			Ok(index) => DoomLevel.use_line(map, level, index, keys)
			Err(NoUsableLine) => NotUsable
		}

	## The nearest special linedef within use reach of the facing direction.
	## Callers that press use repeatedly (replay and authoring harnesses) key
	## their edge detection on this so a moving door is not reversed every tic.
	usable_line_ahead : DoomMap.Map, DoomSim.Vec2, DoomSim.Angle -> Try(U64, [NoUsableLine])
	usable_line_ahead = |map, pos, angle| {
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
		$line
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

# Build one bounded intercept set per simulation tic. Each linedef appears at
# most once even though a two-sided boundary is discoverable from both sectors.
global_map_blockers = |map, level| {
	List.map(
		DoomLevel.global_collision_segments(map, level),
		|segment| {
			start: { x: F64.to_f32_wrap(segment.start.x), y: F64.to_f32_wrap(segment.start.y) },
			end: { x: F64.to_f32_wrap(segment.end.x), y: F64.to_f32_wrap(segment.end.y) },
		},
	)
}

actor_blocker_cache = |map, level, actors, extra_blockers| {
	var $cache = []
	for actor in actors {
		if actor.state.mode == Chase and actor.state.remaining <= 1 {
			match DoomLevel.sector_at(map, { x: F32.to_f64(actor.pos.x), y: F32.to_f64(actor.pos.y) }) {
				Err(_) => {}
				Ok(sector) => if !(List.any($cache, |entry| entry.sector == sector)) {
					map_blockers = DoomRuntime.blockers_for_player(map, level, actor.pos)
					$cache = List.append($cache, { sector, blockers: List.concat(map_blockers, extra_blockers) })
				}
			}
		}
	}
	$cache
}

actor_blockers_from_cache = |cache, map, level, pos, extra_blockers| {
	sector = DoomLevel.sector_at(map, { x: F32.to_f64(pos.x), y: F32.to_f64(pos.y) }) ?? return List.concat(List.map(map.blocking_segments(), |segment| to_segment(segment.start, segment.end)), extra_blockers)
	entry = List.find_first(cache, |candidate| candidate.sector == sector) ?? return List.concat(DoomRuntime.blockers_for_player(map, level, pos), extra_blockers)
	entry.blockers
}

to_segment = |start, end| { start: { x: I64.to_f32(start.x), y: I64.to_f32(start.y) }, end: { x: I64.to_f32(end.x), y: I64.to_f32(end.y) } }

collision_to_segment = |start, end| { start: { x: F64.to_f32_wrap(start.x), y: F64.to_f32_wrap(start.y) }, end: { x: F64.to_f32_wrap(end.x), y: F64.to_f32_wrap(end.y) } }

distance_to_segment_squared = |point, segment| {
	along = DoomSim.sub(segment.end, segment.start)
	length = DoomSim.length_squared(along)
	amount = if length <= 0 0 else F32.max(0, F32.min(1, DoomSim.dot(DoomSim.sub(point, segment.start), along) / length))
	DoomSim.distance_squared(point, DoomSim.add(segment.start, DoomSim.scale(along, amount)))
}

collect_nearby = |player, pickups, skill| {
	var $player = player
	var $pickups = []
	for pickup in pickups {
		if !(pickup.taken) and DoomSim.distance_squared(player.sim.state.pos, pickup.pos) <= DoomRuntime.player_pickup_radius * DoomRuntime.player_pickup_radius {
			result = DoomWorld.collect_for_skill($player, pickup, skill)
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
			r = DoomWorld.actor_radius_for(actor.kind)
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
	actor.state.mode != Dead and List.any(actors, |other| {
		distance = DoomWorld.actor_radius_for(actor.kind) + DoomWorld.actor_radius_for(other.kind)
		other.id != actor.id and other.state.mode != Dead and DoomSim.distance_squared(actor.pos, other.pos) < distance * distance
	})

actor_needs_sight : DoomWorld.Actor -> Bool
actor_needs_sight = |actor|
	actor.state.mode == Look
		or (actor.state.mode == Chase and actor.state.remaining <= 1)
		or (actor.state.mode == Attack and !(actor.state.attacked) and actor.state.remaining == DoomWorld.attack_action_remaining(actor.kind))

advance_projectiles = |projectiles, player_pos, actors, blockers, rng| {
	var $next = []
	var $damage = 0.I64
	var $impacts = []
	var $actor_hits = []
	var $rng = rng
	for projectile in projectiles {
		candidate = DoomSim.add(projectile.pos, projectile.momentum)
		path : DoomSim.Segment
		path = { start: projectile.pos, end: candidate }
		hits_wall = List.any(blockers, |blocker| projectile_hits_blocker(path, blocker))
		hits_player = projectile.target == DoomRuntime.player_sound_id and DoomSim.distance_to_segment_squared(player_pos, path) <= (DoomSim.player_radius + projectile_radius) * (DoomSim.player_radius + projectile_radius)
		hit_actor = projectile_actor_hit(projectile, actors, path)
		actor_before_player = match hit_actor {
			Ok(actor) => hits_player and DoomSim.distance_squared(path.start, actor.pos) < DoomSim.distance_squared(path.start, player_pos)
			Err(_) => Bool.False
		}
		# A blocking line owns the whole swept interval for this bounded tic. It
		# must win over a target behind it; otherwise missiles damage through doors.
		if hits_wall {
			$impacts = List.append($impacts, candidate)
		} else if hits_player and !(actor_before_player) {
			roll = DoomWorld.random($rng)
			$rng = roll.rng
			$damage = $damage + (U8.to_i64(roll.byte % 8) + 1) * projectile.damage
			$impacts = List.append($impacts, candidate)
		} else {
			match hit_actor {
				Ok(actor) => {
					roll = DoomWorld.random($rng)
					$rng = roll.rng
					$actor_hits = List.append($actor_hits, { source: projectile.owner, target: actor.id, damage: (U8.to_i64(roll.byte % 8) + 1) * projectile.damage })
					$impacts = List.append($impacts, candidate)
				}
				Err(_) => if projectile.remaining > 1 {
					$next = List.append($next, { ..projectile, pos: candidate, remaining: projectile.remaining - 1 })
				}
			}
		}
	}
	{ projectiles: $next, damage: $damage, impacts: $impacts, actor_hits: $actor_hits, rng: $rng }
}

# A projectile follows one straight segment per tic. The swept circle hits a
# blocker exactly when the two segments cross or an endpoint of either segment
# is within the projectile radius of the other. The bounding boxes reject the
# overwhelming majority of E1M1 linedefs before those distance calculations.
projectile_hits_blocker : DoomSim.Segment, DoomSim.Segment -> Bool
projectile_hits_blocker = |path, blocker| {
	radius = projectile_radius
	separated = F32.max(path.start.x, path.end.x) + radius < F32.min(blocker.start.x, blocker.end.x)
		or F32.max(blocker.start.x, blocker.end.x) + radius < F32.min(path.start.x, path.end.x)
		or F32.max(path.start.y, path.end.y) + radius < F32.min(blocker.start.y, blocker.end.y)
		or F32.max(blocker.start.y, blocker.end.y) + radius < F32.min(path.start.y, path.end.y)
	if separated {
		Bool.False
	} else {
		radius2 = radius * radius
		segments_cross(path.start, path.end, blocker.start, blocker.end)
			or DoomSim.distance_to_segment_squared(path.start, blocker) <= radius2
			or DoomSim.distance_to_segment_squared(path.end, blocker) <= radius2
			or DoomSim.distance_to_segment_squared(blocker.start, path) <= radius2
			or DoomSim.distance_to_segment_squared(blocker.end, path) <= radius2
	}
}

projectile_actor_hit : DoomRuntime.Projectile, List(DoomWorld.Actor), DoomSim.Segment -> Try(DoomWorld.Actor, [NoActorHit])
projectile_actor_hit = |projectile, actors, path| {
	var $hit = Err(NoActorHit)
	var $best = -1.F32
	for actor in actors {
		radius = DoomWorld.actor_radius_for(actor.kind) + projectile_radius
		if actor.id != projectile.owner and actor.state.mode != Dead and DoomSim.distance_to_segment_squared(actor.pos, path) <= radius * radius {
			distance = DoomSim.distance_squared(path.start, actor.pos)
			if $best < 0 or distance < $best {
				$best = distance
				$hit = Ok(actor)
			}
		}
	}
	$hit
}

aggro_target = |aggro, hunter, actors| {
	match List.find_first(aggro, |value| value.hunter == hunter) {
		Err(_) => Err(PlayerTarget)
		Ok(entry) =>
			match List.find_first(actors, |actor| actor.id == entry.target and actor.state.mode != Dead) {
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
		var $retarget = Bool.False
		for actor in $actors {
			if actor.id == hit.target and actor.state.mode != Dead {
				result = DoomWorld.damage_actor_random(actor, hit.damage, $rng)
				$rng = result.rng
				$retarget = actor.target_threshold == 0 and hit.source != actor.id and result.actor.state.mode != Dead
				retaliating = if $retarget and result.actor.state.mode == Look { ..result.actor, target_threshold: 100, state: DoomWorld.state_for(result.actor.kind, Chase) } else if $retarget { ..result.actor, target_threshold: 100 } else result.actor
				$next = List.append($next, retaliating)
			} else {
				$next = List.append($next, actor)
			}
		}
		$actors = $next
		if $retarget {
			$aggro = set_aggro($aggro, hit.target, hit.source, List.len(actors))
		}
	}
	{ actors: $actors, rng: $rng, aggro: $aggro }
}

# Resolve death actions at their state-defined points. Former humans drop their
# items on death; barrels apply radius damage when their explosion frame begins.
resolve_deaths = |previous, world, blockers| {
	var $actors = world.doom.actors
	var $pickups = world.doom.pickups
	var $player = world.doom.player
	var $rng = world.doom.rng
	var $explosions = world.explosions
	var $sounds = world.sound_origins
	previous_dead = List.map(List.keep_if(previous, |actor| actor.state.mode == Dead), |actor| actor.id)
	newly_dead = List.keep_if($actors, |actor| actor.state.mode == Dead and !(List.contains(previous_dead, actor.id)))
	for dead in newly_dead {
		drop_kind = match dead.kind {
			ZombieMan => Ok(DroppedClip)
			ShotgunGuy => Ok(DroppedShotgun)
			_ => Err(NoDrop)
		}
		match drop_kind {
			Ok(kind) => {
				$pickups = List.append($pickups, { id: List.len($pickups), kind, pos: dead.pos, taken: Bool.False })
			}
			Err(_) => {}
		}
	}
	var $pending = List.keep_if($actors, |actor| barrel_explosion_due(actor, previous))
	var $pending_index = 0.U64
	var $saturated = Bool.False
	while $pending_index < List.len($pending) {
		dead = List.get($pending, $pending_index) ?? crash "pending death index"
		$pending_index = $pending_index + 1
		if dead.kind == Barrel {
					if List.len($sounds) < DoomRuntime.max_sound_origins {
						$sounds = List.append($sounds, dead.pos)
					}
					var $damaged = []
					for actor in $actors {
						if actor.id != dead.id and actor.state.mode != Dead and DoomRuntime.line_of_sight(dead.pos, actor.pos, blockers) {
							damage = radius_damage(dead.pos, actor.pos, DoomWorld.actor_radius_for(actor.kind))
							if damage > 0 {
								result = DoomWorld.damage_actor_random(actor, damage, $rng)
								$rng = result.rng
								$damaged = List.append($damaged, result.actor)
							} else {
								$damaged = List.append($damaged, actor)
							}
						} else {
							$damaged = List.append($damaged, actor)
						}
					}
					$actors = $damaged
					if $player.health > 0 and DoomRuntime.line_of_sight(dead.pos, $player.sim.state.pos, blockers) {
						player_damage = radius_damage(dead.pos, $player.sim.state.pos, DoomWorld.player_collision_radius)
						$player = damage_player_for_skill($player, player_damage, world.skill)
					}
		}
	}
	doom = { ..world.doom, actors: $actors, pickups: $pickups, player: $player, rng: $rng }
	{ world: { ..world, doom, explosions: $explosions, sound_origins: $sounds }, saturated: $saturated }
}

barrel_explosion_due = |actor, previous| {
	if actor.kind != Barrel or actor.state.mode != Dead or actor.state.remaining > 11 {
		Bool.False
	} else {
		match List.find_first(previous, |old| old.id == actor.id) {
			Ok(old) => old.state.mode == Dead and old.state.remaining > 11
			Err(_) => Bool.False
		}
	}
}

radius_damage = |origin, target, radius| {
	dx = F32.abs(target.x - origin.x)
	dy = F32.abs(target.y - origin.y)
	distance = I64.max(0, F32.to_i64_wrap(F32.max(dx, dy)) - F32.to_i64_wrap(radius))
	I64.max(0, 128 - distance)
}

nightmare_respawns = |world, blockers| {
	# Corpses become eligible after twelve seconds, then make a low-probability
	# attempt on a 32-tic cadence. A blocked original spawn point refuses the
	# attempt without changing the corpse.
	if world.doom.player.sim.state.tic % 32 != 0 {
		world
	} else {
		var $actors = world.doom.actors
		var $rng = world.doom.rng
		var $next = []
		for actor in $actors {
			eligible = actor.state.mode == Dead and actor.kind != Barrel and actor.dead_tics >= 12 * DoomSim.tic_rate
			if eligible {
				roll = DoomWorld.random($rng)
				$rng = roll.rng
				radius = DoomWorld.actor_radius_for(actor.kind)
				occupied = DoomSim.distance_squared(actor.spawn_pos, world.doom.player.sim.state.pos) < (radius + DoomWorld.player_collision_radius) * (radius + DoomWorld.player_collision_radius)
					or List.any($actors, |other| {
						minimum = radius + DoomWorld.actor_radius_for(other.kind)
						other.id != actor.id and other.state.mode != Dead and DoomSim.distance_squared(actor.spawn_pos, other.pos) < minimum * minimum
					})
				blocked = DoomSim.any_collision(actor.spawn_pos, radius, blockers)
				if roll.byte <= 4 and !(occupied) and !(blocked) {
					fresh = DoomWorld.actor(actor.id, actor.kind, actor.spawn_pos, actor.spawn_angle, actor.ambush)
					$next = List.append($next, { ..fresh, reaction_time: 18 })
				} else {
					$next = List.append($next, actor)
				}
			} else {
				$next = List.append($next, actor)
			}
		}
		{ ..world, doom: { ..world.doom, actors: $next, rng: $rng } }
	}
}

set_aggro = |aggro, hunter, target, capacity| {
	without = List.keep_if(aggro, |value| value.hunter != hunter)
	if List.len(without) < capacity List.append(without, { hunter, target }) else without
}

advance_explosions = |explosions|
	List.keep_oks(explosions, |explosion| if explosion.remaining > 1 Ok({ ..explosion, remaining: explosion.remaining - 1 }) else Err(Expired))

projectile_speed = 10

projectile_speed_for_skill = |skill| if skill == Nightmare 20 else projectile_speed

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
				var $retarget = Bool.False
				for actor in world.doom.actors {
					if actor.id == id {
						result = DoomWorld.damage_actor_random(actor, shot.damage, $rng)
						$rng = result.rng
						$retarget = actor.target_threshold == 0 and result.actor.state.mode != Dead
						retaliating = if $retarget and result.actor.state.mode == Look { ..result.actor, target_threshold: 100, state: DoomWorld.state_for(result.actor.kind, Chase) } else if $retarget { ..result.actor, target_threshold: 100 } else result.actor
						$actors = List.append($actors, retaliating)
					} else {
						$actors = List.append($actors, actor)
					}
				}
				aggro = if $retarget set_aggro(world.aggro, id, DoomRuntime.player_sound_id, List.len($actors)) else world.aggro
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

prepare_weapon = |world, intent, firing| {
	requested = match intent {
		KeepWeapon => Err(NoWeaponRequest)
		SelectSlot(slot) => weapon_for_slot(slot)
	}
	selected = match requested {
		Ok(weapon) => if DoomWorld.owns(world.doom.player, weapon) Ok(weapon) else Err(NotOwned)
		Err(_) => if firing and !(player_can_fire(world.doom.player)) fallback_weapon(world.doom.player) else Err(KeepCurrent)
	}
	match selected {
		Err(_) => world
		Ok(weapon) => if weapon == world.doom.player.weapon {
			world
		} else {
			player = { ..world.doom.player, weapon }
			{ ..world, doom: { ..world.doom, player }, weapon: { ..world.weapon, phase: 0 } }
		}
	}
}

weapon_for_slot = |slot|
	match slot {
		2 => Ok(Pistol)
		3 => Ok(Shotgun)
		4 => Ok(Chaingun)
		5 => Ok(RocketLauncher)
		6 => Ok(PlasmaRifle)
		8 => Ok(Chainsaw)
		_ => Err(UnsupportedSlot)
	}

fallback_weapon = |player| {
	candidates = [PlasmaRifle, Chaingun, Shotgun, Pistol, Chainsaw, RocketLauncher]
	List.first(List.keep_if(candidates, |weapon| DoomWorld.owns(player, weapon) and weapon_has_ammo(player, weapon)))
}

weapon_has_ammo = |player, weapon|
	match weapon {
		Pistol => player.ammo.bullets > 0
		Shotgun => player.ammo.shells > 0
		Chaingun => player.ammo.bullets > 0
		RocketLauncher => player.ammo.rockets > 0
		PlasmaRifle => player.ammo.cells > 0
		Chainsaw => Bool.True
	}

apply_sector_hazard = |world, map, tic| {
	sector = DoomLevel.sector_at(map, { x: F32.to_f64(world.doom.player.sim.state.pos.x), y: F32.to_f64(world.doom.player.sim.state.pos.y) }) ?? return world
	raw_sector = List.get(map.raw().sectors, sector) ?? return world
	damage = if raw_sector.special == 7 and tic % 32 == 0 5 else 0
	if damage == 0 {
		world
	} else {
		player = damage_player_for_skill(world.doom.player, damage, world.skill)
		{ ..world, doom: { ..world.doom, player }, phase: if player.health <= 0 Dead else world.phase }
	}
}

discover_secret = |world, map| {
	pos = world.doom.player.sim.state.pos
	sector = DoomLevel.sector_at(map, { x: F32.to_f64(pos.x), y: F32.to_f64(pos.y) }) ?? return world
	value = List.get(map.raw().sectors, sector) ?? return world
	if value.special == 9 and !(List.contains(world.visited_secret_sectors, sector)) {
		{ ..world, secrets_found: world.secrets_found + 1, visited_secret_sectors: List.append(world.visited_secret_sectors, sector) }
	} else world
}

damage_player_for_skill = |player, damage, skill|
	DoomWorld.damage_player(player, if skill == Baby damage / 2 else damage)

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
	path : DoomSim.Segment
	path = { start: { x: 0, y: 0 }, end: { x: 100, y: 0 } }
	crossing : DoomSim.Segment
	crossing = { start: { x: 50, y: -20 }, end: { x: 50, y: 20 } }
	grazing : DoomSim.Segment
	grazing = { start: { x: 40, y: 6 }, end: { x: 60, y: 6 } }
	clear : DoomSim.Segment
	clear = { start: { x: 40, y: 6.01 }, end: { x: 60, y: 6.01 } }
	projectile_hits_blocker(path, crossing) and projectile_hits_blocker(path, grazing) and !(projectile_hits_blocker(path, clear))
}

expect {
	base = DoomWorld.actor(1, ZombieMan, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	actor_needs_sight(base)
		and !(actor_needs_sight({ ..base, state: { mode: Chase, remaining: 2, attacked: Bool.False } }))
		and actor_needs_sight({ ..base, state: { mode: Chase, remaining: 1, attacked: Bool.False } })
		and !(actor_needs_sight({ ..base, state: { mode: Attack, remaining: 17, attacked: Bool.False } }))
		and actor_needs_sight({ ..base, state: { mode: Attack, remaining: 16, attacked: Bool.False } })
		and !(actor_needs_sight({ ..base, state: { mode: Attack, remaining: 15, attacked: Bool.True } }))
		and !(actor_needs_sight({ ..base, state: DoomWorld.state(Dead) }))
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
	imp = { ..imp0, state: { mode: Attack, remaining: 6, attacked: Bool.False } }
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
	# A target overlapping a closed boundary must not win merely because both
	# contacts occur during the same bounded projectile tic.
	player = DoomWorld.player({ x: 10, y: 0 }, DoomSim.Angle.from_turns(0.5))
	projectile : DoomRuntime.Projectile
	projectile = { id: 0, owner: 1, target: DoomRuntime.player_sound_id, pos: { x: 0, y: 0 }, momentum: { x: 16, y: 0 }, damage: 12, remaining: 4 }
	wall : DoomSim.Segment
	wall = { start: { x: 4, y: -32 }, end: { x: 4, y: 32 } }
	step = advance_projectiles([projectile], player.sim.state.pos, [], [wall], DoomWorld.Rng.seed(0))
	step.damage == 0 and step.rng.index() == 0 and List.is_empty(step.projectiles) and List.len(step.impacts) == 1
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
	imp = { ..imp0, state: { mode: Attack, remaining: 6, attacked: Bool.False } }
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
	a = { ..a0, state: { mode: Chase, remaining: 1, attacked: Bool.False } }
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
	zombie = { ..zombie0, state: { mode: Attack, remaining: 16, attacked: Bool.False } }
	doom : DoomWorld.World
	doom = { player, actors: [zombie], pickups: [], rng: DoomWorld.Rng.seed(1) }
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
	attacker = { ..attacker0, state: { mode: Attack, remaining: 16, attacked: Bool.False } }
	victim = DoomWorld.actor(2, Imp, { x: 32, y: 0 }, DoomSim.Angle.from_turns(0.5), Bool.False)
	doom : DoomWorld.World
	doom = { player, actors: [attacker, victim], pickups: [], rng: DoomWorld.Rng.seed(0) }
	world = { ..DoomRuntime.initial(doom), aggro: [{ hunter: attacker.id, target: victim.id }] }
	next = DoomRuntime.tic_hearing(world, [], []).world
	victim1 = List.get(next.doom.actors, 1) ?? victim
	retaliates = List.any(next.aggro, |entry| entry.hunter == victim.id and entry.target == attacker.id)
	victim1.health < victim.health and victim1.target_threshold == 100 and victim1.reaction_time == 0 and retaliates and next.doom.player.health == player.health
}

expect {
	# Damage still lands while a retaliation target is committed, but a second
	# attacker cannot steal that target before its threshold expires.
	first = DoomWorld.actor(1, ZombieMan, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	second = DoomWorld.actor(2, Imp, { x: 32, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	victim0 = DoomWorld.actor(3, ShotgunGuy, { x: 64, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	victim = { ..victim0, target_threshold: 50 }
	result = apply_actor_hits([first, second, victim], [{ source: second.id, target: victim.id, damage: 1 }], DoomWorld.Rng.seed(0), [{ hunter: victim.id, target: first.id }])
	updated = List.get(result.actors, 2) ?? victim
	updated.health == victim.health - 1
		and updated.target_threshold == 50
		and List.contains(result.aggro, { hunter: victim.id, target: first.id })
		and !(List.contains(result.aggro, { hunter: victim.id, target: second.id }))
}

expect {
	player = DoomWorld.player({ x: 512, y: 0 }, DoomSim.Angle.from_turns(0.5))
	owner = DoomWorld.actor(1, Imp, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	victim = DoomWorld.actor(2, ZombieMan, { x: 24, y: 0 }, DoomSim.Angle.from_turns(0.5), Bool.False)
	projectile : DoomRuntime.Projectile
	projectile = { id: 0, owner: owner.id, target: victim.id, pos: { x: 0, y: 0 }, momentum: { x: 16, y: 0 }, damage: 3, remaining: 4 }
	step = advance_projectiles([projectile], player.sim.state.pos, [owner, victim], [], DoomWorld.Rng.seed(0))
	hit = List.get(step.actor_hits, 0) ?? crash "owned projectile missed actor"
	hit.source == owner.id and hit.target == victim.id and hit.damage == 3 and step.rng.index() == 1 and List.is_empty(step.projectiles)
}

expect {
	player = DoomWorld.player({ x: 512, y: 0 }, DoomSim.Angle.from_turns(0.5))
	owner = DoomWorld.actor(1, Imp, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	interceptor = DoomWorld.actor(2, ZombieMan, { x: 24, y: 0 }, DoomSim.Angle.from_turns(0.5), Bool.False)
	target = DoomWorld.actor(3, ZombieMan, { x: 48, y: 0 }, DoomSim.Angle.from_turns(0.5), Bool.False)
	projectile : DoomRuntime.Projectile
	projectile = { id: 0, owner: owner.id, target: target.id, pos: { x: 0, y: 0 }, momentum: { x: 40, y: 0 }, damage: 12, remaining: 4 }
	step = advance_projectiles([projectile], player.sim.state.pos, [owner, interceptor, target], [], DoomWorld.Rng.seed(0))
	hit = List.get(step.actor_hits, 0) ?? crash "intercepted projectile did not hit"
	hit.target == interceptor.id
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
	# Linedef 1049 deliberately renders as continuous sky, but sector 40 has no
	# vertical opening. The invisible boundary must still stop a radius-16
	# player approaching it from sector 29.
	map = DoomMap.e1m1
	level = DoomLevel.initial(map)
	var $state = DoomSim.initial({ x: -640, y: 256 }, DoomSim.Angle.from_turns(0.5))
	for _ in List.repeat({}, 20) {
		blockers = DoomRuntime.blockers_for_player(map, level, $state.pos)
		$state = DoomSim.tic($state, { ..DoomSim.neutral, forward: 50 }, blockers)
	}
	sector = DoomLevel.sector_at(map, { x: F32.to_f64($state.pos.x), y: F32.to_f64($state.pos.y) })
	$state.pos.x >= -656 and sector == Ok(29)
}

expect {
	# E1M1 sector 38 is damaging floor special 7: five damage on the global
	# 32-tic cadence, with normal armor absorption handled by player damage.
	player = DoomWorld.player({ x: 2124, y: 958 }, DoomSim.Angle.from_turns(0))
	doom : DoomWorld.World
	doom = { player, actors: [], pickups: [], rng: DoomWorld.Rng.seed(0) }
	world = DoomRuntime.initial(doom)
	safe = apply_sector_hazard(world, DoomMap.e1m1, 31)
	hurt = apply_sector_hazard(world, DoomMap.e1m1, 32)
	safe.doom.player.health == 100 and hurt.doom.player.health == 95
}

expect {
	# Lethal damage wins before pickup contact; a medikit under the player must
	# not resurrect them during the same simulation tic.
	player = { ..DoomWorld.player({ x: 0, y: 0 }, DoomSim.Angle.from_turns(0)), health: 1 }
	zombie0 = DoomWorld.actor(1, ZombieMan, { x: 32, y: 0 }, DoomSim.Angle.from_turns(0.5), Bool.False)
	zombie = { ..zombie0, state: { mode: Attack, remaining: 16, attacked: Bool.False } }
	medikit : DoomWorld.Pickup
	medikit = { id: 0, kind: MedikitPickup, pos: player.sim.state.pos, taken: Bool.False }
	doom : DoomWorld.World
	doom = { player, actors: [zombie], pickups: [medikit], rng: DoomWorld.Rng.seed(1) }
	next = DoomRuntime.tic(DoomRuntime.initial(doom), Bool.False, []).world
	item = List.get(next.doom.pickups, 0) ?? medikit
	next.phase == Dead and next.doom.player.health == 0 and !(item.taken)
}

expect {
	player = DoomWorld.player({ x: 0, y: 0 }, DoomSim.Angle.from_turns(0))
	medium = damage_player_for_skill(player, 15, Medium)
	baby = damage_player_for_skill(player, 15, Baby)
	medium.health == 85 and baby.health == 93
}

expect {
	# Nightmare removes the spawn reaction delay and halves the demon-family
	# state timing represented by two state advances per simulation tic.
	player = DoomWorld.player({ x: 256, y: 0 }, DoomSim.Angle.from_turns(0))
	base = DoomWorld.actor(1, Demon, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	actor = { ..base, state: DoomWorld.state_for(Demon, Chase) }
	doom : DoomWorld.World
	doom = { player, actors: [actor], pickups: [], rng: DoomWorld.Rng.seed(0) }
	medium = DoomRuntime.tic(DoomRuntime.initial_for_skill(doom, Medium), Bool.False, []).world
	nightmare0 = DoomRuntime.initial_for_skill(doom, Nightmare)
	nightmare = DoomRuntime.tic(nightmare0, Bool.False, []).world
	medium_actor = List.get(medium.doom.actors, 0) ?? actor
	nightmare_actor = List.get(nightmare.doom.actors, 0) ?? actor
	initial_actor = List.get(nightmare0.doom.actors, 0) ?? actor
	initial_actor.reaction_time == 0
		and medium_actor.state.mode == Chase
		and medium_actor.state.remaining == 1
		and medium_actor.pos == actor.pos
		and nightmare_actor.state.mode == Chase
		and nightmare_actor.pos != actor.pos
}

expect {
	# Enemy missiles use the fast skill profile's doubled horizontal speed.
	player = DoomWorld.player({ x: 256, y: 0 }, DoomSim.Angle.from_turns(0))
	base = DoomWorld.actor(1, Imp, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	attacker = { ..base, state: { mode: Attack, remaining: 6, attacked: Bool.False } }
	doom : DoomWorld.World
	doom = { player, actors: [attacker], pickups: [], rng: DoomWorld.Rng.seed(0) }
	medium = DoomRuntime.tic(DoomRuntime.initial_for_skill(doom, Medium), Bool.False, []).world
	nightmare = DoomRuntime.tic(DoomRuntime.initial_for_skill(doom, Nightmare), Bool.False, []).world
	medium_projectile = List.get(medium.projectiles, 0) ?? crash "medium projectile missing"
	nightmare_projectile = List.get(nightmare.projectiles, 0) ?? crash "nightmare projectile missing"
	DoomSim.length(medium_projectile.momentum) == 10 and DoomSim.length(nightmare_projectile.momentum) == 20
}

expect {
	base = DoomWorld.player({ x: 0, y: 0 }, DoomSim.Angle.from_turns(0))
	player = { ..base, weapon: Shotgun, weapons: { ..base.weapons, shotgun: Bool.True }, ammo: { ..base.ammo, bullets: 2, shells: 0 } }
	doom : DoomWorld.World
	doom = { player, actors: [], pickups: [], rng: DoomWorld.Rng.seed(0) }
	advanced = DoomRuntime.advance(DoomRuntime.initial(doom), DoomSim.tic_seconds, { ..DoomSim.neutral, fire: Bool.True }, [])
	advanced.fired and advanced.world.doom.player.weapon == Pistol and advanced.world.doom.player.ammo.bullets == 1
}

expect {
	base = DoomWorld.player({ x: 0, y: 0 }, DoomSim.Angle.from_turns(0))
	owned = { ..base, weapons: { ..base.weapons, chaingun: Bool.True } }
	doom : DoomWorld.World
	doom = { player: owned, actors: [], pickups: [], rng: DoomWorld.Rng.seed(0) }
	selected = DoomRuntime.advance(DoomRuntime.initial(doom), DoomSim.tic_seconds, { ..DoomSim.neutral, weapon_slot: SelectSlot(4) }, []).world
	ignored = DoomRuntime.advance(DoomRuntime.initial(doom), DoomSim.tic_seconds, { ..DoomSim.neutral, weapon_slot: SelectSlot(6) }, []).world
	selected.doom.player.weapon == Chaingun and ignored.doom.player.weapon == Pistol
}

expect {
	# E1M1 linedef 55 separates sectors 9/10. The player is not used to derive
	# the actor's blockers: closed global intercepts keep this actor asleep, and
	# the same sight line wakes it after the door has fully opened.
	map = DoomMap.e1m1
	closed_level = DoomLevel.initial(map)
	player = DoomWorld.player({ x: 832, y: 520 }, DoomSim.Angle.from_turns(0.25))
	actor = DoomWorld.actor(1, ZombieMan, { x: 832, y: 568 }, DoomSim.Angle.from_turns(0.75), Bool.False)
	doom : DoomWorld.World
	doom = { player, actors: [actor], pickups: [], rng: DoomWorld.Rng.seed(0) }
	closed = DoomRuntime.tic_hearing_in_map(DoomRuntime.initial(doom), [], [], map, closed_level).world
	activated = DoomLevel.use_line(map, closed_level, 55, { blue: Bool.False, yellow: Bool.False, red: Bool.False })
	var $open_level = match activated {
		Activated(value) => value
		_ => crash "E1M1 door 55 did not activate"
	}
	for _ in List.repeat({}, 80) {
		$open_level = DoomLevel.tick($open_level)
	}
	opened = DoomRuntime.tic_hearing_in_map(DoomRuntime.initial(doom), [], [], map, $open_level).world
	closed_actor = List.get(closed.doom.actors, 0) ?? actor
	opened_actor = List.get(opened.doom.actors, 0) ?? actor
	closed_actor.state.mode == Look and opened_actor.state.mode == Chase
}

expect {
	# A ready chasing monster whose direct step contacts E1M1's ordinary door
	# returns the activated level state from map-backed advancement.
	map = DoomMap.e1m1
	level = DoomLevel.initial(map)
	player = DoomWorld.player({ x: 832, y: 512 }, DoomSim.Angle.from_turns(0.25))
	base = DoomWorld.actor(1, ZombieMan, { x: 832, y: 568 }, DoomSim.Angle.from_turns(0.75), Bool.False)
	actor = { ..base, reaction_time: 0, state: { mode: Chase, remaining: 1, attacked: Bool.False } }
	doom : DoomWorld.World
	doom = { player, actors: [actor], pickups: [], rng: DoomWorld.Rng.seed(0) }
	advanced = DoomRuntime.advance_in_map(DoomRuntime.initial(doom), DoomSim.tic_seconds, DoomSim.neutral, [], map, level)
	after = List.get(advanced.world.doom.actors, 0) ?? actor
	List.len(advanced.level.doors) == 1 and after.pos == actor.pos and after.move_dir == -1 and after.move_count == 8
}

expect {
	player = DoomWorld.player({ x: 508, y: 800 }, DoomSim.Angle.from_turns(0))
	doom : DoomWorld.World
	doom = { player, actors: [], pickups: [], rng: DoomWorld.Rng.seed(0) }
	initial = DoomRuntime.initial(doom)
	first = discover_secret(initial, DoomMap.e1m1)
	second = discover_secret(first, DoomMap.e1m1)
	first.secrets_found == 1 and second.secrets_found == 1 and List.len(second.visited_secret_sectors) == 1
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

expect {
	# A newly killed former human drops one item, and an already dead actor does
	# not produce the drop again on a later resolution pass.
	player = DoomWorld.player({ x: 256, y: 0 }, DoomSim.Angle.from_turns(0))
	alive = DoomWorld.actor(1, ZombieMan, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	dead = DoomWorld.damage_actor(alive, 100)
	doom : DoomWorld.World
	doom = { player, actors: [dead], pickups: [], rng: DoomWorld.Rng.seed(0) }
	first = resolve_deaths([alive], DoomRuntime.initial(doom), [])
	second = resolve_deaths([dead], first.world, [])
	drop = List.get(second.world.doom.pickups, 0) ?? crash "missing former-human drop"
	List.len(second.world.doom.pickups) == 1 and drop.kind == DroppedClip and drop.pos == dead.pos
}

expect {
	# A barrel explodes at its death action point. A nearby barrel killed by that
	# blast waits for its own action point before continuing the cascade.
	player0 = DoomWorld.player({ x: 100, y: 0 }, DoomSim.Angle.from_turns(0))
	player = { ..player0, health: 200 }
	first_alive = DoomWorld.actor(1, Barrel, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	second_alive = DoomWorld.actor(2, Barrel, { x: 50, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	first_dead0 = DoomWorld.damage_actor(first_alive, 100)
	first_before = { ..first_dead0, state: { ..first_dead0.state, remaining: 12 } }
	first_action = { ..first_dead0, state: { ..first_dead0.state, remaining: 11 } }
	doom : DoomWorld.World
	doom = { player, actors: [first_action, second_alive], pickups: [], rng: DoomWorld.Rng.seed(0) }
	first_result = resolve_deaths([first_before, second_alive], DoomRuntime.initial(doom), [])
	second_dead = List.get(first_result.world.doom.actors, 1) ?? second_alive
	second_before = { ..second_dead, state: { ..second_dead.state, remaining: 12 } }
	second_action = { ..second_dead, state: { ..second_dead.state, remaining: 11 } }
	second_world = { ..first_result.world, doom: { ..first_result.world.doom, actors: [first_action, second_action] } }
	second_result = resolve_deaths([first_action, second_before], second_world, [])
	second_dead.state.mode == Dead
		and List.is_empty(second_result.world.explosions)
		and List.len(first_result.world.sound_origins) == 1
		and List.len(second_result.world.sound_origins) == 2
		and second_result.world.doom.player.health < player.health
}

expect {
	# An eligible Nightmare corpse respawns at its original map position with
	# restored health and the post-respawn reaction delay.
	player0 = DoomWorld.player({ x: 256, y: 0 }, DoomSim.Angle.from_turns(0))
	player = { ..player0, sim: { ..player0.sim, state: { ..player0.sim.state, tic: 32 } } }
	spawned = DoomWorld.actor(1, ZombieMan, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0.25), Bool.True)
	moved = { ..spawned, pos: { x: 100, y: 0 } }
	dead0 = DoomWorld.damage_actor(moved, 100)
	dead = { ..dead0, dead_tics: 12 * DoomSim.tic_rate }
	doom : DoomWorld.World
	doom = { player, actors: [dead], pickups: [], rng: DoomWorld.Rng.seed(65) }
	result = nightmare_respawns(DoomRuntime.initial_for_skill(doom, Nightmare), [])
	actor = List.get(result.doom.actors, 0) ?? dead
	actor.state.mode == Look
		and actor.pos == spawned.pos
		and actor.health == 20
		and actor.reaction_time == 18
		and actor.ambush
}

expect {
	# Respawn attempts preserve the corpse when its original position is
	# occupied, while still consuming the scheduled gameplay random byte.
	player0 = DoomWorld.player({ x: 0, y: 0 }, DoomSim.Angle.from_turns(0))
	player = { ..player0, sim: { ..player0.sim, state: { ..player0.sim.state, tic: 32 } } }
	alive = DoomWorld.actor(1, Imp, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	dead0 = DoomWorld.damage_actor(alive, 1000)
	dead = { ..dead0, dead_tics: 12 * DoomSim.tic_rate }
	doom : DoomWorld.World
	doom = { player, actors: [dead], pickups: [], rng: DoomWorld.Rng.seed(65) }
	result = nightmare_respawns(DoomRuntime.initial_for_skill(doom, Nightmare), [])
	actor = List.get(result.doom.actors, 0) ?? dead
	actor.state.mode == Dead and result.doom.rng.index() == 66
}
