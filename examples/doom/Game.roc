## Pure gameplay for the Libre Doom slice. The authored level, progression,
## movement, combat, and win/lose rules have no host resources.
import rr.Math

Game := [].{
	Phase := [Playing, Won, Dead].{
		is_eq : _
	}
	PickupKind := [Ammo, Health, BlueKey].{
		is_eq : _
	}

	Enemy := { id : U64, pos : Math.Vec2, health : I64, cooldown : F32 }.{
		alive : Enemy -> Bool
		alive = |enemy| enemy.health > 0
	}
	Pickup := { id : U64, pos : Math.Vec2, kind : PickupKind, taken : Bool }
	Door := { rect : Math.Rect, open : Bool, requires_key : Bool }
	Player := { pos : Math.Vec2, yaw : F32, health : I64, ammo : I64, has_blue_key : Bool, shot_flash : F32, hurt_flash : F32 }
	World := { player : Player, enemies : List(Enemy), pickups : List(Pickup), door : Door, phase : Phase, elapsed : F32 }
	Input : { forward : F32, strafe : F32, turn : F32, shoot : Bool, use : Bool, restart : Bool, dt : F32 }

	initial : World
	initial = {
		player: { pos: { x: 2.5, y: 3.5 }, yaw: 0, health: 100, ammo: 12, has_blue_key: Bool.False, shot_flash: 0, hurt_flash: 0 },
		enemies: [
			{ id: 1, pos: { x: 6, y: 3.5 }, health: 3, cooldown: 0.5 },
			{ id: 2, pos: { x: 12, y: 4 }, health: 3, cooldown: 0.8 },
			{ id: 3, pos: { x: 14, y: 12.8 }, health: 3, cooldown: 0.4 },
			{ id: 4, pos: { x: 20, y: 8 }, health: 3, cooldown: 0.7 },
		],
		pickups: [
			{ id: 1, pos: { x: 5, y: 12 }, kind: BlueKey, taken: Bool.False },
			{ id: 2, pos: { x: 10.5, y: 7 }, kind: Ammo, taken: Bool.False },
			{ id: 3, pos: { x: 18.5, y: 13 }, kind: Health, taken: Bool.False },
		],
		door: { rect: key_door_rect, open: Bool.False, requires_key: Bool.True },
		phase: Playing,
		elapsed: 0,
	}

	## Three connected spaces: a start room, central combat room, and final room.
	walls : List(Math.Rect)
	walls = [
		Math.rect(0, 0, 24, 1),
		Math.rect(0, 15, 24, 1),
		Math.rect(0, 1, 1, 14),
		Math.rect(23, 1, 1, 14),
		Math.rect(8, 1, 1, 4),
		Math.rect(8, 8, 1, 7),
		Math.rect(16, 1, 1, 9),
		Math.rect(16, 12, 1, 3),
		Math.rect(11, 9, 3, 1),
	]
	key_door_rect : Math.Rect
	key_door_rect = Math.rect(8, 5, 1, 3)
	exit : Math.Rect
	exit = Math.rect(22, 12.5, 0.9, 1.8)

	step : World, Input -> World
	step = |world, input| {
		if input.restart and world.phase != Playing {
			initial
		} else if world.phase != Playing {
			{ ..world, elapsed: world.elapsed + clamped_dt(input.dt) }
		} else {
			dt = clamped_dt(input.dt)
			yaw = wrap_angle(world.player.yaw + input.turn)
			forward = { x: F32.cos(yaw), y: F32.sin(yaw) }
			right = { x: 0 - forward.y, y: forward.x }
			raw_move = Math.add(Math.scale(forward, input.forward), Math.scale(right, input.strafe))
			move = Math.scale(Math.normalize(raw_move), move_speed * dt)
			moved = move_player(world, world.player.pos, move)
			player0 = { ..world.player, pos: moved, yaw, shot_flash: tick(world.player.shot_flash, dt), hurt_flash: tick(world.player.hurt_flash, dt) }
			picked = collect_pickups(player0, world.pickups)
			door = if input.use and door_in_reach(picked.player, world.door) and door_authorized(picked.player, world.door) { ..world.door, open: Bool.True } else world.door
			shot = input.shoot and picked.player.ammo > 0
			player1 = if shot { ..picked.player, ammo: picked.player.ammo - 1, shot_flash: 0.12 } else picked.player
			enemies0 = if shot apply_shot(player1, world.enemies, door) else world.enemies
			enemy_step = advance_enemies(enemies0, player1, door, dt)
			player = if enemy_step.damage > 0 { ..player1, health: player1.health - enemy_step.damage, hurt_flash: 0.18 } else player1
			phase = if player.health <= 0 Dead else if all_enemies_dead(enemy_step.enemies) and player.has_blue_key and door.open and Math.contains(exit, player.pos) Won else Playing
			{ player, enemies: enemy_step.enemies, pickups: picked.pickups, door, phase, elapsed: world.elapsed + dt }
		}
	}

	CollectResult : { player : Player, pickups : List(Pickup) }
	collect_pickups : Player, List(Pickup) -> CollectResult
	collect_pickups = |player, pickups| {
		var $next_player = player
		var $next_pickups = []
		for pickup in pickups {
			if !(pickup.taken) and Math.distance($next_player.pos, pickup.pos) <= pickup_radius {
				$next_player = apply_pickup($next_player, pickup.kind)
				$next_pickups = List.append($next_pickups, { ..pickup, taken: Bool.True })
			} else {
				$next_pickups = List.append($next_pickups, pickup)
			}
		}
		{ player: $next_player, pickups: $next_pickups }
	}
	apply_pickup : Player, PickupKind -> Player
	apply_pickup = |player, kind|
		match kind {
			Ammo => { ..player, ammo: I64.min(player.ammo + 8, max_ammo) }
			Health => { ..player, health: I64.min(player.health + 35, max_health) }
			BlueKey => { ..player, has_blue_key: Bool.True }
		}

	door_in_reach : Player, Door -> Bool
	door_in_reach = |player, door| Math.distance(player.pos, Math.center(door.rect)) <= use_range
	door_authorized : Player, Door -> Bool
	door_authorized = |player, door| !(door.requires_key) or player.has_blue_key

	move_player : World, Math.Vec2, Math.Vec2 -> Math.Vec2
	move_player = |world, position, delta| {
		x_only = { x: position.x + delta.x, y: position.y }
		after_x = if collides(world.door, x_only, player_radius) position else x_only
		y_only = { x: after_x.x, y: after_x.y + delta.y }
		if collides(world.door, y_only, player_radius) after_x else y_only
	}
	collides : Door, Math.Vec2, F32 -> Bool
	collides = |door, position, radius| {
		circle = Math.circle(position, radius)
		List.any(walls, |wall| Math.circle_rect(circle, wall)) or (!(door.open) and Math.circle_rect(circle, door.rect))
	}

	apply_shot : Player, List(Enemy), Door -> List(Enemy)
	apply_shot = |player, enemies, door| {
		var $hit = Bool.False
		var $next = []
		for enemy in enemies {
			if !($hit) and enemy.alive() and shot_hits(player, enemy, door) {
				$hit = Bool.True
				$next = List.append($next, { ..enemy, health: enemy.health - 1 })
			} else {
				$next = List.append($next, enemy)
			}
		}
		$next
	}
	shot_hits : Player, Enemy, Door -> Bool
	shot_hits = |player, enemy, door| {
		to_enemy = Math.sub(enemy.pos, player.pos)
		distance = Math.length(to_enemy)
		facing = { x: F32.cos(player.yaw), y: F32.sin(player.yaw) }
		distance <= weapon_range and Math.dot(facing, Math.normalize(to_enemy)) >= aim_cosine and line_clear(player.pos, enemy.pos, door)
	}

	EnemyStep : { enemies : List(Enemy), damage : I64 }
	advance_enemies : List(Enemy), Player, Door, F32 -> EnemyStep
	advance_enemies = |enemies, player, door, dt| {
		var $damage = 0.I64
		var $next = []
		for enemy in enemies {
			if !(enemy.alive()) {
				$next = List.append($next, enemy)
			} else {
				distance = Math.distance(enemy.pos, player.pos)
				sees_player = distance <= enemy_notice_range and line_clear(enemy.pos, player.pos, door)
				candidate = if sees_player and distance > enemy_attack_range move_enemy(enemy.pos, player.pos, door, dt) else enemy.pos
				cooldown = tick(enemy.cooldown, dt)
				attacks = sees_player and Math.distance(candidate, player.pos) <= enemy_attack_range and cooldown <= 0
				if attacks {
					$damage = $damage + enemy_damage
				}
				$next = List.append($next, { ..enemy, pos: candidate, cooldown: if attacks enemy_attack_cooldown else cooldown })
			}
		}
		{ enemies: $next, damage: $damage }
	}
	move_enemy : Math.Vec2, Math.Vec2, Door, F32 -> Math.Vec2
	move_enemy = |position, target, door, dt| {
		delta = Math.scale(Math.normalize(Math.sub(target, position)), enemy_speed * dt)
		x_only = { x: position.x + delta.x, y: position.y }
		after_x = if collides(door, x_only, enemy_radius) position else x_only
		y_only = { x: after_x.x, y: after_x.y + delta.y }
		if collides(door, y_only, enemy_radius) after_x else y_only
	}

	line_clear : Math.Vec2, Math.Vec2, Door -> Bool
	line_clear = |from, to, door|
		List.all(
			List.map_with_index(List.repeat({}, line_samples), |_unit, index| U64.to_f32(index + 1) / U64.to_f32(line_samples + 1)),
			|amount| !(collides_point(Math.lerp_vec2(from, to, amount), door)),
		)
	collides_point : Math.Vec2, Door -> Bool
	collides_point = |point, door| List.any(walls, |wall| Math.contains(wall, point)) or (!(door.open) and Math.contains(door.rect, point))
	all_enemies_dead : List(Enemy) -> Bool
	all_enemies_dead = |enemies| List.all(enemies, |enemy| !(enemy.alive()))
	clamped_dt : F32 -> F32
	clamped_dt = |dt| Math.clamp(dt, 0, 0.05)
	tick : F32, F32 -> F32
	tick = |value, dt| F32.max(0, value - dt)
	wrap_angle : F32 -> F32
	wrap_angle = |angle| if angle > 3.1415927 angle - 6.2831855 else if angle < -3.1415927 angle + 6.2831855 else angle

	player_radius = 0.28
	enemy_radius = 0.26
	pickup_radius = 0.55
	use_range = 1.8
	move_speed = 4.2
	enemy_speed = 1.25
	enemy_notice_range = 8
	enemy_attack_range = 1.15
	enemy_attack_cooldown = 0.8
	enemy_damage = 8.I64
	weapon_range = 12
	aim_cosine = 0.985
	max_health = 100.I64
	max_ammo = 24.I64
	line_samples = 32.U64
}

