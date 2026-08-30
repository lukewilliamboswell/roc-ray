## The authored brick wall and operations that change it.
import rr.Color
import rr.Math

Bricks := [].{
	Brick : {
		id : U64,
		rect : Math.Rect,
		color : Color.Rgba,
	}

	Row := [Red, Orange, Yellow, Green, Blue]

	left = 44.F32

	top = 88.F32

	width = 64.F32

	height = 22.F32

	gap = 8.F32

	per_row = 10.U64

	band_top = 84.F32

	band_bottom = 236.F32

	score = 10.U64

	## Converts a named brick row into its zero-based vertical index.
	row_index : Row -> U64
	row_index = |row|
		match row {
			Red => 0
			Orange => 1
			Yellow => 2
			Green => 3
			Blue => 4
		}

	## Gives each brick row its arcade color.
	row_color : Row -> Color.Rgba
	row_color = |row|
		match row {
			Red => Color.from_hex_rgb(0xff4f7d)
			Orange => Color.from_hex_rgb(0xff9f45)
			Yellow => Color.from_hex_rgb(0xffe066)
			Green => Color.from_hex_rgb(0x4ce0b3)
			Blue => Color.from_hex_rgb(0x5a9dff)
		}

	## Builds the brick at one row and column of the authored wall.
	brick_at : Row, U64 -> Brick
	brick_at = |row, column| {
		id: row_index(row) * per_row + column,
		rect: Math.rect(
			left + U64.to_f32(column) * (width + gap),
			top + U64.to_f32(row_index(row)) * (height + gap),
			width,
			height,
		),
		color: row_color(row),
	}

	## Builds all ten bricks in one colored row.
	row : Row -> List(Brick)
	row = |kind| [
		brick_at(kind, 0),
		brick_at(kind, 1),
		brick_at(kind, 2),
		brick_at(kind, 3),
		brick_at(kind, 4),
		brick_at(kind, 5),
		brick_at(kind, 6),
		brick_at(kind, 7),
		brick_at(kind, 8),
		brick_at(kind, 9),
	]

	fresh : List(Brick)
	fresh = List.concat(row(Red), List.concat(row(Orange), List.concat(row(Yellow), List.concat(row(Green), row(Blue)))))

	## Finds the first brick touched by the ball, starting at `index`.
	find_hit : List(Brick), Math.Circle, U64 -> Try(Brick, [NotFound])
	find_hit = |bricks, ball, index|
		match List.get(bricks, index) {
			Ok(brick) =>
				if Math.circle_rect(ball, brick.rect) Ok(brick) else find_hit(bricks, ball, index + 1)
			Err(_) => Err(NotFound)
		}

	## Removes the brick hit by the ball from the remaining wall.
	remove : List(Brick), Brick -> List(Brick)
	remove = |bricks, hit| List.keep_if(bricks, |brick| brick.id != hit.id)
}
