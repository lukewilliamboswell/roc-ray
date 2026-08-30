## Paddle state, movement, and geometry for Breakout.
import rr.Math

Paddle := { x : F32 }.{
	Move := [Left, Right, Still].{
		is_eq : _
	}

	width = 112.F32

	height = 16.F32

	y = 548.F32

	speed = 460.F32

	bounce_speed = 360.F32

	initial : Paddle
	initial = { x: (800 - width) * 0.5 }

	## Builds the rectangle used to draw the paddle and collide with the ball.
	rect : Paddle -> Math.Rect
	rect = |paddle| Math.rect(paddle.x, y, width, height)

	## Moves the paddle horizontally while keeping it inside the cabinet.
	move : Paddle, Move, F32 -> Paddle
	move = |paddle, direction, dt| {
		amount =
			match direction {
				Left => -1
				Right => 1
				Still => 0
			}

		{ x: Math.clamp(paddle.x + amount * speed * dt, 0, 800 - width) }
	}
}
