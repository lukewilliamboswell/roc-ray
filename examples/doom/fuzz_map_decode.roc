app [target] { fuzz: platform "../../../roc-fuzz/platform/main.roc" }

## Parser-robustness target: `DoomMap.decode` must return Ok or Err for any
## string, never crash or hang. Inputs are either arbitrary strings or a valid
## small map JSON with byte-level splices applied.

import fuzz.Fuzz
import DoomMap

valid_json : Str
valid_json = "{\"format\":\"doom\",\"map\":\"E1M1\",\"vertices\":[{\"x\":0,\"y\":0},{\"x\":64,\"y\":0},{\"x\":64,\"y\":64},{\"x\":0,\"y\":64}],\"linedefs\":[{\"start_vertex\":0,\"end_vertex\":1,\"flags\":1,\"special\":0,\"tag\":0,\"right_sidedef\":0,\"left_sidedef\":null},{\"start_vertex\":1,\"end_vertex\":2,\"flags\":4,\"special\":1,\"tag\":0,\"right_sidedef\":0,\"left_sidedef\":1}],\"sidedefs\":[{\"x_offset\":0,\"y_offset\":0,\"upper_texture\":null,\"lower_texture\":null,\"middle_texture\":\"STONE\",\"sector\":0},{\"x_offset\":8,\"y_offset\":-4,\"upper_texture\":\"UP\",\"lower_texture\":\"LO\",\"middle_texture\":null,\"sector\":1}],\"sectors\":[{\"floor_height\":0,\"ceiling_height\":128,\"floor_flat\":\"FLOOR\",\"ceiling_flat\":\"CEIL\",\"light_level\":160,\"special\":0,\"tag\":0},{\"floor_height\":16,\"ceiling_height\":96,\"floor_flat\":\"FLOOR\",\"ceiling_flat\":\"CEIL\",\"light_level\":128,\"special\":1,\"tag\":3}],\"things\":[{\"x\":16,\"y\":24,\"angle\":90,\"type\":1,\"flags\":7}],\"segs\":[{\"start_vertex\":0,\"end_vertex\":1,\"angle\":0,\"linedef\":0,\"direction\":0,\"offset\":0}],\"subsectors\":[{\"seg_count\":1,\"first_seg\":0}],\"nodes\":[{\"x\":0,\"y\":0,\"dx\":1,\"dy\":0,\"right_bbox\":{\"top\":64,\"bottom\":0,\"left\":0,\"right\":64},\"left_bbox\":{\"top\":64,\"bottom\":0,\"left\":0,\"right\":64},\"right_child\":{\"kind\":\"subsector\",\"index\":0},\"left_child\":{\"kind\":\"subsector\",\"index\":0}}],\"subsector_polygon_bounds\":{\"min_x\":0,\"min_y\":0,\"max_x\":64,\"max_y\":64},\"subsector_polygons\":[{\"subsector\":0,\"sector\":0,\"points\":[{\"x\":0,\"y\":0},{\"x\":64,\"y\":0},{\"x\":64,\"y\":64},{\"x\":0,\"y\":64}]}]}"

Splice : { position : U64, length : U8, replacement : List(U8) }

Input := { mode : U8, text : Str, splices : List(Splice) }.{
	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		splice_gen = { position: Fuzz.u64_in(0, 1600), length: Fuzz.u8_in(0, 12), replacement: Fuzz.list(Fuzz.u8, 12) }.Fuzz
		{ mode: Fuzz.u8, text: Fuzz.str, splices: Fuzz.list(splice_gen, 4) }.Fuzz
	}
}

apply_splice : List(U8), Splice -> List(U8)
apply_splice = |bytes, splice| {
	len = List.len(bytes)
	position = if len == 0 0 else splice.position % (len + 1)
	before = List.take_first(bytes, position)
	after = List.drop_first(bytes, position + U8.to_u64(splice.length))
	List.concat(List.concat(before, splice.replacement), after)
}

build_text : Input -> Str
build_text = |input| {
	if input.mode % 4 == 0 {
		input.text
	} else {
		var $bytes = Str.to_utf8(valid_json)
		for splice in input.splices {
			$bytes = apply_splice($bytes, splice)
		}
		Str.from_utf8_lossy($bytes)
	}
}

test : Input -> Fuzz.Outcome
test = |input| {
	text = build_text(input)
	match DoomMap.decode(text) {
		Ok(map) => {
			# A decoded map must also be safe to derive from.
			_ = map.wall_spans()
			_ = map.surface_polygons()
			_ = map.blocking_segments()
			_ = map.player_start()
			Fuzz.keep
		}
		Err(_) => Fuzz.keep
	}
}

target = Fuzz.target({
	name: "doom-map-decode",
	test,
	show: |input| build_text(input),
})
