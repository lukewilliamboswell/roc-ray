app [Model, program] { rr: platform "../platform/main.roc" }

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

GameState := [Ready, Playing, Won, GameOver]

Model : {
	bricks : List(Brick),
	paddle_x : F32,
	ball_x : F32,
	ball_y : F32,
	ball_vx : F32,
	ball_vy : F32,
	score : U64,
	lives : U64,
	state : GameState,
	paddle_sound : Audio.Sound,
	brick_sound : Audio.Sound,
	wall_sound : Audio.Sound,
	lose_sound : Audio.Sound,
	start_sound : Audio.Sound,
}

program = { init!, render! }

screen_w : F32
screen_w = 800

screen_h : F32
screen_h = 600

paddle_w : F32
paddle_w = 112

paddle_h : F32
paddle_h = 16

paddle_y : F32
paddle_y = 548

paddle_speed : F32
paddle_speed = 460

ball_radius : F32
ball_radius = 8

launch_vx : F32
launch_vx = 170

launch_vy : F32
launch_vy = -340

brick_left : F32
brick_left = 44

brick_w : F32
brick_w = 64

brick_h : F32
brick_h = 22

brick_gap : F32
brick_gap = 8

init! : App.Init(Model)
init! = App.init(
	{
		..App.default,
		title: "RocRay Breakout",
		target_fps: 120,
	},
	|_host| {
		paddle_x = (screen_w - paddle_w) * 0.5
		seed = {
			bricks: fresh_bricks,
			paddle_x,
			ball_x: paddle_x + paddle_w * 0.5,
			ball_y: paddle_y - ball_radius - 2,
			ball_vx: launch_vx,
			ball_vy: launch_vy,
			score: 0,
			lives: 3,
			state: Ready,
			paddle_sound: Audio.gen_tone!({ freq: 440, ms: 50 }),
			brick_sound: Audio.gen_tone!({ freq: 760, ms: 45 }),
			wall_sound: Audio.gen_tone!({ freq: 260, ms: 40 }),
			lose_sound: Audio.gen_tone!({ freq: 140, ms: 180 }),
			start_sound: Audio.gen_tone!({ freq: 520, ms: 70 }),
		}

		Ok(new_game(seed))
	},
)

brick_at : U64, F32, F32, Color -> Brick
brick_at = |id, x, y, color| {
	id,
	rect: Math.rect(x, y, brick_w, brick_h),
	color,
}

brick_row : U64, F32, Color -> List(Brick)
brick_row = |base_id, y, color| [
	brick_at(base_id + 0, brick_left + 0 * (brick_w + brick_gap), y, color),
	brick_at(base_id + 1, brick_left + 1 * (brick_w + brick_gap), y, color),
	brick_at(base_id + 2, brick_left + 2 * (brick_w + brick_gap), y, color),
	brick_at(base_id + 3, brick_left + 3 * (brick_w + brick_gap), y, color),
	brick_at(base_id + 4, brick_left + 4 * (brick_w + brick_gap), y, color),
	brick_at(base_id + 5, brick_left + 5 * (brick_w + brick_gap), y, color),
	brick_at(base_id + 6, brick_left + 6 * (brick_w + brick_gap), y, color),
	brick_at(base_id + 7, brick_left + 7 * (brick_w + brick_gap), y, color),
	brick_at(base_id + 8, brick_left + 8 * (brick_w + brick_gap), y, color),
	brick_at(base_id + 9, brick_left + 9 * (brick_w + brick_gap), y, color),
]

fresh_bricks : List(Brick)
fresh_bricks = List.concat(
	brick_row(0, 88, Color.from_hex_rgb(0xf94144)),
	List.concat(
		brick_row(10, 118, Color.from_hex_rgb(0xf3722c)),
		List.concat(
			brick_row(20, 148, Color.from_hex_rgb(0xf9c74f)),
			List.concat(
				brick_row(30, 178, Color.from_hex_rgb(0x43aa8b)),
				brick_row(40, 208, Color.from_hex_rgb(0x577590)),
			),
		),
	),
)

new_game : Model -> Model
new_game = |model| {
	paddle_x = (screen_w - paddle_w) * 0.5
	{
		..model,
		bricks: fresh_bricks,
		paddle_x,
		ball_x: paddle_x + paddle_w * 0.5,
		ball_y: paddle_y - ball_radius - 2,
		ball_vx: launch_vx,
		ball_vy: launch_vy,
		score: 0,
		lives: 3,
		state: Ready,
	}
}

paddle_rect : F32 -> Math.Rect
paddle_rect = |paddle_x| Math.rect(paddle_x, paddle_y, paddle_w, paddle_h)

move_paddle : F32, Host -> F32
move_paddle = |paddle_x, host| {
	left = Keys.key_down(host.keys, KeyLeft) or Keys.key_down(host.keys, KeyA)
	right = Keys.key_down(host.keys, KeyRight) or Keys.key_down(host.keys, KeyD)
	dir = if left -1 else if right 1 else 0

	Math.clamp(paddle_x + dir * paddle_speed * host.frame_time, 0, screen_w - paddle_w)
}

ball_on_paddle : Model, F32, U64, GameState -> Model
ball_on_paddle = |model, paddle_x, lives, state| {
	..model,
	paddle_x,
	ball_x: paddle_x + paddle_w * 0.5,
	ball_y: paddle_y - ball_radius - 2,
	ball_vx: launch_vx,
	ball_vy: launch_vy,
	lives,
	state,
}

