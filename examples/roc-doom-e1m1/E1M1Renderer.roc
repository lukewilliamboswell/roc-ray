## Pure E1M1 world-mesh adapter. RocDoomMap owns validated map derivation,
## RocDoomAssets owns compile-time atlas metadata, and this module translates the
## two into structural records accepted by `Draw.textured_triangles_3d!`.
## Geometry is split below the U32 index ceiling so host work stays explicit.
import RocDoomAssets
import RocDoomLevel
import RocDoomMap

E1M1Renderer := [].{
	Vec2 : { x : F32, y : F32 }
	Vec3 : { x : F32, y : F32, z : F32 }
	Tint : { r : U8, g : U8, b : U8, a : U8 }
	Vertex : { position : Vec3, uv : Vec2, tint : Tint }
	Geometry : { vertices : List(Vertex), indices : List(U32) }

	## Build retained world geometry for the one world-atlas texture. Each list
	## item can be submitted as one `textured_triangles_3d!` call with the loaded
	## `world_atlas.png` texture.
	build : List(RocDoomMap.SurfacePolygon), List(RocDoomMap.WallSpan) -> Try(List(Geometry), [MissingFlat(Str), MissingTexture(Str), GeometryPrimitiveTooLarge(U64)])
	build = |surfaces, walls| {
		var $packed = { finished: [], current: empty }
		for surface in surfaces {
			primitive = match surface_geometry(surface) {
				Ok(value) => value
				Err(MissingFlat(name)) => return Err(MissingFlat(name))
			}
			$packed = match pack($packed, primitive) {
				Ok(value) => value
				Err(GeometryPrimitiveTooLarge(count)) => return Err(GeometryPrimitiveTooLarge(count))
			}
		}
		for wall in walls {
			primitive = match wall_geometry(wall) {
				Ok(value) => value
				Err(MissingTexture(name)) => return Err(MissingTexture(name))
			}
			$packed = match pack($packed, primitive) {
				Ok(value) => value
				Err(GeometryPrimitiveTooLarge(count)) => return Err(GeometryPrimitiveTooLarge(count))
			}
		}
		Ok(finish($packed))
	}

	## Build once at startup. Every potentially moving sector plane and every
	## wall touching one is excluded so a later overlay cannot z-fight stale
	## retained geometry.
	build_static : RocDoomMap.Map -> Try(List(Geometry), [MissingFlat(Str), MissingTexture(Str), GeometryPrimitiveTooLarge(U64)])
	build_static = |map| {
		dynamic = RocDoomLevel.dynamic_sectors(map)
		raw = map.raw()
		surfaces = List.keep_if(map.surface_polygons(), |surface| !(List.contains(dynamic, surface.sector)))
		walls = List.keep_if(map.wall_spans(), |wall| !(line_touches_any(raw, wall.linedef, dynamic)) and !(masked_middle(wall)))
		build(surfaces, walls)
	}

	## Build the bounded moving-sector overlay from the current pure level state.
	## E1M1 has a stable small dynamic-sector set; no geometry is retained here.
	build_dynamic = |map, state| {
		dynamic = RocDoomLevel.dynamic_sectors(map)
		raw = map.raw()
		surfaces = List.map(
			List.keep_if(map.surface_polygons(), |surface| List.contains(dynamic, surface.sector)),
			|surface| {
				heights = RocDoomLevel.heights_for(state, surface.sector) ?? crash "level state sector mismatch"
				light_level = RocDoomLevel.light_for(map, state, surface.sector) ?? crash "level light sector mismatch"
				{ ..surface, height: if surface.orientation == Floor heights.floor else heights.ceiling, light_level }
			},
		)
		all_walls = map.wall_spans_at(state.heights)
		walls = List.map(List.keep_if(all_walls, |wall| line_touches_any(raw, wall.linedef, dynamic) and !(masked_middle(wall))), |wall| { ..wall, light_level: RocDoomLevel.light_for(map, state, wall.sector) ?? wall.light_level })
		build(surfaces, walls)
	}

	build_masked_static = |map| {
		dynamic = RocDoomLevel.dynamic_sectors(map)
		raw = map.raw()
		walls = List.keep_if(map.wall_spans(), |wall| !(line_touches_any(raw, wall.linedef, dynamic)) and masked_middle(wall))
		build([], walls)
	}

	build_masked_dynamic = |map, state| {
		dynamic = RocDoomLevel.dynamic_sectors(map)
		raw = map.raw()
		walls = List.map(List.keep_if(map.wall_spans_at(state.heights), |wall| line_touches_any(raw, wall.linedef, dynamic) and masked_middle(wall)), |wall| { ..wall, light_level: RocDoomLevel.light_for(map, state, wall.sector) ?? wall.light_level })
		build([], walls)
	}

	sector_surfaces = |map, state, sector| {
		heights = RocDoomLevel.heights_for(state, sector) ?? crash "level state sector mismatch"
		surfaces = List.map(
			List.keep_if(map.surface_polygons(), |surface| surface.sector == sector),
			|surface| { ..surface, height: if surface.orientation == Floor heights.floor else heights.ceiling, light_level: RocDoomLevel.light_for(map, state, sector) ?? surface.light_level },
		)
		build(surfaces, [])
	}

	surface_geometry : RocDoomMap.SurfacePolygon -> Try(Geometry, [MissingFlat(Str)])
	surface_geometry = |surface| {
		if surface.orientation == Ceiling and surface.flat == "F_SKY1" return Ok(empty)
		rect = RocDoomAssets.flat(surface.flat)?
		tint = light_tint(surface.light_level)
		# Atlas subrects cannot use GPU texture wrapping: interpolating wrapped UVs
		# across a 64-texel boundary samples unrelated atlas entries. Clip each BSP
		# polygon to the flat's tile grid so every triangle interpolates within one
		# copy of the flat.
		Ok(tiled_surface(surface, rect, tint))
	}

	## Camera-centred sky enclosure. Sky ceilings are omitted from world planes,
	## so this far background appears only through F_SKY1 openings.
	sky_geometry : F32, F32 -> Try(Geometry, [MissingTexture(Str)])
	sky_geometry = |camera_x, camera_y| {
		rect = RocDoomAssets.texture("SKY1")?
		tint = { r: 255, g: 255, b: 255, a: 255 }
		r = 200.F32
		# At this radius the enclosure must extend beyond the full perspective
		# frustum. A short wall leaves clear-colour bands above and below SKY1.
		low = -200.F32
		high = 200.F32
		points = [{ x: camera_x - r, z: camera_y - r }, { x: camera_x + r, z: camera_y - r }, { x: camera_x + r, z: camera_y + r }, { x: camera_x - r, z: camera_y + r }]
		var $vertices = []
		var $indices = []
		for edge in List.map_with_index(points, |point, index| { point, index }) {
			next = List.get(points, (edge.index + 1) % 4) ?? crash "sky corner missing"
			offset = U64.to_u32_wrap(List.len($vertices))
			u0 = atlas_u_local(0, rect)
			u1 = atlas_u_local(U64.to_f64(rect.width), rect)
			v0 = atlas_v_local(0, rect)
			v1 = atlas_v_local(U64.to_f64(rect.height), rect)
			$vertices = List.concat(
				$vertices,
				[
					{ position: { x: edge.point.x, y: low, z: edge.point.z }, uv: { x: u0, y: v1 }, tint },
					{ position: { x: next.x, y: low, z: next.z }, uv: { x: u1, y: v1 }, tint },
					{ position: { x: next.x, y: high, z: next.z }, uv: { x: u1, y: v0 }, tint },
					{ position: { x: edge.point.x, y: high, z: edge.point.z }, uv: { x: u0, y: v0 }, tint },
				],
			)
			# The enclosure's centre lies to the left of its counter-clockwise
			# perimeter edges, so its faces use the opposite winding from walls.
			$indices = List.concat($indices, [offset, offset + 1, offset + 2, offset, offset + 2, offset + 3])
		}
		Ok({ vertices: $vertices, indices: $indices })
	}

	wall_geometry : RocDoomMap.WallSpan -> Try(Geometry, [MissingTexture(Str)])
	wall_geometry = |wall| {
		rect = RocDoomAssets.texture(wall.texture)?
		tint = light_tint(wall.light_level)
		dx = I64.to_f64(wall.end.x - wall.start.x)
		dy = I64.to_f64(wall.end.y - wall.start.y)
		length = sqrt(dx * dx + dy * dy)
		height = I64.to_f64(wall.top - wall.bottom)
		horizontal = tile_runs(length, I64.to_f64(wall.x_offset), U64.to_f64(rect.width), 0, [])
		bottom_row = wall_texture_row(wall, wall.bottom, rect.height)
		vertical = descending_tile_runs(height, bottom_row, U64.to_f64(rect.height), 0, [])
		var $vertices = []
		var $indices = []
		for x_run in horizontal {
			for y_run in vertical {
				a = wall_point(wall, dx, dy, length, x_run.from, y_run.from)
				b = wall_point(wall, dx, dy, length, x_run.to, y_run.from)
				c = wall_point(wall, dx, dy, length, x_run.to, y_run.to)
				d = wall_point(wall, dx, dy, length, x_run.from, y_run.to)
				u0 = atlas_u_local(x_run.uv_from, rect)
				u1 = atlas_u_local(x_run.uv_to, rect)
				v0 = atlas_v_local(y_run.uv_from, rect)
				v1 = atlas_v_local(y_run.uv_to, rect)
				offset = U64.to_u32_wrap(List.len($vertices))
				$vertices = List.concat(
					$vertices,
					[
						{ position: a, uv: { x: u0, y: v0 }, tint },
						{ position: b, uv: { x: u1, y: v0 }, tint },
						{ position: c, uv: { x: u1, y: v1 }, tint },
						{ position: d, uv: { x: u0, y: v1 }, tint },
					],
				)
				# Each span is directed so its owning sidedef lies to its right.
				# Reverse the quad fan so its normal points into that owning sector.
				$indices = List.concat($indices, [offset, offset + 2, offset + 1, offset, offset + 3, offset + 2])
			}
		}
		Ok({ vertices: $vertices, indices: $indices })
	}

	## Doom wall texture rows increase downward. This returns the unwrapped row
	## at a world height; atlas splitting applies wrapping afterwards.
	wall_texture_row : RocDoomMap.WallSpan, I64, U64 -> F64
	wall_texture_row = |wall, world_height, texture_height| {
		anchor = match wall.vertical_peg {
			TopAt(height) => I64.to_f64(height)
			BottomAt(height) => I64.to_f64(height) + U64.to_f64(texture_height)
		}
		anchor + I64.to_f64(wall.y_offset) - I64.to_f64(world_height)
	}

	light_tint : I64 -> Tint
	light_tint = |level| {
		value = U64.to_u8_wrap(I64.to_u64_wrap(I64.max(0, I64.min(255, level))))
		{ r: value, g: value, b: value, a: 255 }
	}

	doom_scale = 1 / 64
	max_batch_vertices = 60000.U64
}

