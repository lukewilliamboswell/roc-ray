## Pure Snake timing, state transitions, and gameplay events.
import rr.Random
import Board
import Snake

Game := [].{
	State := [Playing, GameOver].{
		is_eq : _
	}
	RequestedDirection := [KeepDirection, Turn(Snake.Direction)].{
		is_eq : _
	}
	Controls : { requested_direction : RequestedDirection, restart_pressed : Bool, quit_pressed : Bool }
	World : { snake : Snake, food : Board.Cell, score : U64, accumulator : F32, state : State, rng : Random.State }
	Event := [FoodEaten, SnakeCrashed, GameStarted].{
		is_eq : _
	}
	step_time = 0.115.F32

	## Creates a playing world with a fresh snake and reproducibly placed food.
	new_world : Random.State -> World
	new_world = |rng| {
		spawned = Board.spawn_food(rng, Snake.initial.cells)
		{ snake: Snake.initial, food: spawned.cell, score: 0, accumulator: 0, state: Playing, rng: spawned.state }
	}

	## Applies a requested legal turn before the next fixed movement step.
	apply_controls : World, Controls -> World
	apply_controls = |world, controls|
		match controls.requested_direction {
			KeepDirection => world
			Turn(direction) => { ..world, snake: world.snake.request_turn(direction) }
		}

	## Moves the snake once and reports eating or crashing as gameplay events.
	step_snake : World -> (World, List(Event))
	step_snake = |world| {
		next = world.snake.next_head()
		ate = next == world.food
		crashed = !Board.contains(next) or world.snake.hits_self(next, ate)
		if crashed {
			({ ..world, accumulator: 0, state: GameOver }, [SnakeCrashed])
		} else {
			snake = world.snake.advance(next, ate)
			if ate {
				spawned = Board.spawn_food(world.rng, snake.cells)
				({ ..world, snake, food: spawned.cell, score: world.score + 1, rng: spawned.state }, [FoodEaten])
			} else {
				({ ..world, snake }, [])
			}
		}
	}

	## Runs every fixed snake step currently paid for by the accumulator.
	advance_fixed_steps : World, List(Event) -> (World, List(Event))
	advance_fixed_steps = |world, events| {
		if world.accumulator < step_time {
			(world, events)
		} else {
			(next_world, step_events) = step_snake({ ..world, accumulator: world.accumulator - step_time })
			all_events = List.concat(events, step_events)
			match next_world.state {
				Playing => advance_fixed_steps(next_world, all_events)
				GameOver => (next_world, all_events)
			}
		}
	}

	## Advances playing rules by bounded elapsed time at a fixed movement rate.
	update_playing : World, Controls, F32 -> (World, List(Event))
	update_playing = |world, controls, dt| {
		controlled = apply_controls(world, controls)
		advance_fixed_steps({ ..controlled, accumulator: controlled.accumulator + dt }, [])
	}

	## Holds a crashed world or starts a fresh run when restart is pressed.
	update_game_over : World, Controls -> (World, List(Event))
	update_game_over = |world, controls|
		if controls.restart_pressed (new_world(world.rng), [GameStarted]) else (world, [])

	## Advances the current Snake state and returns its ordered gameplay events.
	update : World, Controls, F32 -> (World, List(Event))
	update = |world, controls, dt|
		match world.state {
			Playing => update_playing(world, controls, dt)
			GameOver => update_game_over(world, controls)
		}
}
