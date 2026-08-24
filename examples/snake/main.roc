## Play Snake with the arrow keys; press Space after a crash to restart and
## Escape to quit. The game demonstrates movement at a fixed rate independent
## of drawing speed, reproducible random food placement, and sound effects
## chosen by game rules and played from `update!`.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Time
import rr.Audio
import rr.Color
import rr.Draw
import rr.Devices
import rr.Random
import rr.Math
import rr.Text

Cell : {
	x : I32,
	y : I32,
}

Direction := [DirUp, DirDown, DirLeft, DirRight].{
	is_eq : _

	delta : Direction -> Cell
	delta = |direction|
		match direction {
			DirUp => { x: 0, y: -1 }
			DirDown => { x: 0, y: 1 }
			DirLeft => { x: -1, y: 0 }
			DirRight => { x: 1, y: 0 }
		}

	can_turn_to : Direction, Direction -> Bool
	can_turn_to = |current, requested|
		match current {
			DirUp => requested != DirDown
			DirDown => requested != DirUp
			DirLeft => requested != DirRight
			DirRight => requested != DirLeft
		}
}

GameState := [Playing, GameOver]

## State retained between updates: the snake board and score, queued direction,
## fixed-rate timing, repeatable random state, audio and font resources, and a
## small animation timer. These values are enough for the next update to
## continue the same game and for `render!` to draw it.
Model : {
	snake : List(Cell),
	direction : Direction,
	pending_direction : Direction,
	food : Cell,
	score : U64,
	accumulator : F32,
	state : GameState,
	eat_sound : Audio.Sound,
	crash_sound : Audio.Sound,
	start_sound : Audio.Sound,
	font : Text.Font,

	## Wall-clock seconds since launch, advanced by `update!` and used only by
	## the renderer, to pulse the food and breathe the restart prompt.
	elapsed : F32,

	## Text measured once in `init!`. Only the score changes per frame, and it
	## is short enough to lay out inline.
	title : Text.Prepared,
	hint : Text.Prepared,
	over_title : Text.Prepared,
	over_hint : Text.Prepared,

	## Simulation randomness lives in the model, so food appears on the frame it
	## was eaten and a run replays exactly from its seed.
	rng : Random.State,
}

## What a slice of simulation produced: the model it left behind, and the sounds
## it made getting there.
##
## One frame can run several fixed steps, and each of them can crash or eat, so
## the sounds have to be carried out of the recursion rather than returned by
## whichever step happened to be last.
Stepped : {
	model : Model,
	sounds : List(Audio.Playback),
}

program = { init!, update!, render! }

screen_w = 800.F32

screen_h = 600.F32

board_x = 75.F32

board_y = 80.F32

cell_size = 26.F32

grid_cols = 25.I32

grid_rows = 18.I32

# The same two counts as `U64`, for the list-shaped loops the renderer uses.
grid_cols_count = 25.U64

grid_rows_count = 18.U64

step_time = 0.115.F32

# --- Palette: one dark cabinet, a cyan snake, a warm apple ---
field_top : Color.Rgba
field_top = Color.from_hex_rgb(0x151d3a)

field_bottom : Color.Rgba
field_bottom = Color.from_hex_rgb(0x060810)

board_fill : Color.Rgba
board_fill = Color.from_hex_rgb(0x0b1226)

grid_line : Color.Rgba
grid_line = Color.from_hex_rgb(0x16203f)

snake_head : Color.Rgba
snake_head = Color.from_hex_rgb(0x7ef7d1)

snake_tail : Color.Rgba
snake_tail = Color.from_hex_rgb(0x1d7fb8)

food_neon : Color.Rgba
food_neon = Color.from_hex_rgb(0xff6b8b)

hint_color : Color.Rgba
hint_color = Color.from_hex_rgb(0x6d7aa8)

start_snake : List(Cell)
start_snake = [{ x: 12, y: 9 }, { x: 11, y: 9 }, { x: 10, y: 9 }]

