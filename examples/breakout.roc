app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.6/YsrMnLJw2ahDsyFXNEpipwWQfiM5DSxq5Ve6SyHczN7.tar.zst" }

import rr.App
import rr.Audio
import rr.Color
import rr.Draw
import rr.Host
import rr.Keys
import rr.Math

Brick : {
	id : U64,
	rect : Math.Rect,
	color : Color,
}

Ball : {
	pos : Math.Vec2,
	vel : Math.Vec2,
}

BrickRow := [RedRow, OrangeRow, YellowRow, GreenRow, BlueRow]

PaddleMove := [PaddleLeft, PaddleRight, PaddleStill]

GameState := [Ready, Playing, Won, GameOver]

StepEvent := [GameStarted, WallHit, PaddleHit, BrickHit(Brick), LifeLost(GameState), WallCleared]

Game : {
	bricks : List(Brick),
	paddle_x : F32,
	ball : Ball,
	score : U64,
	lives : U64,
	state : GameState,
}

Sounds : {
	paddle : Audio.Sound,
	brick : Audio.Sound,
	wall : Audio.Sound,
	lose : Audio.Sound,
	start : Audio.Sound,
}

Model : {
	game : Game,
	sounds : Sounds,
}

FrameInput : {
	paddle_move : PaddleMove,
	action_pressed : Bool,
	dt : F32,
}

StepResult : {
	game : Game,
	events : List(StepEvent),
}

program = { init!, render! }

screen_w : F32
screen_w = 800

screen_h : F32
screen_h = 600

top_wall_y : F32
top_wall_y = 58

paddle_w : F32
paddle_w = 112

paddle_h : F32
paddle_h = 16

paddle_y : F32
paddle_y = 548

paddle_speed : F32
paddle_speed = 460

paddle_bounce_speed : F32
paddle_bounce_speed = 360

ball_radius : F32
ball_radius = 8

ball_ready_gap : F32
ball_ready_gap = 2

ball_bounce_gap : F32
ball_bounce_gap = 1

launch_vx : F32
launch_vx = 170

launch_vy : F32
launch_vy = -340

brick_left : F32
brick_left = 44

brick_top : F32
brick_top = 88

brick_w : F32
brick_w = 64

brick_h : F32
brick_h = 22

brick_gap : F32
brick_gap = 8

bricks_per_row : U64
bricks_per_row = 10

brick_score : U64
brick_score = 10

brick_band_top : F32
brick_band_top = 84

brick_band_bottom : F32
brick_band_bottom = 236

initial_lives : U64
initial_lives = 3

init! : App.Init(Model)
init! = App.init(
	{
		..App.default,
		title: "RocRay Breakout",
		target_fps: 120,
	},
	|_host| {
		Ok(
			{
				game: new_game_state(),
				sounds: {
					paddle: Audio.gen_tone!({ freq: 440, ms: 50 }),
					brick: Audio.gen_tone!({ freq: 760, ms: 45 }),
					wall: Audio.gen_tone!({ freq: 260, ms: 40 }),
					lose: Audio.gen_tone!({ freq: 140, ms: 180 }),
					start: Audio.gen_tone!({ freq: 520, ms: 70 }),
				},
			},
		)
	},
)

start_paddle_x : F32
start_paddle_x = (screen_w - paddle_w) * 0.5

launch_ball : F32 -> Ball
launch_ball = |paddle_x| {
	pos: {
		x: paddle_x + paddle_w * 0.5,
		y: paddle_y - ball_radius - ball_ready_gap,
	},
	vel: { x: launch_vx, y: launch_vy },
}

new_game_state : () -> Game
new_game_state = || {
	bricks: fresh_bricks,
	paddle_x: start_paddle_x,
	ball: launch_ball(start_paddle_x),
	score: 0,
	lives: initial_lives,
	state: Ready,
}

brick_row_index : BrickRow -> U64
brick_row_index = |row|
	match row {
		RedRow => 0
		OrangeRow => 1
		YellowRow => 2
		GreenRow => 3
		BlueRow => 4
	}

brick_row_color : BrickRow -> Color
brick_row_color = |row|
	match row {
		RedRow => Color.from_hex_rgb(0xf94144)
		OrangeRow => Color.from_hex_rgb(0xf3722c)
		YellowRow => Color.from_hex_rgb(0xf9c74f)
		GreenRow => Color.from_hex_rgb(0x43aa8b)
		BlueRow => Color.from_hex_rgb(0x577590)
	}

brick_row_y : BrickRow -> F32
brick_row_y = |row| brick_top + U64.to_f32(brick_row_index(row)) * (brick_h + brick_gap)

