## Play Pong against a computer-controlled right paddle.
##
## Use W and S to move, Space to serve or start a new match, and Escape to quit.
## This example shows frame-rate-independent movement, separating game rules
## from sound effects, and seeded random serves that can be reproduced.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.Draw
import rr.Color
import rr.Devices
import rr.Random
import rr.Audio
import rr.App
import rr.Math
import rr.Text

## State kept between updates: ball and paddle movement, scores, visual effects,
## prepared text and sounds, and the random generator used for serves. Keeping
## both game state and short-lived presentation details here lets `render!`
## draw the latest result without changing the game.
Model := {
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
	font : Draw.Font,

	## Presentation state, advanced by the same pure step as the rules.
	## `trail` is the ball's recent positions, newest first; `flash` decays from
	## 1 to 0 after a hit or a point and tints a full-screen additive wash.
	trail : List(Math.Vec2),
	flash : F32,
	flash_color : Color.Rgba,

	## Text measured once in `init!`: the HUD hint and one glyph per reachable
	## score, so no frame pays to lay out a digit that never changes.
	hint : Text.Prepared,
	digits : List(Text.Prepared),

	## Index 0 is the left player's banner, index 1 the right player's.
	win_lines : List(Text.Prepared),
	restart_line : Text.Prepared,

	## Simulation randomness lives in the model, so a serve is drawn on the
	## frame that needs it and a run replays exactly from its seed.
	rng : Random.State,
}.{

	## The match ends as soon as either score reaches the winning score.
	is_over : Model -> Bool
	is_over = |model| model.left_score >= win_score or model.right_score >= win_score
}

# --- Constants (screen is 800x600; speeds in pixels/second) ---
screen_w = 800.F32

screen_h = 600.F32

paddle_w = 15.F32

paddle_h = 100.F32

paddle_margin = 30.F32

ball_r = 10.F32

paddle_speed = 360.F32

ai_speed = 270.F32

init_vx = 260.F32

# vy gained per pixel of offset between ball and paddle centre on a hit
bounce_factor = 6.F32

# First player to this many points wins.
win_score = 5.U64

# The ball's comet: how many past positions to keep, and how far apart to
# sample them.
trail_length = 14.U64

trail_spacing = 11.F32

# --- Palette: one dark field, two rival neons, one warm ball ---
field_top = Color.from_hex_rgb(0x141a35)

field_bottom = Color.from_hex_rgb(0x05060f)

left_neon = Color.from_hex_rgb(0x38e8ff)

right_neon = Color.from_hex_rgb(0xff4fa3)

ball_neon = Color.from_hex_rgb(0xffe7a3)

hint_color = Color.from_hex_rgb(0x6d7aa8)

# A random vertical serve speed in px/second, so each serve leaves at a
# different angle instead of the same predictable line.
# Drawing from the model's own generator rather than an effect keeps the serve
# immediate: the ball leaves on the frame that scored, not the frame after.
random_serve_vy : Random.State -> Random.Generation(F32)
random_serve_vy = |state| {
	drawn = Random.step(state, Random.bounded_i32(-160, 160))
	{ value: I32.to_f32(drawn.value), state: drawn.state }
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
	direction = Random.step(model.rng, Random.bounded_i32(0, 1))
	serve = random_serve_vy(direction.state)
	{
		..model,
		ball_x: screen_w * 0.5,
		ball_y: screen_h * 0.5,
		ball_vx: if direction.value == 0 (init_vx * -1) else init_vx,
		ball_vy: serve.value,
		rng: serve.state,
		left_y: 250,
		right_y: 250,
		left_score: 0,
		right_score: 0,
		trail: [],
		flash: 0,
		flash_color: ball_neon,
	}
}

# The trail is sampled by distance, not by frame: at 240 frames a second a
# per-frame trail would sit entirely inside the ball, and at 30 it would be a
# dashed line. Recording only once the ball has moved `trail_spacing` pixels
# gives the same comet at any frame rate.
push_trail : List(Math.Vec2), Math.Vec2 -> List(Math.Vec2)
push_trail = |trail, pos|
	match List.first(trail) {
		Ok(head) if Math.distance_squared(head, pos) < trail_spacing * trail_spacing => trail
		_ => List.take_first(List.prepend(trail, pos), trail_length)
	}

