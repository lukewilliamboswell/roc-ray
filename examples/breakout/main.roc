## A complete Breakout game with keyboard controls, sound, and an automated
## recording mode. Use Left/Right or A/D to move, Space to launch, and Escape
## to quit. Pass `--record-demo` to create `examples/breakout/demo.gif`. The
## example separates game rules from input, sound effects, and drawing.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/3vVeddfDE6rraq5j8v1cGHtFNaQhC6dij1zGRN63NGP1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Audio
import rr.Color
import rr.Capture
import rr.Draw
import rr.Devices
import rr.Math
import rr.Text

Brick : {
	id : U64,
	rect : Math.Rect,
	color : Color.Rgba,
}

Ball : {
	pos : Math.Vec2,
	vel : Math.Vec2,
}

BrickRow := [RedRow, OrangeRow, YellowRow, GreenRow, BlueRow]

PaddleMove := [PaddleLeft, PaddleRight, PaddleStill]

GameState := [Ready, Playing, Won, GameOver].{
	is_eq : _
}

StepEvent := [GameStarted, WallHit, BrickHit(Brick), LifeLost(GameState), WallCleared].{
	is_eq : _
}

## The complete playable state. `advance` applies one pure game step and reports
## events for `update!` to turn into sounds.
Game := {
	bricks : List(Brick),
	paddle_x : F32,
	ball : Ball,
	score : U64,
	lives : U64,
	state : GameState,
}.{
	advance : Game, FrameInput -> StepResult
	advance = |game, input|
		match game.state {
			Ready => advance_ready(game, input)
			Playing => advance_playing(game, input)
			Won => advance_finished(game, input)
			GameOver => advance_finished(game, input)
		}
}

Sounds : {
	paddle : Audio.Sound,
	brick : Audio.Sound,
	wall : Audio.Sound,
	lose : Audio.Sound,
	start : Audio.Sound,
}

## The Model is the state retained between updates. It keeps the current game,
## loaded sounds, recording-mode choice, animation time, and prepared text so
## `render!` can draw without rebuilding resources every frame.
Model : {
	game : Game,
	sounds : Sounds,
	demo : Bool,

	## Presentation only. `elapsed` is wall-clock seconds, used to breathe the
	## prompts; the rest is text the host measured once at startup.
	elapsed : F32,
	title : Text.Prepared,
	hint : Text.Prepared,
	launch_line : Text.Prepared,
	won_line : Text.Prepared,
	over_line : Text.Prepared,
	restart_line : Text.Prepared,
	font : Text.Font,
}

FrameInput : {
	paddle_move : PaddleMove,
	action_pressed : Bool,
	dt : F32,
}

StepResult : {
	game : Game,
	events : List(StepEvent),
	paddle_hit : Bool,
}

program = { init!, update!, render! }

screen_w = 800.F32

screen_h = 600.F32

# --- Palette: a dark cabinet, a cyan paddle, a warm ball ---
field_top : Color.Rgba
field_top = Color.from_hex_rgb(0x161d3c)

field_bottom : Color.Rgba
field_bottom = Color.from_hex_rgb(0x05070f)

paddle_neon : Color.Rgba
paddle_neon = Color.from_hex_rgb(0x38e8ff)

ball_neon : Color.Rgba
ball_neon = Color.from_hex_rgb(0xffe08a)

hud_color : Color.Rgba
hud_color = Color.from_hex_rgb(0xd7e3ff)

hint_color : Color.Rgba
hint_color = Color.from_hex_rgb(0x6d7aa8)

top_wall_y = 58.F32

paddle_w = 112.F32

paddle_h = 16.F32

paddle_y = 548.F32

paddle_speed = 460.F32

paddle_bounce_speed = 360.F32

ball_radius = 8.F32

ball_ready_gap = 2.F32

ball_bounce_gap = 1.F32

launch_vx = 170.F32

launch_vy = -340.F32

brick_left = 44.F32

brick_top = 88.F32

brick_w = 64.F32

brick_h = 22.F32

brick_gap = 8.F32

bricks_per_row = 10.U64

brick_score = 10.U64

brick_band_top = 84.F32

brick_band_bottom = 236.F32

initial_lives = 3.U64

