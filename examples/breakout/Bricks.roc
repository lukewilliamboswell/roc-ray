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
	fresh = [
		{ id: 0, rect: Math.rect(44, 88, 64, 22), color: Color.rgba(255, 79, 125, 255) },
		{ id: 1, rect: Math.rect(116, 88, 64, 22), color: Color.rgba(255, 79, 125, 255) },
		{ id: 2, rect: Math.rect(188, 88, 64, 22), color: Color.rgba(255, 79, 125, 255) },
		{ id: 3, rect: Math.rect(260, 88, 64, 22), color: Color.rgba(255, 79, 125, 255) },
		{ id: 4, rect: Math.rect(332, 88, 64, 22), color: Color.rgba(255, 79, 125, 255) },
		{ id: 5, rect: Math.rect(404, 88, 64, 22), color: Color.rgba(255, 79, 125, 255) },
		{ id: 6, rect: Math.rect(476, 88, 64, 22), color: Color.rgba(255, 79, 125, 255) },
		{ id: 7, rect: Math.rect(548, 88, 64, 22), color: Color.rgba(255, 79, 125, 255) },
		{ id: 8, rect: Math.rect(620, 88, 64, 22), color: Color.rgba(255, 79, 125, 255) },
		{ id: 9, rect: Math.rect(692, 88, 64, 22), color: Color.rgba(255, 79, 125, 255) },
		{ id: 10, rect: Math.rect(44, 118, 64, 22), color: Color.rgba(255, 159, 69, 255) },
		{ id: 11, rect: Math.rect(116, 118, 64, 22), color: Color.rgba(255, 159, 69, 255) },
		{ id: 12, rect: Math.rect(188, 118, 64, 22), color: Color.rgba(255, 159, 69, 255) },
		{ id: 13, rect: Math.rect(260, 118, 64, 22), color: Color.rgba(255, 159, 69, 255) },
		{ id: 14, rect: Math.rect(332, 118, 64, 22), color: Color.rgba(255, 159, 69, 255) },
		{ id: 15, rect: Math.rect(404, 118, 64, 22), color: Color.rgba(255, 159, 69, 255) },
		{ id: 16, rect: Math.rect(476, 118, 64, 22), color: Color.rgba(255, 159, 69, 255) },
		{ id: 17, rect: Math.rect(548, 118, 64, 22), color: Color.rgba(255, 159, 69, 255) },
		{ id: 18, rect: Math.rect(620, 118, 64, 22), color: Color.rgba(255, 159, 69, 255) },
		{ id: 19, rect: Math.rect(692, 118, 64, 22), color: Color.rgba(255, 159, 69, 255) },
		{ id: 20, rect: Math.rect(44, 148, 64, 22), color: Color.rgba(255, 224, 102, 255) },
		{ id: 21, rect: Math.rect(116, 148, 64, 22), color: Color.rgba(255, 224, 102, 255) },
		{ id: 22, rect: Math.rect(188, 148, 64, 22), color: Color.rgba(255, 224, 102, 255) },
		{ id: 23, rect: Math.rect(260, 148, 64, 22), color: Color.rgba(255, 224, 102, 255) },
		{ id: 24, rect: Math.rect(332, 148, 64, 22), color: Color.rgba(255, 224, 102, 255) },
		{ id: 25, rect: Math.rect(404, 148, 64, 22), color: Color.rgba(255, 224, 102, 255) },
		{ id: 26, rect: Math.rect(476, 148, 64, 22), color: Color.rgba(255, 224, 102, 255) },
		{ id: 27, rect: Math.rect(548, 148, 64, 22), color: Color.rgba(255, 224, 102, 255) },
		{ id: 28, rect: Math.rect(620, 148, 64, 22), color: Color.rgba(255, 224, 102, 255) },
		{ id: 29, rect: Math.rect(692, 148, 64, 22), color: Color.rgba(255, 224, 102, 255) },
		{ id: 30, rect: Math.rect(44, 178, 64, 22), color: Color.rgba(76, 224, 179, 255) },
		{ id: 31, rect: Math.rect(116, 178, 64, 22), color: Color.rgba(76, 224, 179, 255) },
		{ id: 32, rect: Math.rect(188, 178, 64, 22), color: Color.rgba(76, 224, 179, 255) },
		{ id: 33, rect: Math.rect(260, 178, 64, 22), color: Color.rgba(76, 224, 179, 255) },
		{ id: 34, rect: Math.rect(332, 178, 64, 22), color: Color.rgba(76, 224, 179, 255) },
		{ id: 35, rect: Math.rect(404, 178, 64, 22), color: Color.rgba(76, 224, 179, 255) },
		{ id: 36, rect: Math.rect(476, 178, 64, 22), color: Color.rgba(76, 224, 179, 255) },
		{ id: 37, rect: Math.rect(548, 178, 64, 22), color: Color.rgba(76, 224, 179, 255) },
		{ id: 38, rect: Math.rect(620, 178, 64, 22), color: Color.rgba(76, 224, 179, 255) },
		{ id: 39, rect: Math.rect(692, 178, 64, 22), color: Color.rgba(76, 224, 179, 255) },
		{ id: 40, rect: Math.rect(44, 208, 64, 22), color: Color.rgba(90, 157, 255, 255) },
		{ id: 41, rect: Math.rect(116, 208, 64, 22), color: Color.rgba(90, 157, 255, 255) },
		{ id: 42, rect: Math.rect(188, 208, 64, 22), color: Color.rgba(90, 157, 255, 255) },
		{ id: 43, rect: Math.rect(260, 208, 64, 22), color: Color.rgba(90, 157, 255, 255) },
		{ id: 44, rect: Math.rect(332, 208, 64, 22), color: Color.rgba(90, 157, 255, 255) },
		{ id: 45, rect: Math.rect(404, 208, 64, 22), color: Color.rgba(90, 157, 255, 255) },
		{ id: 46, rect: Math.rect(476, 208, 64, 22), color: Color.rgba(90, 157, 255, 255) },
		{ id: 47, rect: Math.rect(548, 208, 64, 22), color: Color.rgba(90, 157, 255, 255) },
		{ id: 48, rect: Math.rect(620, 208, 64, 22), color: Color.rgba(90, 157, 255, 255) },
		{ id: 49, rect: Math.rect(692, 208, 64, 22), color: Color.rgba(90, 157, 255, 255) },
	]

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

band_top = 84.F32

band_bottom = 236.F32

## Recursively finds the first touched brick from one private list index.
find_hit_from : List(Bricks.Brick), Math.Circle, U64 -> Try(Bricks.Brick, [NotFound])
find_hit_from = |bricks, ball, index|
	match List.get(bricks, index) {
		Ok(brick) => if (Math.circle_rect(ball, brick.rect)) Ok(brick) else find_hit_from(bricks, ball, index + 1)
		Err(_) => Err(NotFound)
	}