# The playback for a sound that should only be heard when `cond` is true.
#
# An empty list is the no-op: nothing plays, and the caller can concatenate it
# unconditionally instead of branching around it.
play_if : Bool, Audio.Sound -> List(Audio.Playback)
play_if = |cond, sound| if cond [sound.playback()] else []

program = { init!, update!, render! }

init! : App.Init(Model, [ResourceLimit, SoundGenerationFailed])
init! = App.init(
	App.default.with_title("RocRay Pong").with_size({ width: 800, height: 600 }),
	|startup| {
		# Generate the sound effects once; new_round carries the handles forward.
		font = Draw.default_font!()
		# Only scores 0..win_score can ever be shown, so the whole scoreboard is
		# prepared here and a frame just picks the glyph it needs.
		digits = List.map_try(
			List.map_with_index(List.repeat({}, win_score + 1), |_unit, index| U64.to_str(index)),
			|glyph| Text.from(glyph, font).size(64).prepare!(),
		)?
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
			font: font,
			trail: [],
			flash: 0,
			flash_color: ball_neon,
			hint: Text.from("W / S  move    SPACE  serve    ESC  quit", font).size(18).prepare!()?,
			digits: digits,
			win_lines: [
				Text.from("LEFT PLAYER WINS", font).size(44).prepare!()?,
				Text.from("RIGHT PLAYER WINS", font).size(44).prepare!()?,
			],
			restart_line: Text.from("PRESS SPACE FOR A NEW MATCH", font).size(20).prepare!()?,
			# Entropy is asked for once, here. From this point randomness is
			# model state that `update!` advances without an effect, so this
			# whole run reproduces from the one number below. Replace it with
			# a constant to get the same game every time.
			rng: Random.seed(U64.to_u32_wrap(App.entropy!(startup))),
		}

		Ok(new_round(seed))
	},
)

## A frame's outcome: the model it produced, and the sounds it wants heard.
##
## Both steppers return this shape even when one of them can never make a sound,
## so `update!` joins them without caring which branch it took.
Stepped : {
	model : Model,
	sounds : List(Audio.Playback),
}

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	input = program_input.devices

	# Seconds since the previous frame - the basis for all motion this frame.
	dt = program_input.time.elapsed_seconds

	stepped = if model.is_over() step_game_over(model, input) else step_playing(model, input, dt)

	# The step is pure and says which sounds this frame made; playing them is
	# the one effect here.
	for playback in stepped.sounds {
		playback.play!()
	}

	if input.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		Ok(stepped.model)
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ..])
render! = |model, frame| {
	frame.clear!(field_bottom)
	# The field is a vertical gradient rather than flat black, so the paddles
	# and the glow below have something to sit on.
	frame.rectangle_gradient_v!({ x: 0, y: 0, width: screen_w, height: screen_h, color_top: field_top, color_bottom: field_bottom })
	draw_center_line!(frame)
	draw_scores!(frame, model)

	# One additive scope covers everything that glows, so overlapping light
	# reads as brighter rather than as stacked grey.
	frame.with_blend_mode!(
		Draw.additive_blend,
		|glow_frame| {
			draw_trail!(glow_frame, model)
			draw_glow!(glow_frame, model)
			# Alpha zero when the flash has decayed, so no branch is needed here.
			wash = Color.with_alpha(model.flash_color, F32.to_u8_wrap(model.flash * 70))
			glow_frame.rectangle!({ x: 0, y: 0, width: screen_w, height: screen_h, style: Draw.filled(wash) })
			Ok({})
		},
	)?

	draw_bodies!(frame, model)

	if model.is_over() {
		# Dim the frozen field so the banner reads, then name the winner.
		frame.rectangle!({ x: 0, y: 0, width: screen_w, height: screen_h, style: Draw.filled(Color.with_alpha(field_bottom, 190)) })
		winner_index = if model.left_score >= win_score 0 else 1
		winner_color = if winner_index == 0 left_neon else right_neon
		match List.get(model.win_lines, winner_index) {
			Ok(line) => line.draw!(frame, { pos: { x: screen_w * 0.5, y: 268 }, color: winner_color, align: Text.align_center })
			Err(_) => {}
		}
		model.restart_line.draw!(frame, { pos: { x: screen_w * 0.5, y: 326 }, color: hint_color, align: Text.align_center })
	} else {}

	model.hint.draw!(frame, { pos: { x: screen_w * 0.5, y: screen_h - 26 }, color: hint_color, align: Text.align_center })

	Ok({})
}

