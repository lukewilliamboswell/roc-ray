app [Model, program] { rr: platform "../platform/main.roc" }

import rr.Draw
import rr.Color
import rr.Host
import rr.Keys
import rr.Audio
import rr.App
import rr.Math

# Pong v2 - first to 5 wins, then SPACE to restart.
#
# Player controls the LEFT paddle with W / S; the RIGHT paddle is a simple AI.
# Motion is in pixels/second scaled by host.frame_time (frame-rate independent).
# Serves leave at a random angle. When someone reaches `win_score`, the game
# freezes on a win screen until SPACE is pressed (edge-detected, so holding it
# doesn't instantly restart again).

Model : {
	ball_x : F32,
	ball_y : F32,
	ball_vx : F32,
	ball_vy : F32,
	left_y : F32,
	right_y : F32,
	left_score : U64,
	right_score : U64,
	# Sound handles, generated once in init! and preserved across restarts.
	hit_sound : Audio.Sound,
	wall_sound : Audio.Sound,
	score_sound : Audio.Sound,
}

# --- Constants (screen is 800x600; speeds in pixels/second) ---
screen_w : F32
screen_w = 800

screen_h : F32
screen_h = 600

paddle_w : F32
paddle_w = 15

paddle_h : F32
paddle_h = 100

paddle_margin : F32
paddle_margin = 30

ball_r : F32
ball_r = 10

paddle_speed : F32
paddle_speed = 360

ai_speed : F32
ai_speed = 270

init_vx : F32
init_vx = 260

# vy gained per pixel of offset between ball and paddle centre on a hit
bounce_factor : F32
bounce_factor = 6

# First player to this many points wins.
win_score : U64
win_score = 5

# A random vertical serve speed in px/second, so each serve leaves at a
# different angle instead of the same predictable line.
random_serve_vy! : () => F32
random_serve_vy! = || I32.to_f32(Host.random_i32!(-160, 160))

left_paddle : F32 -> Math.Rect
left_paddle = |y| Math.rect(paddle_margin, y, paddle_w, paddle_h)

right_paddle : F32 -> Math.Rect
right_paddle = |y| Math.rect(screen_w - paddle_margin - paddle_w, y, paddle_w, paddle_h)

ball_circle : F32, F32 -> Math.Circle
ball_circle = |x, y| Math.circle({ x, y }, ball_r)

# A fresh round: ball centred, scores zeroed, served in a random direction.
# Sound handles are carried over from the previous model (generated once).
new_round! : Model => Model
new_round! = |model| {
	serve_dir = if Host.random_i32!(0, 1) == 0 (init_vx * -1) else init_vx
	{
		..model,
		ball_x: screen_w * 0.5,
		ball_y: screen_h * 0.5,
		ball_vx: serve_dir,
		ball_vy: random_serve_vy!(),
		left_y: 250,
		right_y: 250,
		left_score: 0,
		right_score: 0,
	}
}

# Play a sound only when `cond` is true (a no-op otherwise).
play_if! : Bool, Audio.Sound => {}
play_if! = |cond, sound| if cond Audio.play!(sound) else {}

program = { init!, render! }

init! : App.Init(Model)
init! = App.init(
	{
		..App.default,
		title: "RocRay Pong",
	},
	|_host| {
		# Generate the sound effects once; new_round! carries the handles forward.
		seed = {
			ball_x: 0,
			ball_y: 0,
			ball_vx: 0,
			ball_vy: 0,
			left_y: 250,
			right_y: 250,
			left_score: 0,
			right_score: 0,
			hit_sound: Audio.gen_tone!({ freq: 440, ms: 60 }),
			wall_sound: Audio.gen_tone!({ freq: 220, ms: 50 }),
			score_sound: Audio.gen_tone!({ freq: 160, ms: 200 }),
		}

		Ok(new_round!(seed))
	},
)

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {
	game_over = model.left_score >= win_score or model.right_score >= win_score
	if game_over render_game_over!(model, host) else render_playing!(model, host)
}

# --- Win screen: freeze the field and wait for SPACE to start a new game ---
render_game_over! : Model, Host => Try(Model, [Exit(I64), ..])
render_game_over! = |model, host| {
	restart = Keys.key_pressed(host.keys_pressed, KeySpace)
	winner = if model.left_score >= win_score "LEFT PLAYER WINS" else "RIGHT PLAYER WINS"

	Draw.draw!(
		Color.black,
		|| {
			draw_field!(model)
			Draw.text!({ pos: { x: screen_w * 0.5, y: 260 }, text: winner, size: 40, spacing: Draw.default_spacing, color: Color.yellow, font: Draw.default_font, align: Draw.align_center })
			Draw.text!({ pos: { x: screen_w * 0.5, y: 315 }, text: "Press SPACE to restart", size: 24, spacing: Draw.default_spacing, color: Color.white, font: Draw.default_font, align: Draw.align_center })
		},
	)

	Ok(if restart new_round!(model) else model)
}

