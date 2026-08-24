## Pure spatial queries and deterministic moving-sector state for Doom maps.
## Heights are map units and `tick` advances exactly one 35 Hz game tic.
import DoomMap

DoomLevel := [].{
	Point : { x : F64, y : F64 }
	SectorHeights : { floor : I64, ceiling : I64 }
	Keys : { blue : Bool, yellow : Bool, red : Bool }
	DoorPhase := [Opening, Waiting(U64), Closing].{ is_eq : _ }
	Door : { sector : U64, closed : I64, open : I64, speed : I64, phase : DoorPhase, stays_open : Bool }
	FloorMover : { sector : U64, target : I64, speed : I64 }
	State : { heights : List(SectorHeights), doors : List(Door), floors : List(FloorMover) }
	UseResult : [Activated(State), Exit, Locked([Blue, Yellow, Red]), NotUsable]
	Portal : { from_sector : U64, to_sector : U64, bottom : I64, top : I64, step : I64, traversable : Bool }

	initial : DoomMap.Map -> State
	initial = |map| { heights: List.map(map.raw().sectors, |sector| { floor: sector.floor_height, ceiling: sector.ceiling_height }), doors: [], floors: [] }

	## Descend the classic Doom BSP (whose root is the last node) and return the
	## validated sector associated with the reached subsector polygon.
	sector_at : DoomMap.Map, Point -> Try(U64, [OutsideMap])
	sector_at = |map, point| {
		raw = map.raw()
		if List.is_empty(raw.nodes) polygon_sector(raw.subsector_polygons, point, 0) else {
			root = List.len(raw.nodes) - 1
			subsector = descend(raw.nodes, root, point)
			polygon = polygon_for_subsector(raw.subsector_polygons, subsector, 0)
			if point_in_convex(polygon.points, point, 0) Ok(polygon.sector) else Err(OutsideMap)
		}
	}

	heights_for : State, U64 -> Try(SectorHeights, [SectorOutOfRange(U64)])
	heights_for = |state, sector| match List.get(state.heights, sector) { Ok(value) => Ok(value), Err(_) => Err(SectorOutOfRange(sector)) }

	## Evaluate a two-sided line from one of its sectors. A portal is passable
	## only when it is not explicitly blocking, rises at most 24 units, and has
	## at least the 56-unit standing player height above its destination floor.
	portal : DoomMap.Map, State, U64, U64 -> Try(Portal, [LinedefOutOfRange(U64), NotTwoSided, SectorNotOnLine(U64)])
	portal = |map, state, linedef, from_sector| {
		raw = map.raw()
		line = match List.get(raw.linedefs, linedef) { Ok(value) => value, Err(_) => return Err(LinedefOutOfRange(linedef)) }
		right = match line.right_sidedef { Ok(value) => value, Err(Null) => return Err(NotTwoSided) }
		left = match line.left_sidedef { Ok(value) => value, Err(Null) => return Err(NotTwoSided) }
		right_sector = (List.get(raw.sidedefs, right) ?? crash "validated sidedef missing").sector
		left_sector = (List.get(raw.sidedefs, left) ?? crash "validated sidedef missing").sector
		to_sector = if from_sector == right_sector left_sector else if from_sector == left_sector right_sector else return Err(SectorNotOnLine(from_sector))
		from = List.get(state.heights, from_sector) ?? crash "sector state missing"
		to = List.get(state.heights, to_sector) ?? crash "sector state missing"
		bottom = I64.max(from.floor, to.floor)
		top = I64.min(from.ceiling, to.ceiling)
		step = to.floor - from.floor
		blocked = DoomMap.line_flags(line.flags).blocks_players
		Ok({ from_sector, to_sector, bottom, top, step, traversable: !blocked and step <= 24 and top - to.floor >= 56 })
	}

	## Activate the E1M1 use-line door vocabulary. Specials 1 and 117 are
	## ordinary/blazing local doors; 26 is the blue-key variant; 62 opens all
	## tagged doors permanently. Special 11 requests level exit.
	use_line : DoomMap.Map, State, U64, Keys -> UseResult
	use_line = |map, state, linedef, keys| {
		raw = map.raw()
		match List.get(raw.linedefs, linedef) {
			Err(_) => NotUsable
			Ok(line) => match line.special {
				1 => activate_local_door(raw, state, line, Bool.False, 2)
				26 => if keys.blue activate_local_door(raw, state, line, Bool.False, 2) else Locked(Blue)
				23 => activate_tagged_floors(raw, state, line.tag)
				62 => activate_tagged_doors(raw, state, line.tag, Bool.True, 2)
				117 => activate_local_door(raw, state, line, Bool.False, 8)
				11 => Exit
				_ => NotUsable
			}
		}
	}

	## W1 special 2 opens tagged doors permanently when crossed.
	cross_line : DoomMap.Map, State, U64 -> UseResult
	cross_line = |map, state, linedef| {
		raw = map.raw()
		match List.get(raw.linedefs, linedef) {
			Ok(line) => if line.special == 2 activate_tagged_doors(raw, state, line.tag, Bool.True, 2) else NotUsable
			Err(_) => NotUsable
		}
	}

	## Advance all active doors by one deterministic 35 Hz tic.
	tick : State -> State
	tick = |state| {
		doors_advanced = tick_doors(state, state.doors, [], 0)
		tick_floors(doors_advanced, doors_advanced.floors, [], 0)
	}
}

