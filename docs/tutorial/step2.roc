app [Model, program] { rr: platform "../../platform/main.roc" }

# tag::body[]
import rr.App
import rr.Color
import rr.Draw
import rr.Math

screen_width = 800.F32

paddle_width = 120.F32

paddle_height = 16.F32

paddle_y = 560.F32

paddle_speed = 480.F32

# The longest time one cycle may advance the game by, in seconds.
max_dt = 0.05.F32

Model : { paddle_x : F32 }

Msg : []

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default.with_title("Paddle"), |_io| Ok({ paddle_x: 340 }))

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
	Ok({ paddle_x: move_paddle(model.paddle_x, direction, dt) })
}

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |model, frame| {
	frame.clear!(Color.black)
	frame.rectangle!({ x: model.paddle_x, y: paddle_y, width: paddle_width, height: paddle_height, style: Draw.filled(Color.white) })
	Ok({})
}

move_paddle : F32, F32, F32 -> F32
move_paddle = |x, direction, dt|
	Math.clamp(x + direction * paddle_speed * dt, 0, screen_width - paddle_width)
# end::body[]
