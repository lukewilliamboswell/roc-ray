## Pure E1M1 world-mesh adapter. DoomMap owns validated map derivation,
## DoomAssets owns compile-time atlas metadata, and this module translates the
## two into structural records accepted by `Draw.textured_triangles_3d!`.
## Geometry is split below the U32 index ceiling so host work stays explicit.
import DoomAssets
import DoomMap

E1M1Renderer := [].{
	Vec2 : { x : F32, y : F32 }
	Vec3 : { x : F32, y : F32, z : F32 }
	Tint : { r : U8, g : U8, b : U8, a : U8 }
	Vertex : { position : Vec3, uv : Vec2, tint : Tint }
	Geometry : { vertices : List(Vertex), indices : List(U32) }

	## Build retained world geometry for the one world-atlas texture. Each list
	## item can be submitted as one `textured_triangles_3d!` call with the loaded
	## `world_atlas.png` texture.
	build : List(DoomMap.SurfacePolygon), List(DoomMap.WallSpan) -> Try(List(Geometry), [MissingFlat(Str), MissingTexture(Str), GeometryPrimitiveTooLarge(U64)])
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

	surface_geometry : DoomMap.SurfacePolygon -> Try(Geometry, [MissingFlat(Str)])
	surface_geometry = |surface| {
		rect = DoomAssets.flat(surface.flat)?
		tint = light_tint(surface.light_level)
		vertices = List.map(
			surface.vertices,
			|point| {
				position: doom_position(point.x, surface.height, point.y),
				uv: tiled_uv(point.x, point.y, rect),
				tint,
			},
		)
		# DoomMap supplies CCW floors and reversed ceilings. Mapping map Y to
		# world Z reverses the normal, so reversing both fans yields +Y floors
		# and -Y ceilings respectively.
		indices = reversed_fan_indices(List.len(vertices))
		Ok({ vertices, indices })
	}

	wall_geometry : DoomMap.WallSpan -> Try(Geometry, [MissingTexture(Str)])
	wall_geometry = |wall| {
		rect = DoomAssets.texture(wall.texture)?
		tint = light_tint(wall.light_level)
		dx = I64.to_f64(wall.end.x - wall.start.x)
		dy = I64.to_f64(wall.end.y - wall.start.y)
		length = sqrt(dx * dx + dy * dy)
		height = I64.to_f64(wall.top - wall.bottom)
		horizontal = tile_runs(length, I64.to_f64(wall.x_offset), U64.to_f64(rect.width), 0, [])
		vertical = tile_runs(height, I64.to_f64(wall.y_offset), U64.to_f64(rect.height), 0, [])
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
				$indices = List.concat($indices, [offset, offset + 1, offset + 2, offset, offset + 2, offset + 3])
			}
		}
		Ok({ vertices: $vertices, indices: $indices })
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
			shifted = List.map(primitive.indices, |index| index + offset)
			Ok({
				..packed,
				current: {
					vertices: List.concat(packed.current.vertices, primitive.vertices),
					indices: List.concat(packed.current.indices, shifted),
				},
			})
		}
	}
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

atlas_u_local = |local, rect| F64.to_f32_wrap((U64.to_f64(rect.x) + 0.5 + local * (U64.to_f64(rect.width) - 1) / U64.to_f64(rect.width)) / U64.to_f64(DoomAssets.world.width))

atlas_v_local = |local, rect| F64.to_f32_wrap((U64.to_f64(rect.y) + 0.5 + local * (U64.to_f64(rect.height) - 1) / U64.to_f64(rect.height)) / U64.to_f64(DoomAssets.world.height))

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
	points : List(DoomMap.SurfacePoint)
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
	span : DoomMap.WallSpan
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
		sector: 0,
		light_level: 144,
		flags: DoomMap.line_flags(1),
		special: NoSpecial,
	}
	wall = E1M1Renderer.wall_geometry(span) ?? crash "fixture texture missing"
	wall_first = List.get(wall.vertices, 0) ?? crash "wall vertex missing"
	List.len(wall.vertices) >= 4
		and List.len(wall.vertices) % 4 == 0
			and List.len(wall.indices) == List.len(wall.vertices) / 4 * 6
				and wall_first.tint == { r: 144, g: 144, b: 144, a: 255 }
					and List.all(wall.vertices, |vertex| vertex.uv.x >= 0 and vertex.uv.x <= 1 and vertex.uv.y >= 0 and vertex.uv.y <= 1)
}

expect {
	derived_surfaces = DoomMap.e1m1.surface_polygons()
	derived_walls = DoomMap.e1m1.wall_spans()
	batches = E1M1Renderer.build(derived_surfaces, derived_walls) ?? crash "E1M1 atlas entry missing"
	counts = geometry_counts(batches)
	List.len(batches) > 0
		and List.all(batches, |batch| List.len(batch.vertices) <= E1M1Renderer.max_batch_vertices and List.len(batch.indices) % 3 == 0)
			and counts.vertices > List.len(derived_surfaces) * 3
				and counts.indices > counts.vertices
}