descend = |nodes, index, point| {
	node = List.get(nodes, index) ?? crash "validated BSP child missing"
	cross = I64.to_f64(node.dx) * (point.y - I64.to_f64(node.y)) - I64.to_f64(node.dy) * (point.x - I64.to_f64(node.x))
	child = if cross <= 0 node.right_child else node.left_child
	if child.kind == "subsector" child.index else descend(nodes, child.index, point)
}

polygon_sector = |polygons, point, index|
	match List.get(polygons, index) {
		Err(_) => Err(OutsideMap)
		Ok(polygon) => if point_in_convex(polygon.points, point, 0) Ok(polygon.sector) else polygon_sector(polygons, point, index + 1)
	}

polygon_for_subsector = |polygons, subsector, index|
	match List.get(polygons, index) {
		Err(_) => crash "validated BSP polygon missing"
		Ok(polygon) => if polygon.subsector == subsector polygon else polygon_for_subsector(polygons, subsector, index + 1)
	}

point_in_convex = |points, point, index|
	if index >= List.len(points) Bool.True else {
		a = List.get(points, index) ?? crash "validated polygon point missing"
		b = List.get(points, (index + 1) % List.len(points)) ?? crash "validated polygon point missing"
		cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
		cross >= -0.000001 and point_in_convex(points, point, index + 1)
	}

activate_local_door = |raw, state, line, stays_open, speed|
	match line.left_sidedef {
		Err(Null) => NotUsable
		Ok(left_index) => {
			right_index = line.right_sidedef ?? crash "validated right sidedef missing"
			right_sector = (List.get(raw.sidedefs, right_index) ?? crash "validated sidedef missing").sector
			left_sector = (List.get(raw.sidedefs, left_index) ?? crash "validated sidedef missing").sector
			right = List.get(state.heights, right_sector) ?? crash "sector state missing"
			left = List.get(state.heights, left_sector) ?? crash "sector state missing"
			sector = if right.ceiling - right.floor <= left.ceiling - left.floor right_sector else left_sector
			activate_door(raw, state, sector, stays_open, speed)
		}
	}

activate_tagged_doors = |raw, state, tag, stays_open, speed| {
	sectors = tagged_sectors(raw.sectors, tag, 0)
	if List.is_empty(sectors) NotUsable else Activated(activate_doors(raw, state, sectors, 0, stays_open, speed))
}

activate_tagged_floors = |raw, state, tag| {
	sectors = tagged_sectors(raw.sectors, tag, 0)
	if List.is_empty(sectors) NotUsable else Activated(add_floor_movers(raw, state, sectors, 0))
}

add_floor_movers = |raw, state, sectors, index|
	match List.get(sectors, index) {
		Err(_) => state
		Ok(sector) => {
			target = lowest_adjacent_floor(raw, state, sector, 0, Err(NoAdjacent))
			without = List.keep_if(state.floors, |mover| mover.sector != sector)
			next = { ..state, floors: List.append(without, { sector, target, speed: 1 }) }
			add_floor_movers(raw, next, sectors, index + 1)
		}
	}