Packed : { finished : List(E1M1Renderer.Geometry), current : E1M1Renderer.Geometry }

TileRun : { from : F64, to : F64, uv_from : F64, uv_to : F64 }

empty : E1M1Renderer.Geometry
empty = { vertices: [], indices: [] }

line_touches_any = |raw, linedef, sectors| {
	line = List.get(raw.linedefs, linedef) ?? crash "validated linedef missing"
	right = line.right_sidedef ?? crash "validated right sidedef missing"
	right_sector = (List.get(raw.sidedefs, right) ?? crash "validated sidedef missing").sector
	left_touches = match line.left_sidedef {
		Err(Null) => Bool.False
		Ok(left) => List.contains(sectors, (List.get(raw.sidedefs, left) ?? crash "validated sidedef missing").sector)
	}
	List.contains(sectors, right_sector) or left_touches
}

masked_middle = |wall| wall.kind == Middle and wall.flags.two_sided

pack : Packed, E1M1Renderer.Geometry -> Try(Packed, [GeometryPrimitiveTooLarge(U64)])
pack = |packed, primitive| {
	count = List.len(primitive.vertices)
	if count > E1M1Renderer.max_batch_vertices {
		Err(GeometryPrimitiveTooLarge(count))
	} else {
		current_count = List.len(packed.current.vertices)
		if current_count > 0 and current_count + count > E1M1Renderer.max_batch_vertices {
			Ok({ finished: List.append(packed.finished, packed.current), current: primitive })
		} else {
			offset = U64.to_u32_wrap(current_count)
			Ok({
				..packed,
				current: {
					vertices: append_all(packed.current.vertices, primitive.vertices),
					indices: append_shifted(packed.current.indices, primitive.indices, offset),
				},
			})
		}
	}
}

