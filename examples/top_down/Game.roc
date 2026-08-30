## Pure Spark Run world updates and their ordered gameplay events.
import rr.Math
import Hazard
import Level
import Player
import Spark

Game := [].{
	State := [Playing, Won, GameOver].{
		is_eq : _
	}
	Gate := [GateLocked, GateOpen].{
		is_eq : _

		## Reports whether every spark has unlocked the exit gate.
		is_open : Gate -> Bool
		is_open = |gate|
			match gate {
				GateLocked => Bool.False
				GateOpen => Bool.True
			}
	}
	Controls : { move : Math.Vec2, dash_pressed : Bool, restart_pressed : Bool, quit_pressed : Bool }
	World : {
		player : Player,
		sparks : List(Spark),
		score : U64,
		lives : U64,
		phase : F32,
		shake : F32,
		flash : F32,
		burst_pos : Math.Vec2,
		burst_timer : F32,
		gate : Gate,
		gate_flash : F32,
		state : State,
	}
	Event := [DashStarted(Math.Vec2), SparkCollected(Spark), GateOpened, Escaped, Damaged(State), GameStarted].{
		is_eq : _
	}
	burst_duration = 0.36.F32

	## Creates a playing world from immutable level spawn data.
	new : Level -> World
	new = |level| {
		player: Player.new(level.spawn),
		sparks: level.sparks,
		score: 0,
		lives: 3,
		phase: 0,
		shake: 0,
		flash: 0,
		burst_pos: level.spawn,
		burst_timer: 0,
		gate: GateLocked,
		gate_flash: 0,
		state: Playing,
	}

	## Advances gameplay or restarts a finished run and returns ordered events.
	update : Level, World, Controls, F32 -> (World, List(Event))
	update = |level, world, controls, dt|
		match world.state {
			Playing => advance_world(level, world, controls, dt)
			Won => restart_if_requested(level, world, controls)
			GameOver => restart_if_requested(level, world, controls)
		}
}

CollectResult : { world : Game.World, collected : Try(Spark, [NoSpark]), gate_opened : Bool }

EscapeResult : { world : Game.World, escaped : Bool }

DamageResult : { world : Game.World, damaged : Bool }

## Restarts a finished run when the semantic restart control is pressed.
restart_if_requested : Level, Game.World, Game.Controls -> (Game.World, List(Game.Event))
restart_if_requested = |level, world, controls| if controls.restart_pressed (Game.new(level), [GameStarted]) else (world, [])

## Keeps a proposed player center inside the authored world bounds.
clamp_to_world : Level, Math.Vec2 -> Math.Vec2
clamp_to_world = |level, pos| {
	x: Math.clamp(pos.x, Math.left(level.bounds) + Player.radius, Math.right(level.bounds) - Player.radius),
	y: Math.clamp(pos.y, Math.top(level.bounds) + Player.radius, Math.bottom(level.bounds) - Player.radius),
}

## Reports whether a player circle touches an object or solid tile.
any_obstacle_hit : Level, Math.Circle -> Bool
any_obstacle_hit = |level, circle| {
	var $hit = Bool.False
	for obstacle in level.obstacles {
		if obstacle.hit_by(circle) {
			$hit = Bool.True
		}
	}
	if level.tilemap.circle_touches_solid(circle) {
		$hit = Bool.True
	}
	$hit
}

## Moves the player at a chosen speed unless the destination is blocked.
move_player_speed : Level, Math.Vec2, Math.Vec2, F32, F32 -> Math.Vec2
move_player_speed = |level, player, raw_dir, dt, speed| {
	dir = Math.normalize(raw_dir)
	candidate = clamp_to_world(level, Math.add(player, Math.scale(dir, speed * dt)))
	if any_obstacle_hit(level, Math.circle(candidate, Player.radius)) player else candidate
}

## Wraps the shared hazard phase into the unit interval.
wrap_unit : F32 -> F32
wrap_unit = |value| if value >= 1 value - 1 else if value < 0 value + 1 else value

## Counts a positive feedback timer down without crossing below zero.
tick_timer : F32, F32 -> F32
tick_timer = |timer, dt| if timer <= dt 0 else timer - dt

## Finds the first remaining spark touched by the player circle.
find_hit_spark : List(Spark), Math.Circle, U64 -> Try(Spark, [NoSpark])
find_hit_spark = |sparks, player_circle, index|
	match List.get(sparks, index) {
		Ok(spark) => if spark.hit_by(player_circle) Ok(spark) else find_hit_spark(sparks, player_circle, index + 1)
		Err(_) => Err(NoSpark)
	}

## Chooses the gate state from the remaining collectible sparks.
gate_after_collect : List(Spark) -> Game.Gate
gate_after_collect = |remaining| if List.len(remaining) == 0 GateOpen else GateLocked

