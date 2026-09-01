## Spark Run: collect every spark, avoid moving hazards, and reach the gate.
##
## Use WASD or Arrow keys to move, Space to dash or restart, and Escape to quit.
## File structure:
##
## - State (`Game.roc`): player, remaining sparks, score, lives, gate, and feedback
## - Controls (`main.roc`): movement, dash, restart, quit, and repeatable demo route
## - Assets (`GameAssets.roc`): character and tile textures, font, sounds, and music
## - Level (`Level.roc`): Tiled map, spawn, exit, obstacles, hazards, and decorations
## - Gameplay (`Player.roc`, `Spark.roc`, `Hazard.roc`): movement, dash, collection, and damage bodies
## - Rendering (`Render.roc`): camera, arena layers, sprites, effects, HUD, and end states
## - Tests (`main.roc`): facing, collisions, collection, damage, escape, and dash events
app [Model, program] {
	rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/3vVeddfDE6rraq5j8v1cGHtFNaQhC6dij1zGRN63NGP1.tar.zst",
	roc: "nightly-2026-08-23-fb208ba",
}

import rr.App
import rr.Capture
import rr.Color
import rr.Devices
import rr.Draw
import rr.Math
import rr.Tilemap
import Game
import GameAssets
import Hazard
import Level
import Player
import Render
import Spark

Model : { assets : GameAssets, level : Level, world : Game.World, demo : Bool, demo_frame : U64 }

Controls : Game.Controls

program = { init!, update!, render! }

demo_frames = 150.U64

record_demo_flag = "--record-demo"

collect_volume = 0.58.F32

hurt_volume = 0.55.F32

win_volume = 0.48.F32

lose_volume = 0.58.F32

gate_volume = 0.46.F32

dash_volume = 0.3.F32

sparkle_volume = 0.16.F32

music_volume = 0.13.F32

music_won_volume = 0.08.F32

## Configures the interactive window or the repeatable hidden gallery recording.
top_down_config : List(Str) -> App.Config
top_down_config = |args| {
	base = App.default.with_title("RocRay Spark Run").with_frame_pacing(Capped(120))
	if List.contains(args, record_demo_flag) {
		base
			.with_visible(Bool.False)
			.with_output_dir("examples/gallery")
			.with_recording(
				Capture.default
					.with_path("top_down.gif")
					.with_format(Gif)
					.with_fps(25)
					.with_max_frames(demo_frames)
					.with_scale(Quarter)
					.with_timing(FixedStep),
			)
	} else {
		base
	}
}

## Loads resources and level data before starting music and the first world.
init! : App.Init(Model, _)
init! = App.init_for_args(
	top_down_config,
	|startup| {
		assets = GameAssets.load!()?
		level = Level.load!(assets.tiles)?
		assets.sounds.music.play!()
		Ok({ assets, level, world: Game.new(level), demo: List.contains(App.args!(startup), record_demo_flag), demo_frame: 0 })
	},
)

## Converts two opposing keys into one signed movement axis.
axis : Bool, Bool -> F32
axis = |negative, positive| if negative -1 else if positive 1 else 0

## Translates keyboard bindings into semantic Spark Run controls.
read_controls : Devices.Snapshot -> Controls
read_controls = |input| {
	left = input.key_down(KeyLeft) or input.key_down(KeyA)
	right = input.key_down(KeyRight) or input.key_down(KeyD)
	up = input.key_down(KeyUp) or input.key_down(KeyW)
	down = input.key_down(KeyDown) or input.key_down(KeyS)
	{
		move: { x: axis(left, right), y: axis(up, down) },
		dash_pressed: input.key_pressed(KeySpace),
		restart_pressed: input.key_pressed(KeySpace),
		quit_pressed: input.key_pressed(KeyEscape),
	}
}

## Produces the semantic controls for one frame of the gallery route.
demo_controls : U64 -> Controls
demo_controls = |frame| {
	move =
		if frame < 19 {
			{ x: 1, y: 1 }
		} else if frame < 38 {
			{ x: 0, y: -1 }
		} else if frame < 76 {
			{ x: 1, y: 0 }
		} else if frame < 108 {
			{ x: 1, y: 1 }
		} else {
			{ x: -1, y: 0 }
		}
	pressed = frame == 20 or frame == 43 or frame == 82 or frame == 116
	{ move, dash_pressed: pressed, restart_pressed: pressed, quit_pressed: Bool.False }
}

## Converts a world x-coordinate into stereo pan across the level bounds.
pan_for_world_x : Level, F32 -> F32
pan_for_world_x = |level, x| Math.clamp((x - Math.left(level.bounds)) / level.bounds.width * 2 - 1, -1, 1)

