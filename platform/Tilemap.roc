## Tilemap module - Tiled TMX data, tileset drawing, and grid queries.
import Assets
import Camera
import Color
import Draw
import Math
import TilemapHost

TilemapRawProperty : TilemapHost.Property

TilemapRawTileset : TilemapHost.Tileset

TilemapRawTileProperties : TilemapHost.TileProperties

TilemapRawLayer : TilemapHost.Layer

TilemapRawPoint : TilemapHost.Point

TilemapRawObject : TilemapHost.Object

TilemapRawMap : TilemapHost.Map

TilemapTextureBinding : {
	first_gid : U64,
	texture : Assets.Texture,
}

TilemapLayerRole := [Drawn, Solid, Hidden].{
	is_eq : _
}

TilemapObjectRole := [Spawn, Collectible, Hazard, Goal, Checkpoint, Decoration, Exit, Unknown].{
	is_eq : _
}

TilemapLayerRoleRule : {
	name : Str,
	role : TilemapLayerRole,
}

TilemapObjectRoleRule : {
	key : Str,
	role : TilemapObjectRole,
}

TilemapCell : {
	col : U64,
	row : U64,
}

TilemapCellRange : {
	min_col : U64,
	min_row : U64,
	max_col : U64,
	max_row : U64,
}

TilemapFlip : {
	horizontal : Bool,
	vertical : Bool,
	diagonal : Bool,
}

## A tileset with its texture binding resolved once during `build`.
TilemapResolvedTileset : {
	first_gid : U64,
	tile_width : F32,
	tile_height : F32,
	columns : U64,
	texture : Assets.Texture,
}

## Configuration errors found while binding parsed tilesets to host textures.
TilemapBuildError := [MissingTilesetBinding(U64), DuplicateTilesetBinding(U64)]

TilemapBuilder :: {
	raw : TilemapRawMap,
	textures : List(TilemapTextureBinding),
	layer_roles : List(TilemapLayerRoleRule),
	object_roles : List(TilemapObjectRoleRule),
	origin : Math.Vec2,
}.{
	BuildError : TilemapBuildError

	with_origin : TilemapBuilder, Math.Vec2 -> TilemapBuilder
	with_origin = |builder, origin| { ..builder, origin }

	with_tileset_texture : TilemapBuilder, U64, Assets.Texture -> TilemapBuilder
	with_tileset_texture = |builder, first_gid, texture| {
		..builder,
		textures: List.append(builder.textures, { first_gid, texture }),
	}

	layer_role : TilemapBuilder, Str, TilemapLayerRole -> TilemapBuilder
	layer_role = |builder, name, role| {
		..builder,
		layer_roles: List.append(builder.layer_roles, { name, role }),
	}

	object_role : TilemapBuilder, Str, TilemapObjectRole -> TilemapBuilder
	object_role = |builder, key, role| {
		..builder,
		object_roles: List.append(builder.object_roles, { key, role }),
	}

	## Validate every parsed tileset has exactly one texture binding, then resolve
	## those bindings once. Per-frame tile queries remain unchanged and allocation-free.
	build : TilemapBuilder -> Try(Tilemap, [MissingTilesetBinding(U64), DuplicateTilesetBinding(U64), ..])
	build = |builder|
		match resolve_tilesets(builder.raw.tilesets, builder.textures) {
			Ok(resolved_tilesets) => Ok({
				raw: builder.raw,
				layer_roles: builder.layer_roles,
				object_roles: builder.object_roles,
				origin: builder.origin,
				resolved_tilesets,
			})
			Err(MissingTilesetBinding(first_gid)) => Err(MissingTilesetBinding(first_gid))
			Err(DuplicateTilesetBinding(first_gid)) => Err(DuplicateTilesetBinding(first_gid))
		}
}

