## Pure Doom-style sector sound flood. A sound may cross one `blocks_sound`
## linedef, but a second such crossing stops that branch. The queue is bounded
## by two states per sector (before/after the one permitted crossing).
import DoomLevel
import DoomMap

DoomSound := [].{
	heard_sectors : DoomMap.Map, { x : F32, y : F32 } -> List(U64)
	heard_sectors = |map, source| {
		start = DoomLevel.sector_at(map, { x: F32.to_f64(source.x), y: F32.to_f64(source.y) }) ?? return []
		flood(map.raw(), [{ sector: start, blocks: 0.U8 }], [], [])
	}

	can_hear : DoomMap.Map, { x : F32, y : F32 }, { x : F32, y : F32 } -> Bool
	can_hear = |map, source, listener| {
		sector = DoomLevel.sector_at(map, { x: F32.to_f64(listener.x), y: F32.to_f64(listener.y) }) ?? return Bool.False
		List.contains(heard_sectors(map, source), sector)
	}
}

flood = |raw, queue, visited, heard|
	match List.first(queue) {
		Err(_) => heard
		Ok(current) => {
			rest = List.drop_first(queue, 1)
			key = current.sector * 2 + U8.to_u64(current.blocks)
			if List.contains(visited, key) {
				flood(raw, rest, visited, heard)
			} else {
				visited1 = List.append(visited, key)
				heard1 = if List.contains(heard, current.sector) heard else List.append(heard, current.sector)
				neighbors = sector_neighbors(raw, current)
				# Every enqueued state is one of exactly sector_count * 2 keys.
				queue1 = List.concat(rest, neighbors)
				flood(raw, queue1, visited1, heard1)
			}
		}
	}

sector_neighbors = |raw, current| {
	var $result = []
	for line in raw.linedefs {
		match line_sectors(raw, line) {
			Err(_) => {}
			Ok(pair) => {
				neighbor = if pair.right == current.sector Ok(pair.left) else if pair.left == current.sector Ok(pair.right) else Err(NotAdjacent)
				match neighbor {
					Err(_) => {}
					Ok(sector) => {
						crosses_block = DoomMap.line_flags(line.flags).blocks_sound
						if !(crosses_block and current.blocks == 1) {
							$result = List.append($result, { sector, blocks: if crosses_block 1 else current.blocks })
						}
					}
				}
			}
		}
	}
	$result
}

line_sectors = |raw, line| {
	right_index = line.right_sidedef ?? return Err(NotTwoSided)
	left_index = line.left_sidedef ?? return Err(NotTwoSided)
	right = List.get(raw.sidedefs, right_index) ?? return Err(NotTwoSided)
	left = List.get(raw.sidedefs, left_index) ?? return Err(NotTwoSided)
	Ok({ right: right.sector, left: left.sector })
}

expect {
	start = DoomMap.e1m1.player_start() ?? crash "E1M1 player start missing"
	pos = { x: I64.to_f32(start.position.x), y: I64.to_f32(start.position.y) }
	heard = DoomSound.heard_sectors(DoomMap.e1m1, pos)
	List.len(heard) > 1 and DoomSound.can_hear(DoomMap.e1m1, pos, pos)
}

expect {
	# Synthetic three-sector chain with both portals sound-blocking: sector 0
	# reaches sector 1 across one block, but cannot cross the second into 2.
	side = |sector| { x_offset: 0, y_offset: 0, upper_texture: Err(Null), lower_texture: Err(Null), middle_texture: Err(Null), sector }
	line = |right, left| { start_vertex: 0, end_vertex: 1, flags: 0x0040, special: 0, tag: 0, right_sidedef: Ok(right), left_sidedef: Ok(left) }
	raw = {
		format: "doom",
		map: "SOUND",
		vertices: [{ x: 0, y: 0 }, { x: 1, y: 0 }],
		linedefs: [line(0, 1), line(2, 3)],
		sidedefs: [side(0), side(1), side(1), side(2)],
		sectors: [],
		things: [],
		segs: [],
		subsectors: [],
		nodes: [],
		subsector_polygon_bounds: { min_x: 0, min_y: 0, max_x: 0, max_y: 0 },
		subsector_polygons: [],
	}
	heard = flood(raw, [{ sector: 0, blocks: 0.U8 }], [], [])
	List.contains(heard, 0) and List.contains(heard, 1) and !(List.contains(heard, 2))
}
