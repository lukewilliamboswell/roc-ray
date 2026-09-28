## Breakout: clear the brick wall before losing all three balls.
##
## Use A/D or Left/Right to move, Space to launch or restart, and Escape to
## quit. Pass `--record-demo` to write `examples/gallery/breakout.gif`.
## File structure:
##
## - State (`Game.roc`): ball, paddle, remaining bricks, score, lives, and match
## - Controls (`main.roc`): horizontal movement and launch/restart
## - Assets (`GameAssets.roc`): sounds, font, and prepared interface text
## - App wiring (`main.roc`): recording and event sounds
## - Rendering (`Render.roc`): cabinet, brick wall, HUD, bodies, and prompts
## - Gameplay (`Ball.roc`, `Paddle.roc`, `Bricks.roc`): motion and collisions
## - Tests (`main.roc`): key mapping, launch, wall bounce, and last life lost
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc6/7sujbfhDKezq7FAp75Nk4mTkTiPNDH36zmAMyGskmZoy.tar.zst", roc: "nightly-2026-09-27-a3ce7f1" }

import rr.App
import rr.Capture
import rr.Devices
import rr.Draw
import rr.Math
import GameAssets
import Ball
import Game
import Paddle
import Render

Model : {
	assets : GameAssets,
	world : Game.World,
	demo : Bool,
	elapsed : F32,
}

Controls : Game.Controls

program = { init!, update!, render! }

## Recording mode. `--record-demo` hides the window, plays the game from
## `demo_controls` instead of the keyboard, and writes a GIF for the README
## gallery into `examples/gallery/`. The recording stops itself after
## `demo_frames` frames, and `update!` exits when it has been written.
record_demo_flag = "--record-demo"

demo_frames = 150.U64

demo_recording : Capture.Recording
demo_recording =
	Capture.default
		.with_path("breakout.gif")
		.with_format(Gif)
		.with_fps(25)
		.with_max_frames(demo_frames)
		.with_scale(Half)
		.with_timing(FixedStep)

## Selects an interactive window or a hidden one that records the demo.
breakout_config : List(Str) -> App.Config
breakout_config = |args| {
	base = App.default.with_title("RocRay Breakout").with_frame_pacing(Capped(120))
	if List.contains(args, record_demo_flag) base.with_visible(Bool.False).with_output_dir("examples/gallery") else base
}

## Loads presentation assets and creates the first ready-to-launch world.
##
## `PermissionDenied` is in the error list only because `Capture.Writer.start!`
## can return it; the `io` that `init!` receives always has permission to record.
init! : App.Init(Model, [PermissionDenied, ResourceLimit, SoundGenerationFailed])
init! = App.init_for_args(
	breakout_config,
	|io| {
		demo = List.contains(io.args!(), record_demo_flag)
		if demo {
			io.capture().start!(demo_recording)?
		}
		Ok({ assets: GameAssets.load!()?, world: Game.new_world(), demo, elapsed: 0 })
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
	}
}

## Converts demo ball tracking into the same semantic controls as a player.
demo_controls : Game.World -> Controls
demo_controls = |world| {
	paddle_center = Math.center(world.paddle.rect()).x
	delta = world.ball.pos.x - paddle_center
	{
		move: if delta < -8 Left else if delta > 8 Right else Still,
		action_pressed: match world.state {
			Playing => Bool.False
			_ => Bool.True
		},
	}
}

## A demo run is over once its recording has been written, or has failed.
demo_finished : Capture.Status -> Try({}, [Exit(I64)])
demo_finished = |status|
	match status {
		Finished(_) => Err(Exit(0))
		Failed(_) => Err(Exit(1))
		_ => Ok({})
	}

## Interprets one pure gameplay event as its corresponding sound effect.
play_event! : GameAssets, Game.Event => {}
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

## Advances the world and plays its events. In recording mode it also exits
## once the recording is done. Escape needs no code here: `App.default` closes
## the window when it is pressed.
update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, input, _io| {
	# Seconds since the previous cycle, clamped so a stall (dragging the
	# window, a breakpoint) cannot carry the ball through a brick.
	dt = Math.clamp(input.time.elapsed_seconds, 0, 0.25)
	controls = if model.demo demo_controls(model.world) else read_controls(input.devices)
	(world, events) = Game.update(model.world, controls, dt)

	for event in events {
		play_event!(model.assets, event)
	}

	if model.demo {
		demo_finished(input.capture)?
	}
	Ok({ ..model, world, elapsed: model.elapsed + dt })
}

## Delegates presentation of the retained world to the rendering module.
render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit])
render! = |model, frame| Render.draw!(frame, model.assets, model.world, model.elapsed, model.demo)

no_controls : Controls
no_controls = { move: Still, action_pressed: Bool.False }

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

## The demo keeps running while the recording is active, and ends with it.
expect demo_finished(Active({ frames: 10, dropped: 0 })) == Ok({})
expect demo_finished(Finished({ frames: 150, bytes: 4096 })) == Err(Exit(0))
