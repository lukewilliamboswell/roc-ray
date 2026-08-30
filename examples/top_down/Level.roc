## Static arena data loaded from Tiled, with a complete fallback layout.
import rr.Color
import rr.Draw
import rr.Math
import rr.Tilemap
import Hazard
import Spark

Level := {
	tilemap : Tilemap,
	spawn : Math.Vec2,
	exit_center : Math.Vec2,
	exit_radius : F32,
	sparks : List(Spark),
	spark_total : U64,
	obstacles : List(Obstacle),
	hazards : List(Hazard),
	decorations : List(Decoration),
	bounds : Math.Rect,
}.{
	Tile := [
		TileFloor,
		TileBlockA,
		TileBlockB,
		TileMarker,
		TileRockA,
		TilePlantA,
		TilePlantB,
		TileFlowerA,
		TileFlowerB,
		TileCrystalA,
		TileCrystalB,
		TileSparkA,
		TileSparkB,
	]

	Decoration : { pos : Math.Vec2, tile : Tile, scale : F32, rotation : F32 }

	Obstacle := { rect : Math.Rect, tile : Tile, rotation : F32 }.{

		## Returns the obstacle center used to place its decoration.
		center : Obstacle -> Math.Vec2
		center = |obstacle| Math.center(obstacle.rect)

		## Reports whether a circle touches the solid obstacle.
		hit_by : Obstacle, Math.Circle -> Bool
		hit_by = |obstacle, circle| Math.circle_rect(circle, obstacle.rect)
	}

	## Loads the authored Tiled map and binds its visible layers to the tile texture.
	load! = |tiles| {
		raw_map = Tilemap.load_tmx!("examples/top_down/assets/top_down.tmx")?
		tilemap = Tilemap.from_raw(raw_map)
			.with_origin({ x: world_left, y: world_top })
			.with_tileset_texture(1, tiles)
			.layer_role("Ground", Drawn)
			.layer_role("Decor", Drawn)
			.layer_role("Walls", Solid)
			.object_role("spawn", Spawn)
			.object_role("spark", Collectible)
			.object_role("hazard", Hazard)
			.object_role("exit", Exit)
			.build()?
		Ok(from_tilemap(tilemap))
	}

}

world_left = -720.F32

world_top = -520.F32

world_right = 1456.F32

world_bottom = 1144.F32

fallback_spawn : Math.Vec2
fallback_spawn = { x: -560, y: -360 }

fallback_exit_center : Math.Vec2
fallback_exit_center = { x: 1185, y: 920 }

fallback_exit_radius = 58.F32

world_bounds : Math.Rect
world_bounds = Math.rect(world_left, world_top, world_right - world_left, world_bottom - world_top)

## Converts a configured Tiled map into immutable gameplay data.
from_tilemap : Tilemap -> Level
from_tilemap = |tilemap| {
	raw = tilemap.raw_map()
	spawn_object = first_typed_object(tilemap, "spawn")
	exit_object = first_typed_object(tilemap, "exit")
	sparks = sparks_from_tilemap(tilemap)
	{
		tilemap,
		spawn: object_center_or(tilemap, spawn_object, fallback_spawn),
		exit_center: object_center_or(tilemap, exit_object, fallback_exit_center),
		exit_radius: object_radius_or(exit_object, fallback_exit_radius),
		sparks,
		spark_total: List.len(sparks),
		obstacles: obstacles_from_tilemap(raw, tilemap),
		hazards: hazards_from_tilemap(raw, tilemap),
		decorations: decorations_from_tilemap(raw, tilemap),
		bounds: world_bounds,
	}
}

fallback_sparks : List(Spark)
fallback_sparks = [
	Spark.{ id: 0, pos: { x: -430, y: -150 } },
	Spark.{ id: 1, pos: { x: -55, y: -350 } },
	Spark.{ id: 2, pos: { x: 315, y: -295 } },
	Spark.{ id: 3, pos: { x: 760, y: -405 } },
	Spark.{ id: 4, pos: { x: 1110, y: -65 } },
	Spark.{ id: 5, pos: { x: 910, y: 350 } },
	Spark.{ id: 6, pos: { x: 560, y: 820 } },
	Spark.{ id: 7, pos: { x: 105, y: 640 } },
	Spark.{ id: 8, pos: { x: -280, y: 895 } },
	Spark.{ id: 9, pos: { x: -540, y: 410 } },
]