## Removes a touched spark, scores it, and opens the gate when it was last.
collect_spark : Game.World -> CollectResult
collect_spark = |world|
	match find_hit_spark(world.sparks, world.player.circle(), 0) {
		Ok(spark) => {
			remaining = List.keep_if(world.sparks, |item| item.id != spark.id)
			next_gate = gate_after_collect(remaining)
			gate_opened = next_gate == GateOpen and !(world.gate.is_open())
			{
				world: {
					..world,
					sparks: remaining,
					score: world.score + 1,
					shake: 0,
					flash: 0,
					burst_pos: spark.pos,
					burst_timer: Game.burst_duration,
					gate: next_gate,
					gate_flash: if gate_opened 1 else world.gate_flash,
					state: Playing,
				},
				collected: Ok(spark),
				gate_opened,
			}
		}
		Err(_) => { world, collected: Err(NoSpark), gate_opened: Bool.False }
	}

## Reports whether any moving hazard touches the player.
any_hazard_hit : Level, Math.Circle, F32 -> Bool
any_hazard_hit = |level, circle, phase| {
	var $hit = Bool.False
	for hazard in level.hazards {
		if hazard.hit_by(circle, phase) {
			$hit = Bool.True
		}
	}
	$hit
}

## Applies hazard damage, respawn, lives, and game-over rules when vulnerable.
damage_if_needed : Level, Game.World -> DamageResult
damage_if_needed = |level, world| {
	if world.player.invuln <= 0 and any_hazard_hit(level, world.player.circle(), world.phase) {
		next_lives = if world.lives > 0 world.lives - 1 else 0
		next_state = if world.lives <= 1 GameOver else Playing
		{
			world: {
				..world,
				player: world.player.damage_respawn(level.spawn),
				lives: next_lives,
				shake: 10,
				flash: 0.28,
				burst_pos: world.player.pos,
				burst_timer: Game.burst_duration,
				state: next_state,
			},
			damaged: Bool.True,
		}
	} else {
		{ world, damaged: Bool.False }
	}
}

## Wins the run when the player touches the open exit.
escape_if_needed : Level, Game.World -> EscapeResult
escape_if_needed = |level, world| {
	if world.gate.is_open() and Math.circle_overlaps(world.player.circle(), Math.circle(level.exit_center, level.exit_radius)) {
		{
			world: {
				..world,
				shake: 10,
				flash: 0,
				burst_pos: level.exit_center,
				burst_timer: Game.burst_duration,
				gate_flash: 1,
				state: Won,
			},
			escaped: Bool.True,
		}
	} else {
		{ world, escaped: Bool.False }
	}
}

## Includes a gameplay event only when its rule fired.
event_when : Bool, Game.Event -> List(Game.Event)
event_when = |condition, event| if condition [event] else []

## Converts an optional collected spark into its gameplay event.
spark_collected_events : Try(Spark, [NoSpark]) -> List(Game.Event)
spark_collected_events = |collected|
	match collected {
		Ok(spark) => [SparkCollected(spark)]
		Err(_) => []
	}

## Orders all events produced by one playing-world update.
game_events : Bool, Try(Spark, [NoSpark]), Bool, Bool, Bool, Game.State, Math.Vec2 -> List(Game.Event)
game_events = |dash_started, collected, gate_opened, escaped, damaged, damage_state, dash_pos|
	List.concat(
		event_when(dash_started, DashStarted(dash_pos)),
		List.concat(
			spark_collected_events(collected),
			List.concat(event_when(gate_opened, GateOpened), List.concat(event_when(escaped, Escaped), event_when(damaged, Damaged(damage_state)))),
		),
	)

## Advances player movement, hazards, collection, escape, and damage once.
advance_world : Level, Game.World, Game.Controls, F32 -> (Game.World, List(Game.Event))
advance_world = |level, world, controls, dt| {
	moving = controls.move.x != 0 or controls.move.y != 0
	dash_started = controls.dash_pressed and world.player.dash_ready()
	dash_active = dash_started or world.player.dash_active()
	move_dir = if dash_active and !(moving) world.player.facing_dir() else controls.move
	speed = if dash_active Player.dash_speed else Player.speed
	player_pos = move_player_speed(level, world.player.pos, move_dir, dt, speed)
	player = world.player.step({ pos: player_pos, raw_dir: controls.move, move_dir, dash_started, dash_active, dt })
	hazard_speed = 0.15 + U64.to_f32(world.score) * 0.012
	phase = wrap_unit(world.phase + dt * hazard_speed)
	moved = {
		..world,
		player,
		phase,
		shake: Math.clamp(world.shake - dt * 36, 0, 99),
		flash: tick_timer(world.flash, dt * 1.8),
		burst_timer: tick_timer(world.burst_timer, dt),
		gate_flash: tick_timer(world.gate_flash, dt * 1.15),
		state: Playing,
	}
	collect_result = collect_spark(moved)
	escape_result = escape_if_needed(level, collect_result.world)
	damage_result = if escape_result.world.state == Won { world: escape_result.world, damaged: Bool.False } else damage_if_needed(level, escape_result.world)
	(
		damage_result.world,
		game_events(
			dash_started,
			collect_result.collected,
			collect_result.gate_opened,
			escape_result.escaped,
			damage_result.damaged,
			damage_result.world.state,
			world.player.pos,
		),
	)
}
