## Breakout: clear the brick wall before losing all three balls.
##
## Use A/D or Left/Right to move, Space to launch or restart, and Escape to
## quit. Pass `--record-demo` to create `examples/breakout/demo.gif`.
## File structure:
##
## - State (`Game.roc`): ball, paddle, remaining bricks, score, lives, and match
## - Controls (`main.roc`): horizontal movement, launch/restart, and quit
## - App wiring (`main.roc`): assets, recording, and event sounds
## - Rendering (`Render.roc`): cabinet, brick wall, HUD, bodies, and prompts
## - Gameplay (`Ball.roc`, `Paddle.roc`, `Bricks.roc`): motion and collisions
## - Tests (`main.roc`): key mapping, launch, wall bounce, and last life lost
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/3vVeddfDE6rraq5j8v1cGHtFNaQhC6dij1zGRN63NGP1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Capture
import rr.Devices
import rr.Draw
import Ball
import Game
import Render

Model : {
	assets : Render.Assets,
	world : Game.World,
	demo : Bool,
	elapsed : F32,
}

Controls : Game.Controls

program = { init!, update!, render! }

record_demo_flag = "--record-demo"

demo_frames = 150.U64

## Selects an interactive window or a hidden fixed-step GIF recording.
breakout_config : List(Str) -> App.Config
breakout_config = |args| {
	base = App.default.with_title("RocRay Breakout").with_frame_pacing(Capped(120))

	if List.contains(args, record_demo_flag) {
		base
			.with_visible(Bool.False)
			.with_output_dir("examples/breakout")
			.with_recording(
				Capture.default
					.with_path("demo.gif")
					.with_format(Gif)
					.with_fps(25)
					.with_max_frames(demo_frames)
					.with_scale(Half)
					.with_timing(FixedStep),
			)
	} else {
		base
	}
}

## Loads presentation assets and creates the first ready-to-launch world.
init! : App.Init(Model, [ResourceLimit, SoundGenerationFailed])
init! = App.init_for_args(
	breakout_config,
	|startup| {
		demo = List.contains(App.args!(startup), record_demo_flag)
		Ok({ assets: Render.load!()?, world: Game.new_world(), demo, elapsed: 0 })
	},
)

## Translates keyboard bindings into Breakout movement and button intentions.
read_controls : Devices.Snapshot -> Controls
read_controls = |devices| {
	left = devices.key_down(KeyLeft) or devices.key_down(KeyA)
	right = devices.key_down(KeyRight) or devices.key_down(KeyD)
	{
		move: if left Left else if right Right else Still,
		action_pressed: devices.key_pressed(KeySpace),
		quit_pressed: devices.key_pressed(KeyEscape),
	}
}

## Interprets one pure gameplay event as its corresponding sound effect.
play_event! : Render.Assets, Game.Event => {}
play_event! = |assets, event|
	match event {
		GameStarted => assets.sounds.start.playback().play!()
		WallHit => assets.sounds.wall.playback().play!()
		PaddleHit => assets.sounds.paddle.playback().play!()
		BrickHit(_) => assets.sounds.brick.playback().play!()
		LifeLost(_) => assets.sounds.lose.playback().play!()
		WallCleared => assets.sounds.start.playback().play!()
	}

Msg : []

## Advances the world, plays its events, and handles quitting or recording end.
update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	dt = program_input.time.elapsed_seconds
	controls = if model.demo Game.demo_controls(model.world) else read_controls(program_input.devices)
	(world, events) = Game.update(model.world, controls, dt)

	for event in events {
		play_event!(model.assets, event)
	}

	exit =
		if model.demo {
			match program_input.capture {
				Finished(_) => Err(Exit(0))
				Failed(_) => Err(Exit(1))
				_ => Ok({})
			}
		} else if controls.quit_pressed {
			Err(Exit(0))
		} else {
			Ok({})
		}

	match exit {
		Err(code) => Err(code)
		Ok({}) => Ok({ ..model, world, elapsed: model.elapsed + dt })
	}
}

## Delegates presentation of the retained world to the rendering module.
render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ..])
render! = |model, frame| Render.draw!(frame, model.assets, model.world, model.elapsed, model.demo)

no_controls : Controls
no_controls = { move: Still, action_pressed: Bool.False, quit_pressed: Bool.False }

expect read_controls(Devices.none.with_key_down(KeyLeft)).move == Left

expect {
	ready = Game.new_world()
	(world, events) = Game.update(ready, { ..no_controls, action_pressed: Bool.True }, 0)
	world.state == Playing and List.len(events) == 1
}

expect {
	playing = { ..Game.new_world(), state: Playing }
	ball = { ..playing.ball, pos: { ..playing.ball.pos, x: Ball.radius }, velocity: { x: -100, y: -100 } }
	(world, events) = Game.update({ ..playing, ball }, no_controls, 0.1)
	world.ball.velocity.x > 0 and List.len(events) == 1
}

expect {
	playing = { ..Game.new_world(), state: Playing, lives: 1 }
	ball = { ..playing.ball, pos: { ..playing.ball.pos, y: 610 } }
	(world, events) = Game.update({ ..playing, ball }, no_controls, 0)
	world.state == GameOver and world.lives == 0 and List.len(events) == 1
}