neutral_input : Game.Input
neutral_input = { forward: 0, strafe: 0, turn: 0, shoot: Bool.False, use: Bool.False, restart: Bool.False, dt: 0 }

expect {
	world = { ..Game.initial, player: { ..Game.initial.player, pos: { x: 7.2, y: 6.5 } } }
	used = Game.step(world, { ..neutral_input, use: Bool.True })
	blocked = Game.move_player(used, used.player.pos, { x: 2, y: 0 })
	!(used.door.open) and blocked.x < 8
}

expect {
	at_key = { ..Game.initial, player: { ..Game.initial.player, pos: { x: 5, y: 12 } } }
	keyed = Game.step(at_key, neutral_input)
	near_door = { ..keyed, player: { ..keyed.player, pos: { x: 7.2, y: 6.5 } } }
	opened = Game.step(near_door, { ..neutral_input, use: Bool.True })
	keyed.player.has_blue_key and !(keyed.door.open) and opened.door.open
}

expect {
	enemy = { id: 99, pos: { x: 4, y: 3.5 }, health: 3, cooldown: 0 }
	player = { ..Game.initial.player, pos: { x: 3.2, y: 3.5 } }
	result = Game.advance_enemies([enemy], player, Game.initial.door, 0.05)
	result.damage == 8 and (List.get(result.enemies, 0) ?? enemy).cooldown > 0
}