demo_frames = 150.U64

record_demo_flag : Str
record_demo_flag = "--record-demo"

breakout_config : List(Str) -> App.Config
breakout_config = |args| {
	base = App.default.with_title("RocRay Breakout").with_frame_pacing(Capped(120))

	if List.contains(args, record_demo_flag) {
		base
			.with_visible(Bool.False)
			.with_output_dir("examples/breakout")
			.with_recording(
				Capture.default
					.with_path("demo.gif")
					.with_format(Gif)
					.with_fps(25)
					.with_max_frames(demo_frames)
					.with_scale(Half)
					.with_timing(FixedStep),
			)
	} else {
		base
	}
}

init! : App.Init(Model, [ResourceLimit, SoundGenerationFailed])
init! = App.init_for_args(
	breakout_config,
	|startup| {
		font = Draw.default_font!()
		Ok({
			game: new_game_state(),
			demo: List.contains(App.args!(startup), record_demo_flag),
			elapsed: 0,
			font: font,
			title: Text.from("BREAKOUT", font).size(28).spacing(5).prepare!()?,
			hint: Text.from("A / D  or  ARROWS  move    SPACE  launch    ESC  quit", font).size(17).prepare!()?,
			launch_line: Text.from("PRESS SPACE TO LAUNCH", font).size(26).prepare!()?,
			won_line: Text.from("WALL CLEARED", font).size(34).prepare!()?,
			over_line: Text.from("GAME OVER", font).size(34).prepare!()?,
			restart_line: Text.from("PRESS SPACE TO PLAY AGAIN", font).size(19).prepare!()?,
			sounds: {
				paddle: Audio.gen_tone!({ freq: 440, ms: 50 })?,
				brick: Audio.gen_tone!({ freq: 760, ms: 45 })?,
				wall: Audio.gen_tone!({ freq: 260, ms: 40 })?,
				lose: Audio.gen_tone!({ freq: 140, ms: 180 })?,
				start: Audio.gen_tone!({ freq: 520, ms: 70 })?,
			},
		})
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

brick_row_color : BrickRow -> Color.Rgba
brick_row_color = |row|
	match row {
		RedRow => Color.from_hex_rgb(0xff4f7d)
		OrangeRow => Color.from_hex_rgb(0xff9f45)
		YellowRow => Color.from_hex_rgb(0xffe066)
		GreenRow => Color.from_hex_rgb(0x4ce0b3)
		BlueRow => Color.from_hex_rgb(0x5a9dff)
	}

brick_row_y : BrickRow -> F32
brick_row_y = |row| brick_top + U64.to_f32(brick_row_index(row)) * (brick_h + brick_gap)

brick_col_x : U64 -> F32
brick_col_x = |col| brick_left + U64.to_f32(col) * (brick_w + brick_gap)

brick_at : U64, F32, F32, Color.Rgba -> Brick
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

paddle_move_from_input : Devices.Snapshot -> PaddleMove
paddle_move_from_input = |input| {
	left = input.key_down(KeyLeft) or input.key_down(KeyA)
	right = input.key_down(KeyRight) or input.key_down(KeyD)

	if left PaddleLeft else if right PaddleRight else PaddleStill
}

paddle_move_dir : PaddleMove -> F32
paddle_move_dir = |move|
	match move {
		PaddleLeft => -1
		PaddleRight => 1
		PaddleStill => 0
	}

## The step's own `dt` is a parameter rather than something read off a frame,
## because the caller decides how much time this step covers -- a fixed step can
## be handed straight in, which a sampled frame could not express.
frame_input : Devices.Snapshot, F32 -> FrameInput
frame_input = |input, dt| {
	paddle_move: paddle_move_from_input(input),
	action_pressed: input.key_pressed(KeySpace),
	dt,
}

## A demo follows the ball with the ordinary paddle movement rules. It starts
## immediately and restarts after a life, while interactive play keeps using
## the sampled keyboard input above.
demo_frame_input : Game, F32 -> FrameInput
demo_frame_input = |game, dt| {
	paddle_center = game.paddle_x + paddle_w * 0.5
	delta = game.ball.pos.x - paddle_center
	paddle_move = if delta < -8 PaddleLeft else if delta > 8 PaddleRight else PaddleStill
	{
		paddle_move,
		action_pressed: game.state != Playing,
		dt,
	}
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
		{ game: { ..ready_game, state: Playing }, events: [GameStarted], paddle_hit: Bool.False }
	} else {
		{ game: ready_game, events: [], paddle_hit: Bool.False }
	}
}

advance_finished : Game, FrameInput -> StepResult
advance_finished = |game, input| {
	if input.action_pressed {
		{ game: new_game_state(), events: [GameStarted], paddle_hit: Bool.False }
	} else {
		{ game, events: [], paddle_hit: Bool.False }
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
			paddle_hit: Bool.False,
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
		base_events = event_when(hit_wall, WallHit)

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
					paddle_hit: hit_paddle,
				}
			}
			Err(_) => {
				game: { ..game, paddle_x, ball: paddle_ball, state: Playing },
				events: base_events,
				paddle_hit: hit_paddle,
			}
		}
	}
}

