## Snake drawing derived from loaded assets and the resulting world.
import rr.Color
import rr.App
import rr.Draw
import rr.Math
import rr.Text
import Assets
import Board
import Game
import Snake

Render := [].{

	## Draws one complete Snake presentation frame from the resulting world.
	draw! : Draw.Frame, Assets, Game.World, F32 => Try({}, [ScopeLimit, ..])
	draw! = |frame, assets, world, elapsed| {
		frame.clear!(field_bottom)
		draw_background!(frame)
		draw_hud!(frame, assets, world)
		draw_board!(frame)
		draw_snake!(frame, world.snake)
		draw_glow!(frame, world, elapsed)?
		draw_food_body!(frame, world.food, elapsed)
		draw_cell!(frame, world.snake.head(), snake_head, Color.with_alpha(Color.white, 200))
		draw_game_over!(frame, assets, world, elapsed)
		Ok({})
	}
}

## Paints the dark vertical gradient behind the board.
draw_background! : Draw.Frame => {}
draw_background! = |frame| App.effects().render(frame).rectangle_gradient_v!({ x: 0, y: 0, width: 800, height: 600, color_top: field_top, color_bottom: field_bottom })

## Draws the title, score, and keyboard controls around the board.
draw_hud! : Draw.Frame, Assets, Game.World => {}
draw_hud! = |frame, assets, world| {
	assets.title.draw!(frame, { pos: { x: Board.origin.x, y: 26 }, color: snake_head })
	Text.from("SCORE ${U64.to_str(world.score)}", assets.font).size(24).draw!(frame, { pos: { x: 800 - Board.origin.x, y: 30 }, color: hud_color, align: (Top, Right) })
	assets.hint.draw!(frame, { pos: { x: 400, y: 580 }, color: hint_color, align: (Middle, Center) })
}

## Draws the bordered playfield and its faint cell lattice.
draw_board! : Draw.Frame => {}
draw_board! = |frame| {
	draw = App.effects().render(frame)
	board_w = I32.to_f32(Board.columns) * Board.cell_size
	board_h = I32.to_f32(Board.rows) * Board.cell_size
	draw.rounded_rectangle!({ x: Board.origin.x - 8, y: Board.origin.y - 8, width: board_w + 16, height: board_h + 16, radius: 0.06, segments: 8, style: Draw.filled_and_outlined(board_fill, Color.from_hex_rgb(0x2a3566), 2) })
	for column in List.map_with_index(List.repeat({}, Board.columns_count + 1), |_unit, index| Board.origin.x + U64.to_f32(index) * Board.cell_size) {
		draw.line!({ start: { x: column, y: Board.origin.y }, end: { x: column, y: Board.origin.y + board_h }, stroke: Draw.stroke(grid_line, 1) })
	}
	for row in List.map_with_index(List.repeat({}, Board.rows_count + 1), |_unit, index| Board.origin.y + U64.to_f32(index) * Board.cell_size) {
		draw.line!({ start: { x: Board.origin.x, y: row }, end: { x: Board.origin.x + board_w, y: row }, stroke: Draw.stroke(grid_line, 1) })
	}
}

## Draws one rounded snake cell with a fill and outline.
draw_cell! : Draw.Frame, Board.Cell, Color.Rgba, Color.Rgba => {}
draw_cell! = |frame, cell, fill, outline| {
	draw = App.effects().render(frame)
	rect = Board.cell_rect(cell)
	draw.rounded_rectangle!({ x: rect.x + 2, y: rect.y + 2, width: rect.width - 4, height: rect.height - 4, radius: 0.35, segments: 6, style: Draw.filled_and_outlined(fill, outline, 1) })
}

## Blends the snake color from its bright head toward its blue tail.
segment_color : U64, U64 -> Color.Rgba
segment_color = |index, length| {
	t = if length <= 1 0 else U64.to_f32(index) / U64.to_f32(length - 1)
	mix = |from, to| F32.to_u8_wrap(U8.to_f32(from) + (U8.to_f32(to) - U8.to_f32(from)) * t)
	Color.rgba(mix(snake_head.r, snake_tail.r), mix(snake_head.g, snake_tail.g), mix(snake_head.b, snake_tail.b), 255)
}