append_all = |destination, source| {
	var $result = destination
	for item in source {
		$result = List.append($result, item)
	}
	$result
}

append_shifted = |destination, source, offset| {
	var $result = destination
	for index in source {
		$result = List.append($result, index + offset)
	}
	$result
}

finish = |packed| if List.len(packed.current.vertices) == 0 packed.finished else List.append(packed.finished, packed.current)

doom_position = |x, height, y| {
	x: F64.to_f32_wrap(x) * E1M1Renderer.doom_scale,
	y: I64.to_f32(height) * E1M1Renderer.doom_scale,
	z: F64.to_f32_wrap(y) * E1M1Renderer.doom_scale,
}

wall_point = |wall, dx, dy, length, along, above_bottom| {
	amount = if length <= 0 0 else along / length
	{
		x: F64.to_f32_wrap(I64.to_f64(wall.start.x) + dx * amount) * E1M1Renderer.doom_scale,
		y: F64.to_f32_wrap(I64.to_f64(wall.bottom) + above_bottom) * E1M1Renderer.doom_scale,
		z: F64.to_f32_wrap(I64.to_f64(wall.start.y) + dy * amount) * E1M1Renderer.doom_scale,
	}
}

tile_runs : F64, F64, F64, F64, List(TileRun) -> List(TileRun)
tile_runs = |total, offset, period, position, runs| {
	if position >= total {
		runs
	} else {
		local = wrap(offset + position, period)
		amount = F64.min(total - position, period - local)
		run = { from: position, to: position + amount, uv_from: local, uv_to: local + amount }
		tile_runs(total, offset, period, position + amount, List.append(runs, run))
	}
}