## One sound per event, in the order the step produced them.
##
## `List.map` rather than a fold: every event makes exactly one sound, so the
## playback list is the event list retyped, and two brick hits in one step stay
## two brick sounds.
step_event_sounds : Sounds, List(StepEvent) -> List(Audio.Playback)
step_event_sounds = |sounds, events|
	List.map(
		events,
		|event|
			match event {
				GameStarted => sounds.start.playback()
				WallHit => sounds.wall.playback()
				BrickHit(_) => sounds.brick.playback()
				LifeLost(_) => sounds.lose.playback()
				WallCleared => sounds.start.playback()
			},
	)

## `Game.advance` is a pure step returning events, and the events name the
## sounds they want; `update!` is where those sounds are played.
Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	input = program_input.devices
	dt = program_input.time.elapsed_seconds
	exit =
		if model.demo {
			match program_input.capture {
				Finished(_) => Err(Exit(0))
				Failed(_) => Err(Exit(1))
				_ => Ok({})
			}
		} else if input.key_pressed(KeyEscape) {
			Err(Exit(0))
		} else {
			Ok({})
		}

	game_input = if model.demo demo_frame_input(model.game, dt) else frame_input(input, dt)
	result = model.game.advance(game_input)
	if result.paddle_hit {
		model.sounds.paddle.play!()
	}
	for playback in step_event_sounds(model.sounds, result.events) {
		playback.play!()
	}

	match exit {
		Err(code) => Err(code)
		Ok({}) => Ok({ ..model, game: result.game, elapsed: model.elapsed + dt })
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ..])
render! = |model, frame| {
	draw = App.effects().render(frame)
	game = model.game
	frame.clear!(field_bottom)
	draw.rectangle_gradient_v!({ x: 0, y: 0, width: screen_w, height: screen_h, color_top: field_top, color_bottom: field_bottom })
	draw_hud!(frame, model)
	draw_bricks!(frame, game.bricks)

	# One additive scope for everything that emits light, so the halos add up
	# rather than stacking as translucent grey.
	frame.with_blend_mode!(
		Draw.additive_blend,
		|glow_frame| {
			paddle = paddle_rect(game.paddle_x)
			glow_draw = App.effects().render(glow_frame)
			glow_draw.circle_gradient!({ center: Math.center(paddle), radius: 90, color_inner: Color.with_alpha(paddle_neon, 95), color_outer: Color.with_alpha(paddle_neon, 0) })
			glow_draw.circle_gradient!({ center: game.ball.pos, radius: 46, color_inner: Color.with_alpha(ball_neon, 95), color_outer: Color.with_alpha(ball_neon, 0) })
			Ok({})
		},
	)?

	draw_bodies!(frame, game)
	draw_state_overlay!(frame, model)

	Ok({})
}

# Each brick is its own colour with a brighter sheen along the top edge, which
# is what keeps a flat rectangle from reading as a flat rectangle.
draw_brick! : Draw.Frame, Brick => {}
draw_brick! = |frame, brick| {
	draw = App.effects().render(frame)
	draw.rounded_rectangle!({ x: brick.rect.x, y: brick.rect.y, width: brick.rect.width, height: brick.rect.height, radius: 0.28, segments: 6, style: Draw.filled(Color.with_alpha(brick.color, 235)) })
	draw.rectangle!({ x: brick.rect.x + 5, y: brick.rect.y + 3, width: brick.rect.width - 10, height: 3, style: Draw.filled(Color.with_alpha(Color.white, 110)) })
}

