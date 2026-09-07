## Player movement, facing, dash timing, animation, and damage recovery.
import rr.Math
import rr.Sprite

dash_cooldown_time = 0.62.F32

dash_duration = 0.18.F32

Player := {
	pos : Math.Vec2,
	invuln : F32,
	dash_cooldown : F32,
	dash_timer : F32,
	animation : Sprite.Animation,
	facing : Facing,
}.{
	Facing := [North, NorthEast, East, SouthEast, South, SouthWest, West, NorthWest]

	Step : {
		pos : Math.Vec2,
		raw_dir : Math.Vec2,
		move_dir : Math.Vec2,
		dash_started : Bool,
		dash_active : Bool,
		dt : F32,
	}

	radius = 22.F32
	speed = 330.F32
	dash_speed = 760.F32

	## Creates a player at the level spawn facing east.
	new : Math.Vec2 -> Player
	new = |pos| {
		pos,
		invuln: 0,
		dash_cooldown: 0,
		dash_timer: 0,
		animation: Sprite.animation({ frame_count: 4, fps: 10 }),
		facing: East,
	}

	## Returns the player's circular collision body.
	circle : Player -> Math.Circle
	circle = |player| Math.circle(player.pos, radius)

	## Returns the unit direction represented by the current facing.
	facing_dir : Player -> Math.Vec2
	facing_dir = |player| facing_to_vec(player.facing)

	## Returns the sprite rotation represented by the current facing.
	rotation : Player -> F32
	rotation = |player| facing_to_rotation(player.facing)

	## Reports whether the dash cooldown has finished.
	dash_ready : Player -> Bool
	dash_ready = |player| player.dash_cooldown <= 0

	## Reports whether the player is currently dashing.
	dash_active : Player -> Bool
	dash_active = |player| player.dash_timer > 0

	## Returns normalized dash recharge progress for the HUD.
	dash_charge : Player -> F32
	dash_charge = |player| if player.dash_ready() 1 else 1 - player.dash_cooldown / dash_cooldown_time

	## Applies one movement result to timers, animation, and facing.
	step : Player, Step -> Player
	step = |player, frame| {
		raw_moving = is_moving(frame.raw_dir)
		move_moving = is_moving(frame.move_dir)
		{
			..player,
			pos: frame.pos,
			invuln: tick_timer(player.invuln, frame.dt),
			dash_cooldown: if frame.dash_started dash_cooldown_time else tick_timer(player.dash_cooldown, frame.dt),
			dash_timer: if frame.dash_started dash_duration else tick_timer(player.dash_timer, frame.dt),
			animation: if move_moving Sprite.step(player.animation, frame.dt) else idle_animation(player.animation),
			facing: if frame.dash_active and !(raw_moving) player.facing else facing_from_input(frame.raw_dir, player.facing),
		}
	}

	## Returns the player at spawn with temporary invulnerability after damage.
	damage_respawn : Player, Math.Vec2 -> Player
	damage_respawn = |player, respawn_pos| {
		..player,
		pos: respawn_pos,
		invuln: 1.2,
		dash_timer: 0,
		facing: East,
	}
}

## Reports whether an input vector requests movement.
is_moving : Math.Vec2 -> Bool
is_moving = |dir| dir.x != 0 or dir.y != 0

## Chooses an eight-way facing from movement input.
facing_from_input : Math.Vec2, Player.Facing -> Player.Facing
facing_from_input = |dir, fallback| {
	if dir.y < 0 and dir.x == 0 {
		North
	} else if dir.y < 0 and dir.x > 0 {
		NorthEast
	} else if dir.x > 0 and dir.y == 0 {
		East
	} else if dir.x > 0 and dir.y > 0 {
		SouthEast
	} else if dir.y > 0 and dir.x == 0 {
		South
	} else if dir.x < 0 and dir.y > 0 {
		SouthWest
	} else if dir.x < 0 and dir.y == 0 {
		West
	} else if dir.x < 0 and dir.y < 0 {
		NorthWest
	} else {
		fallback
	}
}

## Converts an eight-way facing into a movement vector.
facing_to_vec : Player.Facing -> Math.Vec2
facing_to_vec = |facing|
	match facing {
		North => { x: 0, y: -1 }
		NorthEast => { x: 0.7, y: -0.7 }
		East => { x: 1, y: 0 }
		SouthEast => { x: 0.7, y: 0.7 }
		South => { x: 0, y: 1 }
		SouthWest => { x: -0.7, y: 0.7 }
		West => { x: -1, y: 0 }
		NorthWest => { x: -0.7, y: -0.7 }
	}

## Converts an eight-way facing into sprite degrees.
facing_to_rotation : Player.Facing -> F32
facing_to_rotation = |facing|
	match facing {
		North => -90
		NorthEast => -45
		East => 0
		SouthEast => 45
		South => 90
		SouthWest => 135
		West => 180
		NorthWest => 225
	}

## Resets a stopped player's animation to its first frame.
idle_animation : Sprite.Animation -> Sprite.Animation
idle_animation = |animation| { frame: 0, frame_count: animation.frame_count, fps: animation.fps, elapsed: 0 }

## Counts a positive timer down without crossing below zero.
tick_timer : F32, F32 -> F32
tick_timer = |timer, dt| if timer <= dt 0 else timer - dt