fallback_obstacles : List(Level.Obstacle)
fallback_obstacles = [
	Level.Obstacle.{ rect: Math.rect(-305, -300, 150, 440), tile: TileBlockA, rotation: 0 },
	Level.Obstacle.{ rect: Math.rect(85, -430, 150, 295), tile: TileBlockB, rotation: 11 },
	Level.Obstacle.{ rect: Math.rect(210, -45, 510, 120), tile: TileBlockA, rotation: 22 },
	Level.Obstacle.{ rect: Math.rect(705, 150, 140, 425), tile: TileBlockB, rotation: 33 },
	Level.Obstacle.{ rect: Math.rect(5, 505, 480, 115), tile: TileBlockA, rotation: 44 },
	Level.Obstacle.{ rect: Math.rect(-535, 515, 340, 105), tile: TileBlockB, rotation: 55 },
	Level.Obstacle.{ rect: Math.rect(965, -300, 145, 450), tile: TileBlockA, rotation: 66 },
]

fallback_hazards : List(Hazard)
fallback_hazards = [
	Hazard.{ center: { x: -445, y: 165 }, span: 520, lane: Horizontal, offset: 0, radius: 30, color: Color.from_hex_rgb(0xf94144) },
	Hazard.{ center: { x: 25, y: 320 }, span: 650, lane: Vertical, offset: 0.22, radius: 34, color: Color.from_hex_rgb(0xf3722c) },
	Hazard.{ center: { x: 600, y: -255 }, span: 650, lane: Horizontal, offset: 0.48, radius: 32, color: Color.from_hex_rgb(0xf8961e) },
	Hazard.{ center: { x: 1035, y: 455 }, span: 700, lane: Vertical, offset: 0.72, radius: 36, color: Color.from_hex_rgb(0xf94144) },
]

fallback_decorations : List(Level.Decoration)
fallback_decorations = [
	{ pos: { x: -640, y: 80 }, tile: TileCrystalA, scale: 1.35, rotation: 0 },
	{ pos: { x: -575, y: 585 }, tile: TileCrystalB, scale: 1.2, rotation: 0 },
	{ pos: { x: -85, y: -455 }, tile: TilePlantA, scale: 1.35, rotation: 0 },
	{ pos: { x: 190, y: 185 }, tile: TileMarker, scale: 1.15, rotation: 0 },
	{ pos: { x: 780, y: -210 }, tile: TileBlockA, scale: 1.1, rotation: 12 },
	{ pos: { x: 1110, y: 190 }, tile: TileRockA, scale: 1.45, rotation: 0 },
	{ pos: { x: 1035, y: 785 }, tile: TileBlockB, scale: 1.2, rotation: -14 },
	{ pos: { x: 315, y: 975 }, tile: TileFlowerA, scale: 1.05, rotation: 0 },
	{ pos: { x: -395, y: 960 }, tile: TileFlowerB, scale: 0.9, rotation: 0 },
	{ pos: { x: 1185, y: 735 }, tile: TileSparkA, scale: 0.7, rotation: 20 },
	{ pos: { x: 1280, y: -395 }, tile: TileSparkB, scale: 0.72, rotation: -18 },
	{ pos: { x: -615, y: -405 }, tile: TilePlantB, scale: 1.1, rotation: 0 },
]

## Finds the first map object with the requested authored type.
first_typed_object : Tilemap, Str -> Try(Tilemap.RawObject, [NotFound])
first_typed_object = |tilemap, type_name|
	match List.first(tilemap.objects_typed(type_name)) {
		Ok(object) => Ok(object)
		Err(_) => Err(NotFound)
	}

## Returns an object's world center or a supplied fallback position.
object_center_or : Tilemap, Try(Tilemap.RawObject, [NotFound]), Math.Vec2 -> Math.Vec2
object_center_or = |tilemap, object_result, fallback|
	match object_result {
		Ok(object) => tilemap.object_world_center(object)
		Err(_) => fallback
	}

## Returns an object's radius or a supplied fallback radius.
object_radius_or : Try(Tilemap.RawObject, [NotFound]), F32 -> F32
object_radius_or = |object_result, fallback|
	match object_result {
		Ok(object) => if object.width == 0 and object.height == 0 fallback else F32.max(object.width, object.height) * 0.5
		Err(_) => fallback
	}

