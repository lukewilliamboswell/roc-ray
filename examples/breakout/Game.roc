## Pure Breakout state transitions and their significant gameplay events.
import rr.Math
import Ball
import Bricks
import Paddle

Game := [].{
	State := [Ready, Playing, Won, GameOver].{
		is_eq : _
	}

	Controls : {
		move : Paddle.Move,
		action_pressed : Bool,
		quit_pressed : Bool,
	}

	World : {
		bricks : List(Bricks.Brick),
		paddle : Paddle,
		ball : Ball,
		score : U64,
		lives : U64,
		state : State,
	}

	Event := [GameStarted, WallHit, PaddleHit, BrickHit(Bricks.Brick), LifeLost(State), WallCleared].{
		is_eq : _
	}

	initial_lives = 3.U64

	## Creates a ready-to-launch game with a fresh wall and three lives.
	new_world : () -> World
	new_world = || {
		bricks: Bricks.fresh,
		paddle: Paddle.initial,
		ball: Ball.on(Paddle.initial.rect()),
		score: 0,
		lives: initial_lives,
		state: Ready,
	}

	## Respawns the ball above the paddle that will launch it.
	respawn_ball : World, Paddle -> World
	respawn_ball = |world, paddle| {
		..world,
		paddle,
		ball: Ball.on(paddle.rect()),
	}

	## Produces a single gameplay event only when its condition occurred.
	event_when : Bool, Event -> List(Event)
	event_when = |condition, event| if condition [event] else []

	## Advances the current match state and reports its significant occurrences.
	update : World, Controls, F32 -> (World, List(Event))
	update = |world, controls, dt|
		match world.state {
			Ready => update_ready(world, controls, dt)
			Playing => update_playing(world, controls, dt)
			Won => update_finished(world, controls)
			GameOver => update_finished(world, controls)
		}

	## Moves the waiting paddle and launches the attached ball on request.
	update_ready : World, Controls, F32 -> (World, List(Event))
	update_ready = |world, controls, dt| {
		paddle = world.paddle.move(controls.move, dt)
		ready_world = respawn_ball(world, paddle)

		if controls.action_pressed {
			({ ..ready_world, state: Playing }, [GameStarted])
		} else {
			(ready_world, [])
		}
	}

	## Holds a finished match or replaces it with a fresh one on request.
	update_finished : World, Controls -> (World, List(Event))
	update_finished = |world, controls|
		if controls.action_pressed (new_world(), [GameStarted]) else (world, [])

	## Moves the ball and resolves life, wall, paddle, and brick interactions.
	update_playing : World, Controls, F32 -> (World, List(Event))
	update_playing = |world, controls, dt| {
		paddle = world.paddle.move(controls.move, dt)
		paddle_rect = paddle.rect()
		candidate_ball = world.ball.move(dt)
		lost_life = candidate_ball.pos.y - Ball.radius > 600

		if lost_life {
			next_lives = if world.lives > 0 world.lives - 1 else 0
			next_state = if world.lives <= 1 GameOver else Ready
			next_world = respawn_ball({ ..world, lives: next_lives, state: next_state }, paddle)
			(next_world, [LifeLost(next_state)])
		} else {
			hit_left = candidate_ball.pos.x - Ball.radius < 0
			hit_right = candidate_ball.pos.x + Ball.radius > 800
			hit_top = candidate_ball.pos.y - Ball.radius < 58
			hit_wall = hit_left or hit_right or hit_top

			wall_ball : Ball
			wall_ball = {
				pos: {
					x: if hit_left Ball.radius else if hit_right 800 - Ball.radius else candidate_ball.pos.x,
					y: if hit_top 58 + Ball.radius else candidate_ball.pos.y,
				},
				velocity: {
					x: if hit_left or hit_right world.ball.velocity.x * -1 else world.ball.velocity.x,
					y: if hit_top world.ball.velocity.y * -1 else world.ball.velocity.y,
				},
			}

			hit_paddle = wall_ball.velocity.y > 0 and Math.circle_rect(wall_ball.circle(), paddle_rect)
			paddle_center = Math.center(paddle_rect).x
			paddle_offset = Math.clamp((wall_ball.pos.x - paddle_center) / (Paddle.width * 0.5), -1, 1)
			paddle_ball = if hit_paddle {
				pos: { x: wall_ball.pos.x, y: Paddle.y - Ball.radius - Ball.bounce_gap },
				velocity: {
					x: paddle_offset * Paddle.bounce_speed,
					y: F32.abs(wall_ball.velocity.y) * -1,
				},
			} else {
				wall_ball
			}

			near_bricks = paddle_ball.pos.y + Ball.radius >= Bricks.band_top and paddle_ball.pos.y - Ball.radius <= Bricks.band_bottom
			hit_result = if near_bricks Bricks.find_hit(world.bricks, paddle_ball.circle(), 0) else Err(NotFound)
			collision_events = List.concat(event_when(hit_wall, WallHit), event_when(hit_paddle, PaddleHit))

			match hit_result {
				Ok(hit_brick) => {
					remaining = Bricks.remove(world.bricks, hit_brick)
					state = if List.len(remaining) == 0 Won else Playing
					events = List.concat(collision_events, List.concat([BrickHit(hit_brick)], event_when(state == Won, WallCleared)))
					(
						{
							..world,
							bricks: remaining,
							paddle,
							ball: { ..paddle_ball, velocity: { x: paddle_ball.velocity.x, y: paddle_ball.velocity.y * -1 } },
							score: world.score + Bricks.score,
							state,
						},
						events,
					)
				}
				Err(_) => ({ ..world, paddle, ball: paddle_ball, state: Playing }, collision_events)
			}
		}
	}

	## Converts the demo's ball tracking into the same controls as a player.
	demo_controls : World -> Controls
	demo_controls = |world| {
		paddle_center = world.paddle.x + Paddle.width * 0.5
		delta = world.ball.pos.x - paddle_center
		{
			move: if delta < -8 Left else if delta > 8 Right else Still,
			action_pressed: world.state != Playing,
			quit_pressed: Bool.False,
		}
	}
}
