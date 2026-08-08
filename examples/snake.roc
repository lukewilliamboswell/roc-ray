app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.9.0/3sKTYuHvxSV77dDyZrxuUYgfrAarL6ZtasWMPeH32udh.tar.zst" }

import rr.App
import rr.Audio
import rr.Color
import rr.Draw
import rr.Host
import rr.Program
import rr.Random
import rr.Math

Cell : {
	x : I32,
	y : I32,
}

Direction := [DirUp, DirDown, DirLeft, DirRight].{
	is_eq : _
}

GameState := [Playing, GameOver]

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

	## Simulation randomness lives in the model, so food appears on the frame it
	## was eaten and a run replays exactly from its seed.
	rng : Random.Generator,
}

program = { init!, update!, render! }

screen_w : F32
screen_w = 800

screen_h : F32
screen_h = 600

board_x : F32
board_x = 50

board_y : F32
board_y = 72

cell_size : F32
cell_size = 28

grid_cols : I32
grid_cols = 25

grid_rows : I32
grid_rows = 18

step_time : F32
step_time = 0.115

start_snake : List(Cell)
start_snake = [{ x: 12, y: 9 }, { x: 11, y: 9 }, { x: 10, y: 9 }]

init! : App.Init(Model, [ResourceLimit, SoundGenerationFailed])
init! = App.init(
	App.default.with_title("RocRay Snake").with_frame_pacing(Capped(120)),
	|host| {
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
			# Entropy is asked for once, here. From this point randomness is
			# model state that `update` advances without an effect.
			rng: Random.from_seed(I32.to_u64_wrap(host.random_i32!(0, 2_000_000_000))),
		}

		Ok(new_game(seed))
	},
)