draw_bricks! : Draw.Frame, List(Brick) => {}
draw_bricks! = |frame, bricks| {
	for brick in bricks {
		draw_brick!(frame, brick)
	}
}

draw_bodies! : Draw.Frame, Game => {}
draw_bodies! = |frame, game| {
	draw = App.effects().render(frame)
	paddle = paddle_rect(game.paddle_x)
	draw.rounded_rectangle!({ x: paddle.x, y: paddle.y, width: paddle.width, height: paddle.height, radius: 0.5, segments: 8, style: Draw.filled(paddle_neon) })
	draw.rectangle!({ x: paddle.x + 8, y: paddle.y + 3, width: paddle.width - 16, height: 3, style: Draw.filled(Color.with_alpha(Color.white, 150)) })
	draw.circle!({ center: game.ball.pos, radius: ball_radius, style: Draw.filled(ball_neon) })
	draw.circle!({ center: { x: game.ball.pos.x - 2, y: game.ball.pos.y - 2 }, radius: ball_radius * 0.4, style: Draw.filled(Color.with_alpha(Color.white, 210)) })
}

draw_hud! : Draw.Frame, Model => {}
draw_hud! = |frame, model| {
	draw = App.effects().render(frame)
	model.title.draw!(frame, { pos: { x: 44, y: 22 }, color: paddle_neon })
	draw.text!({ pos: { x: 330, y: 26 }, text: "SCORE ${U64.to_str(model.game.score)}", size: 22, spacing: Draw.default_spacing, color: hud_color, font: model.font })
	draw.text!({ pos: { x: 560, y: 26 }, text: "LIVES ${U64.to_str(model.game.lives)}", size: 22, spacing: Draw.default_spacing, color: hud_color, font: model.font })
	if model.demo {} else draw.fps!({ pos: { x: 730, y: 28 }, size: 18, color: hint_color })
	draw.line!({ start: { x: 44, y: top_wall_y }, end: { x: screen_w - 44, y: top_wall_y }, stroke: Draw.stroke(Color.from_hex_rgb(0x2a3566), 2) })
	model.hint.draw!(frame, { pos: { x: screen_w * 0.5, y: screen_h - 20 }, color: hint_color, align: (Middle, Center) })
}

# A prompt that fades in and out on its own clock, so a waiting screen still has
# a heartbeat.
prompt_alpha : Model -> U8
prompt_alpha = |model| F32.to_u8_wrap(150 + 105 * (0.5 + 0.5 * F32.sin(model.elapsed * 3.4)))

draw_state_overlay! : Draw.Frame, Model => {}
draw_state_overlay! = |frame, model|
	match model.game.state {
		Ready =>
			model.launch_line.draw!(frame, { pos: { x: screen_w * 0.5, y: 350 }, color: Color.with_alpha(hud_color, prompt_alpha(model)), align: (Middle, Center) })
		Playing => {}
		Won => draw_banner!(frame, model, model.won_line, Color.from_hex_rgb(0x4ce0b3))
		GameOver => draw_banner!(frame, model, model.over_line, Color.from_hex_rgb(0xff4f7d))
	}

draw_banner! : Draw.Frame, Model, Text.Prepared, Color.Rgba => {}
draw_banner! = |frame, model, line, accent| {
	draw = App.effects().render(frame)
	draw.rounded_rectangle!({ x: 190, y: 276, width: 420, height: 124, radius: 0.14, segments: 8, style: Draw.filled_and_outlined(Color.with_alpha(field_bottom, 232), Color.with_alpha(accent, 120), 2) })
	line.draw!(frame, { pos: { x: screen_w * 0.5, y: 318 }, color: accent, align: (Middle, Center) })
	model.restart_line.draw!(frame, { pos: { x: screen_w * 0.5, y: 362 }, color: Color.with_alpha(hint_color, prompt_alpha(model)), align: (Middle, Center) })
}
