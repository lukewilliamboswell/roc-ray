## Play Pong against a computer-controlled right paddle.
##
## Use W and S to move, Space to start a new match after game over, and Escape
## to quit. This example shows semantic controls, separate assets and world
## state, gameplay events, and seeded random serves that can be reproduced.
## File structure:
##
## - State: sounds and text plus the ball, paddles, scores, trail, and serve RNG
## - Controls: W/S movement, Space restart, and Escape quit
## - App wiring: loads assets, advances each cycle, and plays event sounds
## - Rendering: draws the neon court, scores, ball trail, and win banner
## - Gameplay: pure rules that move paddles, bounce the ball, and report hits and points
## - Tests: checks key mapping, wall bounces, scoring, and match restart
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/3vVeddfDE6rraq5j8v1cGHtFNaQhC6dij1zGRN63NGP1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.Draw
import rr.Color
import rr.Devices
import rr.Random
import rr.Audio
import rr.App
import rr.Math
import rr.Text

## Host resources loaded once at startup and retained for drawing and sound.
## Keeping them outside `World` lets the game rules operate only on ordinary
## gameplay data.
Assets : {
	hit_sound : Audio.Sound,
	wall_sound : Audio.Sound,
	score_sound : Audio.Sound,
	font : Text.Font,
	hint : Text.Prepared,
	digits : List(Text.Prepared),
	win_lines : List(Text.Prepared),
	restart_line : Text.Prepared,
}

## Dynamic game and presentation state advanced by the pure game step.
Ball : {
	pos : Math.Vec2,
	velocity : Math.Vec2,
}

Player : {
	paddle_y : F32,
	score : U64,
}

World : {
	ball : Ball,
	left : Player,
	right : Player,

	## Presentation state, advanced by the same pure step as the rules.
	## `trail` is the ball's recent positions, newest first; `flash` decays from
	## 1 to 0 after a hit or a point and tints a full-screen additive wash.
	trail : List(Math.Vec2),
	flash : {
		intensity : F32,
		color : Color.Rgba,
	},

	## Simulation randomness lives in the model, so a serve is drawn on the
	## frame that needs it and a run replays exactly from its seed.
	rng : Random.State,
}

## The application owns both host resources and the complete changing world.
Model := {
	assets : Assets,
	world : World,
}

## Gameplay sees intentions, not the keys currently bound to them.
Controls : {
	move : F32,
	new_match_pressed : Bool,
	quit_pressed : Bool,
}

## The match ends as soon as either score reaches the winning score.
is_over : World -> Bool
is_over = |world| world.left.score >= win_score or world.right.score >= win_score

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

# A fresh match: ball centred, scores zeroed, served in a random direction.
new_match : World -> World
new_match = |world| {
	# Direction then speed, drawn in that order from one generator, so the
	# sequence is the same every time a given seed replays.
	direction = Random.step(world.rng, Random.bounded_i32(0, 1))
	serve = random_serve_vy(direction.state)
	{
		..world,
		ball: {
			pos: { x: screen_w * 0.5, y: screen_h * 0.5 },
			velocity: {
				x: if direction.value == 0 (init_vx * -1) else init_vx,
				y: serve.value,
			},
		},
		rng: serve.state,
		left: { paddle_y: 250, score: 0 },
		right: { paddle_y: 250, score: 0 },
		trail: [],
		flash: { intensity: 0, color: ball_neon },
	}
}