new_game : Model -> Model
new_game = |model| {
	spawned = spawn_food(model.rng, start_snake)
	{
		..model,
		rng: spawned.next,
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

delta : Direction -> Cell
delta = |direction|
	match direction {
		DirUp => { x: 0, y: -1 }
		DirDown => { x: 0, y: 1 }
		DirLeft => { x: -1, y: 0 }
		DirRight => { x: 1, y: 0 }
	}

can_turn : Direction, Direction -> Bool
can_turn = |current, requested|
	match current {
		DirUp => requested != DirDown
		DirDown => requested != DirUp
		DirLeft => requested != DirRight
		DirRight => requested != DirLeft
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
spawn_food : Random.Generator, List(Cell) -> { cell : Cell, next : Random.Generator }
spawn_food = |rng, snake| {
	column = Random.in_range(rng, 0, grid_cols - 1)
	row = Random.in_range(column.next, 0, grid_rows - 1)
	{ cell: find_open_cell({ x: column.value, y: row.value }, snake, 0), next: row.next }
}

requested_direction : Model, Host -> Direction
requested_direction = |model, host| {
	up = host.key_pressed(KeyUp) or host.key_pressed(KeyW)
	down = host.key_pressed(KeyDown) or host.key_pressed(KeyS)
	left = host.key_pressed(KeyLeft) or host.key_pressed(KeyA)
	right = host.key_pressed(KeyRight) or host.key_pressed(KeyD)

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

apply_input : Model, Host -> Model
apply_input = |model, host| {
	requested = requested_direction(model, host)
	pending = if can_turn(model.direction, requested) requested else model.pending_direction
	{ ..model, pending_direction: pending }
}

step_snake! : Model => Model
step_snake! = |model| {
	move = delta(model.pending_direction)
	head = head_of(model.snake)
	next_head = { x: head.x + move.x, y: head.y + move.y }
	ate = next_head == model.food
	body_for_collision = if ate model.snake else List.drop_last(model.snake, 1)
	hit_wall = next_head.x < 0 or next_head.x >= grid_cols or next_head.y < 0 or next_head.y >= grid_rows
	hit_self = List.contains(body_for_collision, next_head)

	if hit_wall or hit_self {
		model.crash_sound.play!()
		{ ..model, accumulator: 0, state: GameOver }
	} else {
		next_body = if ate model.snake else List.drop_last(model.snake, 1)
		next_snake = List.prepend(next_body, next_head)

		if ate {
			model.eat_sound.play!()
			spawned = spawn_food(model.rng, next_snake)
			{
				..model,
				snake: next_snake,
				direction: model.pending_direction,
				pending_direction: model.pending_direction,
				food: spawned.cell,
				rng: spawned.next,
				score: model.score + 1,
				accumulator: model.accumulator,
				state: Playing,
			}
		} else {
			{
				..model,
				snake: next_snake,
				direction: model.pending_direction,
				pending_direction: model.pending_direction,
				accumulator: model.accumulator,
				state: Playing,
			}
		}
	}
}

advance_fixed_steps! : Model, Host => Model
advance_fixed_steps! = |model, host| {
	if model.accumulator < step_time {
		model
	} else {
		next = step_snake!({ ..model, accumulator: model.accumulator - step_time })
		match next.state {
			Playing => advance_fixed_steps!(next, host)
			GameOver => next
		}
	}
}

advance_playing! : Model, Host => Model
advance_playing! = |model, host| {
	input_model = apply_input(model, host)
	# Bound catch-up after a breakpoint or stalled window, but retain the fixed
	# step remainder so normal frame-rate variation does not change game speed.
	accumulator = input_model.accumulator + Math.clamp(host.frame_time, 0, 0.25)
	with_accumulator = { ..input_model, accumulator }
	advance_fixed_steps!(with_accumulator, host)
}

update! : Model, Program.Step => Try(Program.Next(Model), [Exit(I64), ..])
update! = |model, step| {
	host = step.input
	if host.key_pressed(KeyEscape) {
		host.exit!(0)
	}

	next = match model.state {
		Playing => advance_playing!(model, host)
		GameOver =>
			if host.key_pressed(KeySpace) {
				model.start_sound.play!()
				new_game(model)
			} else {
				model
			}
		}

	Ok({ model: next, commands: [] })
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(Color.ray_white)
	draw_game!(frame, model)

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
	frame.rounded_rectangle!({ x: rect.x + 2, y: rect.y + 2, width: rect.width - 4, height: rect.height - 4, radius: 6, segments: 6, style: Draw.filled_and_outlined(fill, outline, 2) })
}

draw_food! : Draw.Frame, Cell => {}
draw_food! = |frame, food| {
	rect = cell_rect(food)
	frame.circle!({ center: { x: rect.x + rect.width * 0.5, y: rect.y + rect.height * 0.5 }, radius: cell_size * 0.36, style: Draw.filled_and_outlined(Color.red, Color.dark_gray, 2) })
}

draw_snake_cells! : Draw.Frame, List(Cell) => {}
draw_snake_cells! = |frame, snake| {
	for cell in snake {
		draw_cell!(frame, cell, Color.from_hex_rgb(0x23c552), Color.from_hex_rgb(0x0d5f2a))
	}
}

draw_board! : Draw.Frame => {}
draw_board! = |frame| {
	board_w = I32.to_f32(grid_cols) * cell_size
	board_h = I32.to_f32(grid_rows) * cell_size
	frame.rectangle!({ x: board_x - 4, y: board_y - 4, width: board_w + 8, height: board_h + 8, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x17202a), Color.dark_gray, 2) })
}

draw_game! : Draw.Frame, Model => {}
draw_game! = |frame, model| {
	frame.text_at!({ pos: { x: board_x, y: 24 }, text: "Snake", size: 32, color: Color.dark_gray })
	frame.text_at!({ pos: { x: screen_w - 190, y: 32 }, text: Str.concat("Score ", U64.to_str(model.score)), size: 22, color: Color.gray })
	draw_board!(frame)
	draw_food!(frame, model.food)
	draw_snake_cells!(frame, model.snake)
	draw_cell!(frame, head_of(model.snake), Color.yellow, Color.from_hex_rgb(0x0d5f2a))

	match model.state {
		Playing => {}
		GameOver => {
			frame.rectangle!({ x: board_x, y: 250, width: I32.to_f32(grid_cols) * cell_size, height: 120, style: Draw.filled(Color.with_alpha(Color.black, 210)) })
			frame.text_centered!({ pos: { x: screen_w * 0.5, y: 286 }, text: "Game Over", size: 36, color: Color.white })
			frame.text_centered!({ pos: { x: screen_w * 0.5, y: 330 }, text: "Press SPACE to restart", size: 22, color: Color.light_gray })
		}
	}
}