# Split upward-moving wall geometry at descending texture-row seams. At a
# seam, row `period` and row zero denote the same atlas edge but belong to
# adjacent quads, avoiding filtering across unrelated atlas entries.
descending_tile_runs : F64, F64, F64, F64, List(TileRun) -> List(TileRun)
descending_tile_runs = |total, bottom_row, period, position, runs| {
	if position >= total {
		runs
	} else {
		wrapped = wrap(bottom_row - position, period)
		uv_from = if wrapped <= 0.000001 period else wrapped
		amount = F64.min(total - position, uv_from)
		run = { from: position, to: position + amount, uv_from, uv_to: uv_from - amount }
		descending_tile_runs(total, bottom_row, period, position + amount, List.append(runs, run))
	}
}

reversed_fan_indices = |count| {
	if count < 3 {
		[]
	} else {
		fan_from(1, count, [])
	}
}

fan_from = |index, count, result|
	if index + 1 >= count result else fan_from(index + 1, count, List.concat(result, [0, U64.to_u32_wrap(index + 1), U64.to_u32_wrap(index)]))

reverse = |remaining, result|
	match remaining {
		[] => result
		[first, .. as rest] => reverse(rest, List.prepend(result, first))
	}

geometry_counts = |batches| {
	var $vertices = 0.U64
	var $indices = 0.U64
	for batch in batches {
		$vertices = $vertices + List.len(batch.vertices)
		$indices = $indices + List.len(batch.indices)
	}
	{ vertices: $vertices, indices: $indices }
}

max_geometry_y = |batches| {
	var $maximum = -1000000.F32
	for batch in batches {
		for vertex in batch.vertices {
			$maximum = F32.max($maximum, vertex.position.y)
		}
	}
	$maximum
}

min_geometry_y = |batches| {
	var $minimum = 1000000.F32
	for batch in batches {
		for vertex in batch.vertices {
			$minimum = F32.min($minimum, vertex.position.y)
		}
	}
	$minimum
}

line_wall_extent = |walls, linedef| {
	var $extent = 0.I64
	for wall in walls {
		if wall.linedef == linedef {
			$extent = $extent + wall.top - wall.bottom
		}
	}
	$extent
}

wall_faces_point = |wall, point| {
	geometry = E1M1Renderer.wall_geometry(wall) ?? return Bool.False
	a = List.get(geometry.vertices, U32.to_u64(List.get(geometry.indices, 0) ?? return Bool.False)) ?? return Bool.False
	b = List.get(geometry.vertices, U32.to_u64(List.get(geometry.indices, 1) ?? return Bool.False)) ?? return Bool.False
	c = List.get(geometry.vertices, U32.to_u64(List.get(geometry.indices, 2) ?? return Bool.False)) ?? return Bool.False
	ab = { x: b.position.x - a.position.x, y: b.position.y - a.position.y, z: b.position.z - a.position.z }
	ac = { x: c.position.x - a.position.x, y: c.position.y - a.position.y, z: c.position.z - a.position.z }
	normal_x = ab.y * ac.z - ab.z * ac.y
	normal_z = ab.x * ac.y - ab.y * ac.x
	to_x = F64.to_f32_wrap(point.x) * E1M1Renderer.doom_scale - a.position.x
	to_z = F64.to_f32_wrap(point.y) * E1M1Renderer.doom_scale - a.position.z
	normal_x * to_x + normal_z * to_z > 0
}

wall_owning_point = |wall| {
	dx = I64.to_f64(wall.end.x - wall.start.x)
	dy = I64.to_f64(wall.end.y - wall.start.y)
	length = sqrt(dx * dx + dy * dy)
	{ x: I64.to_f64(wall.start.x + wall.end.x) * 0.5 + dy / length, y: I64.to_f64(wall.start.y + wall.end.y) * 0.5 - dx / length }
}

advance_level = |state, count| if count == 0 state else advance_level(RocDoomLevel.tick(state), count - 1)

ClipAxis := [ClipX, ClipY]

tiled_surface = |surface, rect, tint| {
	first = List.get(surface.vertices, 0) ?? return empty
	var $min_x = first.x
	var $max_x = first.x
	var $min_y = first.y
	var $max_y = first.y
	for point in surface.vertices {
		$min_x = F64.min($min_x, point.x)
		$max_x = F64.max($max_x, point.x)
		$min_y = F64.min($min_y, point.y)
		$max_y = F64.max($max_y, point.y)
	}
	tile_w = U64.to_f64(rect.width)
	tile_h = U64.to_f64(rect.height)
	start_x = $min_x - wrap($min_x, tile_w)
	start_y = $min_y - wrap($min_y, tile_h)
	var $geometry = empty
	var $x = start_x
	while $x <= $max_x {
		var $y = start_y
		while $y <= $max_y {
			points = clip_tile(surface.vertices, $x, $y, $x + tile_w, $y + tile_h)
			if List.len(points) >= 3 and F64.abs(polygon_area(points)) > 0.000001 {
				vertices = List.map(
					points,
					|point| {
						position: doom_position(point.x, surface.height, point.y),
						uv: { x: atlas_u_local(point.x - $x, rect), y: atlas_v_local($y + tile_h - point.y, rect) },
						tint,
					},
				)
				primitive = { vertices, indices: reversed_fan_indices(List.len(vertices)) }
				$geometry = append_geometry($geometry, primitive)
			}
			$y = $y + tile_h
		}
		$x = $x + tile_w
	}
	$geometry
}

