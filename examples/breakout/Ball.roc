## Ball movement and geometry for Breakout.
import rr.Math

Ball := {
	pos : Math.Vec2,
	velocity : Math.Vec2,
}.{
	radius = 8.F32

	ready_gap = 2.F32

	bounce_gap = 1.F32

	launch_velocity : Math.Vec2
	launch_velocity = { x: 170, y: -340 }

	## Places a newly launched ball just above the center of the paddle.
	on : Math.Rect -> Ball
	on = |paddle| {
		pos: {
			x: Math.center(paddle).x,
			y: paddle.y - radius - ready_gap,
		},
		velocity: launch_velocity,
	}

	## Advances the ball along its current velocity for `dt` seconds.
	move : Ball, F32 -> Ball
	move = |ball, dt| { ..ball, pos: Math.add(ball.pos, Math.scale(ball.velocity, dt)) }

	## Builds the circle used to test this ball against paddles and bricks.
	circle : Ball -> Math.Circle
	circle = |ball| Math.circle(ball.pos, radius)
}
