## Pure spatial queries and deterministic moving-sector state for Doom maps.
## Heights are map units and `tick` advances exactly one 35 Hz game tic.
import DoomMap

DoomLevel := [].{
	Point : { x : F64, y : F64 }
	SectorHeights : { floor : I64, ceiling : I64 }
	Keys : { blue : Bool, yellow : Bool, red : Bool }
	DoorPhase := [Opening, Waiting(U64), Closing].{
		is_eq : _
	}
	Door : { sector : U64, closed : I64, open : I64, speed : I64, phase : DoorPhase, stays_open : Bool }
	FloorMover : { sector : U64, target : I64, speed : I64 }
	LiftPhase := [Lowering, LiftWaiting(U64), Raising].{
		is_eq : _
	}
	Lift : { sector : U64, low : I64, high : I64, speed : I64, phase : LiftPhase }
	LightFlash : { sector : U64, low : I64, high : I64, count : U64, dark : Bool }
	State : { heights : List(SectorHeights), incident_lines : List(List(U64)), doors : List(Door), floors : List(FloorMover), lifts : List(Lift), tic : U64, light_rng : U8, light_flashes : List(LightFlash) }
	UseResult : [Activated(State), Exit, Locked([Blue, Yellow, Red]), NotUsable]
	Portal : { from_sector : U64, to_sector : U64, bottom : I64, top : I64, step : I64, traversable : Bool }
	CollisionSegment : { linedef : U64, start : Point, end : Point }

	initial : DoomMap.Map -> State
	initial = |map| {
		raw = map.raw()
		{
			heights: List.map(raw.sectors, |sector| { floor: sector.floor_height, ceiling: sector.ceiling_height }),
			incident_lines: List.map_with_index(raw.sectors, |_sector, sector| incident_lines_for(raw, sector, 0, [])),
			doors: [],
			floors: [],
			lifts: [],
			tic: 0,
			light_rng: 0,
			light_flashes: initial_light_flashes(raw, 0, []),
		}
	}

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
	heights_for = |state, sector| match List.get(state.heights, sector) {
		Ok(value) => Ok(value)
		Err(_) => Err(SectorOutOfRange(sector))
	}

	light_for : DoomMap.Map, State, U64 -> Try(I64, [SectorOutOfRange(U64)])
	light_for = |map, state, sector| {
		raw_sector = List.get(map.raw().sectors, sector) ?? return Err(SectorOutOfRange(sector))
		if raw_sector.special == 12 {
			low = lowest_adjacent_light(map.raw(), sector, 0, raw_sector.light_level)
			Ok(if state.tic == 0 or state.tic % 20 >= 16 raw_sector.light_level else low)
		} else {
			match List.find_first(state.light_flashes, |flash| flash.sector == sector) {
				Ok(flash) => Ok(if flash.dark flash.low else flash.high)
				Err(_) => Ok(raw_sector.light_level)
			}
		}
	}

	## Evaluate a two-sided line from one of its sectors. A portal is passable
	## only when it is not explicitly blocking, rises at most 24 units, and has
	## at least the 56-unit standing player height above its destination floor.
	portal : DoomMap.Map, State, U64, U64 -> Try(Portal, [LinedefOutOfRange(U64), NotTwoSided, SectorNotOnLine(U64)])
	portal = |map, state, linedef, from_sector| {
		raw = map.raw()
		line = match List.get(raw.linedefs, linedef) {
			Ok(value) => value
			Err(_) => return Err(LinedefOutOfRange(linedef))
		}
		right = match line.right_sidedef {
			Ok(value) => value
			Err(Null) => return Err(NotTwoSided)
		}
		left = match line.left_sidedef {
			Ok(value) => value
			Err(Null) => return Err(NotTwoSided)
		}
		right_sector = (List.get(raw.sidedefs, right) ?? crash "validated sidedef missing").sector
		left_sector = (List.get(raw.sidedefs, left) ?? crash "validated sidedef missing").sector
		to_sector = if from_sector == right_sector left_sector else if from_sector == left_sector right_sector else return Err(SectorNotOnLine(from_sector))
		from = List.get(state.heights, from_sector) ?? crash "sector state missing"
		to = List.get(state.heights, to_sector) ?? crash "sector state missing"
		bottom = I64.max(from.floor, to.floor)
		top = I64.min(from.ceiling, to.ceiling)
		step = to.floor - from.floor
		blocked = DoomMap.line_flags(line.flags).blocks_players
		Ok({ from_sector, to_sector, bottom, top, step, traversable: !blocked and step <= 24 and top - bottom >= 56 })
	}

	## Return the current sector boundary segments that collision must retain.
	## Open, traversable two-sided portals are deliberately omitted.
	collision_segments : DoomMap.Map, State, U64 -> List(CollisionSegment)
	collision_segments = |map, state, sector| {
		lines = List.get(state.incident_lines, sector) ?? return []
		collision_segments_indexed(map, map.raw(), state, sector, lines, 0)
	}

	## Return each currently blocking map boundary once, in linedef order. A
	## two-sided boundary is retained when either traversal direction is closed.
	global_collision_segments : DoomMap.Map, State -> List(CollisionSegment)
	global_collision_segments = |map, state| {
		raw = map.raw()
		var $segments = List.with_capacity(List.len(raw.linedefs))
		var $linedef = 0.U64
		for line in raw.linedefs {
			blocks = match line.left_sidedef {
				Err(Null) => Bool.True
				Ok(left_index) => {
					right_index = line.right_sidedef ?? crash "validated two-sided linedef missing right side"
					right_sector = (List.get(raw.sidedefs, right_index) ?? crash "validated right sidedef missing").sector
					left_sector = (List.get(raw.sidedefs, left_index) ?? crash "validated left sidedef missing").sector
					right = List.get(state.heights, right_sector) ?? crash "sector state missing"
					left = List.get(state.heights, left_sector) ?? crash "sector state missing"
					floor_delta = I64.abs(right.floor - left.floor)
					opening = I64.min(right.ceiling, left.ceiling) - I64.max(right.floor, left.floor)
					DoomMap.line_flags(line.flags).blocks_players or floor_delta > 24 or opening < 56
				}
			}
			if blocks {
				a = List.get(raw.vertices, line.start_vertex) ?? crash "validated vertex missing"
				b = List.get(raw.vertices, line.end_vertex) ?? crash "validated vertex missing"
				$segments = List.append($segments, { linedef: $linedef, start: { x: I64.to_f64(a.x), y: I64.to_f64(a.y) }, end: { x: I64.to_f64(b.x), y: I64.to_f64(b.y) } })
			}
			$linedef = $linedef + 1
		}
		$segments
	}

	collision_candidate_count : State, U64 -> U64
	collision_candidate_count = |state, sector| List.len(List.get(state.incident_lines, sector) ?? [])

	## Return special linedefs crossed by a swept point, in map order. Endpoint
	## touches count only when the sweep changes side, preventing repeat triggers
	## while moving along a line.
	crossed_lines : DoomMap.Map, Point, Point -> List(U64)
	crossed_lines = |map, start, end| crossed_lines_from(map.raw(), start, end, 0)

	## Sectors whose planes can move under the supported E1M1 specials. Render
	## adapters use this stable set to keep them out of retained static geometry.
	dynamic_sectors : DoomMap.Map -> List(U64)
	dynamic_sectors = |map| {
		raw = map.raw()
		var $result = dynamic_sectors_from(raw, initial(map), 0, [])
		for entry in List.map_with_index(raw.sectors, |sector, index| { sector, index }) {
			if (entry.sector.special == 1 or entry.sector.special == 12) and !(List.contains($result, entry.index)) {
				$result = List.append($result, entry.index)
			}
		}
		$result
	}

	## Whether retained dynamic geometry needs rebuilding. Simulation tics that
	## leave every moving height and animated sector light unchanged reuse the
	## previous batches.
	render_changed : DoomMap.Map, State, State -> Bool
	render_changed = |map, before, after| render_changed_in(map, before, after, dynamic_sectors(map), 0)

	## Activate the E1M1 use-line vocabulary. Specials 1 and 117 are
	## ordinary/blazing local doors; 26 is the blue-key variant; 23 lowers
	## tagged floors; 62 is the switch form of the special-88 lift. Special 11
	## requests level exit.
	use_line : DoomMap.Map, State, U64, Keys -> UseResult
	use_line = |map, state, linedef, keys| {
		raw = map.raw()
		match List.get(raw.linedefs, linedef) {
			Err(_) => NotUsable
			Ok(line) => match line.special {
				1 => activate_local_door(raw, state, line, Bool.False, 2)
				26 => if keys.blue activate_local_door(raw, state, line, Bool.False, 2) else Locked(Blue)
				23 => activate_tagged_floors(raw, state, line.tag)
				62 => activate_tagged_lifts(raw, state, line.tag)
				117 => activate_local_door(raw, state, line, Bool.False, 8)
				11 => Exit
				_ => NotUsable
			}
		}
	}

	## Monsters may operate ordinary, non-secret local doors. They can reopen a
	## closing door, but cannot reverse one that is already opening or waiting.
	monster_use_line : DoomMap.Map, State, U64 -> UseResult
	monster_use_line = |map, state, linedef| {
		raw = map.raw()
		match List.get(raw.linedefs, linedef) {
			Ok(line) if line.special == 1 and !(DoomMap.line_flags(line.flags).secret) => monster_activate_local_door(raw, state, line)
			_ => NotUsable
		}
	}

	## W1 special 2 opens tagged doors permanently; WR special 88 starts the
	## tagged lower-wait-raise lift cycle.
	cross_line : DoomMap.Map, State, U64 -> UseResult
	cross_line = |map, state, linedef| {
		raw = map.raw()
		match List.get(raw.linedefs, linedef) {
			Ok(line) => if line.special == 2 activate_tagged_doors(raw, state, line.tag, Bool.True, 2) else if line.special == 88 activate_tagged_lifts(raw, state, line.tag) else NotUsable
			Err(_) => NotUsable
		}
	}

	## Advance all active doors by one deterministic 35 Hz tic.
	tick : State -> State
	tick = |state| {
		doors_advanced = tick_doors(state, state.doors, [], 0)
		floors_advanced = tick_floors(doors_advanced, doors_advanced.floors, [], 0)
		lifts_advanced = tick_lifts(floors_advanced, floors_advanced.lifts, [], 0)
		light = tick_light_flashes(lifts_advanced.light_flashes, lifts_advanced.light_rng, [], 0)
		{ ..lifts_advanced, tic: lifts_advanced.tic + 1, light_rng: light.rng, light_flashes: light.flashes }
	}
}

