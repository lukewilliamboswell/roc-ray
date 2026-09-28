app [Model, program] { rr: platform "../../platform/main.roc" }

# The snippets in the manual's "Roc for RocRay" chapter, gathered into one app
# so that scripts/check_tutorial.py compiles and tests them.

# tag::imports[]
import rr.App
import rr.Audio
import rr.Color
import rr.Draw
# end::imports[]

Model : { score : U64 }

Msg : []

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default.with_title("Primer"), |_io| Ok({ score: 0 }))

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, _input, _io| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |model, frame| {
	frame.clear!(Color.black)
	# tag::interpolation[]
	frame.text_at!({ pos: { x: 20, y: 20 }, text: "Score: ${model.score.to_str()}", size: 24, color: Color.white })
	# end::interpolation[]
	Ok({})
}

# tag::values[]
speed = 480.F32
title = "Paddle"
lives = 3.U64
# end::values[]

# tag::block[]
area = {
	width = 800.F32
	height = 600.F32
	width * height
}
# end::block[]

# tag::records[]
paddle = { x: 340.F32, y: 560.F32, width: 120.F32 }

paddle_x = paddle.x

moved = { ..paddle, x: paddle.x + 10 }
# end::records[]

# tag::pun[]
make_point = |x, y| { x, y }
# end::pun[]

# tag::single-field[]
make_score = |score| { score: score }
# end::single-field[]

# tag::alias[]
Point : { x : F32, y : F32 }

origin : Point
origin = { x: 0, y: 0 }
# end::alias[]

# tag::nominal[]
Lives := U64.{
	lose_one : Lives -> Lives
	lose_one = |Lives.(count)| Lives.(count - 1)
}
# end::nominal[]

# tag::tags[]
Event : [PaddleHit, BallLost, Nothing]

points_for : Event -> U64
points_for = |event|
	match event {
		PaddleHit => 1
		BallLost => 0
		Nothing => 0
	}
# end::tags[]

# tag::payloads[]
Shape : [Circle(F32), Box(F32, F32)]

area_of : Shape -> F32
area_of = |shape|
	match shape {
		Circle(radius) => 3.14159 * radius * radius
		Box(width, height) => width * height
	}
# end::payloads[]

# tag::if[]
direction_for : Bool, Bool -> F32
direction_for = |left_down, right_down|
	if left_down {
		-1
	} else if right_down {
		1
	} else {
		0
	}
# end::if[]

# tag::functions[]
double : F32 -> F32
double = |x| x * 2

clamp_speed : F32, F32 -> F32
clamp_speed = |value, limit| if value > limit limit else value
# end::functions[]

# tag::effectful[]
play_for! : Event, Audio.Sound => {}
play_for! = |event, hit_sound|
	match event {
		PaddleHit => hit_sound.play!()
		_ => {}
	}
# end::effectful[]

# tag::try[]
Sounds : { hit : Audio.Sound, miss : Audio.Sound }

make_sounds! : {} => Try(Sounds, [SoundGenerationFailed, ResourceLimit])
make_sounds! = |{}| {
	hit = Audio.gen_tone!({ freq: 660, ms: 60 })?
	miss = Audio.gen_tone!({ freq: 160, ms: 300 })?
	Ok({ hit, miss })
}
# end::try[]

# tag::tuples[]
split_score : U64 -> (U64, U64)
split_score = |score| (score // 10, score % 10)

tens_digit = {
	(tens, _ones) = split_score(42)
	tens
}
# end::tuples[]

# tag::methods[]
config = App.default.with_title("Paddle").with_size({ width: 800, height: 600 })

score_text = 42.U64.to_str()

same_text = U64.to_str(42)
# end::methods[]

# tag::expect[]
expect double(2) == 4

expect points_for(PaddleHit) == 1

expect {
	(tens, ones) = split_score(42)
	tens == 4 and ones == 2
}
# end::expect[]

expect speed > 0 and lives == 3 and title == "Paddle" and area > 0
expect paddle_x == 340 and moved.x == 350
expect make_point(1, 2) == { x: 1, y: 2 }
expect make_score(7) == { score: 7 }
expect origin.x == 0
expect area_of(Box(2, 3)) == 6
expect direction_for(Bool.True, Bool.False) == -1
expect clamp_speed(900, 600) == 600
expect tens_digit == 4
expect score_text == same_text
expect config.title() == "Paddle"