activate_doors = |raw, state, sectors, index, stays_open, speed|
	match List.get(sectors, index) {
		Err(_) => state
		Ok(sector) => {
			next = match activate_door(raw, state, sector, stays_open, speed) { Activated(value) => value, _ => state }
			activate_doors(raw, next, sectors, index + 1, stays_open, speed)
		}
	}

tagged_sectors = |sectors, tag, index|
	match List.get(sectors, index) {
		Err(_) => []
		Ok(sector) => {
			rest = tagged_sectors(sectors, tag, index + 1)
			if tag != 0 and sector.tag == tag List.prepend(rest, index) else rest
		}
	}

activate_door = |raw, state, sector, stays_open, speed| {
	current = List.get(state.heights, sector) ?? crash "sector state missing"
	open = lowest_adjacent_ceiling(raw, state, sector, 0, Err(NoAdjacent)) - 4
	door = { sector, closed: current.ceiling, open, speed, phase: Opening, stays_open }
	without = List.keep_if(state.doors, |active| active.sector != sector)
	Activated({ ..state, doors: List.append(without, door) })
}

lowest_adjacent_ceiling = |raw, state, sector, line_index, found|
	match List.get(raw.linedefs, line_index) {
		Err(_) => found ?? crash "door sector has no adjacent sector"
		Ok(line) => {
			next = adjacent_sector(raw, line, sector)
			found2 = match next {
				Err(_) => found
				Ok(other) => {
					height = (List.get(state.heights, other) ?? crash "sector state missing").ceiling
					match found { Err(NoAdjacent) => Ok(height), Ok(value) => Ok(I64.min(value, height)) }
				}
			}
			lowest_adjacent_ceiling(raw, state, sector, line_index + 1, found2)
		}
	}

lowest_adjacent_floor = |raw, state, sector, line_index, found|
	match List.get(raw.linedefs, line_index) {
		Err(_) => found ?? crash "floor sector has no adjacent sector"
		Ok(line) => {
			next = adjacent_sector(raw, line, sector)
			found2 = match next {
				Err(_) => found
				Ok(other) => {
					height = (List.get(state.heights, other) ?? crash "sector state missing").floor
					match found { Err(NoAdjacent) => Ok(height), Ok(value) => Ok(I64.min(value, height)) }
				}
			}
			lowest_adjacent_floor(raw, state, sector, line_index + 1, found2)
		}
	}

adjacent_sector = |raw, line, sector|
	match line.left_sidedef {
		Err(Null) => Err(NotAdjacent)
		Ok(left_index) => {
			right_index = line.right_sidedef ?? crash "validated right sidedef missing"
			right = (List.get(raw.sidedefs, right_index) ?? crash "validated sidedef missing").sector
			left = (List.get(raw.sidedefs, left_index) ?? crash "validated sidedef missing").sector
			if right == sector Ok(left) else if left == sector Ok(right) else Err(NotAdjacent)
		}
	}

tick_doors = |state, remaining, next_doors, index|
	match List.get(remaining, index) {
		Err(_) => { ..state, doors: next_doors }
		Ok(door) => {
			heights = List.get(state.heights, door.sector) ?? crash "sector state missing"
			advanced = match door.phase {
				Opening => {
					ceiling = I64.min(door.open, heights.ceiling + door.speed)
					phase = if ceiling >= door.open { if door.stays_open Waiting(0) else Waiting(150) } else Opening
					{ heights: { ..heights, ceiling }, door: { ..door, phase }, finished: door.stays_open and ceiling >= door.open }
				}
				Waiting(tics) => if tics == 0 { heights, door, finished: Bool.True } else { heights, door: { ..door, phase: if tics == 1 Closing else Waiting(tics - 1) }, finished: Bool.False }
				Closing => {
					ceiling = I64.max(door.closed, heights.ceiling - door.speed)
					{ heights: { ..heights, ceiling }, door, finished: ceiling <= door.closed }
				}
			}
			replaced = List.replace(state.heights, door.sector, advanced.heights) ?? crash "sector state missing"
			state2 = { ..state, heights: replaced.list }
			doors2 = if advanced.finished next_doors else List.append(next_doors, advanced.door)
			tick_doors(state2, remaining, doors2, index + 1)
		}
	}

