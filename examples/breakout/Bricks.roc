## The authored brick wall and operations that change it.
import rr.Color
import rr.Math

Bricks := [].{
	Brick : {
		id : U64,
		rect : Math.Rect,
		color : Color.Rgba,
	}

	score = 10.U64
	fresh : List(Brick)
	fresh = List.concat(build_row(Red), List.concat(build_row(Orange), List.concat(build_row(Yellow), List.concat(build_row(Green), build_row(Blue)))))

	## Finds the first brick touched by the ball.
	find_hit : List(Brick), Math.Circle -> Try(Brick, [NotFound])
	find_hit = |bricks, ball|
		if ball.center.y + ball.radius < band_top or ball.center.y - ball.radius > band_bottom {
			Err(NotFound)
		} else {
			find_hit_from(bricks, ball, 0)
		}

	## Removes the brick hit by the ball from the remaining wall.
	remove : List(Brick), Brick -> List(Brick)
	remove = |bricks, hit| List.keep_if(bricks, |brick| brick.id != hit.id)
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

## Converts a named brick row into its zero-based vertical index.
row_index : Row -> U64
row_index = |kind|
	match kind {
		Red => 0
		Orange => 1
		Yellow => 2
		Green => 3
		Blue => 4
	}

## Gives each brick row its arcade color.
row_color : Row -> Color.Rgba
row_color = |kind|
	match kind {
		Red => Color.from_hex_rgb(0xff4f7d)
		Orange => Color.from_hex_rgb(0xff9f45)
		Yellow => Color.from_hex_rgb(0xffe066)
		Green => Color.from_hex_rgb(0x4ce0b3)
		Blue => Color.from_hex_rgb(0x5a9dff)
	}

## Builds the brick at one row and column of the authored wall.
brick_at : Row, U64 -> Bricks.Brick
brick_at = |kind, column| {
	id: row_index(kind) * per_row + column,
	rect: Math.rect(
		left + U64.to_f32(column) * (width + gap),
		top + U64.to_f32(row_index(kind)) * (height + gap),
		width,
		height,
	),
	color: row_color(kind),
}

## Builds all ten bricks in one colored row.
build_row : Row -> List(Bricks.Brick)
build_row = |kind| [
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

## Recursively finds the first touched brick from one private list index.
find_hit_from : List(Bricks.Brick), Math.Circle, U64 -> Try(Bricks.Brick, [NotFound])
find_hit_from = |bricks, ball, index|
	match List.get(bricks, index) {
		Ok(brick) => if Math.circle_rect(ball, brick.rect) Ok(brick) else find_hit_from(bricks, ball, index + 1)
		Err(_) => Err(NotFound)
	}