# --- Active play ---
render_playing! : Model, Host => Try(Model, [Exit(I64), ..])
render_playing! = |model, host| {

	# Seconds since the previous frame - the basis for all motion this frame.
	dt = host.frame_time

	# Angle to use if the ball is served (scored) this frame.
	serve_vy = random_serve_vy!()

	# --- Left paddle: player input (W up, S down) ---
	w_down = Keys.key_down(host.keys, KeyW)
	s_down = Keys.key_down(host.keys, KeyS)
	left_dir = if w_down (paddle_speed * -1) else if s_down paddle_speed else 0
	left_y = Math.clamp(model.left_y + left_dir * dt, 0, screen_h - paddle_h)

	# --- Right paddle: simple AI tracks the ball's vertical position ---
	right_center = model.right_y + paddle_h * 0.5
	right_dir = if model.ball_y < right_center - 4 (ai_speed * -1) else if model.ball_y > right_center + 4 ai_speed else 0
	right_y = Math.clamp(model.right_y + right_dir * dt, 0, screen_h - paddle_h)

	# --- Move ball ---
	nx0 = model.ball_x + model.ball_vx * dt
	ny0 = model.ball_y + model.ball_vy * dt

	# Bounce off top / bottom walls
	hit_top = ny0 - ball_r < 0
	hit_bottom = ny0 + ball_r > screen_h
	ny = if hit_top ball_r else if hit_bottom (screen_h - ball_r) else ny0
	vy_wall = if hit_top (model.ball_vy * -1) else if hit_bottom (model.ball_vy * -1) else model.ball_vy

	# Paddle geometry
	left_rect = left_paddle(left_y)
	right_rect = right_paddle(right_y)
	ball_shape = ball_circle(nx0, ny)

	# Paddle collisions (reflect horizontally; set vy from where the ball struck)
	hit_left = model.ball_vx < 0 and nx0 >= Math.left(left_rect) and Math.circle_rect(ball_shape, left_rect)
	hit_right = model.ball_vx > 0 and nx0 <= Math.right(right_rect) and Math.circle_rect(ball_shape, right_rect)

	left_paddle_center = Math.center(left_rect).y
	right_paddle_center = Math.center(right_rect).y

	nx = if hit_left (Math.right(left_rect) + ball_r) else if hit_right (Math.left(right_rect) - ball_r) else nx0
	vx = if hit_left (model.ball_vx * -1) else if hit_right (model.ball_vx * -1) else model.ball_vx
	vy = if hit_left ((ny - left_paddle_center) * bounce_factor) else if hit_right ((ny - right_paddle_center) * bounce_factor) else vy_wall

	# --- Scoring: ball left the field on the left or right edge ---
	out_left = nx - ball_r < 0
	out_right = nx + ball_r > screen_w

	final_ball_x = if out_left (screen_w * 0.5) else if out_right (screen_w * 0.5) else nx
	final_ball_y = if out_left (screen_h * 0.5) else if out_right (screen_h * 0.5) else ny
	final_vx = if out_left (init_vx * -1) else if out_right init_vx else vx
	final_vy = if out_left serve_vy else if out_right serve_vy else vy

	left_score = if out_right model.left_score + 1 else model.left_score
	right_score = if out_left model.right_score + 1 else model.right_score

	next = {
		..model,
		ball_x: final_ball_x,
		ball_y: final_ball_y,
		ball_vx: final_vx,
		ball_vy: final_vy,
		left_y: left_y,
		right_y: right_y,
		left_score: left_score,
		right_score: right_score,
	}

	# Sound effects for this frame's events.
	play_if!(hit_left or hit_right, model.hit_sound)
	play_if!(hit_top or hit_bottom, model.wall_sound)
	play_if!(out_left or out_right, model.score_sound)

	Draw.draw!(
		Color.black,
		|| draw_field!(next),
	)

	Ok(next)
}

# Draw the static scene (center line, paddles, ball, scores) for a model.
draw_field! : Model => {}
draw_field! = |model| {
	left_rect = left_paddle(model.left_y)
	right_rect = right_paddle(model.right_y)
	ball_shape = ball_circle(model.ball_x, model.ball_y)

	Draw.line!({ start: { x: screen_w * 0.5, y: 0 }, end: { x: screen_w * 0.5, y: screen_h }, stroke: Draw.stroke(Color.dark_gray, 2) })
	Draw.rectangle!({ x: left_rect.x, y: left_rect.y, width: left_rect.width, height: left_rect.height, style: Draw.filled(Color.white) })
	Draw.rectangle!({ x: right_rect.x, y: right_rect.y, width: right_rect.width, height: right_rect.height, style: Draw.filled(Color.white) })
	Draw.circle!({ center: ball_shape.center, radius: ball_shape.radius, style: Draw.filled(Color.ray_white) })
	Draw.text!({ pos: { x: screen_w * 0.25, y: 20 }, text: U64.to_str(model.left_score), size: 40, spacing: Draw.default_spacing, color: Color.white, font: Draw.default_font, align: Draw.align_top_center })
	Draw.text!({ pos: { x: screen_w * 0.75, y: 20 }, text: U64.to_str(model.right_score), size: 40, spacing: Draw.default_spacing, color: Color.white, font: Draw.default_font, align: Draw.align_top_center })
}