init! : App.Init(Model, [ResourceLimit, SoundGenerationFailed])
init! = App.init(
	App.default.with_title("RocRay Snake").with_size({ width: 800, height: 600 }).with_frame_pacing(Capped(120)),
	|startup| {
		font = Draw.default_font!()
		seed = {
			snake: start_snake,
			direction: DirRight,
			pending_direction: DirRight,
			food: { x: 18, y: 9 },
			score: 0,
			accumulator: 0,
			state: Playing,
			eat_sound: Audio.gen_tone!({ freq: 620, ms: 70 })?,
			crash_sound: Audio.gen_tone!({ freq: 120, ms: 180 })?,
			start_sound: Audio.gen_tone!({ freq: 360, ms: 80 })?,
			font: font,
			elapsed: 0,
			title: Text.from("SNAKE", font).size(30).spacing(6).prepare!()?,
			hint: Text.from("ARROWS / WASD  turn    SPACE  restart    ESC  quit", font).size(17).prepare!()?,
			over_title: Text.from("GAME OVER", font).size(40).prepare!()?,
			over_hint: Text.from("PRESS SPACE TO PLAY AGAIN", font).size(19).prepare!()?,
			# Entropy is asked for once, here. From this point randomness is
			# model state that `update!` advances without an effect, so this
			# whole run reproduces from the one number below. Replace it with
			# a constant to get the same game every time.
			rng: Random.seed(U64.to_u32_wrap(App.entropy!(startup))),
		}

		Ok(new_game(seed))
	},
)

new_game : Model -> Model
new_game = |model| {
	spawned = spawn_food(model.rng, start_snake)
	{
		..model,
		rng: spawned.state,
		snake: start_snake,
		direction: DirRight,
		pending_direction: DirRight,
		food: spawned.cell,
		score: 0,
		accumulator: 0,
		state: Playing,
	}
}

head_of : List(Cell) -> Cell
head_of = |snake|
	match List.first(snake) {
		Ok(head) => head
		Err(_) => { x: 0, y: 0 }
	}

find_open_cell : Cell, List(Cell), I32 -> Cell
find_open_cell = |seed, snake, attempt| {
	cell_count = grid_cols * grid_rows
	if attempt >= cell_count {
		seed
	} else {
		flat_index = (seed.y * grid_cols + seed.x + attempt) % cell_count
		candidate = {
			x: flat_index % grid_cols,
			y: flat_index // grid_cols,
		}
		if List.contains(snake, candidate) find_open_cell(seed, snake, attempt + 1) else candidate
	}
}

# Drawing from the model's generator rather than an effect keeps food placement
# immediate, and makes a run replay exactly from its seed.
spawn_food : Random.State, List(Cell) -> { cell : Cell, state : Random.State }
spawn_food = |state, snake| {
	column = Random.step(state, Random.bounded_i32(0, grid_cols - 1))
	row = Random.next(column, Random.bounded_i32(0, grid_rows - 1))
	{ cell: find_open_cell({ x: column.value, y: row.value }, snake, 0), state: row.state }
}

requested_direction : Model, Devices.Snapshot -> Direction
requested_direction = |model, input| {
	up = input.key_pressed(KeyUp) or input.key_pressed(KeyW)
	down = input.key_pressed(KeyDown) or input.key_pressed(KeyS)
	left = input.key_pressed(KeyLeft) or input.key_pressed(KeyA)
	right = input.key_pressed(KeyRight) or input.key_pressed(KeyD)

	if up {
		DirUp
	} else if down {
		DirDown
	} else if left {
		DirLeft
	} else if right {
		DirRight
	} else {
		model.pending_direction
	}
}

apply_input : Model, Devices.Snapshot -> Model
apply_input = |model, input| {
	requested = requested_direction(model, input)
	pending = if model.direction.can_turn_to(requested) requested else model.pending_direction
	{ ..model, pending_direction: pending }
}

