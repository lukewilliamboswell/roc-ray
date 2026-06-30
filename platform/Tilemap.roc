## Tilemap module - Tiled TMX data, tileset drawing, and grid queries.
import Assets
import Color
import Draw
import Math

TilemapRawProperty : {
	name : Str,
	kind : U8,
	text : Str,
	number : F32,
	integer : I64,
	bool_value : Bool,
}

TilemapRawTileset : {
	first_gid : U64,
	name : Str,
	tile_width : F32,
	tile_height : F32,
	tile_count : U64,
	columns : U64,
	image_source : Str,
	image_width : F32,
	image_height : F32,
	property_start : U64,
	property_count : U64,
}

TilemapRawTileProperties : {
	gid : U64,
	property_start : U64,
	property_count : U64,
}

TilemapRawLayer : {
	name : Str,
	width : U64,
	height : U64,
	gid_start : U64,
	gid_count : U64,
	property_start : U64,
	property_count : U64,
	visible : Bool,
	opacity : F32,
}

TilemapRawPoint : {
	x : F32,
	y : F32,
}

TilemapRawObject : {
	id : U64,
	name : Str,
	type_name : Str,
	x : F32,
	y : F32,
	width : F32,
	height : F32,
	rotation : F32,
	kind : U8,
	point_start : U64,
	point_count : U64,
	property_start : U64,
	property_count : U64,
}

TilemapRawMap : {
	width : U64,
	height : U64,
	tile_width : F32,
	tile_height : F32,
	map_property_start : U64,
	map_property_count : U64,
	tilesets : List(TilemapRawTileset),
	tile_properties : List(TilemapRawTileProperties),
	layers : List(TilemapRawLayer),
	gids : List(U64),
	objects : List(TilemapRawObject),
	points : List(TilemapRawPoint),
	properties : List(TilemapRawProperty),
}

TilemapLoadTmxRawResult : {
	ok : Bool,
	err : U8,
	map : TilemapRawMap,
}

TilemapTextureBinding : {
	first_gid : U64,
	texture : Assets.Texture,
}

TilemapLayerRole := [Drawn, Solid, Hidden]

TilemapObjectRole := [Spawn, Collectible, Hazard, Goal, Checkpoint, Decoration, Exit, Unknown]

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

TilemapBuilder :: {
	raw : TilemapRawMap,
	textures : List(TilemapTextureBinding),
	layer_roles : List(TilemapLayerRoleRule),
	object_roles : List(TilemapObjectRoleRule),
	origin : Math.Vec2,
}.{
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

	build : TilemapBuilder -> Tilemap
	build = |builder| {
		raw: builder.raw,
		textures: builder.textures,
		layer_roles: builder.layer_roles,
		object_roles: builder.object_roles,
		origin: builder.origin,
	}
}

