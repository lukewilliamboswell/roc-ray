app [Model, program] { rr: platform "../../platform/main.roc" }

# tag::body[]
import rr.App
import rr.Color
import rr.Draw
import rr.Math

screen_width = 800.F32

screen_height = 600.F32

paddle_width = 120.F32

paddle_height = 16.F32

paddle_y = 560.F32

paddle_speed = 480.F32

ball_radius = 10.F32

# The longest time one cycle may advance the game by, in seconds.
max_dt = 0.05.F32

Ball : { pos : Math.Vec2, velocity : Math.Vec2 }

Model : { paddle_x : F32, ball : Ball }

Msg : []

program = { init!, update!, render! }

serve : Ball
serve = { pos: { x: screen_width / 2, y: 120 }, velocity: { x: 220, y: 260 } }

init! : App.Init(Model, [])
init! = App.init(App.default.with_title("Paddle"), |_io| Ok({ paddle_x: 340, ball: serve }))

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, input, _io| {
	dt = Math.clamp(input.time.elapsed_seconds, 0, max_dt)
	direction =
		if input.devices.key_down(KeyLeft) {
			-1
		} else if input.devices.key_down(KeyRight) {
			1
		} else {
			0
		}
	Ok({
		paddle_x: move_paddle(model.paddle_x, direction, dt),
		ball: move_ball(model.ball, dt),
	})
}

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |model, frame| {
	frame.clear!(Color.black)
	frame.rectangle!({ x: model.paddle_x, y: paddle_y, width: paddle_width, height: paddle_height, style: Draw.filled(Color.white) })
	frame.circle!({ center: model.ball.pos, radius: ball_radius, style: Draw.filled(Color.yellow) })
	Ok({})
}

move_paddle : F32, F32, F32 -> F32
move_paddle = |x, direction, dt|
	Math.clamp(x + direction * paddle_speed * dt, 0, screen_width - paddle_width)

move_ball : Ball, F32 -> Ball
move_ball = |ball, dt| {
	x = ball.pos.x + ball.velocity.x * dt
	y = ball.pos.y + ball.velocity.y * dt
	off_left = x < ball_radius and ball.velocity.x < 0
	off_right = x > screen_width - ball_radius and ball.velocity.x > 0
	vx = if off_left or off_right -ball.velocity.x else ball.velocity.x
	vy = if y < ball_radius and ball.velocity.y < 0 -ball.velocity.y else ball.velocity.y
	if y > screen_height + ball_radius {
		serve
	} else {
		{ pos: { x, y }, velocity: { x: vx, y: vy } }
	}
}
# end::body[]