step_snake : Model -> Stepped
step_snake = |model| {
	move = model.pending_direction.delta()
	head = head_of(model.snake)
	next_head = { x: head.x + move.x, y: head.y + move.y }
	ate = next_head == model.food
	body_for_collision = if ate model.snake else List.drop_last(model.snake, 1)
	hit_wall = next_head.x < 0 or next_head.x >= grid_cols or next_head.y < 0 or next_head.y >= grid_rows
	hit_self = List.contains(body_for_collision, next_head)

	if hit_wall or hit_self {
		{
			model: { ..model, accumulator: 0, state: GameOver },
			sounds: [model.crash_sound.playback()],
		}
	} else {
		next_body = if ate model.snake else List.drop_last(model.snake, 1)
		next_snake = List.prepend(next_body, next_head)

		if ate {
			spawned = spawn_food(model.rng, next_snake)
			{
				model: {
					..model,
					snake: next_snake,
					direction: model.pending_direction,
					pending_direction: model.pending_direction,
					food: spawned.cell,
					rng: spawned.state,
					score: model.score + 1,
					accumulator: model.accumulator,
					state: Playing,
				},
				sounds: [model.eat_sound.playback()],
			}
		} else {
			{
				model: {
					..model,
					snake: next_snake,
					direction: model.pending_direction,
					pending_direction: model.pending_direction,
					accumulator: model.accumulator,
					state: Playing,
				},
				sounds: [],
			}
		}
	}
}

## Run as many fixed steps as the accumulator has paid for, carrying the sounds
## along.
##
## `sounds` is the running total rather than something the tail returns: a
## frame that catches up over three steps can eat twice and then crash, and all
## three sounds have to survive, in that order. Returning only the last step's
## sounds would silently drop the earlier ones.
advance_fixed_steps : Model, List(Audio.Playback) -> Stepped
advance_fixed_steps = |model, sounds| {
	if model.accumulator < step_time {
		{ model, sounds }
	} else {
		stepped = step_snake({ ..model, accumulator: model.accumulator - step_time })
		so_far = List.concat(sounds, stepped.sounds)
		match stepped.model.state {
			Playing => advance_fixed_steps(stepped.model, so_far)
			GameOver => { model: stepped.model, sounds: so_far }
		}
	}
}

## Fold one frame's worth of time into the accumulator and run the steps it pays
## for.
##
## `dt` arrives already bounded rather than being read from a frame here: this
## takes the seconds it should advance by, so a caller can hand it a real
## cycle's elapsed time or a fixed step without inventing a `Time.Cycle` that
## never happened.
advance_playing : Model, Devices.Snapshot, F32 -> Stepped
advance_playing = |model, input, dt| {
	input_model = apply_input(model, input)
	accumulator = input_model.accumulator + dt
	with_accumulator = { ..input_model, accumulator }
	advance_fixed_steps(with_accumulator, [])
}

## A model with no host resources behind it, so the rules above can be exercised
## from an `expect`. `Audio.Sound.stub` is a sound that plays nothing, which is
## all a pure test needs of one.
test_model : Model
test_model = {
	snake: start_snake,
	direction: DirRight,
	pending_direction: DirRight,
	food: { x: 18, y: 9 },
	score: 0,
	accumulator: 0,
	state: Playing,
	eat_sound: Audio.Sound.stub,
	crash_sound: Audio.Sound.stub,
	start_sound: Audio.Sound.stub,
	font: Text.font_stub,
	elapsed: 0,
	title: Text.Prepared.stub,
	hint: Text.Prepared.stub,
	over_title: Text.Prepared.stub,
	over_hint: Text.Prepared.stub,
	rng: Random.seed(1),
}

expect {
	direction : Direction
	direction = DirUp
	direction.delta() == { x: 0, y: -1 }
}

## A turn into the body is refused; any other turn is allowed.
expect {
	direction : Direction
	direction = DirRight
	!direction.can_turn_to(DirLeft)
}

expect {
	direction : Direction
	direction = DirRight
	direction.can_turn_to(DirUp)
}

## Food never lands on the snake: the probe walks on until it finds a free cell.
expect find_open_cell({ x: 12, y: 9 }, start_snake, 0) == { x: 13, y: 9 }

## An ordinary step moves the head one cell and drops the tail, so the length
## holds and nothing sounds.
expect {
	stepped = step_snake(test_model)
	head_of(stepped.model.snake) == { x: 13, y: 9 } and List.len(stepped.model.snake) == 3 and List.is_empty(stepped.sounds)
}