expect {
	# At longer sight range the same bounded enemy pass advances toward the
	# player instead of attacking in place.
	enemy = { id: 99, pos: { x: 6, y: 3.5 }, health: 3, cooldown: 0 }
	player = { ..Game.initial.player, pos: { x: 2.5, y: 3.5 } }
	result = Game.advance_enemies([enemy], player, Game.initial.door, 0.05)
	moved = List.get(result.enemies, 0) ?? enemy
	moved.pos.x < enemy.pos.x and result.damage == 0
}

expect {
	# Pickup policy is typed and capped: health and ammunition can share a
	# location and are each consumed exactly once in the same bounded pass.
	player = { ..Game.initial.player, health: 80, ammo: 20 }
	pickups = [
		{ id: 10, pos: player.pos, kind: Health, taken: Bool.False },
		{ id: 11, pos: player.pos, kind: Ammo, taken: Bool.False },
	]
	collected = Game.collect_pickups(player, pickups)
	collected.player.health == 100 and collected.player.ammo == 24 and List.all(collected.pickups, |pickup| pickup.taken)
}

expect {
	# Deterministic complete route: key, door, four encounters, keyed exit.
	at_key = { ..Game.initial, player: { ..Game.initial.player, pos: { x: 5, y: 12 } } }
	keyed = Game.step(at_key, neutral_input)
	near_door = { ..keyed, player: { ..keyed.player, pos: { x: 7.2, y: 6.5 } } }
	opened = Game.step(near_door, { ..neutral_input, use: Bool.True })
	var $cleared = opened
	for enemy in opened.enemies {
		$cleared = { ..$cleared, player: { ..$cleared.player, pos: { x: enemy.pos.x - 1.5, y: enemy.pos.y }, yaw: 0 } }
		$cleared = Game.step($cleared, { ..neutral_input, shoot: Bool.True })
		$cleared = Game.step($cleared, { ..neutral_input, shoot: Bool.True })
		$cleared = Game.step($cleared, { ..neutral_input, shoot: Bool.True })
	}
	at_exit = { ..$cleared, player: { ..$cleared.player, pos: Math.center(Game.exit) } }
	finished = Game.step(at_exit, neutral_input)
	finished.phase == Won and Game.all_enemies_dead(finished.enemies)
}

expect {
	early = { ..Game.initial, player: { ..Game.initial.player, pos: Math.center(Game.exit) } }
	refused = Game.step(early, neutral_input)
	restarted = Game.step({ ..Game.initial, phase: Won }, { ..neutral_input, restart: Bool.True })
	refused.phase == Playing and restarted.phase == Playing and restarted.player.pos == Game.initial.player.pos and List.len(restarted.enemies) == 4
}
