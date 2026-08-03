## Internal TMX parser transport.
##
## This module is intentionally not exposed by the platform package.
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

	load_tmx! : Str => LoadResult
}
