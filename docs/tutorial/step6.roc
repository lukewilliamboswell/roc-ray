app [Model, program] { rr: platform "../../platform/main.roc" }

# tag::body[]
import rr.App
import rr.Audio
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

speed_up = 1.05.F32

# The longest time one cycle may advance the game by, in seconds.
max_dt = 0.05.F32

starting_lives = 3.U64

Ball : { pos : Math.Vec2, velocity : Math.Vec2 }

Model : {
	paddle_x : F32,
	ball : Ball,
	score : U64,
	lives : U64,
	hit_sound : Audio.Sound,
	miss_sound : Audio.Sound,
}

Event : [PaddleHit, BallLost, Nothing]

Msg : []

program = { init!, update!, render! }

serve : Ball
serve = { pos: { x: screen_width / 2, y: 120 }, velocity: { x: 220, y: 260 } }

init! : App.Init(Model, [SoundGenerationFailed, ResourceLimit])
init! = App.init(
	App.default.with_title("Paddle"),
	|_io| {
		hit_sound = Audio.gen_tone!({ freq: 660, ms: 60 })?
		miss_sound = Audio.gen_tone!({ freq: 160, ms: 300 })?
		Ok({
			paddle_x: 340,
			ball: serve,
			score: 0,
			lives: starting_lives,
			hit_sound,
			miss_sound,
		})
	},
)

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, input, _io| {
	if model.lives == 0 {
		if input.devices.key_pressed(KeySpace) {
			Ok(new_game(model))
		} else {
			Ok(model)
		}
	} else {
		dt = Math.clamp(input.time.elapsed_seconds, 0, max_dt)
		direction =
			if input.devices.key_down(KeyLeft) {
				-1
			} else if input.devices.key_down(KeyRight) {
				1
			} else {
				0
			}
		(next, event) = advance(model, direction, dt)
		match event {
			PaddleHit => next.hit_sound.play!()
			BallLost => next.miss_sound.play!()
			Nothing => {}
		}
		Ok(next)
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |model, frame| {
	frame.clear!(Color.black)
	frame.rectangle!({ x: model.paddle_x, y: paddle_y, width: paddle_width, height: paddle_height, style: Draw.filled(Color.white) })
	frame.circle!({ center: model.ball.pos, radius: ball_radius, style: Draw.filled(Color.yellow) })
	frame.text_at!({ pos: { x: 20, y: 20 }, text: "Score: ${model.score.to_str()}", size: 24, color: Color.white })
	frame.text_at!({ pos: { x: 680, y: 20 }, text: "Lives: ${model.lives.to_str()}", size: 24, color: Color.white })
	if model.lives == 0 {
		frame.text_at!({ pos: { x: 230, y: 280 }, text: "Game over. Press Space.", size: 32, color: Color.red })
	}
	Ok({})
}

# The rules of the game. These functions are pure, so `roc test` can check them.

new_game : Model -> Model
new_game = |model| {
	..model,
	paddle_x: 340,
	ball: serve,
	score: 0,
	lives: starting_lives,
}

advance : Model, F32, F32 -> (Model, Event)
advance = |model, direction, dt| {
	paddle_x = move_paddle(model.paddle_x, direction, dt)
	(ball, event) = move_ball(model.ball, paddle_x, dt)
	next = { ..model, paddle_x, ball }
	match event {
		PaddleHit => ({ ..next, score: next.score + 1 }, event)
		BallLost => ({ ..next, lives: next.lives - 1 }, event)
		Nothing => (next, event)
	}
}

move_paddle : F32, F32, F32 -> F32
move_paddle = |x, direction, dt|
	Math.clamp(x + direction * paddle_speed * dt, 0, screen_width - paddle_width)

move_ball : Ball, F32, F32 -> (Ball, Event)
move_ball = |ball, paddle_x, dt| {
	x = ball.pos.x + ball.velocity.x * dt
	y = ball.pos.y + ball.velocity.y * dt
	off_left = x < ball_radius and ball.velocity.x < 0
	off_right = x > screen_width - ball_radius and ball.velocity.x > 0
	vx = if off_left or off_right -ball.velocity.x else ball.velocity.x
	vy = if y < ball_radius and ball.velocity.y < 0 -ball.velocity.y else ball.velocity.y
	paddle = Math.rect(paddle_x, paddle_y, paddle_width, paddle_height)
	touching = Math.circle_rect(Math.circle({ x, y }, ball_radius), paddle)
	if vy > 0 and touching {
		({ pos: { x, y }, velocity: { x: vx * speed_up, y: -vy * speed_up } }, PaddleHit)
	} else if y > screen_height + ball_radius {
		(serve, BallLost)
	} else {
		({ pos: { x, y }, velocity: { x: vx, y: vy } }, Nothing)
	}
}

expect move_paddle(0, -1, 0.5) == 0
expect move_paddle(screen_width - paddle_width, 1, 0.5) == screen_width - paddle_width

expect {
	falling = { pos: { x: 400, y: screen_height }, velocity: { x: 0, y: 300 } }
	(_, event) = move_ball(falling, 0, 0.1)
	event == BallLost
}

expect {
	above_paddle = { pos: { x: 400, y: paddle_y - ball_radius }, velocity: { x: 0, y: 300 } }
	(ball, event) = move_ball(above_paddle, 350, 0.01)
	event == PaddleHit and ball.velocity.y < 0
}
# end::body[]
