## Internal TMX parser transport.
##
## This module is intentionally not exposed by the platform package.
import Assets

TilemapHost := [].{
	Property : {
		name : Str,
		kind : U8,
		text : Str,
		number : F32,
		integer : I64,
		bool_value : Bool,
	}

	Tileset : {
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

	TileProperties : { gid : U64, property_start : U64, property_count : U64 }

	Layer : {
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

	Point : { x : F32, y : F32 }

	Object : {
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

	Map : {
		width : U64,
		height : U64,
		tile_width : F32,
		tile_height : F32,
		map_property_start : U64,
		map_property_count : U64,
		tilesets : List(Tileset),
		tile_properties : List(TileProperties),
		layers : List(Layer),
		gids : List(U64),
		objects : List(Object),
		points : List(Point),
		properties : List(Property),
	}

	LoadResult : { ok : Bool, err : U8, map : Map }

	## Primitive layer metadata prepared once by `Tilemap.Builder.build` and
	## borrowed by the host for a complete batched draw operation.
	RenderLayer : {
		width : U64,
		height : U64,
		gid_start : U64,
		gid_count : U64,
		visible : Bool,
		role : U8,
	}

	## A resolved tileset. The surrounding list owns each texture while a draw
	## request is in flight, so the host can safely borrow its lifecycle token.
	RenderTileset : {
		first_gid : U64,
		tile_width : F32,
		tile_height : F32,
		columns : U64,
		texture : Assets.Texture,
	}

	## Borrowed flat render plan. Lists are built once with the Tilemap value and
	## shared across calls; constructing this record never constructs a List.
	RenderRequest : {
		gids : List(U64),
		layers : List(RenderLayer),
		tilesets : List(RenderTileset),
		origin_x : F32,
		origin_y : F32,
		map_tile_width : F32,
		map_tile_height : F32,
		selector_kind : U8,
		selector_value : U64,
		culled : Bool,
		min_col : U64,
		min_row : U64,
		max_col : U64,
		max_row : U64,
	}

	load_tmx! : Str => LoadResult
	draw! : RenderRequest => {}
}
