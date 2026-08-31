## Paddle state, movement, and geometry for Breakout.
import rr.Math
import Ball

width = 112.F32

height = 16.F32

y = 548.F32

speed = 460.F32

bounce_speed = 360.F32

bounce_gap = 1.F32

Paddle := { x : F32 }.{
	Move := [Left, Right, Still].{
		is_eq : _
	}

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

	## Rebounds a descending ball from this paddle using its contact offset.
	bounce : Paddle, Ball -> Ball
	bounce = |paddle, ball| {
		paddle_rect = paddle.rect()
		paddle_offset = Math.clamp((ball.pos.x - Math.center(paddle_rect).x) / (paddle_rect.width * 0.5), -1, 1)
		Ball.{
			pos: { x: ball.pos.x, y: paddle_rect.y - Ball.radius - bounce_gap },
			velocity: { x: paddle_offset * bounce_speed, y: F32.abs(ball.velocity.y) * -1 },
		}
	}
}