# Soft dashes rather than one hard rule: the halfway point is marked without
# competing with the paddles for attention.
draw_center_line! : Draw.Frame => {}
draw_center_line! = |frame| {
	for dash in List.map_with_index(List.repeat({}, 15), |_unit, index| 12 + U64.to_f32(index) * 40) {
		y = dash
		frame.rounded_rectangle!({ x: screen_w * 0.5 - 2, y: y, width: 4, height: 22, radius: 1, segments: 4, style: Draw.filled(Color.from_hex_rgb(0x2a3566)) })
	}
}

# Newest position first, so the index is the age of the sample: alpha and radius
# both fall off with it and the ball drags a short comet tail.
draw_trail! : Draw.Frame, Model => {}
draw_trail! = |frame, model| {
	for sample in List.map_with_index(model.trail, |pos, index| { pos, fade: 1 - U64.to_f32(index) / U64.to_f32(trail_length) }) {
		frame.circle!({
			center: sample.pos,
			radius: ball_r * (0.35 + 0.55 * sample.fade),
			style: Draw.filled(Color.with_alpha(ball_neon, F32.to_u8_wrap(sample.fade * sample.fade * 130))),
		})
	}
}

# Radial gradients fading to fully transparent, drawn additively, are the
# cheapest convincing bloom available without a shader.
draw_glow! : Draw.Frame, Model => {}
draw_glow! = |frame, model| {
	halo! = |center, color, radius| frame.circle_gradient!({
		center: center,
		radius: radius,
		color_inner: Color.with_alpha(color, 100),
		color_outer: Color.with_alpha(color, 0),
	})

	halo!(Math.center(left_paddle(model.left_y)), left_neon, 68)
	halo!(Math.center(right_paddle(model.right_y)), right_neon, 68)
	halo!({ x: model.ball_x, y: model.ball_y }, ball_neon, 46)
}

# The solid bodies, drawn over their own glow so the edges stay crisp.
draw_bodies! : Draw.Frame, Model => {}
draw_bodies! = |frame, model| {
	left_rect = left_paddle(model.left_y)
	right_rect = right_paddle(model.right_y)

	frame.rounded_rectangle!({ x: left_rect.x, y: left_rect.y, width: left_rect.width, height: left_rect.height, radius: 0.5, segments: 8, style: Draw.filled(left_neon) })
	frame.rounded_rectangle!({ x: right_rect.x, y: right_rect.y, width: right_rect.width, height: right_rect.height, radius: 0.5, segments: 8, style: Draw.filled(right_neon) })
	frame.circle!({ center: { x: model.ball_x, y: model.ball_y }, radius: ball_r, style: Draw.filled(ball_neon) })
	frame.circle!({ center: { x: model.ball_x - 2, y: model.ball_y - 3 }, radius: ball_r * 0.42, style: Draw.filled(Color.white) })
}

# Scores are prepared glyphs picked by value, so a frame lays out no text.
draw_scores! : Draw.Frame, Model => {}
draw_scores! = |frame, model| {
	draw_score! = |score, x, color|
		match List.get(model.digits, score) {
			Ok(glyph) => glyph.draw!(frame, { pos: { x: x, y: 30 }, color: color, align: Text.align_top_center })
			Err(_) => {}
		}

	draw_score!(model.left_score, screen_w * 0.32, Color.with_alpha(left_neon, 220))
	draw_score!(model.right_score, screen_w * 0.68, Color.with_alpha(right_neon, 220))
}

# --- Win screen: freeze the field and wait for SPACE to start a new game ---
step_game_over : Model, Devices.Snapshot -> Stepped
step_game_over = |model, input| {
	model: if input.key_pressed(KeySpace) new_round(model) else { ..model, flash: F32.max(model.flash - 0.02, 0) },
	sounds: [],
}