advance_ready! : Model, Host => Model
advance_ready! = |model, host| {
	paddle_x = move_paddle(model.paddle_x, host)
	ready_model = ball_on_paddle(model, paddle_x, model.lives, Ready)

	if Keys.key_pressed(host.keys_pressed, KeySpace) {
		Audio.play!(model.start_sound)
		{ ..ready_model, state: Playing }
	} else {
		ready_model
	}
}

play_if! : Bool, Audio.Sound => {}
play_if! = |cond, sound| if cond Audio.play!(sound) else {}

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

advance_playing! : Model, Host => Model
advance_playing! = |model, host| {
	paddle_x = move_paddle(model.paddle_x, host)
	paddle = paddle_rect(paddle_x)

	nx0 = model.ball_x + model.ball_vx * host.frame_time
	ny0 = model.ball_y + model.ball_vy * host.frame_time
	lost_life = ny0 - ball_radius > screen_h

	if lost_life {
		Audio.play!(model.lose_sound)
		next_lives = if model.lives > 0 model.lives - 1 else 0
		next_state = if model.lives <= 1 GameOver else Ready
		ball_on_paddle(model, paddle_x, next_lives, next_state)
	} else {
		hit_left = nx0 - ball_radius < 0
		hit_right = nx0 + ball_radius > screen_w
		hit_top = ny0 - ball_radius < 58

		nx = if hit_left ball_radius else if hit_right screen_w - ball_radius else nx0
		ny = if hit_top 58 + ball_radius else ny0
		vx_wall = if hit_left or hit_right model.ball_vx * -1 else model.ball_vx
		vy_wall = if hit_top model.ball_vy * -1 else model.ball_vy

		wall_ball = Math.circle({ x: nx, y: ny }, ball_radius)
		hit_paddle = vy_wall > 0 and Math.circle_rect(wall_ball, paddle)
		paddle_center = Math.center(paddle).x
		paddle_offset = Math.clamp((nx - paddle_center) / (paddle_w * 0.5), -1, 1)
		vx_paddle = if hit_paddle paddle_offset * 360 else vx_wall
		vy_paddle = if hit_paddle F32.abs(vy_wall) * -1 else vy_wall
		ny_paddle = if hit_paddle paddle_y - ball_radius - 1 else ny

		play_if!(hit_left or hit_right or hit_top, model.wall_sound)
		play_if!(hit_paddle, model.paddle_sound)

		ball_shape = Math.circle({ x: nx, y: ny_paddle }, ball_radius)
		near_bricks = ny_paddle + ball_radius >= 84 and ny_paddle - ball_radius <= 236
		hit_result = if near_bricks find_hit_brick(model.bricks, ball_shape, 0) else Err(NotFound)

		match hit_result {
			Ok(hit_brick) => {
				Audio.play!(model.brick_sound)
				remaining = List.keep_if(model.bricks, |brick| brick.id != hit_brick.id)
				state = if List.len(remaining) == 0 Won else Playing
				play_if!(state == Won, model.start_sound)
				{ ..model, bricks: remaining, paddle_x, ball_x: nx, ball_y: ny_paddle, ball_vx: vx_paddle, ball_vy: vy_paddle * -1, score: model.score + 10, state }
			}
			Err(_) => { ..model, paddle_x, ball_x: nx, ball_y: ny_paddle, ball_vx: vx_paddle, ball_vy: vy_paddle, state: Playing }
		}
	}
}

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {
	if Keys.key_pressed(host.keys_pressed, KeyEscape) {
		Host.exit!(0)
	}

	next = match model.state {
		Ready => advance_ready!(model, host)
		Playing => advance_playing!(model, host)
		Won =>
			if Keys.key_pressed(host.keys_pressed, KeySpace) {
				Audio.play!(model.start_sound)
				new_game(model)
			} else {
				model
			}
		GameOver =>
			if Keys.key_pressed(host.keys_pressed, KeySpace) {
				Audio.play!(model.start_sound)
				new_game(model)
			} else {
				model
			}
		}

	Draw.draw!(
		Color.ray_white,
		|| draw_game!(next),
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

draw_game! : Model => {}
draw_game! = |model| {
	Draw.text_at!({ pos: { x: 44, y: 24 }, text: "Breakout", size: 30, color: Color.dark_gray })
	Draw.text_at!({ pos: { x: 290, y: 32 }, text: Str.concat("Score ", U64.to_str(model.score)), size: 22, color: Color.gray })
	Draw.text_at!({ pos: { x: 620, y: 32 }, text: Str.concat("Lives ", U64.to_str(model.lives)), size: 22, color: Color.gray })
	Draw.fps!({ pos: { x: 730, y: 32 }, size: 18, color: Color.gray })
	Draw.line!({ start: { x: 44, y: 58 }, end: { x: screen_w - 44, y: 58 }, stroke: Draw.stroke(Color.light_gray, 2) })

	draw_bricks!(model.bricks)

	paddle = paddle_rect(model.paddle_x)
	Draw.rounded_rectangle!({ x: paddle.x, y: paddle.y, width: paddle.width, height: paddle.height, radius: 7, segments: 8, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x277da1), Color.dark_gray, 2) })
	Draw.circle!({ center: { x: model.ball_x, y: model.ball_y }, radius: ball_radius, style: Draw.filled_and_outlined(Color.from_hex_rgb(0xf9c74f), Color.dark_gray, 2) })

	match model.state {
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