Tilemap :: {
	raw : TilemapRawMap,
	textures : List(TilemapTextureBinding),
	layer_roles : List(TilemapLayerRoleRule),
	object_roles : List(TilemapObjectRoleRule),
	origin : Math.Vec2,
}.{

	RawMap : TilemapRawMap
	RawLayer : TilemapRawLayer
	RawObject : TilemapRawObject
	RawProperty : TilemapRawProperty
	RawTileset : TilemapRawTileset
	RawPoint : TilemapRawPoint
	Cell : TilemapCell
	LayerRole : TilemapLayerRole
	ObjectRole : TilemapObjectRole
	LoadTmxRawResult : TilemapLoadTmxRawResult
	Builder : TilemapBuilder

	err_not_found : U8
	err_not_found = 1

	err_read_failed : U8
	err_read_failed = 2

	err_parse_failed : U8
	err_parse_failed = 3

	err_unsupported : U8
	err_unsupported = 4

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

	load_tmx_raw! : Str => TilemapLoadTmxRawResult

	load_tmx! : Str => Try(TilemapRawMap, [NotFound, ReadFailed, ParseFailed, Unsupported, ..])
	load_tmx! = |path| {
		result = Tilemap.load_tmx_raw!(path)
		if result.ok {
			Ok(result.map)
		} else if result.err == Tilemap.err_not_found {
			Err(NotFound)
		} else if result.err == Tilemap.err_read_failed {
			Err(ReadFailed)
		} else if result.err == Tilemap.err_unsupported {
			Err(Unsupported)
		} else {
			Err(ParseFailed)
		}
	}

	from_raw : TilemapRawMap -> TilemapBuilder
	from_raw = |raw| {
		raw,
		textures: [],
		layer_roles: [],
		object_roles: [],
		origin: Math.zero,
	}

	raw_map : Tilemap -> TilemapRawMap
	raw_map = |map| map.raw

	layer_role_for : Tilemap, TilemapRawLayer -> TilemapLayerRole
	layer_role_for = |map, layer| {
		var $role = Drawn
		for rule in map.layer_roles {
			if rule.name == layer.name {
				$role = rule.role
			}
		}
		$role
	}

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

	objects : Tilemap -> List(TilemapRawObject)
	objects = |map| map.raw.objects

	objects_named : Tilemap, Str -> List(TilemapRawObject)
	objects_named = |map, name| List.keep_if(map.raw.objects, |object| object.name == name)

	objects_typed : Tilemap, Str -> List(TilemapRawObject)
	objects_typed = |map, type_name| List.keep_if(map.raw.objects, |object| object.type_name == type_name)

	objects_with_role : Tilemap, TilemapObjectRole -> List(TilemapRawObject)
	objects_with_role = |map, role| List.keep_if(map.raw.objects, |object| Tilemap.object_role_for(map, object) == role)

	first_object : Tilemap, TilemapObjectRole -> Try(TilemapRawObject, [NotFound])
	first_object = |map, role|
		match List.first(Tilemap.objects_with_role(map, role)) {
			Ok(object) => Ok(object)
			Err(_) => Err(NotFound)
		}

	object_center : TilemapRawObject -> Math.Vec2
	object_center = |object| {
		if object.width == 0 and object.height == 0 {
			{ x: object.x, y: object.y }
		} else {
			{ x: object.x + object.width * 0.5, y: object.y + object.height * 0.5 }
		}
	}

	object_rect : TilemapRawObject -> Math.Rect
	object_rect = |object| Math.rect(object.x, object.y, object.width, object.height)

	object_circle : TilemapRawObject -> Math.Circle
	object_circle = |object| Math.circle(Tilemap.object_center(object), F32.max(object.width, object.height) * 0.5)

	object_world_center : Tilemap, TilemapRawObject -> Math.Vec2
	object_world_center = |map, object| Math.add(map.origin, Tilemap.object_center(object))

	object_world_rect : Tilemap, TilemapRawObject -> Math.Rect
	object_world_rect = |map, object| Math.rect(map.origin.x + object.x, map.origin.y + object.y, object.width, object.height)

	object_world_circle : Tilemap, TilemapRawObject -> Math.Circle
	object_world_circle = |map, object| Math.circle(Tilemap.object_world_center(map, object), F32.max(object.width, object.height) * 0.5)

	property_named : TilemapRawMap, U64, U64, Str -> Try(TilemapRawProperty, [NotFound])
	property_named = |raw, start, count, name| {
		property_named_at(raw, start, count, name, 0)
	}

	object_property : TilemapRawMap, TilemapRawObject, Str -> Try(TilemapRawProperty, [NotFound])
	object_property = |raw, object, name| Tilemap.property_named(raw, object.property_start, object.property_count, name)

	layer_property : TilemapRawMap, TilemapRawLayer, Str -> Try(TilemapRawProperty, [NotFound])
	layer_property = |raw, layer, name| Tilemap.property_named(raw, layer.property_start, layer.property_count, name)

	property_str : TilemapRawMap, TilemapRawObject, Str, Str -> Str
	property_str = |raw, object, name, default|
		match Tilemap.object_property(raw, object, name) {
			Ok(property) => property.text
			Err(_) => default
		}

	property_f32 : TilemapRawMap, TilemapRawObject, Str, F32 -> F32
	property_f32 = |raw, object, name, default|
		match Tilemap.object_property(raw, object, name) {
			Ok(property) => property.number
			Err(_) => default
		}

	property_i64 : TilemapRawMap, TilemapRawObject, Str, I64 -> I64
	property_i64 = |raw, object, name, default|
		match Tilemap.object_property(raw, object, name) {
			Ok(property) => property.integer
			Err(_) => default
		}

	property_bool : TilemapRawMap, TilemapRawObject, Str, Bool -> Bool
	property_bool = |raw, object, name, default|
		match Tilemap.object_property(raw, object, name) {
			Ok(property) => property.bool_value
			Err(_) => default
		}

	cell_at_world : Tilemap, Math.Vec2 -> Try(TilemapCell, [OutOfBounds])
	cell_at_world = |map, pos| cell_at_world_row(map, pos, 0)

	world_rect_for_cell : Tilemap, TilemapCell -> Math.Rect
	world_rect_for_cell = |map, cell| {
		x: map.origin.x + U64.to_f32(cell.col) * map.raw.tile_width,
		y: map.origin.y + U64.to_f32(cell.row) * map.raw.tile_height,
		width: map.raw.tile_width,
		height: map.raw.tile_height,
	}

	gid_at : Tilemap, Str, TilemapCell -> Try(U64, [NotFound, OutOfBounds])
	gid_at = |map, layer_name, cell|
		match find_layer(map.raw.layers, layer_name) {
			Ok(layer) => gid_at_layer(map.raw, layer, cell)
			Err(_) => Err(NotFound)
		}

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

	solid_at_world : Tilemap, Math.Vec2 -> Bool
	solid_at_world = |map, pos|
		match Tilemap.cell_at_world(map, pos) {
			Ok(cell) => Tilemap.solid_cell(map, cell)
			Err(_) => Bool.False
		}

	circle_touches_solid : Tilemap, Math.Circle -> Bool
	circle_touches_solid = |map, circle| circle_touches_solid_row(map, circle, 0)

	draw_layer! : Tilemap, Str => {}
	draw_layer! = |map, layer_name| {
		match find_layer(map.raw.layers, layer_name) {
			Ok(layer) => draw_layer_cells!(map, layer, 0)
			Err(_) => {}
		}
	}

	draw_layers! : Tilemap, TilemapLayerRole => {}
	draw_layers! = |map, role| {
		for layer in map.raw.layers {
			if Tilemap.layer_role_for(map, layer) == role {
				draw_layer_cells!(map, layer, 0)
			}
		}
	}

	draw_all! : Tilemap => {}
	draw_all! = |map| {
		for layer in map.raw.layers {
			role = Tilemap.layer_role_for(map, layer)
			if role == Drawn or role == Solid {
				draw_layer_cells!(map, layer, 0)
			}
		}
	}

	clean_gid : U64 -> U64
	clean_gid = |gid| {
		without_h = if gid >= 2_147_483_648 gid - 2_147_483_648 else gid
		without_v = if without_h >= 1_073_741_824 without_h - 1_073_741_824 else without_h
		without_d = if without_v >= 536_870_912 without_v - 536_870_912 else without_v
		if without_d >= 268_435_456 without_d - 268_435_456 else without_d
	}
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

cell_at_world_row : Tilemap, Math.Vec2, U64 -> Try(TilemapCell, [OutOfBounds])
cell_at_world_row = |map, pos, row| {
	if row >= map.raw.height {
		Err(OutOfBounds)
	} else {
		match cell_at_world_col(map, pos, row, 0) {
			Ok(cell) => Ok(cell)
			Err(_) => cell_at_world_row(map, pos, row + 1)
		}
	}
}

cell_at_world_col : Tilemap, Math.Vec2, U64, U64 -> Try(TilemapCell, [OutOfBounds])
cell_at_world_col = |map, pos, row, col| {
	if col >= map.raw.width {
		Err(OutOfBounds)
	} else {
		cell = { col, row }
		if Math.contains(Tilemap.world_rect_for_cell(map, cell), pos) {
			Ok(cell)
		} else {
			cell_at_world_col(map, pos, row, col + 1)
		}
	}
}

circle_touches_solid_row : Tilemap, Math.Circle, U64 -> Bool
circle_touches_solid_row = |map, circle, row| {
	if row >= map.raw.height {
		Bool.False
	} else if circle_touches_solid_col(map, circle, row, 0) {
		Bool.True
	} else {
		circle_touches_solid_row(map, circle, row + 1)
	}
}

circle_touches_solid_col : Tilemap, Math.Circle, U64, U64 -> Bool
circle_touches_solid_col = |map, circle, row, col| {
	if col >= map.raw.width {
		Bool.False
	} else {
		cell = { col, row }
		if Tilemap.solid_cell(map, cell) and Math.circle_rect(circle, Tilemap.world_rect_for_cell(map, cell)) {
			Bool.True
		} else {
			circle_touches_solid_col(map, circle, row, col + 1)
		}
	}
}

draw_layer_cells! : Tilemap, TilemapRawLayer, U64 => {}
draw_layer_cells! = |map, layer, index| {
	if index >= layer.gid_count or !(layer.visible) {
		{}
	} else {
		match List.get(map.raw.gids, layer.gid_start + index) {
			Ok(raw_gid) => {
				gid = Tilemap.clean_gid(raw_gid)
				if gid != 0 {
					cell = { col: index % layer.width, row: index // layer.width }
					draw_gid!(map, gid, cell)
				}
			}
			Err(_) => {}
		}
		draw_layer_cells!(map, layer, index + 1)
	}
}

draw_gid! : Tilemap, U64, TilemapCell => {}
draw_gid! = |map, gid, cell| {
	match find_tileset(map.raw.tilesets, gid) {
		Ok(tileset) =>
			match find_texture(map.textures, tileset.first_gid) {
				Ok(texture) => {
					local = gid - tileset.first_gid
					columns = if tileset.columns == 0 1 else tileset.columns
					source = {
						x: U64.to_f32(local % columns) * tileset.tile_width,
						y: U64.to_f32(local // columns) * tileset.tile_height,
						width: tileset.tile_width,
						height: tileset.tile_height,
					}
					Draw.texture!(
						{
							texture,
							source,
							dest: Tilemap.world_rect_for_cell(map, cell),
							origin: Math.zero,
							rotation: 0,
							tint: Color.white,
						},
					)
				}
				Err(_) => {}
			}
		Err(_) => {}
	}
}

find_tileset : List(TilemapRawTileset), U64 -> Try(TilemapRawTileset, [NotFound])
find_tileset = |tilesets, gid| {
	var $found = Err(NotFound)
	for tileset in tilesets {
		if gid >= tileset.first_gid {
			$found = Ok(tileset)
		}
	}
	$found
}

find_texture : List(TilemapTextureBinding), U64 -> Try(Assets.Texture, [NotFound])
find_texture = |textures, first_gid| {
	var $found = Err(NotFound)
	for binding in textures {
		if binding.first_gid == first_gid {
			$found = Ok(binding.texture)
		}
	}
	$found
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
	tilesets: [test_tileset],
	tile_properties: [],
	layers: [test_ground_layer, test_walls_layer],
	gids: [1, 1, 1, 1, 1, 1, 0, 2, 0, 0, 0, 0],
	objects: [test_spawn_object],
	points: [],
	properties: [test_speed_property],
}

test_map : Tilemap
test_map = Tilemap.from_raw(test_raw)
	.layer_role(
		"Walls",
		Solid,
	)
	.object_role(
		"spawn",
		Spawn,
	)
	.build()

offset_test_map : Tilemap
offset_test_map = Tilemap.from_raw(test_raw)
	.with_origin(
		{ x: 100, y: 200 },
	)
	.object_role(
		"spawn",
		Spawn,
	)
	.build()

expect Tilemap.layer_role_for(test_map, test_walls_layer) == Solid
expect Tilemap.object_role_for(test_map, test_spawn_object) == Spawn
expect Tilemap.world_rect_for_cell(test_map, { col: 2, row: 1 }) == Math.rect(32, 16, 16, 16)
expect Tilemap.gid_at(test_map, "Walls", { col: 1, row: 0 }) == Ok(2)
expect Tilemap.solid_cell(test_map, { col: 1, row: 0 })
expect Tilemap.solid_at_world(test_map, { x: 20, y: 4 })
expect Tilemap.circle_touches_solid(test_map, Math.circle({ x: 24, y: 8 }, 7))
expect Tilemap.cell_at_world(test_map, { x: 34, y: 18 }) == Ok({ col: 2, row: 1 })
expect Tilemap.property_f32(test_raw, test_spawn_object, "speed", 0) == 12.5
expect Tilemap.object_world_center(offset_test_map, test_spawn_object) == { x: 108, y: 208 }
expect Tilemap.clean_gid(2_147_483_648 + 17) == 17