read_controls : Devices.Snapshot -> Controls
read_controls = |devices| {
	move: if devices.key_down(KeyW) -1 else if devices.key_down(KeyS) 1 else 0,
	new_match_pressed: devices.key_pressed(KeySpace),
	quit_pressed: devices.key_pressed(KeyEscape),
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

program = { init!, update!, render! }

init! : App.Init(Model, [ResourceLimit, SoundGenerationFailed])
init! = App.init(
	App.default.with_title("RocRay Pong").with_size({ width: 800, height: 600 }),
	|startup| {
		# Generate and prepare every host resource before the first cycle.
		font = Draw.default_font!()
		# Only scores 0..win_score can ever be shown, so the whole scoreboard is
		# prepared here and a frame just picks the glyph it needs.
		digits = List.map_try(
			List.map_with_index(List.repeat({}, win_score + 1), |_unit, index| U64.to_str(index)),
			|glyph| Text.from(glyph, font).size(64).prepare!(),
		)?
		assets = {
			hit_sound: Audio.gen_tone!({ freq: 440, ms: 60 })?,
			wall_sound: Audio.gen_tone!({ freq: 220, ms: 50 })?,
			score_sound: Audio.gen_tone!({ freq: 160, ms: 200 })?,
			font: font,
			hint: Text.from("W / S  move    SPACE  new match    ESC  quit", font).size(18).prepare!()?,
			digits: digits,
			win_lines: [
				Text.from("LEFT PLAYER WINS", font).size(44).prepare!()?,
				Text.from("RIGHT PLAYER WINS", font).size(44).prepare!()?,
			],
			restart_line: Text.from("PRESS SPACE FOR A NEW MATCH", font).size(20).prepare!()?,
		}
		world_seed = {
			ball: { pos: { x: 0, y: 0 }, velocity: { x: 0, y: 0 } },
			left: { paddle_y: 250, score: 0 },
			right: { paddle_y: 250, score: 0 },
			trail: [],
			flash: { intensity: 0, color: ball_neon },
			# Entropy is asked for once, here. From this point randomness is
			# model state that `update!` advances without an effect, so this
			# whole run reproduces from the one number below. Replace it with
			# a constant to get the same game every time.
			rng: Random.seed(U64.to_u32_wrap(App.entropy!(startup))),
		}

		Ok({ assets, world: new_match(world_seed) })
	},
)

## Significant gameplay occurrences interpreted by the application boundary.
GameEvent := [PaddleHit, WallHit, PointScored]

play_event! : Assets, GameEvent => {}
play_event! = |assets, event|
	match event {
		PaddleHit => assets.hit_sound.playback().play!()
		WallHit => assets.wall_sound.playback().play!()
		PointScored => assets.score_sound.playback().play!()
	}

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	controls = read_controls(program_input.devices)

	# Seconds since the previous frame - the basis for all motion this frame.
	dt = program_input.time.elapsed_seconds

	(world, events) = if is_over(model.world) {
		step_game_over(model.world, controls)
	} else {
		step_playing(model.world, controls, dt)
	}

	# The step reports gameplay events; the application boundary interprets
	# those events as effects without putting sound handles in the world.
	for event in events {
		play_event!(model.assets, event)
	}

	if controls.quit_pressed {
		Err(Exit(0))
	} else {
		Ok({ ..model, world })
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ..])
render! = |model, frame| {
	assets = model.assets
	world = model.world
	frame.clear!(field_bottom)
	# The field is a vertical gradient rather than flat black, so the paddles
	# and the glow below have something to sit on.
	frame.rectangle_gradient_v!({ x: 0, y: 0, width: screen_w, height: screen_h, color_top: field_top, color_bottom: field_bottom })
	draw_center_line!(frame)
	draw_scores!(frame, assets, world)

	# One additive scope covers everything that glows, so overlapping light
	# reads as brighter rather than as stacked grey.
	frame.with_blend_mode!(
		Draw.additive_blend,
		|glow_frame| {
			draw_trail!(glow_frame, world)
			draw_glow!(glow_frame, world)
			# Alpha zero when the flash has decayed, so no branch is needed here.
			wash = Color.with_alpha(world.flash.color, F32.to_u8_wrap(world.flash.intensity * 70))
			glow_frame.rectangle!({ x: 0, y: 0, width: screen_w, height: screen_h, style: Draw.filled(wash) })
			Ok({})
		},
	)?

	draw_bodies!(frame, world)

	if is_over(world) {
		# Dim the frozen field so the banner reads, then name the winner.
		frame.rectangle!({ x: 0, y: 0, width: screen_w, height: screen_h, style: Draw.filled(Color.with_alpha(field_bottom, 190)) })
		winner_index = if world.left.score >= win_score 0 else 1
		winner_color = if winner_index == 0 left_neon else right_neon
		match List.get(assets.win_lines, winner_index) {
			Ok(line) => line.draw!(frame, { pos: { x: screen_w * 0.5, y: 268 }, color: winner_color, align: (Middle, Center) })
			Err(_) => {}
		}
		assets.restart_line.draw!(frame, { pos: { x: screen_w * 0.5, y: 326 }, color: hint_color, align: (Middle, Center) })
	} else {}

	assets.hint.draw!(frame, { pos: { x: screen_w * 0.5, y: screen_h - 26 }, color: hint_color, align: (Middle, Center) })

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
draw_trail! : Draw.Frame, World => {}
draw_trail! = |frame, world| {
	for sample in List.map_with_index(world.trail, |pos, index| { pos, fade: 1 - U64.to_f32(index) / U64.to_f32(trail_length) }) {
		frame.circle!({
			center: sample.pos,
			radius: ball_r * (0.35 + 0.55 * sample.fade),
			style: Draw.filled(Color.with_alpha(ball_neon, F32.to_u8_wrap(sample.fade * sample.fade * 130))),
		})
	}
}

# Radial gradients fading to fully transparent, drawn additively, are the
# cheapest convincing bloom available without a shader.
draw_glow! : Draw.Frame, World => {}
draw_glow! = |frame, world| {
	halo! = |center, color, radius| frame.circle_gradient!({
		center: center,
		radius: radius,
		color_inner: Color.with_alpha(color, 100),
		color_outer: Color.with_alpha(color, 0),
	})

	halo!(Math.center(left_paddle(world.left.paddle_y)), left_neon, 68)
	halo!(Math.center(right_paddle(world.right.paddle_y)), right_neon, 68)
	halo!(world.ball.pos, ball_neon, 46)
}

# The solid bodies, drawn over their own glow so the edges stay crisp.
draw_bodies! : Draw.Frame, World => {}
draw_bodies! = |frame, world| {
	left_rect = left_paddle(world.left.paddle_y)
	right_rect = right_paddle(world.right.paddle_y)

	frame.rounded_rectangle!({ x: left_rect.x, y: left_rect.y, width: left_rect.width, height: left_rect.height, radius: 0.5, segments: 8, style: Draw.filled(left_neon) })
	frame.rounded_rectangle!({ x: right_rect.x, y: right_rect.y, width: right_rect.width, height: right_rect.height, radius: 0.5, segments: 8, style: Draw.filled(right_neon) })
	frame.circle!({ center: world.ball.pos, radius: ball_r, style: Draw.filled(ball_neon) })
	frame.circle!({ center: { x: world.ball.pos.x - 2, y: world.ball.pos.y - 3 }, radius: ball_r * 0.42, style: Draw.filled(Color.white) })
}

# Scores are prepared glyphs picked by value, so a frame lays out no text.
draw_scores! : Draw.Frame, Assets, World => {}
draw_scores! = |frame, assets, world| {
	draw_score! = |score, x, color|
		match List.get(assets.digits, score) {
			Ok(glyph) => glyph.draw!(frame, { pos: { x: x, y: 30 }, color: color, align: (Top, Center) })
			Err(_) => {}
		}

	draw_score!(world.left.score, screen_w * 0.32, Color.with_alpha(left_neon, 220))
	draw_score!(world.right.score, screen_w * 0.68, Color.with_alpha(right_neon, 220))
}

# --- Win screen: freeze the field and wait for SPACE to start a new game ---
step_game_over : World, Controls -> (World, List(GameEvent))
step_game_over = |world, controls| {
	next_world = if controls.new_match_pressed new_match(world) else { ..world, flash: { ..world.flash, intensity: F32.max(world.flash.intensity - 0.02, 0) } }
	(next_world, [])
}

# --- Active play ---
## Play is a function of the sampled input and how much time to advance by, so
## the caller passes both rather than a whole frame the stepper would only take
## one field from.
step_playing : World, Controls, F32 -> (World, List(GameEvent))
step_playing = |world, controls, dt| {

	# --- Left paddle: semantic player movement ---
	left_y = Math.clamp(world.left.paddle_y + controls.move * paddle_speed * dt, 0, screen_h - paddle_h)

	# --- Right paddle: simple AI tracks the ball's vertical position ---
	right_center = world.right.paddle_y + paddle_h * 0.5
	right_dir = if world.ball.pos.y < right_center - 4 (ai_speed * -1) else if world.ball.pos.y > right_center + 4 ai_speed else 0
	right_y = Math.clamp(world.right.paddle_y + right_dir * dt, 0, screen_h - paddle_h)

	# --- Move ball ---
	nx0 = world.ball.pos.x + world.ball.velocity.x * dt
	ny0 = world.ball.pos.y + world.ball.velocity.y * dt

	# Bounce off top / bottom walls
	hit_top = ny0 - ball_r < 0
	hit_bottom = ny0 + ball_r > screen_h
	ny = if hit_top ball_r else if hit_bottom (screen_h - ball_r) else ny0
	vy_wall = if hit_top (world.ball.velocity.y * -1) else if hit_bottom (world.ball.velocity.y * -1) else world.ball.velocity.y

	# Paddle geometry
	left_rect = left_paddle(left_y)
	right_rect = right_paddle(right_y)
	ball_shape = ball_circle(nx0, ny)

	# Paddle collisions (reflect horizontally; set vy from where the ball struck)
	hit_left = world.ball.velocity.x < 0 and nx0 >= Math.left(left_rect) and Math.circle_rect(ball_shape, left_rect)
	hit_right = world.ball.velocity.x > 0 and nx0 <= Math.right(right_rect) and Math.circle_rect(ball_shape, right_rect)

	left_paddle_center = Math.center(left_rect).y
	right_paddle_center = Math.center(right_rect).y

	nx = if hit_left (Math.right(left_rect) + ball_r) else if hit_right (Math.left(right_rect) - ball_r) else nx0
	vx = if hit_left (world.ball.velocity.x * -1) else if hit_right (world.ball.velocity.x * -1) else world.ball.velocity.x
	vy = if hit_left ((ny - left_paddle_center) * bounce_factor) else if hit_right ((ny - right_paddle_center) * bounce_factor) else vy_wall

	# --- Scoring: ball left the field on the left or right edge ---
	out_left = nx - ball_r < 0
	out_right = nx + ball_r > screen_w
	# Draw randomness only when a new serve is actually needed.
	# The generator only advances when a serve is actually needed, so an idle
	# rally does not consume draws.
	serve = if out_left or out_right random_serve_vy(world.rng) else { value: vy, state: world.rng }

	final_ball = {
		pos: {
			x: if out_left or out_right (screen_w * 0.5) else nx,
			y: if out_left or out_right (screen_h * 0.5) else ny,
		},
		velocity: {
			x: if out_left (init_vx * -1) else if out_right init_vx else vx,
			y: if out_left or out_right serve.value else vy,
		},
	}

	left = { paddle_y: left_y, score: if out_right world.left.score + 1 else world.left.score }
	right = { paddle_y: right_y, score: if out_left world.right.score + 1 else world.right.score }

	scored = out_left or out_right
	paddled = hit_left or hit_right

	# Presentation, derived from the events this frame already computed: a point
	# flashes hard in the scorer's colour, a hit gently, and otherwise the
	# previous flash decays.
	flash_intensity =
		if scored 1.0
		else if paddled 0.45
		else if hit_top or hit_bottom 0.22
		else F32.max(world.flash.intensity - dt * 2.4, 0)
	flash_color =
		if out_right left_neon
		else if out_left right_neon
		else if hit_left left_neon
		else if hit_right right_neon
		else world.flash.color

	# A serve teleports the ball, so the trail is cleared rather than stretched
	# across the field as one long streak.
	trail = if scored [] else push_trail(world.trail, final_ball.pos)

	next = {
		..world,
		ball: final_ball,
		left: left,
		right: right,
		rng: serve.state,
		trail: trail,
		flash: { intensity: flash_intensity, color: flash_color },
	}

	# Gameplay events for this frame, in the order the boundary handles them.
	(
		next,
		List.concat(
			if hit_left or hit_right [PaddleHit] else [],
			List.concat(
				if hit_top or hit_bottom [WallHit] else [],
				if out_left or out_right [PointScored] else [],
			),
		),
	)
}

## Ordinary game data and neutral controls make the simulation directly
## testable without host resources or platform input.
test_world : World
test_world = {
	ball: {
		pos: { x: screen_w * 0.5, y: screen_h * 0.5 },
		velocity: { x: init_vx, y: 0 },
	},
	left: { paddle_y: 250, score: 0 },
	right: { paddle_y: 250, score: 0 },
	trail: [],
	flash: { intensity: 0, color: ball_neon },
	rng: Random.seed(1),
}

no_controls : Controls
no_controls = { move: 0, new_match_pressed: Bool.False, quit_pressed: Bool.False }

expect !is_over(test_world)
expect is_over({ ..test_world, right: { ..test_world.right, score: win_score } })

## Raw key bindings are translated once at the edge of the application.
expect read_controls(Devices.none.with_key_down(KeyW)).move == -1
expect read_controls(Devices.none.with_key_pressed(KeyEscape)).quit_pressed

## The top wall reflects the ball and reports one event.
expect {
	ball = {
		..test_world.ball,
		pos: { ..test_world.ball.pos, y: ball_r },
		velocity: { ..test_world.ball.velocity, y: -100 },
	}
	(world, events) = step_playing({ ..test_world, ball }, no_controls, 0.1)
	world.ball.velocity.y > 0 and List.len(events) == 1
}

## A ball past the right edge scores for the left player and re-serves from the
## centre.
expect {
	ball = { ..test_world.ball, pos: { ..test_world.ball.pos, x: screen_w - 5 } }
	(world, _) = step_playing({ ..test_world, ball }, no_controls, 0.1)
	world.left.score == 1 and world.ball.pos.x == screen_w * 0.5
}

## The win screen holds until SPACE, and SPACE starts a whole new match rather
## than resuming the old one.
expect {
	finished = { ..test_world, left: { ..test_world.left, score: win_score } }
	new_match_controls = { ..no_controls, new_match_pressed: Bool.True }
	(waiting_world, _) = step_game_over(finished, no_controls)
	(restarted_world, _) = step_game_over(finished, new_match_controls)
	waiting_world.left.score == win_score and restarted_world.left.score == 0
}