brick_col_x : U64 -> F32
brick_col_x = |col| brick_left + U64.to_f32(col) * (brick_w + brick_gap)

brick_at : U64, F32, F32, Color -> Brick
brick_at = |id, x, y, color| {
	id,
	rect: Math.rect(x, y, brick_w, brick_h),
	color,
}

brick_in_row : BrickRow, U64 -> Brick
brick_in_row = |row, col| {
	id = brick_row_index(row) * bricks_per_row + col
	brick_at(id, brick_col_x(col), brick_row_y(row), brick_row_color(row))
}

brick_row : BrickRow -> List(Brick)
brick_row = |row| [
	brick_in_row(row, 0),
	brick_in_row(row, 1),
	brick_in_row(row, 2),
	brick_in_row(row, 3),
	brick_in_row(row, 4),
	brick_in_row(row, 5),
	brick_in_row(row, 6),
	brick_in_row(row, 7),
	brick_in_row(row, 8),
	brick_in_row(row, 9),
]

fresh_bricks : List(Brick)
fresh_bricks = List.concat(
	brick_row(RedRow),
	List.concat(
		brick_row(OrangeRow),
		List.concat(
			brick_row(YellowRow),
			List.concat(
				brick_row(GreenRow),
				brick_row(BlueRow),
			),
		),
	),
)

paddle_move_from_host : Host -> PaddleMove
paddle_move_from_host = |host| {
	left = Keys.key_down(host.keys, KeyLeft) or Keys.key_down(host.keys, KeyA)
	right = Keys.key_down(host.keys, KeyRight) or Keys.key_down(host.keys, KeyD)

	if left PaddleLeft else if right PaddleRight else PaddleStill
}

paddle_move_dir : PaddleMove -> F32
paddle_move_dir = |move|
	match move {
		PaddleLeft => -1
		PaddleRight => 1
		PaddleStill => 0
	}

frame_input : Host -> FrameInput
frame_input = |host| {
	paddle_move: paddle_move_from_host(host),
	action_pressed: Keys.key_pressed(host.keys_pressed, KeySpace),
	dt: host.frame_time,
}

paddle_rect : F32 -> Math.Rect
paddle_rect = |paddle_x| Math.rect(paddle_x, paddle_y, paddle_w, paddle_h)

move_paddle : F32, PaddleMove, F32 -> F32
move_paddle = |paddle_x, move, dt|
	Math.clamp(paddle_x + paddle_move_dir(move) * paddle_speed * dt, 0, screen_w - paddle_w)

ball_circle : Ball -> Math.Circle
ball_circle = |ball| Math.circle(ball.pos, ball_radius)

move_ball : Ball, F32 -> Ball
move_ball = |ball, dt| { ..ball, pos: Math.add(ball.pos, Math.scale(ball.vel, dt)) }

ball_on_paddle : Game, F32, U64, GameState -> Game
ball_on_paddle = |game, paddle_x, lives, state| {
	..game,
	paddle_x,
	ball: launch_ball(paddle_x),
	lives,
	state,
}

event_when : Bool, StepEvent -> List(StepEvent)
event_when = |condition, event| if condition [event] else []

advance_ready : Game, FrameInput -> StepResult
advance_ready = |game, input| {
	paddle_x = move_paddle(game.paddle_x, input.paddle_move, input.dt)
	ready_game = ball_on_paddle(game, paddle_x, game.lives, Ready)

	if input.action_pressed {
		{ game: { ..ready_game, state: Playing }, events: [GameStarted] }
	} else {
		{ game: ready_game, events: [] }
	}
}

advance_finished : Game, FrameInput -> StepResult
advance_finished = |game, input| {
	if input.action_pressed {
		{ game: new_game_state(), events: [GameStarted] }
	} else {
		{ game, events: [] }
	}
}

find_hit_brick : List(Brick), Math.Circle, U64 -> Try(Brick, [NotFound])
find_hit_brick = |bricks, ball_shape, index|
	match List.get(bricks, index) {
		Ok(brick) =>
			if Math.circle_rect(ball_shape, brick.rect) {
				Ok(brick)
			} else {
				find_hit_brick(bricks, ball_shape, index + 1)
			}
		Err(_) => Err(NotFound)
	}