## Eating keeps the tail, scores, and asks for a sound.
expect {
	stepped = step_snake({ ..test_model, food: { x: 13, y: 9 } })
	List.len(stepped.model.snake) == 4 and stepped.model.score == 1 and List.len(stepped.sounds) == 1
}

## Walking off the board ends the run.
expect {
	stepped = step_snake({ ..test_model, snake: [{ x: 24, y: 9 }] })
	match stepped.model.state {
		GameOver => Bool.True
		Playing => Bool.False
	}
}

## The accumulator is what makes speed independent of frame rate: two steps'
## worth of seconds runs two steps, whether that arrived as one frame or four.
expect {
	stepped = advance_playing(test_model, Devices.none, step_time * 2)
	head_of(stepped.model.snake) == { x: 14, y: 9 }
}

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	input = program_input.devices

	# Bound catch-up after a breakpoint or stalled window, but retain the fixed
	# step remainder so normal frame-rate variation does not change game speed.
	dt = Math.clamp(program_input.time.elapsed_seconds, 0, 0.25)

	stepped = match model.state {
		Playing => advance_playing(model, input, dt)
		GameOver =>
			if input.key_pressed(KeySpace) {
				{ model: new_game(model), sounds: [model.start_sound.playback()] }
			} else {
				{ model, sounds: [] }
			}
		}

	# The step is pure and says which sounds it made, in order; this is where
	# they are played.
	for playback in stepped.sounds {
		playback.play!()
	}

	if input.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		Ok({ ..stepped.model, elapsed: stepped.model.elapsed + dt })
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ..])
render! = |model, frame| {
	frame.clear!(field_bottom)
	frame.rectangle_gradient_v!({ x: 0, y: 0, width: screen_w, height: screen_h, color_top: field_top, color_bottom: field_bottom })
	draw_hud!(frame, model)
	draw_board!(frame)
	draw_snake_cells!(frame, model.snake)

	# Everything that glows shares one additive scope, so overlapping light adds
	# up instead of stacking as translucent grey.
	frame.with_blend_mode!(
		Draw.additive_blend,
		|glow_frame| {
			draw_food!(glow_frame, model)
			head_rect = cell_rect(head_of(model.snake))
			glow_frame.circle_gradient!({
				center: Math.center(head_rect),
				radius: cell_size * 1.5,
				color_inner: Color.with_alpha(snake_head, 90),
				color_outer: Color.with_alpha(snake_head, 0),
			})
			Ok({})
		},
	)?

	draw_food_body!(frame, model)
	draw_cell!(frame, head_of(model.snake), snake_head, Color.with_alpha(Color.white, 200))
	draw_game_over!(frame, model)

	Ok({})
}

cell_rect : Cell -> Math.Rect
cell_rect = |cell| {
	x: board_x + I32.to_f32(cell.x) * cell_size,
	y: board_y + I32.to_f32(cell.y) * cell_size,
	width: cell_size,
	height: cell_size,
}

draw_cell! : Draw.Frame, Cell, Color.Rgba, Color.Rgba => {}
draw_cell! = |frame, cell, fill, outline| {
	rect = cell_rect(cell)
	frame.rounded_rectangle!({ x: rect.x + 2, y: rect.y + 2, width: rect.width - 4, height: rect.height - 4, radius: 0.35, segments: 6, style: Draw.filled_and_outlined(fill, outline, 1) })
}

# The apple breathes: one sine of the model's own clock drives both the halo
# radius and its brightness, so the board never sits completely still.
food_pulse : Model -> F32
food_pulse = |model| 0.5 + 0.5 * F32.sin(model.elapsed * 3.4)

draw_food! : Draw.Frame, Model => {}
draw_food! = |frame, model| {
	pulse = food_pulse(model)
	frame.circle_gradient!({
		center: Math.center(cell_rect(model.food)),
		radius: cell_size * (1.0 + 0.5 * pulse),
		color_inner: Color.with_alpha(food_neon, F32.to_u8_wrap(70 + 60 * pulse)),
		color_outer: Color.with_alpha(food_neon, 0),
	})
}