Tilemap :: {
	raw : TilemapRawMap,
	layer_roles : List(TilemapLayerRoleRule),
	object_roles : List(TilemapObjectRoleRule),
	origin : Math.Vec2,
	resolved_tilesets : List(TilemapResolvedTileset),
}.{

	## Parsed TMX data stored in flat lists to avoid a heap allocation per nested item.
	RawMap : TilemapRawMap

	## Parsed tile-layer metadata and a range into the map GID list.
	RawLayer : TilemapRawLayer

	## Parsed Tiled object metadata and ranges into point and property lists.
	RawObject : TilemapRawObject

	## Parsed Tiled property with tagged scalar storage.
	RawProperty : TilemapRawProperty

	## Parsed tileset metadata and its property range.
	RawTileset : TilemapRawTileset

	## Parsed object point in map-local coordinates.
	RawPoint : TilemapRawPoint

	## Zero-based tile column and row.
	Cell : TilemapCell

	## Inclusive rectangular range of map cells.
	CellRange : TilemapCellRange

	## Decoded Tiled tile-transform flags.
	Flip : TilemapFlip
	ResolvedTileset : TilemapResolvedTileset

	## Application-level behavior assigned to a named layer.
	LayerRole : TilemapLayerRole

	## Application-level behavior assigned to an object name or type.
	ObjectRole : TilemapObjectRole

	## Immutable tilemap configuration builder.
	Builder : TilemapBuilder

	## Empty parsed map value, useful as a deliberate fallback.
	empty_raw_map : TilemapRawMap
	empty_raw_map = {
		width: 0,
		height: 0,
		tile_width: 0,
		tile_height: 0,
		map_property_start: 0,
		map_property_count: 0,
		tilesets: [],
		tile_properties: [],
		layers: [],
		gids: [],
		objects: [],
		points: [],
		properties: [],
	}

	## Parse a Tiled TMX map. The returned data is an allocation-efficient set of
	## flat lists with index ranges for nested properties, objects, and tile data.
	load_tmx! : Str => Try(TilemapRawMap, [NotFound, ReadFailed, ParseFailed, Unsupported, ..])
	load_tmx! = |path| {
		result = TilemapHost.load_tmx!(path)
		if result.ok {
			Ok(result.map)
		} else if result.err == err_not_found {
			Err(NotFound)
		} else if result.err == err_read_failed {
			Err(ReadFailed)
		} else if result.err == err_unsupported {
			Err(Unsupported)
		} else {
			Err(ParseFailed)
		}
	}

	## Begin configuring a drawable and queryable tilemap from parsed TMX data.
	from_raw : TilemapRawMap -> TilemapBuilder
	from_raw = |raw| {
		raw,
		textures: [],
		layer_roles: [],
		object_roles: [],
		origin: Math.zero,
	}

	## Access the parsed flat-map data backing a configured tilemap.
	raw_map : Tilemap -> TilemapRawMap
	raw_map = |map| map.raw

	## Resolve a layer's configured semantic role; unmatched layers are drawn.
	layer_role_for : Tilemap, TilemapRawLayer -> TilemapLayerRole
	layer_role_for = |map, layer| layer_role_for_rules(map.layer_roles, layer.name)

	## Resolve an object's configured semantic role; unmatched objects are unknown.
	object_role_for : Tilemap, TilemapRawObject -> TilemapObjectRole
	object_role_for = |map, object| {
		var $role = Unknown
		for rule in map.object_roles {
			if rule.key == object.type_name or rule.key == object.name {
				$role = rule.role
			}
		}
		$role
	}

	## Return every parsed object in source order.
	objects : Tilemap -> List(TilemapRawObject)
	objects = |map| map.raw.objects

	## Return objects whose Tiled name matches exactly.
	objects_named : Tilemap, Str -> List(TilemapRawObject)
	objects_named = |map, name| List.keep_if(map.raw.objects, |object| object.name == name)

	## Return objects whose Tiled type matches exactly.
	objects_typed : Tilemap, Str -> List(TilemapRawObject)
	objects_typed = |map, type_name| List.keep_if(map.raw.objects, |object| object.type_name == type_name)

	## Return objects matching a configured semantic role.
	objects_with_role : Tilemap, TilemapObjectRole -> List(TilemapRawObject)
	objects_with_role = |map, role| List.keep_if(map.raw.objects, |object| Tilemap.object_role_for(map, object) == role)

	## Return the first object matching a configured semantic role.
	first_object : Tilemap, TilemapObjectRole -> Try(TilemapRawObject, [NotFound])
	first_object = |map, role|
		match List.first(Tilemap.objects_with_role(map, role)) {
			Ok(object) => Ok(object)
			Err(_) => Err(NotFound)
		}

	## Return an object's center in map-local coordinates.
	object_center : TilemapRawObject -> Math.Vec2
	object_center = |object| {
		if object.width == 0 and object.height == 0 {
			{ x: object.x, y: object.y }
		} else {
			{ x: object.x + object.width * 0.5, y: object.y + object.height * 0.5 }
		}
	}

	## Return an object's bounding rectangle in map-local coordinates.
	object_rect : TilemapRawObject -> Math.Rect
	object_rect = |object| Math.rect(object.x, object.y, object.width, object.height)

	## Approximate an object as a circle centered in its bounds.
	object_circle : TilemapRawObject -> Math.Circle
	object_circle = |object| Math.circle(Tilemap.object_center(object), F32.max(object.width, object.height) * 0.5)

	## Return an object's center translated by the tilemap origin.
	object_world_center : Tilemap, TilemapRawObject -> Math.Vec2
	object_world_center = |map, object| Math.add(map.origin, Tilemap.object_center(object))

	## Return an object's bounds translated by the tilemap origin.
	object_world_rect : Tilemap, TilemapRawObject -> Math.Rect
	object_world_rect = |map, object| Math.rect(map.origin.x + object.x, map.origin.y + object.y, object.width, object.height)

	## Return an object's circle translated by the tilemap origin.
	object_world_circle : Tilemap, TilemapRawObject -> Math.Circle
	object_world_circle = |map, object| Math.circle(Tilemap.object_world_center(map, object), F32.max(object.width, object.height) * 0.5)

	## Look up a property within an explicit flat-list range.
	property_named : TilemapRawMap, U64, U64, Str -> Try(TilemapRawProperty, [NotFound])
	property_named = |raw, start, count, name| {
		property_named_at(raw, start, count, name, 0)
	}

	## Look up a property attached to an object.
	object_property : TilemapRawMap, TilemapRawObject, Str -> Try(TilemapRawProperty, [NotFound])
	object_property = |raw, object, name| Tilemap.property_named(raw, object.property_start, object.property_count, name)

	## Look up a property attached to a layer.
	layer_property : TilemapRawMap, TilemapRawLayer, Str -> Try(TilemapRawProperty, [NotFound])
	layer_property = |raw, layer, name| Tilemap.property_named(raw, layer.property_start, layer.property_count, name)

	## Read an object's string property, or return the supplied default.
	property_str : TilemapRawMap, TilemapRawObject, Str, Str -> Str
	property_str = |raw, object, name, default|
		match Tilemap.object_property(raw, object, name) {
			Ok(property) => property.text
			Err(_) => default
		}

	## Read an object's numeric property, or return the supplied default.
	property_f32 : TilemapRawMap, TilemapRawObject, Str, F32 -> F32
	property_f32 = |raw, object, name, default|
		match Tilemap.object_property(raw, object, name) {
			Ok(property) => property.number
			Err(_) => default
		}

	## Read an object's integer property, or return the supplied default.
	property_i64 : TilemapRawMap, TilemapRawObject, Str, I64 -> I64
	property_i64 = |raw, object, name, default|
		match Tilemap.object_property(raw, object, name) {
			Ok(property) => property.integer
			Err(_) => default
		}

	## Read an object's boolean property, or return the supplied default.
	property_bool : TilemapRawMap, TilemapRawObject, Str, Bool -> Bool
	property_bool = |raw, object, name, default|
		match Tilemap.object_property(raw, object, name) {
			Ok(property) => property.bool_value
			Err(_) => default
		}

	## Convert a world-space position to a map cell, accounting for map origin.
	cell_at_world : Tilemap, Math.Vec2 -> Try(TilemapCell, [OutOfBounds])
	cell_at_world = |map, pos| {
		rel_x = pos.x - map.origin.x
		rel_y = pos.y - map.origin.y
		if map.raw.tile_width <= 0 or map.raw.tile_height <= 0 or rel_x < 0 or rel_y < 0 {
			Err(OutOfBounds)
		} else {
			match F32.floor_to_u64_try(rel_x / map.raw.tile_width) {
				Ok(col) =>
					match F32.floor_to_u64_try(rel_y / map.raw.tile_height) {
						Ok(row) =>
							if col < map.raw.width and row < map.raw.height {
								Ok({ col, row })
							} else {
								Err(OutOfBounds)
							}
						Err(_) => Err(OutOfBounds)
					}
				Err(_) => Err(OutOfBounds)
			}
		}
	}

	## Return the inclusive cell range overlapping a world-space rectangle's
	## half-open area. The arithmetic is O(1), allocation-free, and clamps the
	## range to map bounds.
	cell_range_for_world_rect : Tilemap, Math.Rect -> Try(TilemapCellRange, [OutOfBounds])
	cell_range_for_world_rect = |map, bounds| {
		map_right = map.origin.x + U64.to_f32(map.raw.width) * map.raw.tile_width
		map_bottom = map.origin.y + U64.to_f32(map.raw.height) * map.raw.tile_height
		left = F32.max(bounds.x, map.origin.x)
		top = F32.max(bounds.y, map.origin.y)
		right = F32.min(Math.right(bounds), map_right)
		bottom = F32.min(Math.bottom(bounds), map_bottom)

		if map.raw.width == 0 or map.raw.height == 0 or map.raw.tile_width <= 0 or map.raw.tile_height <= 0 or right <= left or bottom <= top {
			Err(OutOfBounds)
		} else {
			match F32.floor_to_u64_try((left - map.origin.x) / map.raw.tile_width) {
				Ok(min_col) =>
					match F32.floor_to_u64_try((top - map.origin.y) / map.raw.tile_height) {
						Ok(min_row) =>
							match F32.ceiling_to_u64_try((right - map.origin.x) / map.raw.tile_width) {
								Ok(max_col_exclusive) =>
									match F32.ceiling_to_u64_try((bottom - map.origin.y) / map.raw.tile_height) {
										Ok(max_row_exclusive) => Ok({ min_col, min_row, max_col: max_col_exclusive - 1, max_row: max_row_exclusive - 1 })
										Err(_) => Err(OutOfBounds)
									}
								Err(_) => Err(OutOfBounds)
							}
						Err(_) => Err(OutOfBounds)
					}
				Err(_) => Err(OutOfBounds)
			}
		}
	}

	## Return the world-space rectangle covered by a map cell.
	world_rect_for_cell : Tilemap, TilemapCell -> Math.Rect
	world_rect_for_cell = |map, cell| {
		x: map.origin.x + U64.to_f32(cell.col) * map.raw.tile_width,
		y: map.origin.y + U64.to_f32(cell.row) * map.raw.tile_height,
		width: map.raw.tile_width,
		height: map.raw.tile_height,
	}

	## Read the cleaned tile GID at a named layer and cell.
	gid_at : Tilemap, Str, TilemapCell -> Try(U64, [NotFound, OutOfBounds])
	gid_at = |map, layer_name, cell|
		match find_layer(map.raw.layers, layer_name) {
			Ok(layer) => gid_at_layer(map.raw, layer, cell)
			Err(_) => Err(NotFound)
		}

	## Whether any layer configured as solid contains a tile in this cell.
	solid_cell : Tilemap, TilemapCell -> Bool
	solid_cell = |map, cell| {
		var $solid = Bool.False
		for layer in map.raw.layers {
			if Tilemap.layer_role_for(map, layer) == Solid {
				match gid_at_layer(map.raw, layer, cell) {
					Ok(gid) => if Tilemap.clean_gid(gid) != 0 {
						$solid = Bool.True
					}
					Err(_) => {}
				}
			}
		}
		$solid
	}

	## Whether a world-space point falls in a solid cell.
	solid_at_world : Tilemap, Math.Vec2 -> Bool
	solid_at_world = |map, pos|
		match Tilemap.cell_at_world(map, pos) {
			Ok(cell) => Tilemap.solid_cell(map, cell)
			Err(_) => Bool.False
		}

	## Whether a world-space circle overlaps any configured solid tile.
	circle_touches_solid : Tilemap, Math.Circle -> Bool
	circle_touches_solid = |map, circle| {

		## Expand very slightly so a circle exactly tangent to a neighbouring cell
		## still tests that cell despite the culling range's half-open semantics.
		extent = circle.radius + 0.0001
		bounds = Math.rect(circle.center.x - extent, circle.center.y - extent, extent * 2, extent * 2)
		match Tilemap.cell_range_for_world_rect(map, bounds) {
			Ok(range) => {
				var $touches = Bool.False
				for layer in map.raw.layers {
					if !$touches and Tilemap.layer_role_for(map, layer) == Solid {
						$touches = circle_touches_solid_row(map, layer, circle, range, range.min_row)
					}
				}
				$touches
			}
			Err(_) => Bool.False
		}
	}

	## Draw one named visible layer without camera culling.
	draw_layer! : Tilemap, Draw.Frame, Str => {}
	draw_layer! = |map, frame, layer_name| {
		match find_layer(map.raw.layers, layer_name) {
			Ok(layer) => draw_layer_cells!(map, frame, layer, 0)
			Err(_) => {}
		}
	}

	## Draw only cells intersecting `world_view`. This is the preferred hot path
	## for maps larger than the viewport: culled cells perform no hosted effects.
	draw_layer_in! : Tilemap, Draw.Frame, Str, Math.Rect => {}
	draw_layer_in! = |map, frame, layer_name, world_view| {
		match find_layer(map.raw.layers, layer_name) {
			Ok(layer) => draw_layer_view!(map, frame, layer, world_view)
			Err(_) => {}
		}
	}

	## Draw every visible layer configured with the `Drawn` role.
	draw_layers! : Tilemap, Draw.Frame, TilemapLayerRole => {}
	draw_layers! = |map, frame, role| {
		for layer in map.raw.layers {
			if Tilemap.layer_role_for(map, layer) == role {
				draw_layer_cells!(map, frame, layer, 0)
			}
		}
	}

	## Draw visible configured layers culled to a world-space viewport.
	draw_layers_in! : Tilemap, Draw.Frame, TilemapLayerRole, Math.Rect => {}
	draw_layers_in! = |map, frame, role, world_view| {
		for layer in map.raw.layers {
			if Tilemap.layer_role_for(map, layer) == role {
				draw_layer_view!(map, frame, layer, world_view)
			}
		}
	}

	## Draw every visible tile layer, regardless of configured role.
	draw_all! : Tilemap, Draw.Frame => {}
	draw_all! = |map, frame| {
		for layer in map.raw.layers {
			role = Tilemap.layer_role_for(map, layer)
			if role == Drawn or role == Solid {
				draw_layer_cells!(map, frame, layer, 0)
			}
		}
	}

	## Draw every visible tile layer culled to a world-space viewport.
	draw_all_in! : Tilemap, Draw.Frame, Math.Rect => {}
	draw_all_in! = |map, frame, world_view| {
		for layer in map.raw.layers {
			role = Tilemap.layer_role_for(map, layer)
			if role == Drawn or role == Solid {
				draw_layer_view!(map, frame, layer, world_view)
			}
		}
	}

	## Compute the world-space axis-aligned bounds visible through a 2D camera,
	## including non-centered offsets and rotation. This is pure and allocates no
	## temporary list.
	viewport_for_camera : Camera.Camera2D, Math.Vec2 -> Math.Rect
	viewport_for_camera = |camera, screen_size| camera.viewport(screen_size)

	## Convenience form of `draw_all_in!` for camera-driven scenes.
	draw_all_for_camera! : Tilemap, Draw.Frame, Camera.Camera2D, Math.Vec2 => {}
	draw_all_for_camera! = |map, frame, camera, screen_size| map.draw_all_in!(frame, camera.viewport(screen_size))

	## Decode Tiled horizontal, vertical, and diagonal flip flags.
	flip_for_gid : U64 -> TilemapFlip
	flip_for_gid = |gid| {
		horizontal: gid >= 2_147_483_648,
		vertical: (gid % 2_147_483_648) >= 1_073_741_824,
		diagonal: (gid % 1_073_741_824) >= 536_870_912,
	}

	## Remove Tiled flip flags from a packed global tile ID.
	clean_gid : U64 -> U64
	clean_gid = |gid| {
		without_h = if gid >= 2_147_483_648 gid - 2_147_483_648 else gid
		without_v = if without_h >= 1_073_741_824 without_h - 1_073_741_824 else without_h
		without_d = if without_v >= 536_870_912 without_v - 536_870_912 else without_v
		if without_d >= 268_435_456 without_d - 268_435_456 else without_d
	}
}