advance_playing : Game, FrameInput -> StepResult
advance_playing = |game, input| {
	paddle_x = move_paddle(game.paddle_x, input.paddle_move, input.dt)
	paddle = paddle_rect(paddle_x)
	next_ball = move_ball(game.ball, input.dt)
	lost_life = next_ball.pos.y - ball_radius > screen_h

	if lost_life {
		next_lives = if game.lives > 0 game.lives - 1 else 0
		next_state = if game.lives <= 1 GameOver else Ready
		{
			game: ball_on_paddle(game, paddle_x, next_lives, next_state),
			events: [LifeLost(next_state)],
		}
	} else {
		hit_left = next_ball.pos.x - ball_radius < 0
		hit_right = next_ball.pos.x + ball_radius > screen_w
		hit_top = next_ball.pos.y - ball_radius < top_wall_y
		hit_wall = hit_left or hit_right or hit_top

		wall_pos = {
			x: if hit_left ball_radius else if hit_right screen_w - ball_radius else next_ball.pos.x,
			y: if hit_top top_wall_y + ball_radius else next_ball.pos.y,
		}
		wall_vel = {
			x: if hit_left or hit_right game.ball.vel.x * -1 else game.ball.vel.x,
			y: if hit_top game.ball.vel.y * -1 else game.ball.vel.y,
		}
		wall_ball = { pos: wall_pos, vel: wall_vel }

		hit_paddle = wall_ball.vel.y > 0 and Math.circle_rect(ball_circle(wall_ball), paddle)
		paddle_center = Math.center(paddle).x
		paddle_offset = Math.clamp((wall_ball.pos.x - paddle_center) / (paddle_w * 0.5), -1, 1)
		paddle_ball = if hit_paddle {
			pos: { x: wall_ball.pos.x, y: paddle_y - ball_radius - ball_bounce_gap },
			vel: {
				x: paddle_offset * paddle_bounce_speed,
				y: F32.abs(wall_ball.vel.y) * -1,
			},
		} else {
			wall_ball
		}

		ball_shape = ball_circle(paddle_ball)
		near_bricks = paddle_ball.pos.y + ball_radius >= brick_band_top and paddle_ball.pos.y - ball_radius <= brick_band_bottom
		hit_result = if near_bricks find_hit_brick(game.bricks, ball_shape, 0) else Err(NotFound)
		base_events = List.concat(event_when(hit_wall, WallHit), event_when(hit_paddle, PaddleHit))

		match hit_result {
			Ok(hit_brick) => {
				remaining = List.keep_if(game.bricks, |brick| brick.id != hit_brick.id)
				state = if List.len(remaining) == 0 Won else Playing
				events = List.concat(base_events, List.concat([BrickHit(hit_brick)], event_when(state == Won, WallCleared)))
				{
					game: {
						..game,
						bricks: remaining,
						paddle_x,
						ball: { ..paddle_ball, vel: { x: paddle_ball.vel.x, y: paddle_ball.vel.y * -1 } },
						score: game.score + brick_score,
						state,
					},
					events,
				}
			}
			Err(_) => {
				game: { ..game, paddle_x, ball: paddle_ball, state: Playing },
				events: base_events,
			}
		}
	}
}

advance_game : Game, FrameInput -> StepResult
advance_game = |game, input|
	match game.state {
		Ready => advance_ready(game, input)
		Playing => advance_playing(game, input)
		Won => advance_finished(game, input)
		GameOver => advance_finished(game, input)
	}

play_step_events! : Sounds, List(StepEvent) => {}
play_step_events! = |sounds, events| {
	for event in events {
		match event {
			GameStarted => Audio.play!(sounds.start)
			WallHit => Audio.play!(sounds.wall)
			PaddleHit => Audio.play!(sounds.paddle)
			BrickHit(_) => Audio.play!(sounds.brick)
			LifeLost(_) => Audio.play!(sounds.lose)
			WallCleared => Audio.play!(sounds.start)
		}
	}
}

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {
	if Keys.key_pressed(host.keys_pressed, KeyEscape) {
		Host.exit!(0)
	}

	result = advance_game(model.game, frame_input(host))
	play_step_events!(model.sounds, result.events)
	next = { ..model, game: result.game }

	Draw.draw!(
		Color.ray_white,
		|| draw_game!(next.game),
	)

	Ok(next)
}

draw_brick! : Brick => {}
draw_brick! = |brick|
	Draw.rounded_rectangle!({ x: brick.rect.x, y: brick.rect.y, width: brick.rect.width, height: brick.rect.height, radius: 5, segments: 6, style: Draw.filled_and_outlined(brick.color, Color.with_alpha(Color.black, 90), 2) })

draw_bricks! : List(Brick) => {}
draw_bricks! = |bricks| {
	for brick in bricks {
		draw_brick!(brick)
	}
}

