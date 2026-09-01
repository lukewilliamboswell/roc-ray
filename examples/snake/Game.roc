## Pure Snake timing, state transitions, and gameplay events.
import rr.Random
import Board
import Snake

step_time = 0.115.F32

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

	## Creates a playing world with a fresh snake and reproducibly placed food.
	new_world : Random.State -> World
	new_world = |rng| {
		spawned = Board.spawn_food(rng, Snake.initial.cells)
		{ snake: Snake.initial, food: spawned.cell, score: 0, accumulator: 0, state: Playing, rng: spawned.state }
	}

	## Advances the current Snake state and returns its ordered gameplay events.
	update : World, Controls, F32 -> (World, List(Event))
	update = |world, controls, dt|
		match world.state {
			Playing => update_playing(world, controls, dt)
			GameOver => update_game_over(world, controls)
		}
}

## Applies a requested legal turn before the next fixed movement step.
apply_controls : Game.World, Game.Controls -> Game.World
apply_controls = |world, controls|
	match controls.requested_direction {
		KeepDirection => world
		Turn(direction) => { ..world, snake: world.snake.request_turn(direction) }
	}

## Moves the snake once and reports eating or crashing as gameplay events.
step_snake : Game.World -> (Game.World, List(Game.Event))
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
advance_fixed_steps : Game.World, List(Game.Event) -> (Game.World, List(Game.Event))
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
update_playing : Game.World, Game.Controls, F32 -> (Game.World, List(Game.Event))
update_playing = |world, controls, dt| {
	controlled = apply_controls(world, controls)
	advance_fixed_steps({ ..controlled, accumulator: controlled.accumulator + dt }, [])
}

## Holds a crashed world or starts a fresh run when restart is pressed.
update_game_over : Game.World, Game.Controls -> (Game.World, List(Game.Event))
update_game_over = |world, controls| if controls.restart_pressed (Game.new_world(world.rng), [GameStarted]) else (world, [])

no_controls : Game.Controls
no_controls = { requested_direction: KeepDirection, restart_pressed: Bool.False, quit_pressed: Bool.False }

expect {
	world = Game.new_world(Random.seed(1))
	(next, events) = step_snake(world)
	next.snake.head() == { x: 13, y: 9 } and List.len(next.snake.cells) == 3 and List.is_empty(events)
}

expect {
	world = { ..Game.new_world(Random.seed(1)), food: { x: 13, y: 9 } }
	(next, events) = step_snake(world)
	List.len(next.snake.cells) == 4 and next.score == 1 and events == [FoodEaten]
}

expect {
	world = Game.new_world(Random.seed(1))
	snake : Snake
	snake = Snake.{ cells: [{ x: 24, y: 9 }], direction: world.snake.direction, pending_direction: world.snake.pending_direction }
	(next, events) = step_snake({ ..world, snake })
	next.state == GameOver and events == [SnakeCrashed]
}

expect {
	world = Game.new_world(Random.seed(1))
	(next, _events) = Game.update(world, no_controls, step_time * 2)
	next.snake.head() == { x: 14, y: 9 }
}