draw_food_body! : Draw.Frame, Model => {}
draw_food_body! = |frame, model| {
	center = Math.center(cell_rect(model.food))
	radius = cell_size * (0.3 + 0.04 * food_pulse(model))
	frame.circle!({ center: center, radius: radius, style: Draw.filled(food_neon) })
	frame.circle!({ center: { x: center.x - radius * 0.3, y: center.y - radius * 0.35 }, radius: radius * 0.32, style: Draw.filled(Color.with_alpha(Color.white, 190)) })
}

# The body fades from head to tail. Mixing the two palette colors by position
# rather than giving every segment one color is what reads as a direction of
# travel when the snake is long.
segment_color : U64, U64 -> Color.Rgba
segment_color = |index, length| {
	t = if length <= 1 0 else U64.to_f32(index) / U64.to_f32(length - 1)
	mix = |from, to| F32.to_u8_wrap(U8.to_f32(from) + (U8.to_f32(to) - U8.to_f32(from)) * t)
	Color.rgba(mix(snake_head.r, snake_tail.r), mix(snake_head.g, snake_tail.g), mix(snake_head.b, snake_tail.b), 255)
}

draw_snake_cells! : Draw.Frame, List(Cell) => {}
draw_snake_cells! = |frame, snake| {
	length = List.len(snake)
	for segment in List.map_with_index(snake, |cell, index| { cell, color: segment_color(index, length) }) {
		draw_cell!(frame, segment.cell, segment.color, Color.with_alpha(segment.color, 90))
	}
}

draw_board! : Draw.Frame => {}
draw_board! = |frame| {
	board_w = I32.to_f32(grid_cols) * cell_size
	board_h = I32.to_f32(grid_rows) * cell_size
	frame.rounded_rectangle!({ x: board_x - 8, y: board_y - 8, width: board_w + 16, height: board_h + 16, radius: 0.06, segments: 8, style: Draw.filled_and_outlined(board_fill, Color.from_hex_rgb(0x2a3566), 2) })

	# A faint lattice, so a cell is a place rather than an empty field.
	for column in List.map_with_index(List.repeat({}, grid_cols_count + 1), |_unit, index| board_x + U64.to_f32(index) * cell_size) {
		frame.line!({ start: { x: column, y: board_y }, end: { x: column, y: board_y + board_h }, stroke: Draw.stroke(grid_line, 1) })
	}
	for row in List.map_with_index(List.repeat({}, grid_rows_count + 1), |_unit, index| board_y + U64.to_f32(index) * cell_size) {
		frame.line!({ start: { x: board_x, y: row }, end: { x: board_x + board_w, y: row }, stroke: Draw.stroke(grid_line, 1) })
	}
}

draw_hud! : Draw.Frame, Model => {}
draw_hud! = |frame, model| {
	model.title.draw!(frame, { pos: { x: board_x, y: 26 }, color: snake_head, align: Text.align_top_left })
	frame.text!({ pos: { x: screen_w - board_x, y: 30 }, text: "SCORE ${U64.to_str(model.score)}", size: 24, spacing: Draw.default_spacing, color: Color.from_hex_rgb(0xd7e3ff), font: model.font, align: Draw.align_top_right })
	model.hint.draw!(frame, { pos: { x: screen_w * 0.5, y: screen_h - 20 }, color: hint_color, align: Text.align_center })
}

draw_game_over! : Draw.Frame, Model => {}
draw_game_over! = |frame, model|
	match model.state {
		Playing => {}
		GameOver => {
			board_w = I32.to_f32(grid_cols) * cell_size
			frame.rectangle!({ x: board_x - 8, y: 236, width: board_w + 16, height: 140, style: Draw.filled(Color.with_alpha(field_bottom, 225)) })
			model.over_title.draw!(frame, { pos: { x: screen_w * 0.5, y: 282 }, color: food_neon, align: Text.align_center })
			# The prompt breathes on the same clock as the food, so a waiting
			# screen still has a heartbeat.
			prompt_alpha = F32.to_u8_wrap(150 + 105 * food_pulse(model))
			model.over_hint.draw!(frame, { pos: { x: screen_w * 0.5, y: 336 }, color: Color.with_alpha(hint_color, prompt_alpha), align: Text.align_center })
		}
	}