draw_game! : Game => {}
draw_game! = |game| {
	Draw.text_at!({ pos: { x: 44, y: 24 }, text: "Breakout", size: 30, color: Color.dark_gray })
	Draw.text_at!({ pos: { x: 290, y: 32 }, text: Str.concat("Score ", U64.to_str(game.score)), size: 22, color: Color.gray })
	Draw.text_at!({ pos: { x: 620, y: 32 }, text: Str.concat("Lives ", U64.to_str(game.lives)), size: 22, color: Color.gray })
	Draw.fps!({ pos: { x: 730, y: 32 }, size: 18, color: Color.gray })
	Draw.line!({ start: { x: 44, y: top_wall_y }, end: { x: screen_w - 44, y: top_wall_y }, stroke: Draw.stroke(Color.light_gray, 2) })

	draw_bricks!(game.bricks)

	paddle = paddle_rect(game.paddle_x)
	Draw.rounded_rectangle!({ x: paddle.x, y: paddle.y, width: paddle.width, height: paddle.height, radius: 7, segments: 8, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x277da1), Color.dark_gray, 2) })
	Draw.circle!({ center: game.ball.pos, radius: ball_radius, style: Draw.filled_and_outlined(Color.from_hex_rgb(0xf9c74f), Color.dark_gray, 2) })

	match game.state {
		Ready => {
			Draw.text_centered!({ pos: { x: screen_w * 0.5, y: 338 }, text: "Press SPACE to launch", size: 24, color: Color.dark_gray })
			Draw.text_centered!({ pos: { x: screen_w * 0.5, y: 370 }, text: "Move with A/D or arrow keys", size: 18, color: Color.gray })
		}
		Playing => {}
		Won => {
			Draw.rectangle!({ x: 210, y: 280, width: 380, height: 118, style: Draw.filled(Color.with_alpha(Color.black, 210)) })
			Draw.text_centered!({ pos: { x: screen_w * 0.5, y: 318 }, text: "You cleared the wall", size: 30, color: Color.white })
			Draw.text_centered!({ pos: { x: screen_w * 0.5, y: 360 }, text: "Press SPACE to play again", size: 20, color: Color.light_gray })
		}
		GameOver => {
			Draw.rectangle!({ x: 210, y: 280, width: 380, height: 118, style: Draw.filled(Color.with_alpha(Color.black, 210)) })
			Draw.text_centered!({ pos: { x: screen_w * 0.5, y: 318 }, text: "Game Over", size: 34, color: Color.white })
			Draw.text_centered!({ pos: { x: screen_w * 0.5, y: 360 }, text: "Press SPACE to restart", size: 20, color: Color.light_gray })
		}
	}
}

still_input : FrameInput
still_input = { paddle_move: PaddleStill, action_pressed: Bool.False, dt: 0 }

expect List.len(fresh_bricks) == bricks_per_row * 5
expect brick_row_index(BlueRow) == 4
expect brick_row_y(YellowRow) == 148
expect paddle_move_dir(PaddleLeft) == -1
expect paddle_move_dir(PaddleRight) == 1
expect paddle_move_dir(PaddleStill) == 0
expect launch_ball(start_paddle_x).pos == { x: 400, y: 538 }
expect ball_circle(launch_ball(start_paddle_x)).radius == ball_radius

expect {
	result = advance_ready(new_game_state(), { paddle_move: PaddleStill, action_pressed: Bool.True, dt: 0 })
	result.game.state == Playing and match List.first(result.events) {
		Ok(GameStarted) => Bool.True
		Ok(_) => Bool.False
		Err(_) => Bool.False
	}
}

expect {
	game = { ..new_game_state(), state: Playing, ball: { pos: { x: 20, y: top_wall_y + ball_radius - 1 }, vel: { x: 0, y: -100 } } }
	result = advance_playing(game, still_input)
	result.game.ball.vel.y == 100 and match List.first(result.events) {
		Ok(WallHit) => Bool.True
		Ok(_) => Bool.False
		Err(_) => Bool.False
	}
}

expect {
	game = { ..new_game_state(), state: Playing, lives: 1, ball: { pos: { x: 10, y: screen_h + ball_radius + 1 }, vel: { x: 0, y: 0 } } }
	result = advance_playing(game, still_input)
	result.game.state == GameOver and result.game.lives == 0 and match List.first(result.events) {
		Ok(LifeLost(state)) => state == GameOver
		Ok(_) => Bool.False
		Err(_) => Bool.False
	}
}

expect {
	brick = brick_at(99, 100, 100, Color.red)
	result = find_hit_brick([brick], Math.circle({ x: 105, y: 105 }, 1), 0)
	match result {
		Ok(hit) => hit.id == 99
		Err(_) => Bool.False
	}
}