# --- Active play ---
## Play is a function of the sampled input and how much time to advance by, so
## the caller passes both rather than a whole frame the stepper would only take
## one field from.
step_playing : Model, Devices.Snapshot, F32 -> Stepped
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
	serve = if out_left or out_right random_serve_vy(model.rng) else { value: vy, state: model.rng }

	final_ball_x = if out_left (screen_w * 0.5) else if out_right (screen_w * 0.5) else nx
	final_ball_y = if out_left (screen_h * 0.5) else if out_right (screen_h * 0.5) else ny
	final_vx = if out_left (init_vx * -1) else if out_right init_vx else vx
	final_vy = if out_left serve.value else if out_right serve.value else vy

	left_score = if out_right model.left_score + 1 else model.left_score
	right_score = if out_left model.right_score + 1 else model.right_score

	scored = out_left or out_right
	paddled = hit_left or hit_right

	# Presentation, derived from the events this frame already computed: a point
	# flashes hard in the scorer's colour, a hit gently, and otherwise the
	# previous flash decays.
	flash =
		if scored 1.0
		else if paddled 0.45
		else if hit_top or hit_bottom 0.22
		else F32.max(model.flash - dt * 2.4, 0)
	flash_color =
		if out_right left_neon
		else if out_left right_neon
		else if hit_left left_neon
		else if hit_right right_neon
		else model.flash_color

	# A serve teleports the ball, so the trail is cleared rather than stretched
	# across the field as one long streak.
	trail = if scored [] else push_trail(model.trail, { x: final_ball_x, y: final_ball_y })

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
		rng: serve.state,
		trail: trail,
		flash: flash,
		flash_color: flash_color,
	}

	# Sound effects for this frame's events, in the order they are played.
	{
		model: next,
		sounds: List.concat(
			play_if(hit_left or hit_right, model.hit_sound),
			List.concat(
				play_if(hit_top or hit_bottom, model.wall_sound),
				play_if(out_left or out_right, model.score_sound),
			),
		),
	}
}

## A model with no host resources behind it, so the steppers above can be
## exercised from an `expect`. The stubs are a font that measures nothing and
## sounds that play nothing, which is all a pure test asks of them.
test_model : Model
test_model = {
	ball_x: screen_w * 0.5,
	ball_y: screen_h * 0.5,
	ball_vx: init_vx,
	ball_vy: 0,
	left_y: 250,
	right_y: 250,
	left_score: 0,
	right_score: 0,
	hit_sound: Audio.Sound.stub,
	wall_sound: Audio.Sound.stub,
	score_sound: Audio.Sound.stub,
	font: Draw.Font.stub,
	trail: [],
	flash: 0,
	flash_color: ball_neon,
	hint: Text.Prepared.stub,
	digits: [],
	win_lines: [],
	restart_line: Text.Prepared.stub,
	rng: Random.seed(1),
}

expect !test_model.is_over()
expect { ..test_model, right_score: win_score }.is_over()

## The empty list is the no-op, so a caller can concatenate unconditionally.
expect List.is_empty(play_if(Bool.False, Audio.Sound.stub))
expect List.len(play_if(Bool.True, Audio.Sound.stub)) == 1

## The top wall reflects the ball and asks for one sound.
expect {
	stepped = step_playing({ ..test_model, ball_y: ball_r, ball_vy: -100 }, Devices.none, 0.1)
	stepped.model.ball_vy > 0 and List.len(stepped.sounds) == 1
}

## A ball past the right edge scores for the left player and re-serves from the
## centre.
expect {
	stepped = step_playing({ ..test_model, ball_x: screen_w - 5 }, Devices.none, 0.1)
	stepped.model.left_score == 1 and stepped.model.ball_x == screen_w * 0.5
}

## The win screen holds until SPACE, and SPACE starts a whole new match rather
## than resuming the old one.
expect {
	finished = { ..test_model, left_score: win_score }
	step_game_over(finished, Devices.none).model.left_score == win_score
		and step_game_over(finished, Devices.none.with_key_pressed(KeySpace)).model.left_score == 0
}
