## Snake: grow by eating food without hitting the walls or your own body.
##
## Use Arrow keys or WASD to turn, Space to restart, and Escape to quit.
## File structure:
##
## - State (`Game.roc`): snake, food, score, fixed-step timing, and run state
## - Controls (`main.roc`): requested turn, restart, and quit
## - Assets (`Assets.roc`): sounds, font, and prepared interface text
## - App wiring (`main.roc`): reproducible random seed and event sounds
## - Rendering (`Render.roc`): board, HUD, snake, food, glow, and game over
## - Gameplay (`Snake.roc`, `Board.roc`): legal turns, growth, collisions, and food
## - Tests (`main.roc`): turns, food placement, movement, eating, and crashes
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/3vVeddfDE6rraq5j8v1cGHtFNaQhC6dij1zGRN63NGP1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Devices
import rr.Draw
import rr.Math
import rr.Random
import Assets
import Board
import Game
import Render
import Snake

Model : { assets : Assets, world : Game.World, elapsed : F32 }

Controls : Game.Controls

program = { init!, update!, render! }

## Loads presentation assets and seeds the first reproducible Snake world.
init! : App.Init(Model, [ResourceLimit, SoundGenerationFailed])
init! = App.init(
	App.default.with_title("RocRay Snake").with_size({ width: 800, height: 600 }).with_frame_pacing(Capped(120)),
	|startup| {
		rng = Random.seed(U64.to_u32_wrap(App.entropy!(startup)))
		Ok({ assets: Assets.load!()?, world: Game.new_world(rng), elapsed: 0 })
	},
)

## Translates keyboard bindings into a requested Snake turn and buttons.
read_controls : Devices.Snapshot -> Controls
read_controls = |devices| {
	requested_direction =
		if devices.key_pressed(KeyUp) or devices.key_pressed(KeyW) {
			Turn(Up)
		} else if devices.key_pressed(KeyDown) or devices.key_pressed(KeyS) {
			Turn(Down)
		} else if devices.key_pressed(KeyLeft) or devices.key_pressed(KeyA) {
			Turn(Left)
		} else if devices.key_pressed(KeyRight) or devices.key_pressed(KeyD) {
			Turn(Right)
		} else {
			KeepDirection
		}
	{ requested_direction, restart_pressed: devices.key_pressed(KeySpace), quit_pressed: devices.key_pressed(KeyEscape) }
}

## Interprets one pure Snake event as its corresponding sound effect.
play_event! : Assets, Game.Event => {}
play_event! = |assets, event|
	match event {
		FoodEaten => assets.sounds.eat.playback().play!()
		SnakeCrashed => assets.sounds.crash_sound.playback().play!()
		GameStarted => assets.sounds.start.playback().play!()
	}

Msg : []

## Advances pure rules, plays their events, and handles the quit control.
update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	controls = read_controls(program_input.devices)
	dt = Math.clamp(program_input.time.elapsed_seconds, 0, 0.25)
	(world, events) = Game.update(model.world, controls, dt)
	for event in events {
		play_event!(model.assets, event)
	}
	if controls.quit_pressed Err(Exit(0)) else Ok({ ..model, world, elapsed: model.elapsed + dt })
}

## Delegates presentation of the retained world to the rendering module.
render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ..])
render! = |model, frame| Render.draw!(frame, model.assets, model.world, model.elapsed)

no_controls : Controls
no_controls = { requested_direction: KeepDirection, restart_pressed: Bool.False, quit_pressed: Bool.False }

expect read_controls(Devices.none.with_key_pressed(KeyUp)).requested_direction == Turn(Up)
expect {
	direction : Snake.Direction
	direction = Right
	!direction.can_turn_to(Left)
}

expect {
	direction : Snake.Direction
	direction = Right
	direction.can_turn_to(Up)
}
expect Board.find_open_cell({ x: 12, y: 9 }, Snake.initial.cells, 0) == { x: 13, y: 9 }

expect {
	world = Game.new_world(Random.seed(1))
	(next, events) = Game.step_snake(world)
	next.snake.head() == { x: 13, y: 9 } and List.len(next.snake.cells) == 3 and List.is_empty(events)
}

expect {
	world = { ..Game.new_world(Random.seed(1)), food: { x: 13, y: 9 } }
	(next, events) = Game.step_snake(world)
	List.len(next.snake.cells) == 4 and next.score == 1 and events == [FoodEaten]
}

expect {
	world = Game.new_world(Random.seed(1))
	snake : Snake
	snake = { ..world.snake, cells: [{ x: 24, y: 9 }] }
	(next, events) = Game.step_snake({ ..world, snake })
	next.state == GameOver and events == [SnakeCrashed]
}

expect {
	world = Game.new_world(Random.seed(1))
	(next, _events) = Game.update(world, no_controls, Game.step_time * 2)
	next.snake.head() == { x: 14, y: 9 }
}
