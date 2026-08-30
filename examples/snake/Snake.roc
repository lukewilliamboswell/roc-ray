## Snake body movement and legal direction changes.
import Board

Snake := { cells : List(Board.Cell), direction : Direction, pending_direction : Direction }.{
	Direction := [Up, Down, Left, Right].{
		is_eq : _
	}

	initial : Snake
	initial = { cells: initial_cells, direction: Right, pending_direction: Right }

	## Returns the leading cell of a non-empty snake.
	head : Snake -> Board.Cell
	head = |snake|
		match List.first(snake.cells) {
			Ok(cell) => cell
			Err(_) => { x: 0, y: 0 }
		}

	## Queues a direction unless it would reverse into the snake's neck.
	request_turn : Snake, Direction -> Snake
	request_turn = |snake, requested| {
		pending_direction = if can_turn_to(snake.direction, requested) requested else snake.pending_direction
		{ ..snake, pending_direction }
	}

	## Computes the cell the snake will enter on its next fixed step.
	next_head : Snake -> Board.Cell
	next_head = |snake| {
		move = direction_delta(snake.pending_direction)
		head_cell = snake.head()
		{ x: head_cell.x + move.x, y: head_cell.y + move.y }
	}

	## Reports whether entering a cell collides with the body that will remain.
	hits_self : Snake, Board.Cell, Bool -> Bool
	hits_self = |snake, next, growing| {
		body = if growing snake.cells else List.drop_last(snake.cells, 1)
		List.contains(body, next)
	}

	## Moves into a cell, retaining the tail only when food was eaten.
	advance : Snake, Board.Cell, Bool -> Snake
	advance = |snake, next, growing| {
		body = if growing snake.cells else List.drop_last(snake.cells, 1)
		{ cells: List.prepend(body, next), direction: snake.pending_direction, pending_direction: snake.pending_direction }
	}
}

initial_cells : List(Board.Cell)
initial_cells = [{ x: 12, y: 9 }, { x: 11, y: 9 }, { x: 10, y: 9 }]

## Returns the private one-cell displacement for a direction.
direction_delta : Snake.Direction -> Board.Cell
direction_delta = |direction|
	match direction {
		Up => { x: 0, y: -1 }
		Down => { x: 0, y: 1 }
		Left => { x: -1, y: 0 }
		Right => { x: 1, y: 0 }
	}

## Reports whether a requested direction avoids reversing into the neck.
can_turn_to : Snake.Direction, Snake.Direction -> Bool
can_turn_to = |current, requested|
	match current {
		Up => requested != Down
		Down => requested != Up
		Left => requested != Right
		Right => requested != Left
	}