clip_tile = |points, min_x, min_y, max_x, max_y|
	clip_edge(clip_edge(clip_edge(clip_edge(points, ClipX, min_x, Bool.True), ClipX, max_x, Bool.False), ClipY, min_y, Bool.True), ClipY, max_y, Bool.False)

clip_edge = |points, axis, boundary, keep_greater| {
	previous = List.last(points) ?? return []
	var $result = []
	var $before = previous
	for after in points {
		before_inside = point_inside($before, axis, boundary, keep_greater)
		after_inside = point_inside(after, axis, boundary, keep_greater)
		if before_inside != after_inside {
			$result = append_distinct_point($result, edge_intersection($before, after, axis, boundary))
		}
		if after_inside {
			$result = append_distinct_point($result, after)
		}
		$before = after
	}
	match ($result, List.get($result, 0), List.last($result)) {
		(values, Ok(first), Ok(last)) => if F64.abs(first.x - last.x) < 0.0000001 and F64.abs(first.y - last.y) < 0.0000001 List.drop_last(values, 1) else values
		(values, _, _) => values
	}
}

append_distinct_point = |points, point|
	match List.last(points) {
		Ok(previous) => if F64.abs(previous.x - point.x) < 0.0000001 and F64.abs(previous.y - point.y) < 0.0000001 points else List.append(points, point)
		Err(_) => List.append(points, point)
	}

point_inside = |point, axis, boundary, keep_greater| {
	value = match axis {
		ClipX => point.x
		ClipY => point.y
	}
	if keep_greater value >= boundary else value <= boundary
}

edge_intersection = |start, end, axis, boundary| {
	delta = match axis {
		ClipX => end.x - start.x
		ClipY => end.y - start.y
	}
	t = if F64.abs(delta) < 0.0000001 0 else (boundary - match axis {
		ClipX => start.x
		ClipY => start.y
	}) / delta
	{ x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t }
}

polygon_area = |points| {
	previous = List.last(points) ?? return 0
	var $area = 0
	var $before = previous
	for after in points {
		$area = $area + $before.x * after.y - after.x * $before.y
		$before = after
	}
	$area * 0.5
}

convex_contains = |points, point| {
	previous = List.last(points) ?? return Bool.False
	var $inside = Bool.True
	var $before = previous
	for after in points {
		cross = (after.x - $before.x) * (point.y - $before.y) - (after.y - $before.y) * (point.x - $before.x)
		if cross < -0.000001 {
			$inside = Bool.False
		}
		$before = after
	}
	$inside
}

floor_geometry_faces_up = |geometry| floor_triangles_face_up(geometry.vertices, geometry.indices, 0)

sky_geometry_faces_in = |geometry, center| sky_triangles_face_in(geometry.vertices, geometry.indices, center, 0)

sky_triangles_face_in = |vertices, indices, center, index|
	if index >= List.len(indices) {
		Bool.True
	} else {
		a = List.get(vertices, U32.to_u64(List.get(indices, index) ?? return Bool.False)) ?? return Bool.False
		b = List.get(vertices, U32.to_u64(List.get(indices, index + 1) ?? return Bool.False)) ?? return Bool.False
		c = List.get(vertices, U32.to_u64(List.get(indices, index + 2) ?? return Bool.False)) ?? return Bool.False
		ux = b.position.x - a.position.x
		uy = b.position.y - a.position.y
		uz = b.position.z - a.position.z
		vx = c.position.x - a.position.x
		vy = c.position.y - a.position.y
		vz = c.position.z - a.position.z
		normal_x = uy * vz - uz * vy
		normal_z = ux * vy - uy * vx
		triangle_x = (a.position.x + b.position.x + c.position.x) / 3
		triangle_z = (a.position.z + b.position.z + c.position.z) / 3
		normal_x * (center.x - triangle_x) + normal_z * (center.z - triangle_z) > 0
			and sky_triangles_face_in(vertices, indices, center, index + 3)
	}

floor_triangles_face_up = |vertices, indices, index| {
	if index >= List.len(indices) Bool.True else {
		a = List.get(vertices, U32.to_u64(List.get(indices, index) ?? return Bool.False)) ?? return Bool.False
		b = List.get(vertices, U32.to_u64(List.get(indices, index + 1) ?? return Bool.False)) ?? return Bool.False
		c = List.get(vertices, U32.to_u64(List.get(indices, index + 2) ?? return Bool.False)) ?? return Bool.False
		normal_y = (b.position.z - a.position.z) * (c.position.x - a.position.x) - (b.position.x - a.position.x) * (c.position.z - a.position.z)
		normal_y > 0 and floor_triangles_face_up(vertices, indices, index + 3)
	}
}