err_not_found : U8
err_not_found = 1

err_read_failed : U8
err_read_failed = 2

err_unsupported : U8
err_unsupported = 4

layer_role_for_rules : List(TilemapLayerRoleRule), Str -> TilemapLayerRole
layer_role_for_rules = |rules, layer_name| {
	var $role = Drawn
	for rule in rules {
		if rule.name == layer_name {
			$role = rule.role
		}
	}
	$role
}

resolve_tilesets : List(TilemapRawTileset), List(TilemapTextureBinding) -> Try(List(TilemapResolvedTileset), TilemapBuildError)
resolve_tilesets = |tilesets, textures| {
	var $result = Ok([])
	for tileset in tilesets {
		match $result {
			Ok(resolved) =>
				match find_unique_texture(textures, tileset.first_gid) {
					Ok(texture) => {
						$result = Ok(
							List.append(
								resolved,
								{
									first_gid: tileset.first_gid,
									tile_width: tileset.tile_width,
									tile_height: tileset.tile_height,
									columns: if tileset.columns == 0 1 else tileset.columns,
									texture,
								},
							),
						)
					}
					Err(error) => {
						$result = Err(error)
					}
				}
			Err(_) => {}
		}
	}
	$result
}

property_named_at : TilemapRawMap, U64, U64, Str, U64 -> Try(TilemapRawProperty, [NotFound])
property_named_at = |raw, start, count, name, offset| {
	if offset >= count {
		Err(NotFound)
	} else {
		match List.get(raw.properties, start + offset) {
			Ok(property) =>
				if property.name == name {
					Ok(property)
				} else {
					property_named_at(raw, start, count, name, offset + 1)
				}
			Err(_) => Err(NotFound)
		}
	}
}