## Performs the audio or music effect requested by one pure gameplay event.
play_event! : GameAssets, Level, Game.World, Game.World, Game.Event => {}
play_event! = |assets, level, previous_world, world, event| {
	sounds = assets.sounds
	match event {
		DashStarted(pos) =>
			sounds.dash.playback().with_volume(dash_volume).with_pan(pan_for_world_x(level, pos.x)).with_pitch(0.95 + U64.to_f32(previous_world.score) * 0.015).play!()
		SparkCollected(spark) => {
			sounds.collect.playback().with_volume(collect_volume).with_pan(pan_for_world_x(level, spark.pos.x)).play!()
			if world.score % 3 == 0 {
				sounds.sparkle.playback().with_volume(sparkle_volume).with_pitch(0.92 + U64.to_f32(world.score) * 0.045).play!()
			} else {
				{}
			}
		}
		GateOpened => sounds.gate.playback().with_volume(gate_volume).play!()
		Escaped => {
			sounds.music.set_volume!(music_won_volume)
			sounds.win.playback().with_volume(win_volume).play!()
		}
		Damaged(state) =>
			if state == GameOver {
				sounds.lose.playback().with_volume(lose_volume).play!()
			} else {
				sounds.hurt.playback().with_volume(hurt_volume).play!()
			}
		GameStarted => sounds.music.set_volume!(music_volume)
	}
}

Msg : []

## Advances pure gameplay, performs its events, and handles capture or quit.
update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	controls = if model.demo demo_controls(model.demo_frame) else read_controls(program_input.devices)
	dt = program_input.time.elapsed_seconds
	(world, events) = Game.update(model.level, model.world, controls, dt)
	for event in events {
		play_event!(model.assets, model.level, model.world, world, event)
	}
	if model.demo {
		match program_input.capture {
			Finished(_) => Err(Exit(0))
			Failed(_) => Err(Exit(1))
			_ => Ok({ ..model, world, demo_frame: model.demo_frame + 1 })
		}
	} else if controls.quit_pressed {
		Err(Exit(0))
	} else {
		Ok({ ..model, world, demo_frame: model.demo_frame + 1 })
	}
}

## Delegates the complete presentation frame to the rendering module.
render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ..])
render! = |model, frame| Render.draw!(frame, model.assets, model.level, model.world)

no_controls : Controls
no_controls = { move: { x: 0, y: 0 }, dash_pressed: Bool.False, restart_pressed: Bool.False, quit_pressed: Bool.False }

test_level : Level
test_level = {
	tilemap: Tilemap.empty,
	spawn: { x: -560, y: -360 },
	exit_center: { x: 1185, y: 920 },
	exit_radius: 58,
	sparks: [Spark.{ id: 0, pos: { x: -430, y: -150 } }, Spark.{ id: 1, pos: { x: 100, y: 100 } }],
	spark_total: 2,
	obstacles: [],
	hazards: [Hazard.{ center: { x: -445, y: 165 }, span: 520, lane: Horizontal, offset: 0, radius: 30, color: Color.red }],
	decorations: [],
	bounds: Math.rect(-720, -520, 2176, 1664),
}

expect Player.new(test_level.spawn).circle().radius == Player.radius
expect Player.new(test_level.spawn).facing_dir() == { x: 1, y: 0 }
expect
	match Player.new(test_level.spawn).facing {
		East => Bool.True
		_ => Bool.False
	}
expect Player.new({ x: 10, y: 20 }).damage_respawn(test_level.spawn).pos == test_level.spawn

expect {
	hazard = Hazard.{ center: { x: 0, y: 0 }, span: 20, lane: Horizontal, offset: 0, radius: 5, color: Color.white }
	hazard.pos(0) == { x: -10, y: 0 } and hazard.pos(0.25) == { x: 0, y: 0 }
}

expect {
	world = { ..Game.new(test_level), player: Player.new({ x: -430, y: -150 }) }
	(next, events) = Game.update(test_level, world, no_controls, 0)
	next.score == 1 and events == [SparkCollected(Spark.{ id: 0, pos: { x: -430, y: -150 } })]
}

expect {
	world = { ..Game.new(test_level), player: Player.new({ x: -705, y: 165 }) }
	(next, events) = Game.update(test_level, world, no_controls, 0)
	next.lives == 2 and events == [Damaged(Playing)]
}

expect {
	world = { ..Game.new(test_level), gate: GateOpen, player: Player.new(test_level.exit_center) }
	(next, events) = Game.update(test_level, world, no_controls, 0)
	next.state == Won and events == [Escaped]
}

expect {
	controls = { ..no_controls, move: { x: 1, y: 0 }, dash_pressed: Bool.True }
	(next, events) = Game.update(test_level, Game.new(test_level), controls, 0.01)
	List.first(events) == Ok(DashStarted(test_level.spawn)) and next.player.dash_active()
}