render_changed_in = |map, before, after, sectors, index|
	match List.get(sectors, index) {
		Err(_) => Bool.False
		Ok(sector) => {
			before_heights = DoomLevel.heights_for(before, sector) ?? crash "dynamic sector missing"
			after_heights = DoomLevel.heights_for(after, sector) ?? crash "dynamic sector missing"
			before_light = DoomLevel.light_for(map, before, sector) ?? crash "dynamic light missing"
			after_light = DoomLevel.light_for(map, after, sector) ?? crash "dynamic light missing"
			before_heights != after_heights or before_light != after_light or render_changed_in(map, before, after, sectors, index + 1)
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

crossed_lines_from = |raw, start, end, index|
	match List.get(raw.linedefs, index) {
		Err(_) => []
		Ok(line) => {
			rest = crossed_lines_from(raw, start, end, index + 1)
			if line.special == 0 rest else {
				a_raw = List.get(raw.vertices, line.start_vertex) ?? crash "validated vertex missing"
				b_raw = List.get(raw.vertices, line.end_vertex) ?? crash "validated vertex missing"
				a = { x: I64.to_f64(a_raw.x), y: I64.to_f64(a_raw.y) }
				b = { x: I64.to_f64(b_raw.x), y: I64.to_f64(b_raw.y) }
				start_side = line_side(a, b, start)
				end_side = line_side(a, b, end)
				line_start_side = line_side(start, end, a)
				line_end_side = line_side(start, end, b)
				changes_side = (start_side < 0 and end_side >= 0) or (start_side > 0 and end_side <= 0)
				intersects_extent = (line_start_side <= 0 and line_end_side >= 0) or (line_start_side >= 0 and line_end_side <= 0)
				if changes_side and intersects_extent List.prepend(rest, index) else rest
			}
		}
	}

line_side = |a, b, point| (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)

incident_lines_for = |raw, sector, index, result|
	match List.get(raw.linedefs, index) {
		Err(_) => result
		Ok(line) => {
			right = side_sector(raw, line.right_sidedef)
			left = side_sector(raw, line.left_sidedef)
			next = if right == Ok(sector) or left == Ok(sector) List.append(result, index) else result
			incident_lines_for(raw, sector, index + 1, next)
		}
	}

collision_segments_indexed = |map, raw, state, sector, lines, offset|
	match List.get(lines, offset) {
		Err(_) => []
		Ok(index) => {
			rest = collision_segments_indexed(map, raw, state, sector, lines, offset + 1)
			line = List.get(raw.linedefs, index) ?? crash "validated incident linedef missing"
			blocks = match line.left_sidedef {
				Err(Null) => Bool.True
				Ok(_) => match DoomLevel.portal(map, state, index, sector) {
					Ok(opening) => !(opening.traversable)
					Err(_) => Bool.True
				}
			}
			if blocks {
				a = List.get(raw.vertices, line.start_vertex) ?? crash "validated vertex missing"
				b = List.get(raw.vertices, line.end_vertex) ?? crash "validated vertex missing"
				List.prepend(rest, { linedef: index, start: { x: I64.to_f64(a.x), y: I64.to_f64(a.y) }, end: { x: I64.to_f64(b.x), y: I64.to_f64(b.y) } })
			} else rest
		}
		}

collision_segments_from = |map, raw, state, sector, index|
	match List.get(raw.linedefs, index) {
		Err(_) => []
		Ok(line) => {
			rest = collision_segments_from(map, raw, state, sector, index + 1)
			right_sector = side_sector(raw, line.right_sidedef)
			left_sector = side_sector(raw, line.left_sidedef)
			touches = right_sector == Ok(sector) or left_sector == Ok(sector)
			blocks = if !touches Bool.False else match line.left_sidedef {
				Err(Null) => Bool.True
				Ok(_) => match DoomLevel.portal(map, state, index, sector) {
					Ok(opening) => !(opening.traversable)
					Err(_) => Bool.True
				}
			}
			if blocks {
				a = List.get(raw.vertices, line.start_vertex) ?? crash "validated vertex missing"
				b = List.get(raw.vertices, line.end_vertex) ?? crash "validated vertex missing"
				List.prepend(rest, { linedef: index, start: { x: I64.to_f64(a.x), y: I64.to_f64(a.y) }, end: { x: I64.to_f64(b.x), y: I64.to_f64(b.y) } })
			} else rest
		}
	}

side_sector = |raw, side_ref|
	match side_ref {
		Err(Null) => Err(NoSector)
		Ok(index) => Ok((List.get(raw.sidedefs, index) ?? crash "validated sidedef missing").sector)
	}

lowest_adjacent_light = |raw, sector, line_index, found|
	match List.get(raw.linedefs, line_index) {
		Err(_) => found
		Ok(line) => {
			right = side_sector(raw, line.right_sidedef)
			left = side_sector(raw, line.left_sidedef)
			other = if right == Ok(sector) left else if left == Ok(sector) right else Err(NotAdjacent)
			next = match other {
				Ok(index) => I64.min(found, (List.get(raw.sectors, index) ?? crash "adjacent sector missing").light_level)
				Err(_) => found
			}
			lowest_adjacent_light(raw, sector, line_index + 1, next)
		}
	}

initial_light_flashes = |raw, sector, result|
	match List.get(raw.sectors, sector) {
		Err(_) => result
		Ok(value) => {
			next = if value.special == 1 {
				List.append(result, { sector, low: lowest_adjacent_light(raw, sector, 0, value.light_level), high: value.light_level, count: 64, dark: Bool.False })
			} else result
			initial_light_flashes(raw, sector + 1, next)
		}
	}

tick_light_flashes = |remaining, rng, result, index|
	match List.get(remaining, index) {
		Err(_) => { flashes: result, rng }
		Ok(flash) => {
			if flash.count > 1 {
				tick_light_flashes(remaining, rng, List.append(result, { ..flash, count: flash.count - 1 }), index + 1)
			} else {
				next_rng = U16.to_u8_wrap(U8.to_u16(rng) * 73 + 41)
				dark = !(flash.dark)
				count = if dark 7 + U8.to_u64(next_rng % 8) else 64 + U8.to_u64(next_rng % 64)
				tick_light_flashes(remaining, next_rng, List.append(result, { ..flash, count, dark }), index + 1)
			}
		}
	}

dynamic_sectors_from = |raw, state, index, result|
	match List.get(raw.linedefs, index) {
		Err(_) => result
		Ok(line) => {
			sectors = match line.special {
				1 => local_door_sectors(raw, state, line)
				26 => local_door_sectors(raw, state, line)
				117 => local_door_sectors(raw, state, line)
				2 => tagged_sectors(raw.sectors, line.tag, 0)
				23 => tagged_sectors(raw.sectors, line.tag, 0)
				62 => tagged_sectors(raw.sectors, line.tag, 0)
				88 => tagged_sectors(raw.sectors, line.tag, 0)
				_ => []
			}
			dynamic_sectors_from(raw, state, index + 1, append_unique(result, sectors, 0))
		}
	}

local_door_sectors = |raw, state, line|
	match line.left_sidedef {
		Err(Null) => []
		Ok(left_index) => {
			right_index = line.right_sidedef ?? crash "validated right sidedef missing"
			right_sector = (List.get(raw.sidedefs, right_index) ?? crash "validated sidedef missing").sector
			left_sector = (List.get(raw.sidedefs, left_index) ?? crash "validated sidedef missing").sector
			right = List.get(state.heights, right_sector) ?? crash "sector state missing"
			left = List.get(state.heights, left_sector) ?? crash "sector state missing"
			[if right.ceiling - right.floor <= left.ceiling - left.floor right_sector else left_sector]
		}
	}

append_unique = |result, values, index|
	match List.get(values, index) {
		Err(_) => result
		Ok(value) => append_unique(if List.contains(result, value) result else List.append(result, value), values, index + 1)
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

monster_activate_local_door = |raw, state, line|
	match line.left_sidedef {
		Err(Null) => NotUsable
		Ok(left_index) => {
			right_index = line.right_sidedef ?? crash "validated right sidedef missing"
			right_sector = (List.get(raw.sidedefs, right_index) ?? crash "validated sidedef missing").sector
			left_sector = (List.get(raw.sidedefs, left_index) ?? crash "validated sidedef missing").sector
			right = List.get(state.heights, right_sector) ?? crash "sector state missing"
			left = List.get(state.heights, left_sector) ?? crash "sector state missing"
			sector = if right.ceiling - right.floor <= left.ceiling - left.floor right_sector else left_sector
			match List.find_first(state.doors, |active| active.sector == sector) {
				Ok(active) => match active.phase {
					Closing => {
						doors = List.map(state.doors, |door| if door.sector == sector { ..door, phase: Opening } else door)
						Activated({ ..state, doors })
					}
					Opening | Waiting(_) => NotUsable
				}
				Err(_) => activate_door(raw, state, sector, Bool.False, 2)
			}
		}
	}

activate_tagged_doors = |raw, state, tag, stays_open, speed|
	activated_if_changed(state, activate_doors(raw, state, tagged_sectors(raw.sectors, tag, 0), 0, stays_open, speed))

activate_tagged_floors = |raw, state, tag|
	activated_if_changed(state, add_floor_movers(raw, state, tagged_sectors(raw.sectors, tag, 0), 0))

activate_tagged_lifts = |raw, state, tag|
	activated_if_changed(state, add_lifts(raw, state, tagged_sectors(raw.sectors, tag, 0), 0))

## A tagged special that started no mover (no tagged sector, or none with an
## adjacent sector to move toward) is reported as unusable.
activated_if_changed = |before, after|
	if List.len(after.doors) == List.len(before.doors) and List.len(after.floors) == List.len(before.floors) and List.len(after.lifts) == List.len(before.lifts) NotUsable else Activated(after)

add_lifts = |raw, state, sectors, index|
	match List.get(sectors, index) {
		Err(_) => state
		Ok(sector) => {
			match lowest_adjacent_floor(raw, state, sector, 0, Err(NoAdjacent)) {
				Ok(low) if !(List.any(state.lifts, |lift| lift.sector == sector)) => {
					heights = List.get(state.heights, sector) ?? crash "sector state missing"
					next = { ..state, lifts: List.append(state.lifts, { sector, low, high: heights.floor, speed: 1, phase: Lowering }) }
					add_lifts(raw, next, sectors, index + 1)
				}
				_ => add_lifts(raw, state, sectors, index + 1)
			}
		}
	}

add_floor_movers = |raw, state, sectors, index|
	match List.get(sectors, index) {
		Err(_) => state
		Ok(sector) => {
			match lowest_adjacent_floor(raw, state, sector, 0, Err(NoAdjacent)) {
				Err(NoAdjacent) => add_floor_movers(raw, state, sectors, index + 1)
				Ok(target) => {
					without = List.keep_if(state.floors, |mover| mover.sector != sector)
					next = { ..state, floors: List.append(without, { sector, target, speed: 1 }) }
					add_floor_movers(raw, next, sectors, index + 1)
				}
			}
		}
	}

activate_doors = |raw, state, sectors, index, stays_open, speed|
	match List.get(sectors, index) {
		Err(_) => state
		Ok(sector) => {
			next = if List.any(state.doors, |active| active.sector == sector) state else match activate_door(raw, state, sector, stays_open, speed) {
				Activated(value) => value
				_ => state
			}
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

## Vanilla `EV_VerticalDoor`: using a sector whose door is already moving
## reverses it rather than rebuilding it, so the original closed height is
## kept. A closing door reopens; an opening or waiting door starts closing.
## Tagged activation (`EV_DoDoor`) instead leaves an active door alone.
activate_door = |raw, state, sector, stays_open, speed| {
	match List.find_first(state.doors, |active| active.sector == sector) {
		Ok(active) => {
			reversed = match active.phase {
				Closing => { ..active, phase: Opening }
				Opening => { ..active, phase: Closing }
				Waiting(_) => { ..active, phase: Closing }
			}
			doors = List.map(state.doors, |door| if door.sector == sector reversed else door)
			Activated({ ..state, doors })
		}
		Err(_) => match lowest_adjacent_ceiling(raw, state, sector, 0, Err(NoAdjacent)) {
			# A sector with no two-sided line has nothing to open toward; vanilla
			# leaves it alone, and validation admits such tags.
			Err(NoAdjacent) => NotUsable
			Ok(lowest) => {
				current = List.get(state.heights, sector) ?? crash "sector state missing"
				# A door whose surroundings are no higher than it cannot open; it
				# finishes in place rather than pulling its own ceiling down.
				open = I64.max(current.ceiling, lowest - 4)
				door = { sector, closed: current.ceiling, open, speed, phase: Opening, stays_open }
				Activated({ ..state, doors: List.append(state.doors, door) })
			}
		}
	}
}

lowest_adjacent_ceiling = |raw, state, sector, line_index, found|
	match List.get(raw.linedefs, line_index) {
		Err(_) => found
		Ok(line) => {
			next = adjacent_sector(raw, line, sector)
			found2 = match next {
				Err(_) => found
				Ok(other) => {
					height = (List.get(state.heights, other) ?? crash "sector state missing").ceiling
					match found {
						Err(NoAdjacent) => Ok(height)
						Ok(value) => Ok(I64.min(value, height))
					}
				}
			}
			lowest_adjacent_ceiling(raw, state, sector, line_index + 1, found2)
		}
	}

lowest_adjacent_floor = |raw, state, sector, line_index, found|
	match List.get(raw.linedefs, line_index) {
		Err(_) => found
		Ok(line) => {
			next = adjacent_sector(raw, line, sector)
			found2 = match next {
				Err(_) => found
				Ok(other) => {
					height = (List.get(state.heights, other) ?? crash "sector state missing").floor
					match found {
						Err(NoAdjacent) => Ok(height)
						Ok(value) => Ok(I64.min(value, height))
					}
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
					phase = if ceiling >= door.open {
						if door.stays_open Waiting(0) else Waiting(150)
					} else Opening
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

tick_lifts = |state, remaining, next_lifts, index|
	match List.get(remaining, index) {
		Err(_) => { ..state, lifts: next_lifts }
		Ok(lift) => {
			heights = List.get(state.heights, lift.sector) ?? crash "sector state missing"
			advanced = match lift.phase {
				Lowering => {
					floor = I64.max(lift.low, heights.floor - lift.speed)
					phase = if floor <= lift.low LiftWaiting(105) else Lowering
					{ heights: { ..heights, floor }, lift: { ..lift, phase }, finished: Bool.False }
				}
				LiftWaiting(tics) => { heights, lift: { ..lift, phase: if tics <= 1 Raising else LiftWaiting(tics - 1) }, finished: Bool.False }
				Raising => {
					floor = I64.min(lift.high, heights.floor + lift.speed)
					{ heights: { ..heights, floor }, lift, finished: floor >= lift.high }
				}
			}
			replaced = List.replace(state.heights, lift.sector, advanced.heights) ?? crash "sector state missing"
			state2 = { ..state, heights: replaced.list }
			lifts2 = if advanced.finished next_lifts else List.append(next_lifts, advanced.lift)
			tick_lifts(state2, remaining, lifts2, index + 1)
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
	var $equivalent = Bool.True
	var $sum = 0.U64
	var $maximum = 0.U64
	for indexed in List.map_with_index(map.raw().sectors, |_sector, index| index) {
		indexed_segments = DoomLevel.collision_segments(map, state, indexed)
		full_segments = collision_segments_from(map, map.raw(), state, indexed, 0)
		$equivalent = $equivalent and indexed_segments == full_segments
		count = DoomLevel.collision_candidate_count(state, indexed)
		$sum = $sum + count
		$maximum = U64.max($maximum, count)
	}
	# Every two-sided line is incident to at most two sectors; the pinned E1M1
	# topology has no sector with more than 64 candidate lines. This turns each
	# actor query from 1175 line checks into at most 64 exact portal evaluations.
	$equivalent and $sum <= List.len(map.raw().linedefs) * 2 and $maximum <= 64
}

expect {
	# Every real two-sided E1M1 boundary must report the geometric opening it
	# actually tests. Checking both directions catches clearance accidentally
	# measured from only the destination floor.
	map = DoomMap.e1m1
	raw = map.raw()
	state = DoomLevel.initial(map)
	var $valid = Bool.True
	for entry in List.map_with_index(raw.linedefs, |line, index| { line, index }) {
		match (entry.line.right_sidedef, entry.line.left_sidedef) {
			(Ok(right_index), Ok(left_index)) => {
				right_sector = (List.get(raw.sidedefs, right_index) ?? crash "validated right side missing").sector
				left_sector = (List.get(raw.sidedefs, left_index) ?? crash "validated left side missing").sector
				for from_sector in [right_sector, left_sector] {
					portal = DoomLevel.portal(map, state, entry.index, from_sector) ?? crash "validated portal missing"
					from = DoomLevel.heights_for(state, portal.from_sector) ?? crash "from sector missing"
					to = DoomLevel.heights_for(state, portal.to_sector) ?? crash "to sector missing"
					expected_bottom = I64.max(from.floor, to.floor)
					expected_top = I64.min(from.ceiling, to.ceiling)
					expected_step = to.floor - from.floor
					expected_traversable = !(DoomMap.line_flags(entry.line.flags).blocks_players) and expected_step <= 24 and expected_top - expected_bottom >= 56
					if portal.bottom != expected_bottom or portal.top != expected_top or portal.step != expected_step or portal.traversable != expected_traversable {
						$valid = Bool.False
					}
				}
			}
			_ => {}
		}
	}
	$valid
}

expect {
	map = DoomMap.e1m1
	initial = DoomLevel.initial(map)
	activated = DoomLevel.use_line(map, initial, 55, { blue: Bool.False, yellow: Bool.False, red: Bool.False })
	var $opened = match activated {
		Activated(value) => value
		_ => crash "door missing"
	}
	for _ in List.repeat({}, 80) {
		$opened = DoomLevel.tick($opened)
	}
	List.all(
		List.map_with_index(map.raw().sectors, |_sector, index| index),
		|sector| DoomLevel.collision_segments(map, $opened, sector) == collision_segments_from(map, map.raw(), $opened, sector, 0),
	)
}

expect {
	# A monster can start an ordinary local door and reopen it while closing,
	# but repeated contact never reverses an opening door.
	map = DoomMap.e1m1
	initial = DoomLevel.initial(map)
	opened = DoomLevel.monster_use_line(map, initial, 55)
	match opened {
		Activated(opening) => {
			repeated = DoomLevel.monster_use_line(map, opening, 55)
			closing = DoomLevel.use_line(map, opening, 55, { blue: Bool.False, yellow: Bool.False, red: Bool.False })
			match closing {
				Activated(value) => match DoomLevel.monster_use_line(map, value, 55) {
					Activated(reopened) => repeated == NotUsable and (List.get(reopened.doors, 0) ?? crash "reopened door missing").phase == Opening
					_ => Bool.False
				}
				_ => Bool.False
			}
		}
		_ => Bool.False
	}
}

expect {
	map = DoomMap.e1m1
	initial = DoomLevel.initial(map)
	var $after64 = initial
	for _ in List.repeat({}, 64) {
		$after64 = DoomLevel.tick($after64)
	}
	flash_bright = DoomLevel.light_for(map, initial, 32) ?? -1
	flash_dark = DoomLevel.light_for(map, $after64, 32) ?? -1
	strobe_initial = DoomLevel.light_for(map, initial, 90) ?? -1
	strobe_dark = DoomLevel.light_for(map, DoomLevel.tick(initial), 90) ?? -1
	var $after16 = initial
	for _ in List.repeat({}, 16) {
		$after16 = DoomLevel.tick($after16)
	}
	strobe_bright = DoomLevel.light_for(map, $after16, 90) ?? -1
	flash_dark < flash_bright and $after64.light_rng != 0 and strobe_dark < strobe_initial and strobe_bright == strobe_initial
}

expect {
	map = DoomMap.e1m1
	state = DoomLevel.initial(map)
	locked = DoomLevel.use_line(map, state, 421, { blue: Bool.False, yellow: Bool.False, red: Bool.False })
	unlocked = DoomLevel.use_line(map, state, 421, { blue: Bool.True, yellow: Bool.False, red: Bool.False })
	locked == Locked(Blue) and match unlocked {
		Activated(next) => List.len(next.doors) == 1
		_ => Bool.False
	}
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
	match DoomLevel.cross_line(map, initial, 593) {
		Activated(moving) => {
			lift = List.get(moving.lifts, 0) ?? crash "special-88 lift missing"
			before = DoomLevel.heights_for(moving, lift.sector) ?? crash "lift sector missing"
			after = DoomLevel.heights_for(DoomLevel.tick(moving), lift.sector) ?? crash "lift sector missing"
			finished = advance_tics(moving, 400)
			finish_height = DoomLevel.heights_for(finished, lift.sector) ?? crash "lift sector missing"
			lift.low < lift.high and after.floor == I64.max(lift.low, before.floor - 1) and finish_height.floor == lift.high and List.is_empty(finished.lifts)
		}
		_ => Bool.False
	}
}

expect {
	map = DoomMap.e1m1
	raw = map.raw()
	line = List.get(raw.linedefs, 593) ?? crash "special-88 line missing"
	a = List.get(raw.vertices, line.start_vertex) ?? crash "line vertex missing"
	b = List.get(raw.vertices, line.end_vertex) ?? crash "line vertex missing"
	mid_x = (I64.to_f64(a.x) + I64.to_f64(b.x)) / 2
	mid_y = (I64.to_f64(a.y) + I64.to_f64(b.y)) / 2
	dx = I64.to_f64(b.x - a.x)
	dy = I64.to_f64(b.y - a.y)
	crossed = DoomLevel.crossed_lines(map, { x: mid_x + dy, y: mid_y - dx }, { x: mid_x - dy, y: mid_y + dx })
	List.contains(crossed, 593)
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
			opened_state = advance_tics(opening, 80)
			opened = DoomLevel.portal(map, opened_state, 55, from_sector) ?? crash "door portal missing"
			closed_segments = DoomLevel.collision_segments(map, initial, from_sector)
			opened_segments = DoomLevel.collision_segments(map, opened_state, from_sector)
			closed_global = DoomLevel.global_collision_segments(map, initial)
			opened_global = DoomLevel.global_collision_segments(map, opened_state)
			!(closed.traversable)
				and opened.traversable
					and opened.step <= 24
						and opened.top - opened.bottom >= 56
							and List.any(closed_segments, |segment| segment.linedef == 55)
								and !(List.any(opened_segments, |segment| segment.linedef == 55))
									and List.any(closed_global, |segment| segment.linedef == 55)
										and !(List.any(opened_global, |segment| segment.linedef == 55))
		}
		_ => Bool.False
	}
}

expect {
	# L2: re-using a door keeps its original closed height. Interrupting the
	# close reopens it (vanilla EV_VerticalDoor) and it later rests at the
	# initial ceiling; using a fully open door starts it closing.
	map = DoomMap.e1m1
	no_keys = { blue: Bool.False, yellow: Bool.False, red: Bool.False }
	initial = DoomLevel.initial(map)
	use = |state| match DoomLevel.use_line(map, state, 55, no_keys) {
		Activated(next) => next
		_ => crash "door 55 not usable"
	}
	first = use(initial)
	door = List.get(first.doors, 0) ?? crash "door missing"
	at_rest = DoomLevel.heights_for(initial, door.sector) ?? crash "sector missing"
	interrupted = use(advance_tics(first, 233))
	reopened = List.get(interrupted.doors, 0) ?? crash "reopened door missing"
	settled = advance_tics(interrupted, 1000)
	settled_heights = DoomLevel.heights_for(settled, door.sector) ?? crash "sector missing"
	open_state = advance_tics(first, 100)
	open_heights = DoomLevel.heights_for(open_state, door.sector) ?? crash "sector missing"
	closing = advance_tics(use(open_state), 10)
	closing_heights = DoomLevel.heights_for(closing, door.sector) ?? crash "sector missing"
	closed_again = DoomLevel.heights_for(advance_tics(closing, 1000), door.sector) ?? crash "sector missing"
	reopened.closed == at_rest.ceiling
		and reopened.phase == Opening
			and List.is_empty(settled.doors)
				and settled_heights.ceiling == at_rest.ceiling
					and closing_heights.ceiling < open_heights.ceiling
						and closed_again.ceiling == at_rest.ceiling
}

expect {
	# L1: special 62 is the switch form of the lower-wait-raise lift (vanilla
	# "SR Lift"), not a permanent door. On E1M1 its tags name the lift sectors
	# driven by the walk-over special 88, so using the switch lowers the lift
	# floor, never touches a ceiling, and the floor rises back afterwards.
	map = DoomMap.e1m1
	no_keys = { blue: Bool.False, yellow: Bool.False, red: Bool.False }
	initial = DoomLevel.initial(map)
	match DoomLevel.use_line(map, initial, 1064, no_keys) {
		Activated(started) => {
			lift = List.get(started.lifts, 0) ?? crash "lift missing"
			rest = DoomLevel.heights_for(initial, lift.sector) ?? crash "sector missing"
			lowered = DoomLevel.heights_for(advance_tics(started, 40), lift.sector) ?? crash "sector missing"
			settled = advance_tics(started, 400)
			raised = DoomLevel.heights_for(settled, lift.sector) ?? crash "sector missing"
			List.is_empty(started.doors)
				and lowered.floor < rest.floor
					and lowered.ceiling == rest.ceiling
						and raised == rest
							and List.is_empty(settled.lifts)
		}
		_ => Bool.False
	}
}

expect {
	# M2: a tagged special whose tag reaches a sector with no two-sided line
	# has nothing to move; vanilla leaves that sector alone. Validation admits
	# such maps, so activation must answer NotUsable rather than crash.
	sector = { floor_height: 0, ceiling_height: 128, floor_flat: "FLOOR", ceiling_flat: "CEIL", light_level: 160, special: 0, tag: 0 }
	side = { x_offset: 0, y_offset: 0, upper_texture: Err(Null), lower_texture: Err(Null), middle_texture: Ok("WALL"), sector: 0 }
	polygon = { subsector: 0, sector: 0, points: [{ x: 0, y: 0 }, { x: 64, y: 0 }, { x: 0, y: 64 }] }
	raw = {
		format: "doom",
		map: "ORPHAN",
		vertices: [{ x: 0, y: 0 }, { x: 64, y: 0 }],
		linedefs: [
			{ start_vertex: 0, end_vertex: 1, flags: 1, special: 62, tag: 1, right_sidedef: Ok(0), left_sidedef: Err(Null) },
			{ start_vertex: 1, end_vertex: 0, flags: 1, special: 2, tag: 1, right_sidedef: Ok(0), left_sidedef: Err(Null) },
			{ start_vertex: 0, end_vertex: 1, flags: 1, special: 23, tag: 1, right_sidedef: Ok(0), left_sidedef: Err(Null) },
			{ start_vertex: 1, end_vertex: 0, flags: 1, special: 88, tag: 1, right_sidedef: Ok(0), left_sidedef: Err(Null) },
		],
		sidedefs: [side],
		sectors: [sector, { ..sector, tag: 1 }],
		things: [],
		segs: [{ start_vertex: 0, end_vertex: 1, angle: 0, linedef: 0, direction: 0, offset: 0 }],
		subsectors: [{ seg_count: 1, first_seg: 0 }],
		nodes: [],
		subsector_polygon_bounds: { min_x: 0, min_y: 0, max_x: 64, max_y: 64 },
		subsector_polygons: [polygon],
	}
	map = DoomMap.validate(raw) ?? crash "orphan fixture should validate"
	state = DoomLevel.initial(map)
	no_keys = { blue: Bool.False, yellow: Bool.False, red: Bool.False }
	unusable = |result| match result {
		NotUsable => Bool.True
		_ => Bool.False
	}
	unusable(DoomLevel.use_line(map, state, 0, no_keys))
		and unusable(DoomLevel.cross_line(map, state, 1))
			and unusable(DoomLevel.use_line(map, state, 2, no_keys))
				and unusable(DoomLevel.cross_line(map, state, 3))
}