find_layer : List(TilemapRawLayer), Str -> Try(TilemapRawLayer, [NotFound])
find_layer = |layers, name| {
	var $found = Err(NotFound)
	for layer in layers {
		if layer.name == name {
			$found = Ok(layer)
		}
	}
	$found
}

gid_at_layer : TilemapRawMap, TilemapRawLayer, TilemapCell -> Try(U64, [NotFound, OutOfBounds])
gid_at_layer = |raw, layer, cell| {
	if cell.col >= layer.width or cell.row >= layer.height {
		Err(OutOfBounds)
	} else {
		index = layer.gid_start + cell.row * layer.width + cell.col
		match List.get(raw.gids, index) {
			Ok(gid) => Ok(gid)
			Err(_) => Err(NotFound)
		}
	}
}

circle_touches_solid_row : Tilemap, TilemapRawLayer, Math.Circle, TilemapCellRange, U64 -> Bool
circle_touches_solid_row = |map, layer, circle, range, row| {
	if row > range.max_row {
		Bool.False
	} else if circle_touches_solid_col(map, layer, circle, range, row, range.min_col) {
		Bool.True
	} else {
		circle_touches_solid_row(map, layer, circle, range, row + 1)
	}
}

circle_touches_solid_col : Tilemap, TilemapRawLayer, Math.Circle, TilemapCellRange, U64, U64 -> Bool
circle_touches_solid_col = |map, layer, circle, range, row, col| {
	if col > range.max_col {
		Bool.False
	} else {
		cell = { col, row }
		gid_is_solid = match gid_at_layer(map.raw, layer, cell) {
			Ok(gid) => Tilemap.clean_gid(gid) != 0
			Err(_) => Bool.False
		}
		if gid_is_solid and Math.circle_rect(circle, Tilemap.world_rect_for_cell(map, cell)) {
			Bool.True
		} else {
			circle_touches_solid_col(map, layer, circle, range, row, col + 1)
		}
	}
}