append_geometry = |destination, source| {
	offset = List.len(destination.vertices)
	{
		vertices: append_all(destination.vertices, source.vertices),
		indices: append_shifted(destination.indices, source.indices, U64.to_u32_wrap(offset)),
	}
}

## Half-texel inset keeps filtered samples inside the atlas padding. Coordinate
## wrapping is computed in Doom texels before normalization into atlas space.
atlas_u = |doom_texel, rect| {
	local = wrap(doom_texel, U64.to_f64(rect.width))
	atlas_u_local(local, rect)
}

atlas_v = |doom_texel, rect| {
	local = wrap(doom_texel, U64.to_f64(rect.height))
	atlas_v_local(local, rect)
}

atlas_u_local = |local, rect| F64.to_f32_wrap((U64.to_f64(rect.x) + 0.5 + local * (U64.to_f64(rect.width) - 1) / U64.to_f64(rect.width)) / U64.to_f64(RocDoomAssets.world.width))

atlas_v_local = |local, rect| F64.to_f32_wrap((U64.to_f64(rect.y) + 0.5 + local * (U64.to_f64(rect.height) - 1) / U64.to_f64(rect.height)) / U64.to_f64(RocDoomAssets.world.height))

tiled_uv = |x, y, rect| { x: atlas_u(x, rect), y: atlas_v(0 - y, rect) }

wrap = |value, period| if value < 0 wrap(value + period, period) else if value >= period wrap(value - period, period) else value

sqrt = |value| {
	if value <= 0 {
		0
	} else {
		var $guess = if value >= 1 value else 1
		for _ in List.repeat({}, 18) {
			$guess = ($guess + value / $guess) * 0.5
		}
		$guess
	}
}

fixture_surface = |orientation, vertices| {
	subsector: 0,
	sector: 0,
	orientation,
	vertices,
	height: if orientation == Floor 0 else 128,
	flat: "AQF001",
	light_level: 160,
}

expect {
	points : List(RocDoomMap.SurfacePoint)
	points = [{ x: 0, y: 0 }, { x: 64, y: 0 }, { x: 64, y: 64 }, { x: 0, y: 64 }]
	floor = E1M1Renderer.surface_geometry(fixture_surface(Floor, points)) ?? crash "fixture flat missing"
	ceiling = E1M1Renderer.surface_geometry(fixture_surface(Ceiling, reverse(points, []))) ?? crash "fixture flat missing"
	floor_first = List.get(floor.vertices, 0) ?? crash "floor vertex missing"
	ceiling_first = List.get(ceiling.vertices, 0) ?? crash "ceiling vertex missing"
	List.len(floor.vertices) == 4
		and floor.indices == [0, 2, 1, 0, 3, 2]
			and ceiling.indices == [0, 2, 1, 0, 3, 2]
				and floor_first.position == { x: 0, y: 0, z: 0 }
					and ceiling_first.position.y == 2
}

expect {
	span : RocDoomMap.WallSpan
	span = {
		linedef: 0,
		side: Right,
		kind: Middle,
		start: { x: 0, y: 0 },
		end: { x: 128, y: 0 },
		bottom: 0,
		top: 128,
		texture: "AQCOMP01",
		x_offset: 0,
		y_offset: 0,
		vertical_peg: TopAt(128),
		sector: 0,
		light_level: 144,
		flags: RocDoomMap.line_flags(1),
		special: NoSpecial,
	}
	wall = E1M1Renderer.wall_geometry(span) ?? crash "fixture texture missing"
	wall_first = List.get(wall.vertices, 0) ?? crash "wall vertex missing"
	List.len(wall.vertices) >= 4
		and List.len(wall.vertices) % 4 == 0
			and List.len(wall.indices) == List.len(wall.vertices) / 4 * 6
				and List.take_first(wall.indices, 6) == [0, 2, 1, 0, 3, 2]
					and wall_first.tint == { r: 144, g: 144, b: 144, a: 255 }
						and List.all(wall.vertices, |vertex| vertex.uv.x >= 0 and vertex.uv.x <= 1 and vertex.uv.y >= 0 and vertex.uv.y <= 1)
}

expect {
	base : RocDoomMap.WallSpan
	base = {
		linedef: 0,
		side: Right,
		kind: Middle,
		start: { x: 0, y: 0 },
		end: { x: 64, y: 0 },
		bottom: 16,
		top: 80,
		texture: "AQCOMP01",
		x_offset: 0,
		y_offset: 7,
		vertical_peg: TopAt(80),
		sector: 0,
		light_level: 160,
		flags: RocDoomMap.line_flags(0),
		special: NoSpecial,
	}
	top_pegged = E1M1Renderer.wall_texture_row(base, 80, 64)
	bottom_pegged = E1M1Renderer.wall_texture_row({ ..base, vertical_peg: BottomAt(16) }, 16, 64)
	top_pegged == 7 and bottom_pegged == 71
}

