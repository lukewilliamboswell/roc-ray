app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.9.0/3sKTYuHvxSV77dDyZrxuUYgfrAarL6ZtasWMPeH32udh.tar.zst" }

import rr.Draw
import rr.Color
import rr.Input
import rr.Program
import rr.Random
import rr.Audio
import rr.App
import rr.Math

# Pong v2 - first to 5 wins, then SPACE to restart.
#
# Player controls the LEFT paddle with W / S; the RIGHT paddle is a simple AI.
# Motion is in pixels/second scaled by the step's elapsed seconds (frame-rate
# independent).
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

	## Simulation randomness lives in the model, so a serve is drawn on the
	## frame that needs it and a run replays exactly from its seed.
	rng : Random.Generator,
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
# Drawing from the model's own generator rather than an effect keeps the serve
# immediate: the ball leaves on the frame that scored, not the frame after.
random_serve_vy : Random.Generator -> { value : F32, next : Random.Generator }
random_serve_vy = |rng| {
	drawn = Random.in_range(rng, -160, 160)
	{ value: I32.to_f32(drawn.value), next: drawn.next }
}

left_paddle : F32 -> Math.Rect
left_paddle = |y| Math.rect(paddle_margin, y, paddle_w, paddle_h)

right_paddle : F32 -> Math.Rect
right_paddle = |y| Math.rect(screen_w - paddle_margin - paddle_w, y, paddle_w, paddle_h)

ball_circle : F32, F32 -> Math.Circle
ball_circle = |x, y| Math.circle({ x, y }, ball_r)

# A fresh round: ball centred, scores zeroed, served in a random direction.
# Sound handles are carried over from the previous model (generated once).
new_round : Model -> Model
new_round = |model| {
	# Direction then speed, drawn in that order from one generator, so the
	# sequence is the same every time a given seed replays.
	direction = Random.in_range(model.rng, 0, 1)
	serve = random_serve_vy(direction.next)
	{
		..model,
		ball_x: screen_w * 0.5,
		ball_y: screen_h * 0.5,
		ball_vx: if direction.value == 0 (init_vx * -1) else init_vx,
		ball_vy: serve.value,
		rng: serve.next,
		left_y: 250,
		right_y: 250,
		left_score: 0,
		right_score: 0,
	}
}

# The actions for a sound that should only be heard when `cond` is true.
#
# An empty list is the no-op: nothing plays, and the caller can concatenate it
# unconditionally instead of branching around it.
play_if : Bool, Audio.Sound -> List(Program.Action)
play_if = |cond, sound| if cond [sound.play()] else []

program = { init!, update, render! }

init! : App.Init(Model, [ResourceLimit, SoundGenerationFailed])
init! = App.init(
	App.default.with_title("RocRay Pong"),
	|startup| {
		# Generate the sound effects once; new_round carries the handles forward.
		seed = {
			ball_x: 0,
			ball_y: 0,
			ball_vx: 0,
			ball_vy: 0,
			left_y: 250,
			right_y: 250,
			left_score: 0,
			right_score: 0,
			hit_sound: Audio.gen_tone!({ freq: 440, ms: 60 })?,
			wall_sound: Audio.gen_tone!({ freq: 220, ms: 50 })?,
			score_sound: Audio.gen_tone!({ freq: 160, ms: 200 })?,
			# Entropy is asked for once, here. From this point randomness is
			# model state that `update` advances without an effect.
			rng: Random.from_seed(I32.to_u64_wrap(startup.random_i32!(0, 2_000_000_000))),
		}

		Ok(new_round(seed))
	},
)

## Whether the match is over is a function of the scores, so both `update` and
## `render!` ask rather than storing a flag that could drift out of step.
game_over : Model -> Bool
game_over = |model| model.left_score >= win_score or model.right_score >= win_score

## A frame's outcome: the model it produced, and the sounds it wants heard.
##
## Both steppers return this shape even when one of them can never make a sound,
## so `update` joins them without caring which branch it took.
Stepped : {
	model : Model,
	actions : List(Program.Action),
}