## Draws every snake segment with a head-to-tail color gradient.
draw_snake! : Draw.Frame, Snake => {}
draw_snake! = |frame, snake| {
	length = List.len(snake.cells)
	for segment in List.map_with_index(snake.cells, |cell, index| { cell, color: segment_color(index, length) }) {
		draw_cell!(frame, segment.cell, segment.color, Color.with_alpha(segment.color, 90))
	}
}

## Produces the shared breathing pulse for food and restart presentation.
pulse : F32 -> F32
pulse = |elapsed| 0.5 + 0.5 * F32.sin(elapsed * 3.4)

## Draws additive halos behind the food and snake's head.
draw_glow! : Draw.Frame, Game.World, F32 => Try({}, [ScopeLimit, ..])
draw_glow! = |frame, world, elapsed|
	frame.with_blend_mode!(
		Draw.additive_blend,
		|glow_frame| {
			food_pulse = pulse(elapsed)
			glow_draw = App.effects().render(glow_frame)
			glow_draw.circle_gradient!({ center: Math.center(Board.cell_rect(world.food)), radius: Board.cell_size * (1.0 + 0.5 * food_pulse), color_inner: Color.with_alpha(food_neon, F32.to_u8_wrap(70 + 60 * food_pulse)), color_outer: Color.with_alpha(food_neon, 0) })
			glow_draw.circle_gradient!({ center: Math.center(Board.cell_rect(world.snake.head())), radius: Board.cell_size * 1.5, color_inner: Color.with_alpha(snake_head, 90), color_outer: Color.with_alpha(snake_head, 0) })
			Ok({})
		},
	)

## Draws the pulsing apple body and its small highlight.
draw_food_body! : Draw.Frame, Board.Cell, F32 => {}
draw_food_body! = |frame, food, elapsed| {
	draw = App.effects().render(frame)
	center = Math.center(Board.cell_rect(food))
	radius = Board.cell_size * (0.3 + 0.04 * pulse(elapsed))
	draw.circle!({ center, radius, style: Draw.filled(food_neon) })
	draw.circle!({ center: { x: center.x - radius * 0.3, y: center.y - radius * 0.35 }, radius: radius * 0.32, style: Draw.filled(Color.with_alpha(Color.white, 190)) })
}

## Draws the game-over panel and breathing restart prompt after a crash.
draw_game_over! : Draw.Frame, Assets, Game.World, F32 => {}
draw_game_over! = |frame, assets, world, elapsed|
	match world.state {
		Playing => {}
		GameOver => {
			board_w = I32.to_f32(Board.columns) * Board.cell_size
			App.effects().render(frame).rectangle!({ x: Board.origin.x - 8, y: 236, width: board_w + 16, height: 140, style: Draw.filled(Color.with_alpha(field_bottom, 225)) })
			assets.over_title.draw!(frame, { pos: { x: 400, y: 282 }, color: food_neon, align: (Middle, Center) })
			prompt_alpha = F32.to_u8_wrap(150 + 105 * pulse(elapsed))
			assets.over_hint.draw!(frame, { pos: { x: 400, y: 336 }, color: Color.with_alpha(hint_color, prompt_alpha), align: (Middle, Center) })
		}
	}

field_top = Color.from_hex_rgb(0x151d3a)

field_bottom = Color.from_hex_rgb(0x060810)

board_fill = Color.from_hex_rgb(0x0b1226)

grid_line = Color.from_hex_rgb(0x16203f)

snake_head = Color.from_hex_rgb(0x7ef7d1)

snake_tail = Color.from_hex_rgb(0x1d7fb8)

food_neon = Color.from_hex_rgb(0xff6b8b)

hud_color = Color.from_hex_rgb(0xd7e3ff)

hint_color = Color.from_hex_rgb(0x6d7aa8)