draw_layer_cells! : Tilemap, Draw.Frame, TilemapRawLayer, U64 => {}
draw_layer_cells! = |map, frame, layer, index| {
	if index >= layer.gid_count or !(layer.visible) {
		{}
	} else {
		match List.get(map.raw.gids, layer.gid_start + index) {
			Ok(raw_gid) => {
				gid = Tilemap.clean_gid(raw_gid)
				if gid != 0 {
					cell = { col: index % layer.width, row: index // layer.width }
					draw_gid!(map, frame, raw_gid, cell)
				}
			}
			Err(_) => {}
		}
		draw_layer_cells!(map, frame, layer, index + 1)
	}
}

draw_layer_view! : Tilemap, Draw.Frame, TilemapRawLayer, Math.Rect => {}
draw_layer_view! = |map, frame, layer, world_view| {
	if layer.visible {
		match Tilemap.cell_range_for_world_rect(map, world_view) {
			Ok(range) => draw_layer_range_rows!(map, frame, layer, range, range.min_row)
			Err(_) => {}
		}
	}
}

draw_layer_range_rows! : Tilemap, Draw.Frame, TilemapRawLayer, TilemapCellRange, U64 => {}
draw_layer_range_rows! = |map, frame, layer, range, row| {
	if row <= range.max_row and row < layer.height {
		draw_layer_range_cols!(map, frame, layer, range, row, range.min_col)
		draw_layer_range_rows!(map, frame, layer, range, row + 1)
	}
}

draw_layer_range_cols! : Tilemap, Draw.Frame, TilemapRawLayer, TilemapCellRange, U64, U64 => {}
draw_layer_range_cols! = |map, frame, layer, range, row, col| {
	if col <= range.max_col and col < layer.width {
		index = row * layer.width + col
		if index < layer.gid_count {
			match List.get(map.raw.gids, layer.gid_start + index) {
				Ok(raw_gid) => if Tilemap.clean_gid(raw_gid) != 0 draw_gid!(map, frame, raw_gid, { col, row })
				Err(_) => {}
			}
		}
		draw_layer_range_cols!(map, frame, layer, range, row, col + 1)
	}
}

draw_gid! : Tilemap, Draw.Frame, U64, TilemapCell => {}
draw_gid! = |map, frame, raw_gid, cell| {
	gid = Tilemap.clean_gid(raw_gid)
	match find_resolved_tileset(map.resolved_tilesets, gid) {
		Ok(tileset) => {
			local = gid - tileset.first_gid
			source = {
				x: U64.to_f32(local % tileset.columns) * tileset.tile_width,
				y: U64.to_f32(local // tileset.columns) * tileset.tile_height,
				width: tileset.tile_width,
				height: tileset.tile_height,
			}
			dest = Tilemap.world_rect_for_cell(map, cell)
			flip = Tilemap.flip_for_gid(raw_gid)
			frame.texture_quad!({
				texture: tileset.texture,
				source,
				top_left: transformed_corner(dest, { x: 0, y: 0 }, flip),
				bottom_left: transformed_corner(dest, { x: 0, y: 1 }, flip),
				bottom_right: transformed_corner(dest, { x: 1, y: 1 }, flip),
				top_right: transformed_corner(dest, { x: 1, y: 0 }, flip),
				tint: Color.white,
			})
		}
		Err(_) => {}
	}
}

transformed_corner : Math.Rect, Math.Vec2, TilemapFlip -> Math.Vec2
transformed_corner = |dest, corner, flip| {

	## Tiled applies the anti-diagonal transform before horizontal/vertical flips.
	diagonal = if flip.diagonal { x: 1 - corner.y, y: 1 - corner.x } else corner
	x = if flip.horizontal 1 - diagonal.x else diagonal.x
	y = if flip.vertical 1 - diagonal.y else diagonal.y
	{ x: dest.x + x * dest.width, y: dest.y + y * dest.height }
}

find_resolved_tileset : List(TilemapResolvedTileset), U64 -> Try(TilemapResolvedTileset, [NotFound])
find_resolved_tileset = |tilesets, gid| {
	var $found = Err(NotFound)
	for tileset in tilesets {
		if gid >= tileset.first_gid {
			$found = Ok(tileset)
		}
	}
	$found
}

find_unique_texture : List(TilemapTextureBinding), U64 -> Try(Assets.Texture, TilemapBuildError)
find_unique_texture = |textures, first_gid| {
	var $found = Err(MissingTilesetBinding(first_gid))
	var $count = 0
	for binding in textures {
		if binding.first_gid == first_gid {
			$count = $count + 1
			$found = Ok(binding.texture)
		}
	}
	if $count == 0 {
		Err(MissingTilesetBinding(first_gid))
	} else if $count > 1 {
		Err(DuplicateTilesetBinding(first_gid))
	} else {
		$found
	}
}

test_tileset : TilemapRawTileset
test_tileset = {
	first_gid: 1,
	name: "test",
	tile_width: 16,
	tile_height: 16,
	tile_count: 4,
	columns: 2,
	image_source: "tiles.png",
	image_width: 32,
	image_height: 32,
	property_start: 0,
	property_count: 0,
}

test_ground_layer : TilemapRawLayer
test_ground_layer = { name: "Ground", width: 3, height: 2, gid_start: 0, gid_count: 6, property_start: 0, property_count: 0, visible: Bool.True, opacity: 1 }

test_walls_layer : TilemapRawLayer
test_walls_layer = { name: "Walls", width: 3, height: 2, gid_start: 6, gid_count: 6, property_start: 0, property_count: 0, visible: Bool.True, opacity: 1 }

test_spawn_object : TilemapRawObject
test_spawn_object = { id: 1, name: "spawn-a", type_name: "spawn", x: 8, y: 8, width: 0, height: 0, rotation: 0, kind: 1, point_start: 0, point_count: 0, property_start: 0, property_count: 1 }

test_speed_property : TilemapRawProperty
test_speed_property = { name: "speed", kind: 2, text: "12.5", number: 12.5, integer: 12, bool_value: Bool.True }

test_raw : TilemapRawMap
test_raw = {
	width: 3,
	height: 2,
	tile_width: 16,
	tile_height: 16,
	map_property_start: 0,
	map_property_count: 0,
	tilesets: [],
	tile_properties: [],
	layers: [test_ground_layer, test_walls_layer],
	gids: [1, 1, 1, 1, 1, 1, 0, 2, 0, 0, 0, 0],
	objects: [test_spawn_object],
	points: [],
	properties: [test_speed_property],
}

test_map_result : Try(Tilemap, TilemapBuildError)
test_map_result = Tilemap.from_raw(test_raw)
	.layer_role(
		"Walls",
		Solid,
	)
	.object_role(
		"spawn",
		Spawn,
	)
	.build()

offset_test_map_result : Try(Tilemap, TilemapBuildError)
offset_test_map_result = Tilemap.from_raw(test_raw)
	.with_origin(
		{ x: 100, y: 200 },
	)
	.object_role(
		"spawn",
		Spawn,
	)
	.build()

expect match test_map_result {
	Ok(test_map) =>
		test_map.layer_role_for(test_walls_layer) == Solid
			and test_map.object_role_for(test_spawn_object) == Spawn
				and test_map.world_rect_for_cell({ col: 2, row: 1 }) == Math.rect(32, 16, 16, 16)
					and test_map.gid_at("Walls", { col: 1, row: 0 }) == Ok(2)
						and test_map.solid_cell({ col: 1, row: 0 })
							and test_map.solid_at_world({ x: 20, y: 4 })
								and test_map.circle_touches_solid(Math.circle({ x: 24, y: 8 }, 7))
									and test_map.circle_touches_solid(Math.circle({ x: 8, y: 8 }, 8))
										and test_map.cell_at_world({ x: 34, y: 18 }) == Ok({ col: 2, row: 1 })
											and test_map.cell_at_world({ x: -0.01, y: 0 }) == Err(OutOfBounds)
												and test_map.cell_range_for_world_rect(Math.rect(15, 0, 18, 17)) == Ok({ min_col: 0, min_row: 0, max_col: 2, max_row: 1 })
	Err(_) => False
}
expect Tilemap.property_f32(test_raw, test_spawn_object, "speed", 0) == 12.5
expect match offset_test_map_result {
	Ok(offset_test_map) => offset_test_map.object_world_center(test_spawn_object) == { x: 108, y: 208 }
	Err(_) => False
}
expect Tilemap.clean_gid(2_147_483_648 + 17) == 17
expect Tilemap.flip_for_gid(2_147_483_648 + 1) == { horizontal: Bool.True, vertical: Bool.False, diagonal: Bool.False }
expect transformed_corner(Math.rect(10, 20, 30, 40), { x: 0, y: 0 }, { horizontal: Bool.False, vertical: Bool.False, diagonal: Bool.True }) == { x: 40, y: 60 }
expect match Tilemap.from_raw({ ..test_raw, tilesets: [test_tileset] }).build() {
	Err(MissingTilesetBinding(1)) => True
	_ => False
}
expect {
	settings : Camera.Settings
	settings = { target: Math.vec2(100, 50), offset: Math.vec2(20, 10), rotation: 0, zoom: 2 }
	result = Camera.new(settings)
	match result {
		Ok(camera) => Tilemap.viewport_for_camera(camera, { x: 80, y: 40 }) == Math.rect(90, 45, 40, 20)
		Err(_) => False
	}
}
expect {
	settings : Camera.Settings
	settings = { target: Math.zero, offset: Math.zero, rotation: 0, zoom: -2 }
	result = Camera.new(settings)
	match result {
		Ok(camera) => camera.viewport({ x: 80, y: 40 }) == Math.rect(-40, -20, 40, 20)
		Err(_) => False
	}
}
expect {
	result = Camera.follow({ x: 100, y: 200 }, { screen: { x: 800, y: 600 }, zoom: 2 })
	match result {
		Ok(camera) => Tilemap.viewport_for_camera(camera, { x: 800, y: 600 }) == Math.rect(-100, 50, 400, 300)
		Err(_) => False
	}
}