tick_floors = |state, remaining, next_floors, index|
	match List.get(remaining, index) {
		Err(_) => { ..state, floors: next_floors }
		Ok(mover) => {
			heights = List.get(state.heights, mover.sector) ?? crash "sector state missing"
			floor = I64.max(mover.target, heights.floor - mover.speed)
			replaced = List.replace(state.heights, mover.sector, { ..heights, floor }) ?? crash "sector state missing"
			state2 = { ..state, heights: replaced.list }
			floors2 = if floor <= mover.target next_floors else List.append(next_floors, mover)
			tick_floors(state2, remaining, floors2, index + 1)
		}
	}

advance_tics = |state, count|
	if count == 0 state else advance_tics(DoomLevel.tick(state), count - 1)

expect {
	map = DoomMap.e1m1
	start = map.player_start() ?? crash "E1M1 player start missing"
	sector = DoomLevel.sector_at(map, { x: I64.to_f64(start.position.x), y: I64.to_f64(start.position.y) }) ?? crash "player outside BSP"
	heights = DoomLevel.heights_for(DoomLevel.initial(map), sector) ?? crash "sector missing"
	heights.ceiling - heights.floor >= 56
}

expect {
	map = DoomMap.e1m1
	state = DoomLevel.initial(map)
	locked = DoomLevel.use_line(map, state, 421, { blue: Bool.False, yellow: Bool.False, red: Bool.False })
	unlocked = DoomLevel.use_line(map, state, 421, { blue: Bool.True, yellow: Bool.False, red: Bool.False })
	locked == Locked(Blue) and match unlocked { Activated(next) => List.len(next.doors) == 1, _ => Bool.False }
}

expect {
	map = DoomMap.e1m1
	state = DoomLevel.initial(map)
	activated = DoomLevel.use_line(map, state, 55, { blue: Bool.False, yellow: Bool.False, red: Bool.False })
	match activated {
		Activated(opening) => {
			door = List.get(opening.doors, 0) ?? crash "door missing"
			before = DoomLevel.heights_for(opening, door.sector) ?? crash "door sector missing"
			after = DoomLevel.heights_for(DoomLevel.tick(opening), door.sector) ?? crash "door sector missing"
			after.ceiling == I64.min(door.open, before.ceiling + 2)
		}
		_ => Bool.False
	}
}

expect {
	map = DoomMap.e1m1
	initial = DoomLevel.initial(map)
	match DoomLevel.use_line(map, initial, 753, { blue: Bool.False, yellow: Bool.False, red: Bool.False }) {
		Activated(moving) => {
			mover = List.get(moving.floors, 0) ?? crash "tagged floor mover missing"
			before = DoomLevel.heights_for(moving, mover.sector) ?? crash "floor sector missing"
			after = DoomLevel.heights_for(DoomLevel.tick(moving), mover.sector) ?? crash "floor sector missing"
			after.floor == I64.max(mover.target, before.floor - 1)
		}
		_ => Bool.False
	}
}

expect {
	map = DoomMap.e1m1
	raw = map.raw()
	line = List.get(raw.linedefs, 55) ?? crash "E1M1 door line missing"
	right_side = List.get(raw.sidedefs, line.right_sidedef ?? crash "door right side missing") ?? crash "door side missing"
	left_side = List.get(raw.sidedefs, line.left_sidedef ?? crash "door left side missing") ?? crash "door side missing"
	initial = DoomLevel.initial(map)
	activated = DoomLevel.use_line(map, initial, 55, { blue: Bool.False, yellow: Bool.False, red: Bool.False })
	match activated {
		Activated(opening) => {
			door = List.get(opening.doors, 0) ?? crash "door missing"
			from_sector = if door.sector == right_side.sector left_side.sector else right_side.sector
			closed = DoomLevel.portal(map, initial, 55, from_sector) ?? crash "door portal missing"
			opened = DoomLevel.portal(map, advance_tics(opening, 80), 55, from_sector) ?? crash "door portal missing"
			!(closed.traversable) and opened.traversable and opened.step <= 24 and opened.top - opened.bottom >= 56
		}
		_ => Bool.False
	}
}
