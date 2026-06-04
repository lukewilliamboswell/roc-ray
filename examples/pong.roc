app [Model, program] { rr: platform "../platform/main.roc" }

import rr.Draw
import rr.Host
import rr.Keys

# Pong v1 - frame-rate independent.
#
# Player controls the LEFT paddle with W / S.
# The RIGHT paddle is a simple AI that tracks the ball.
#
# All speeds are in pixels per SECOND and scaled by `host.frame_time` (seconds
# since the previous frame), so motion is the same whether the host runs at 60
# or 240 FPS. `host.frame_time` is 0 on the very first frame.

Model : {
	ball_x : F32,
	ball_y : F32,
	ball_vx : F32,
	ball_vy : F32,
	left_y : F32,
	right_y : F32,
	left_score : U64,
	right_score : U64,
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

clamp : F32, F32, F32 -> F32
clamp = |v, lo, hi| if v < lo lo else if v > hi hi else v

# A random vertical serve speed in px/second, so each serve leaves at a
# different angle instead of the same predictable line.
random_serve_vy! : () => F32
random_serve_vy! = || I32.to_f32(Host.random_i32!(-160, 160))

program = { init!, render! }

init! : Host => Try(Model, [Exit(I64), ..])
init! = |_host| {
	# set_screen_size!'s error is `[NotSupported, ..]`, which doesn't unify with
	# this function's `[Exit(I64), ..]`, so discard the result.
	_ = Host.set_screen_size!({ width: 800, height: 600 })

	# QA knob: change this and the ball/paddle speeds should look identical,
	# because all motion is scaled by host.frame_time. Try 30, 60, 144, 240.
	Host.set_target_fps!(240)

	# Serve in a random direction at a random angle.
	serve_dir = if Host.random_i32!(0, 1) == 0 (init_vx * -1) else init_vx

	Ok(
		{
			ball_x: 400,
			ball_y: 300,
			ball_vx: serve_dir,
			ball_vy: random_serve_vy!(),
			left_y: 250,
			right_y: 250,
			left_score: 0,
			right_score: 0,
		},
	)
}

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {

	# Seconds since the previous frame - the basis for all motion this frame.
	dt = host.frame_time

	# Angle to use if the ball is served (scored) this frame.
	serve_vy = random_serve_vy!()

	# --- Left paddle: player input (W up, S down) ---
	w_down = Keys.key_down(host.keys, KeyW)
	s_down = Keys.key_down(host.keys, KeyS)
	left_dir = if w_down (paddle_speed * -1) else if s_down paddle_speed else 0
	left_y = clamp(model.left_y + left_dir * dt, 0, screen_h - paddle_h)

	# --- Right paddle: simple AI tracks the ball's vertical position ---
	right_center = model.right_y + paddle_h * 0.5
	right_dir = if model.ball_y < right_center - 4 (ai_speed * -1) else if model.ball_y > right_center + 4 ai_speed else 0
	right_y = clamp(model.right_y + right_dir * dt, 0, screen_h - paddle_h)

	# --- Move ball ---
	nx0 = model.ball_x + model.ball_vx * dt
	ny0 = model.ball_y + model.ball_vy * dt

	# Bounce off top / bottom walls
	hit_top = ny0 - ball_r < 0
	hit_bottom = ny0 + ball_r > screen_h
	ny = if hit_top ball_r else if hit_bottom (screen_h - ball_r) else ny0
	vy_wall = if hit_top (model.ball_vy * -1) else if hit_bottom (model.ball_vy * -1) else model.ball_vy

	# Paddle geometry
	left_x = paddle_margin
	left_right = left_x + paddle_w
	right_x = screen_w - paddle_margin - paddle_w

	# Paddle collisions (reflect horizontally; set vy from where the ball struck)
	hit_left = model.ball_vx < 0 and nx0 - ball_r <= left_right and nx0 >= left_x and ny + ball_r >= left_y and ny - ball_r <= left_y + paddle_h
	hit_right = model.ball_vx > 0 and nx0 + ball_r >= right_x and nx0 <= right_x + paddle_w and ny + ball_r >= right_y and ny - ball_r <= right_y + paddle_h

	left_paddle_center = left_y + paddle_h * 0.5
	right_paddle_center = right_y + paddle_h * 0.5

	nx = if hit_left (left_right + ball_r) else if hit_right (right_x - ball_r) else nx0
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

	Draw.draw!(
		Black,
		|| {
			# Center line
			Draw.line!({ start: { x: screen_w * 0.5, y: 0 }, end: { x: screen_w * 0.5, y: screen_h }, color: DarkGray })

			# Paddles
			Draw.rectangle!({ x: left_x, y: left_y, width: paddle_w, height: paddle_h, color: White })
			Draw.rectangle!({ x: right_x, y: right_y, width: paddle_w, height: paddle_h, color: White })

			# Ball
			Draw.circle!({ center: { x: final_ball_x, y: final_ball_y }, radius: ball_r, color: RayWhite })

			# Scores
			Draw.text!({ pos: { x: screen_w * 0.25, y: 20 }, text: U64.to_str(left_score), size: 40, color: White })
			Draw.text!({ pos: { x: screen_w * 0.75, y: 20 }, text: U64.to_str(right_score), size: 40, color: White })
		},
	)

	Ok(
		{
			ball_x: final_ball_x,
			ball_y: final_ball_y,
			ball_vx: final_vx,
			ball_vy: final_vy,
			left_y: left_y,
			right_y: right_y,
			left_score: left_score,
			right_score: right_score,
		},
	)
}
