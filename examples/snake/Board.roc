## Snake board geometry and reproducible food placement.
import rr.Math
import rr.Random

Board := [].{
	Cell : { x : I32, y : I32 }

	columns = 25.I32
	rows = 18.I32
	columns_count = 25.U64
	rows_count = 18.U64
	origin : Math.Vec2
	origin = { x: 75, y: 80 }
	cell_size = 26.F32

	## Reports whether a cell lies inside the playable grid.
	contains : Cell -> Bool
	contains = |cell| cell.x >= 0 and cell.x < columns and cell.y >= 0 and cell.y < rows

	## Converts a grid cell into its screen-space rectangle.
	cell_rect : Cell -> Math.Rect
	cell_rect = |cell| { x: origin.x + I32.to_f32(cell.x) * cell_size, y: origin.y + I32.to_f32(cell.y) * cell_size, width: cell_size, height: cell_size }

	## Chooses a reproducible unoccupied food cell and advances the random state.
	spawn_food : Random.State, List(Cell) -> { cell : Cell, state : Random.State }
	spawn_food = |state, occupied| {
		column = Random.step(state, Random.bounded_i32(0, columns - 1))
		row = Random.next(column, Random.bounded_i32(0, rows - 1))
		{ cell: find_open_cell({ x: column.value, y: row.value }, occupied, 0), state: row.state }
	}
}

## Walks forward from a candidate until it finds a cell outside the snake.
find_open_cell : Board.Cell, List(Board.Cell), I32 -> Board.Cell
find_open_cell = |seed, occupied, attempt| {
	cell_count = Board.columns * Board.rows
	if attempt >= cell_count {
		seed
	} else {
		flat_index = (seed.y * Board.columns + seed.x + attempt) % cell_count
		candidate = { x: flat_index % Board.columns, y: flat_index // Board.columns }
		if List.contains(occupied, candidate) find_open_cell(seed, occupied, attempt + 1) else candidate
	}
}

expect find_open_cell({ x: 12, y: 9 }, [{ x: 12, y: 9 }, { x: 11, y: 9 }, { x: 10, y: 9 }], 0) == { x: 13, y: 9 }