expect {
	derived_surfaces = RocDoomMap.e1m1.surface_polygons()
	derived_walls = RocDoomMap.e1m1.wall_spans()
	batches = E1M1Renderer.build(derived_surfaces, derived_walls) ?? crash "E1M1 atlas entry missing"
	counts = geometry_counts(batches)
	List.len(batches) > 0
		and List.all(batches, |batch| List.len(batch.vertices) <= E1M1Renderer.max_batch_vertices and List.len(batch.indices) % 3 == 0)
			and counts.vertices > List.len(derived_surfaces) * 3
				and counts.indices > counts.vertices
}

expect {
	# Back-face culling must never turn an otherwise derived wall span into a
	# black opening. Test every E1M1 side against a point inside its owning
	# sector rather than pinning one example's index order.
	map = RocDoomMap.e1m1
	List.all(map.wall_spans(), |wall| wall_faces_point(wall, wall_owning_point(wall)))
}

expect {
	map = RocDoomMap.e1m1
	initial = RocDoomLevel.initial(map)
	activated = RocDoomLevel.use_line(map, initial, 55, { blue: Bool.False, yellow: Bool.False, red: Bool.False })
	match activated {
		Activated(opening) => {
			door = List.get(opening.doors, 0) ?? crash "E1M1 door missing"
			mid_state = RocDoomLevel.tick(opening)
			closed_geometry = E1M1Renderer.sector_surfaces(map, initial, door.sector) ?? crash "door flat missing"
			mid_geometry = E1M1Renderer.sector_surfaces(map, mid_state, door.sector) ?? crash "door flat missing"
			open_geometry = E1M1Renderer.sector_surfaces(map, advance_level(opening, 80), door.sector) ?? crash "door flat missing"
			initial_extent = line_wall_extent(map.wall_spans_at(initial.heights), 55)
			mid_walls = map.wall_spans_at(mid_state.heights)
			mid_extent = line_wall_extent(mid_walls, 55)
			closed_door_wall = List.find_first(map.wall_spans_at(initial.heights), |span| span.linedef == 55 and span.kind == Upper) ?? crash "closed door wall missing"
			mid_door_wall = List.find_first(mid_walls, |span| span.linedef == 55 and span.kind == Upper) ?? crash "moving door wall missing"
			max_geometry_y(mid_geometry) == max_geometry_y(closed_geometry) + 2 * E1M1Renderer.doom_scale
				and max_geometry_y(open_geometry) == I64.to_f32(door.open) * E1M1Renderer.doom_scale
					and mid_extent != initial_extent
						and closed_door_wall.vertical_peg == BottomAt(door.closed)
							and mid_door_wall.vertical_peg == BottomAt(door.closed + 2)
		}
		_ => Bool.False
	}
}

expect {
	# The E1M1 player starts exactly on a BSP leaf seam. Both sides must retain
	# sector-140 floor coverage, and tile clipping must keep every emitted floor
	# triangle front-facing from the camera above it.
	map = RocDoomMap.e1m1
	start = map.player_start() ?? crash "E1M1 start missing"
	sector = List.get(map.raw().sectors, 140) ?? crash "start sector missing"
	floors = List.keep_if(map.surface_polygons(), |surface| surface.sector == 140 and surface.orientation == Floor)
	start_point = { x: I64.to_f64(start.position.x), y: I64.to_f64(start.position.y) }
	left = { x: start_point.x - 0.01, y: start_point.y }
	right = { x: start_point.x + 0.01, y: start_point.y }
	start.position == { x: -416, y: 256 }
		and RocDoomLevel.sector_at(map, start_point) == Ok(140)
			and sector.floor_height == 0
				and sector.special == 0
					and List.any(floors, |surface| convex_contains(surface.vertices, left))
						and List.any(floors, |surface| convex_contains(surface.vertices, right))
							and List.all(floors, |surface| floor_geometry_faces_up(E1M1Renderer.surface_geometry(surface) ?? crash "start flat missing"))
}

expect {
	map = RocDoomMap.e1m1
	initial = RocDoomLevel.initial(map)
	match RocDoomLevel.cross_line(map, initial, 593) {
		Activated(moving) => {
			lift = List.get(moving.lifts, 0) ?? crash "E1M1 lift missing"
			initial_geometry = E1M1Renderer.sector_surfaces(map, initial, lift.sector) ?? crash "lift flat missing"
			mid_geometry = E1M1Renderer.sector_surfaces(map, RocDoomLevel.tick(moving), lift.sector) ?? crash "lift flat missing"
			low_geometry = E1M1Renderer.sector_surfaces(map, advance_level(moving, 140), lift.sector) ?? crash "lift flat missing"
			min_geometry_y(mid_geometry) == min_geometry_y(initial_geometry) - E1M1Renderer.doom_scale
				and min_geometry_y(low_geometry) == I64.to_f32(lift.low) * E1M1Renderer.doom_scale
		}
		_ => Bool.False
	}
}

