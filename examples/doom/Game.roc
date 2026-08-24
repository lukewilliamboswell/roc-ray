## Pure gameplay for the Libre Doom vertical slice. The room layout, movement,
## combat, and win/lose loop deliberately have no host resources so they can be
## tested without opening a window.
import rr.Math

Game := [].{
	Phase := [Playing, Won, Dead].{
		is_eq : _
	}

	Enemy := {
		pos : Math.Vec2,
		health : I64,
		cooldown : F32,
	}.{
		alive : Enemy -> Bool
		alive = |enemy| enemy.health > 0
	}

	Pickup := {
		pos : Math.Vec2,
		taken : Bool,
	}

	Player := {
		pos : Math.Vec2,
		yaw : F32,
		health : I64,
		ammo : I64,
		shot_flash : F32,
		hurt_flash : F32,
	}

	World := {
		player : Player,
		enemy : Enemy,
		pickup : Pickup,
		phase : Phase,
		elapsed : F32,
	}

	Input : {
		forward : F32,
		strafe : F32,
		turn : F32,
		shoot : Bool,
		restart : Bool,
		dt : F32,
	}

	initial : World
	initial = {
		player: { pos: { x: 2.5, y: 3.5 }, yaw: 0, health: 100, ammo: 8, shot_flash: 0, hurt_flash: 0 },
		enemy: { pos: { x: 10.5, y: 3.5 }, health: 3, cooldown: 0.6 },
		pickup: { pos: { x: 5.5, y: 8.5 }, taken: Bool.False },
		phase: Playing,
		elapsed: 0,
	}

	## The level is a large room with a central divider. These rectangles are
	## also the source geometry for the drawing adapter in `main.roc`.
	walls : List(Math.Rect)
	walls = [
		Math.rect(0, 0, 14, 1),
		Math.rect(0, 10, 14, 1),
		Math.rect(0, 1, 1, 9),
		Math.rect(13, 1, 1, 9),
		Math.rect(6, 1, 1, 5),
		Math.rect(6, 8, 1, 2),
	]

	exit : Math.Rect
	exit = Math.rect(12.2, 8.2, 0.7, 1.5)

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
			moved = move_player(world.player.pos, move)
			player0 = {
				..world.player,
				pos: moved,
				yaw,
				shot_flash: tick(world.player.shot_flash, dt),
				hurt_flash: tick(world.player.hurt_flash, dt),
			}

			picked = !(world.pickup.taken) and Math.distance(moved, world.pickup.pos) <= pickup_radius
			player1 = if picked { ..player0, ammo: I64.min(player0.ammo + 6, 20) } else player0
			pickup = if picked { ..world.pickup, taken: Bool.True } else world.pickup

			shot = input.shoot and player1.ammo > 0
			hit = shot and world.enemy.alive() and shot_hits(player1, world.enemy)
			player2 = if shot { ..player1, ammo: player1.ammo - 1, shot_flash: 0.12 } else player1
			enemy0 = if hit { ..world.enemy, health: world.enemy.health - 1 } else world.enemy

			enemy_range = Math.distance(player2.pos, enemy0.pos)
			enemy_can_attack = enemy0.alive() and enemy_range < 6 and line_clear(player2.pos, enemy0.pos)
			damage = enemy_can_attack and enemy0.cooldown <= 0
			enemy = { ..enemy0, cooldown: if damage 0.75 else tick(enemy0.cooldown, dt) }
			player = if damage { ..player2, health: player2.health - 10, hurt_flash: 0.18 } else player2

			phase = if player.health <= 0 Dead else if !(enemy.alive()) and Math.contains(exit, player.pos) Won else Playing
			{ player, enemy, pickup, phase, elapsed: world.elapsed + dt }
		}
	}

	move_player : Math.Vec2, Math.Vec2 -> Math.Vec2
	move_player = |position, delta| {
		x_only = { x: position.x + delta.x, y: position.y }
		after_x = if collides(x_only) position else x_only
		y_only = { x: after_x.x, y: after_x.y + delta.y }
		if collides(y_only) after_x else y_only
	}

	collides : Math.Vec2 -> Bool
	collides = |position| List.any(walls, |wall| Math.circle_rect(Math.circle(position, player_radius), wall))

	shot_hits : Player, Enemy -> Bool
	shot_hits = |player, enemy| {
		to_enemy = Math.sub(enemy.pos, player.pos)
		distance = Math.length(to_enemy)
		facing = { x: F32.cos(player.yaw), y: F32.sin(player.yaw) }
		distance <= weapon_range
			and Math.dot(facing, Math.normalize(to_enemy)) >= aim_cosine
				and line_clear(player.pos, enemy.pos)
	}

	line_clear : Math.Vec2, Math.Vec2 -> Bool
	line_clear = |from, to| {
		# A bounded sample is sufficient for this authored axis-aligned room and
		# keeps visibility policy entirely in Roc.
		List.all(
			List.map_with_index(List.repeat({}, 16), |_unit, index| U64.to_f32(index + 1) / 17),
			|amount| !(collides_point(Math.lerp_vec2(from, to, amount))),
		)
	}

	collides_point : Math.Vec2 -> Bool
	collides_point = |point| List.any(walls, |wall| Math.contains(wall, point))

	clamped_dt : F32 -> F32
	clamped_dt = |dt| Math.clamp(dt, 0, 0.05)

	tick : F32, F32 -> F32
	tick = |value, dt| F32.max(0, value - dt)

	wrap_angle : F32 -> F32
	wrap_angle = |angle| {
		full = 6.2831855
		if angle > 3.1415927 angle - full else if angle < -3.1415927 angle + full else angle
	}

	player_radius = 0.28
	pickup_radius = 0.55
	move_speed = 4.2
	weapon_range = 12
	aim_cosine = 0.985
}

expect {
	world = Game.initial
	blocked = Game.step(world, { forward: -1, strafe: 0, turn: 0, shoot: Bool.False, restart: Bool.False, dt: 1 })
	blocked.player.pos.x > 1
}

expect {
	world = { ..Game.initial, player: { ..Game.initial.player, pos: { x: 8, y: 3.5 } } }
	after = Game.step(world, { forward: 0, strafe: 0, turn: 0, shoot: Bool.True, restart: Bool.False, dt: 0.016 })
	after.enemy.health == 2 and after.player.ammo == 7 and after.player.shot_flash > 0
}

expect {
	# The divider blocks shots even when an enemy is geometrically in front.
	player = { ..Game.initial.player, pos: { x: 4, y: 3 }, yaw: 0 }
	enemy = { ..Game.initial.enemy, pos: { x: 8, y: 3 } }
	!(Game.shot_hits(player, enemy))
}

expect {
	dead = { ..Game.initial, phase: Dead }
	Game.step(dead, { forward: 0, strafe: 0, turn: 0, shoot: Bool.False, restart: Bool.True, dt: 0 }).phase == Playing
}