update : Model, Program.Step -> Try(Program.Next(Model), [Exit(I64), ..])
update = |model, step| {
	input = step.input

	# Seconds since the previous frame - the basis for all motion this frame.
	dt = step.time.elapsed_seconds

	exit_actions = if input.key_pressed(KeyEscape) [Program.exit(0)] else []

	stepped = if game_over(model) step_game_over(model, input) else step_playing(model, input, dt)

	Ok({
		model: stepped.model,
		actions: List.concat(exit_actions, stepped.actions),
		tasks: [],
	})
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(Color.black)
	draw_field!(frame, model)

	if game_over(model) {
		winner = if model.left_score >= win_score "LEFT PLAYER WINS" else "RIGHT PLAYER WINS"
		frame.text!({ pos: { x: screen_w * 0.5, y: 260 }, text: winner, size: 40, spacing: Draw.default_spacing, color: Color.yellow, font: Draw.default_font, align: Draw.align_center })
		frame.text!({ pos: { x: screen_w * 0.5, y: 315 }, text: "Press SPACE to restart", size: 24, spacing: Draw.default_spacing, color: Color.white, font: Draw.default_font, align: Draw.align_center })
	}

	Ok({})
}

# --- Win screen: freeze the field and wait for SPACE to start a new game ---
step_game_over : Model, Input.Snapshot -> Stepped
step_game_over = |model, input| {
	model: if input.key_pressed(KeySpace) new_round(model) else model,
	actions: [],
}

# --- Active play ---
## Play is a function of the sampled input and how much time to advance by, so
## the caller passes both rather than a whole frame the stepper would only take
## one field from.
step_playing : Model, Input.Snapshot, F32 -> Stepped
step_playing = |model, input, dt| {

	# --- Left paddle: player input (W up, S down) ---
	w_down = input.key_down(KeyW)
	s_down = input.key_down(KeyS)
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
	# Draw randomness only when a new serve is actually needed.
	# The generator only advances when a serve is actually needed, so an idle
	# rally does not consume draws.
	serve = if out_left or out_right random_serve_vy(model.rng) else { value: vy, next: model.rng }

	final_ball_x = if out_left (screen_w * 0.5) else if out_right (screen_w * 0.5) else nx
	final_ball_y = if out_left (screen_h * 0.5) else if out_right (screen_h * 0.5) else ny
	final_vx = if out_left (init_vx * -1) else if out_right init_vx else vx
	final_vy = if out_left serve.value else if out_right serve.value else vy

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
		rng: serve.next,
	}

	# Sound effects for this frame's events, in the order they used to be played.
	# The platform applies them before anything is drawn, so a paddle hit is
	# still heard on the frame it happened.
	{
		model: next,
		actions: List.concat(
			play_if(hit_left or hit_right, model.hit_sound),
			List.concat(
				play_if(hit_top or hit_bottom, model.wall_sound),
				play_if(out_left or out_right, model.score_sound),
			),
		),
	}
}

# Draw the static scene (center line, paddles, ball, scores) for a model.
draw_field! : Draw.Frame, Model => {}
draw_field! = |frame, model| {
	left_rect = left_paddle(model.left_y)
	right_rect = right_paddle(model.right_y)
	ball_shape = ball_circle(model.ball_x, model.ball_y)

	frame.line!({ start: { x: screen_w * 0.5, y: 0 }, end: { x: screen_w * 0.5, y: screen_h }, stroke: Draw.stroke(Color.dark_gray, 2) })
	frame.rectangle!({ x: left_rect.x, y: left_rect.y, width: left_rect.width, height: left_rect.height, style: Draw.filled(Color.white) })
	frame.rectangle!({ x: right_rect.x, y: right_rect.y, width: right_rect.width, height: right_rect.height, style: Draw.filled(Color.white) })
	frame.circle!({ center: ball_shape.center, radius: ball_shape.radius, style: Draw.filled(Color.ray_white) })
	frame.text!({ pos: { x: screen_w * 0.25, y: 20 }, text: U64.to_str(model.left_score), size: 40, spacing: Draw.default_spacing, color: Color.white, font: Draw.default_font, align: Draw.align_top_center })
	frame.text!({ pos: { x: screen_w * 0.75, y: 20 }, text: U64.to_str(model.right_score), size: 40, spacing: Draw.default_spacing, color: Color.white, font: Draw.default_font, align: Draw.align_top_center })
}