## Reads collectible sparks from the map or uses the fallback route.
sparks_from_tilemap : Tilemap -> List(Spark)
sparks_from_tilemap = |tilemap| {
	var $sparks = []
	for object in tilemap.objects_typed("spark") {
		pos = tilemap.object_world_center(object)
		$sparks = List.append($sparks, Spark.{ id: object.id, pos })
	}
	if List.len($sparks) == 0 fallback_sparks else $sparks
}

## Reads solid obstacles from the map or uses the fallback arrangement.
obstacles_from_tilemap : Tilemap.RawMap, Tilemap -> List(Level.Obstacle)
obstacles_from_tilemap = |raw, tilemap| {
	var $items = []
	for object in tilemap.objects_typed("obstacle") {
		rect = tilemap.object_world_rect(object)
		tile = tile_from_name(Tilemap.property_str(raw, object, "tile", "TileBlockA"))
		rotation = Tilemap.property_f32(raw, object, "rotation", object.rotation)
		$items = List.append($items, Level.Obstacle.{ rect, tile, rotation })
	}
	if List.len($items) == 0 fallback_obstacles else $items
}

## Reads moving hazards from the map or uses the fallback lanes.
hazards_from_tilemap : Tilemap.RawMap, Tilemap -> List(Hazard)
hazards_from_tilemap = |raw, tilemap| {
	var $items = []
	for object in tilemap.objects_typed("hazard") {
		center = tilemap.object_world_center(object)
		lane = lane_from_name(Tilemap.property_str(raw, object, "lane", "Horizontal"))
		span = Tilemap.property_f32(raw, object, "span", 520)
		offset = Tilemap.property_f32(raw, object, "offset", 0)
		radius = Tilemap.property_f32(raw, object, "radius", 30)
		$items = List.append($items, Hazard.{ center, span, lane, offset, radius, color: hazard_color(object.id) })
	}
	if List.len($items) == 0 fallback_hazards else $items
}

## Reads decorative props from the map or uses the fallback scenery.
decorations_from_tilemap : Tilemap.RawMap, Tilemap -> List(Level.Decoration)
decorations_from_tilemap = |raw, tilemap| {
	var $items = []
	for object in tilemap.objects_typed("decoration") {
		$items = List.append(
			$items,
			{
				pos: tilemap.object_world_center(object),
				tile: tile_from_name(Tilemap.property_str(raw, object, "tile", "TilePlantA")),
				scale: Tilemap.property_f32(raw, object, "scale", 1),
				rotation: Tilemap.property_f32(raw, object, "rotation", object.rotation),
			},
		)
	}
	if List.len($items) == 0 fallback_decorations else $items
}

## Decodes an authored tile name into the renderable tile tag.
tile_from_name : Str -> Level.Tile
tile_from_name = |name|
	if name == "TileBlockB" {
		TileBlockB
	} else if name == "TileMarker" {
		TileMarker
	} else if name == "TileRockA" {
		TileRockA
	} else if name == "TilePlantA" {
		TilePlantA
	} else if name == "TilePlantB" {
		TilePlantB
	} else if name == "TileFlowerA" {
		TileFlowerA
	} else if name == "TileFlowerB" {
		TileFlowerB
	} else if name == "TileCrystalA" {
		TileCrystalA
	} else if name == "TileCrystalB" {
		TileCrystalB
	} else if name == "TileSparkA" {
		TileSparkA
	} else if name == "TileSparkB" {
		TileSparkB
	} else {
		TileBlockA
	}

## Decodes an authored lane name into a hazard lane.
lane_from_name : Str -> Hazard.Lane
lane_from_name = |name| if name == "Vertical" Vertical else Horizontal

## Chooses a hazard color deterministically from its map identifier.
hazard_color : U64 -> Color.Rgba
hazard_color = |id|
	match id % 4 {
		0 => Color.from_hex_rgb(0xf94144)
		1 => Color.from_hex_rgb(0xf3722c)
		2 => Color.from_hex_rgb(0xf8961e)
		_ => Color.from_hex_rgb(0xf94144)
	}

expect Level.Obstacle.{ rect: Math.rect(0, 0, 10, 10), tile: TileBlockA, rotation: 0 }.hit_by(Math.circle({ x: 5, y: 5 }, 1))
expect !(Level.Obstacle.{ rect: Math.rect(0, 0, 10, 10), tile: TileBlockA, rotation: 0 }.hit_by(Math.circle({ x: 30, y: 30 }, 1)))