expect {
	map = RocDoomMap.e1m1
	initial = RocDoomLevel.initial(map)
	static = E1M1Renderer.build_static(map) ?? crash "static E1M1 atlas entry missing"
	dynamic = E1M1Renderer.build_dynamic(map, initial) ?? crash "dynamic E1M1 atlas entry missing"
	List.len(RocDoomLevel.dynamic_sectors(map)) > 0 and List.len(static) > 0 and List.len(dynamic) > 0
}

expect {
	map = RocDoomMap.e1m1
	state0 = RocDoomLevel.initial(map)
	state1 = match RocDoomLevel.use_line(map, state0, 55, { blue: Bool.True, yellow: Bool.True, red: Bool.True }) {
		Activated(value) => value
		_ => state0
	}
	state2 = match RocDoomLevel.use_line(map, state1, 753, { blue: Bool.True, yellow: Bool.True, red: Bool.True }) {
		Activated(value) => value
		_ => state1
	}
	state3 = match RocDoomLevel.cross_line(map, state2, 593) {
		Activated(value) => value
		_ => state2
	}
	worst = advance_level(state3, 70)
	static = E1M1Renderer.build_static(map) ?? crash "static geometry missing"
	dynamic = E1M1Renderer.build_dynamic(map, worst) ?? crash "dynamic geometry missing"
	static_counts = geometry_counts(static)
	dynamic_counts = geometry_counts(dynamic)
	List.len(RocDoomLevel.dynamic_sectors(map)) <= 32
		and List.len(dynamic) <= 4
			and static_counts.vertices <= 55000
				and static_counts.indices <= 80000
					and dynamic_counts.vertices <= 5000
						and dynamic_counts.indices <= 7000
							and dynamic_counts.vertices < static_counts.vertices
								and List.all(List.concat(static, dynamic), |batch| List.len(batch.vertices) <= E1M1Renderer.max_batch_vertices and List.len(batch.indices) % 3 == 0)
}

expect {
	map = RocDoomMap.e1m1
	sky_surfaces = List.keep_if(map.surface_polygons(), |surface| surface.orientation == Ceiling and surface.flat == "F_SKY1")
	first = List.get(sky_surfaces, 0) ?? crash "E1M1 sky ceiling missing"
	omitted = E1M1Renderer.surface_geometry(first) ?? crash "sky sentinel should not need a flat"
	sky = E1M1Renderer.sky_geometry(0, 0) ?? crash "SKY1 texture missing"
	List.len(sky_surfaces) > 0
		and List.is_empty(omitted.vertices)
			and List.is_empty(omitted.indices)
				and List.len(sky.vertices) == 16
					and List.len(sky.indices) == 24
						and sky_geometry_faces_in(sky, { x: 0, z: 0 })
}

expect {
	# Linedef 1049 is E1M1's intentional west-facing sky portal: both adjacent
	# ceilings use the sky sentinel and its sidedefs deliberately omit textures.
	# It must reveal the inward-facing sky enclosure, not acquire a fake wall.
	raw = RocDoomMap.e1m1.raw()
	line = List.get(raw.linedefs, 1049) ?? crash "E1M1 west sky portal missing"
	right = List.get(raw.sidedefs, line.right_sidedef ?? crash "west sky portal right side missing") ?? crash "west sky portal right side invalid"
	left = List.get(raw.sidedefs, line.left_sidedef ?? crash "west sky portal left side missing") ?? crash "west sky portal left side invalid"
	right_sector = List.get(raw.sectors, right.sector) ?? crash "west sky portal right sector invalid"
	left_sector = List.get(raw.sectors, left.sector) ?? crash "west sky portal left sector invalid"
	spans = List.keep_if(RocDoomMap.e1m1.wall_spans(), |span| span.linedef == 1049)
	right_sector.ceiling_flat == "F_SKY1"
		and left_sector.ceiling_flat == "F_SKY1"
			and right_sector.ceiling_height == 128
				and left_sector.ceiling_height == 0
					and List.is_empty(spans)
}

expect {
	map = RocDoomMap.e1m1
	masked = List.keep_if(map.wall_spans(), masked_middle)
	first = List.get(masked, 0) ?? crash "E1M1 masked middle missing"
	geometry = E1M1Renderer.wall_geometry(first) ?? crash "masked texture missing"
	static = E1M1Renderer.build_masked_static(map) ?? crash "masked atlas incomplete"
	first_vertex = List.get(geometry.vertices, 0) ?? crash "masked wall vertex missing"
	List.len(masked) > 0
		and first.kind == Middle
			and first.flags.two_sided
				and List.len(static) > 0
					and first_vertex.tint.r == U64.to_u8_wrap(I64.to_u64_wrap(first.light_level))
						and List.all(geometry.vertices, |vertex| vertex.uv.x >= 0 and vertex.uv.x <= 1 and vertex.uv.y >= 0 and vertex.uv.y <= 1)
}
