## Pure decoding and render/collision derivation for a deterministic Doom
## map-lump export. Flat polygons come from validated BSP subsector seg loops;
## sector linedefs alone are not sufficient because sectors may be concave or
## contain holes.

import "assets/freedoom/generated/e1m1/map.json" as e1m1_json : Str

DoomMap := [].{
	Vertex : { x : I64, y : I64 }
	Linedef : { start_vertex : U64, end_vertex : U64, flags : U64, special : U64, tag : U64, right_sidedef : Try(U64, [Null]), left_sidedef : Try(U64, [Null]) }
	Sidedef : { x_offset : I64, y_offset : I64, upper_texture : Try(Str, [Null]), lower_texture : Try(Str, [Null]), middle_texture : Try(Str, [Null]), sector : U64 }
	Sector : { floor_height : I64, ceiling_height : I64, floor_flat : Str, ceiling_flat : Str, light_level : I64, special : U64, tag : U64 }
	Thing : { x : I64, y : I64, angle : I64, type : U64, flags : U64 }
	Seg : { start_vertex : U64, end_vertex : U64, angle : U64, linedef : U64, direction : U64, offset : U64 }
	Subsector : { seg_count : U64, first_seg : U64 }
	BBox : { top : I64, bottom : I64, left : I64, right : I64 }
	Child : { kind : Str, index : U64 }
	Node : { x : I64, y : I64, dx : I64, dy : I64, right_bbox : BBox, left_bbox : BBox, right_child : Child, left_child : Child }
	SurfacePoint : { x : F64, y : F64 }
	SubsectorPolygon : { subsector : U64, sector : U64, points : List(SurfacePoint) }
	PolygonBounds : { min_x : F64, min_y : F64, max_x : F64, max_y : F64 }

	Raw : { format : Str, map : Str, vertices : List(Vertex), linedefs : List(Linedef), sidedefs : List(Sidedef), sectors : List(Sector), things : List(Thing), segs : List(Seg), subsectors : List(Subsector), nodes : List(Node), subsector_polygon_bounds : PolygonBounds, subsector_polygons : List(SubsectorPolygon) }

	Side := [Right, Left].{
		is_eq : _
	}
	WallKind := [Middle, Upper, Lower].{
		is_eq : _
	}
	LineFlags : {
		blocks_players : Bool,
		blocks_monsters : Bool,
		two_sided : Bool,
		upper_unpegged : Bool,
		lower_unpegged : Bool,
		secret : Bool,
		blocks_sound : Bool,
		hidden_on_map : Bool,
		shown_on_map : Bool,
	}
	Special : [NoSpecial, Special({ number : U64, tag : U64 })]
	SurfaceOrientation := [Floor, Ceiling].{
		is_eq : _
	}

	## The world-height edge to which texture row zero is pegged. `BottomAt`
	## requires the renderer to add the decoded texture height before applying
	## the sidedef's vertical offset.
	VerticalPeg := [TopAt(I64), BottomAt(I64)].{
		is_eq : _
	}
	SurfacePolygon : { subsector : U64, sector : U64, orientation : SurfaceOrientation, vertices : List(SurfacePoint), height : I64, flat : Str, light_level : I64 }
	SectorHeights : { floor : I64, ceiling : I64 }
	BlockingSegment : { linedef : U64, start : Vertex, end : Vertex, flags : LineFlags, special : Special }
	PlayerStart : { position : Vertex, angle : I64, flags : U64 }
	WallSpan : {
		linedef : U64,
		side : Side,
		kind : WallKind,
		start : Vertex,
		end : Vertex,
		bottom : I64,
		top : I64,
		texture : Str,
		x_offset : I64,
		y_offset : I64,
		vertical_peg : VerticalPeg,
		sector : U64,
		light_level : I64,
		flags : LineFlags,
		special : Special,
	}

	Map :: Raw.{
		raw : Map -> Raw
		raw = |Map.(value)| value

		wall_spans : Map -> List(WallSpan)
		wall_spans = |Map.(value)| derive_all_spans(value)

		## Re-derive spans from application-owned moving sector heights. The list
		## must preserve the validated map's sector order and cardinality.
		wall_spans_at : Map, List(SectorHeights) -> List(WallSpan)
		wall_spans_at = |Map.(value), heights| if List.len(heights) != List.len(value.sectors) crash "sector height count mismatch" else derive_all_spans({ ..value, sectors: resolve_sector_heights(value.sectors, heights, 0, []) })

		surface_polygons : Map -> List(SurfacePolygon)
		surface_polygons = |Map.(value)| derive_surfaces(value, 0)

		blocking_segments : Map -> List(BlockingSegment)
		blocking_segments = |Map.(value)| derive_blocking_segments(value, 0)

		player_start : Map -> Try(PlayerStart, [PlayerStartMissing, MultiplePlayerStarts])
		player_start = |Map.(value)| find_player_start(value.things, 0, Err(PlayerStartMissing))
	}

	## Decode the asset pipeline's deterministic `map.json`, then validate every
	## cross-lump index and structural invariant used by the derived helpers.
	decode = |text|
		match Json.parse(text) {
			Ok(raw) => validate(raw)
			Err(_) => Err(InvalidJson)
		}

	## The generated E1M1 asset is imported and decoded once here. Consumers
	## should use this nominal value instead of importing or parsing map.json.
	e1m1 : Map
	e1m1 = decode(e1m1_json) ?? crash "generated E1M1 map failed validation"

	## Validate an already-decoded fixture or generated value.
	validate = |raw| {
		if raw.format != "doom" {
			Err(InvalidFormat(raw.format))
		} else if Str.is_empty(raw.map) {
			Err(EmptyMapName)
		} else {
			validate_linedefs(raw, 0)?
			validate_sidedefs(raw, 0)?
			validate_sectors(raw.sectors, 0)?
			validate_things(raw.things, 0)?
			validate_segs(raw, 0)?
			validate_subsectors(raw, 0)?
			validate_nodes(raw, 0)?
			validate_polygons(raw, 0, [])?
			Ok(Map.(raw))
		}
	}

	## Decode the stable meanings of the original Doom linedef flag bits.
	line_flags : U64 -> LineFlags
	line_flags = |flags| {
		blocks_players: bit_set(flags, 0x0001),
		blocks_monsters: bit_set(flags, 0x0002),
		two_sided: bit_set(flags, 0x0004),
		upper_unpegged: bit_set(flags, 0x0008),
		lower_unpegged: bit_set(flags, 0x0010),
		secret: bit_set(flags, 0x0020),
		blocks_sound: bit_set(flags, 0x0040),
		hidden_on_map: bit_set(flags, 0x0080),
		shown_on_map: bit_set(flags, 0x0100),
	}
}

bit_set : U64, U64 -> Bool
bit_set = |value, mask| U64.bitwise_and(value, mask) != 0

validate_linedefs = |raw, index|
	match List.get(raw.linedefs, index) {
		Err(_) => Ok({})
		Ok(line) => {
			if line.start_vertex >= List.len(raw.vertices) Err(VertexOutOfRange({ linedef: index, vertex: line.start_vertex })) else if line.end_vertex >= List.len(raw.vertices) Err(VertexOutOfRange({ linedef: index, vertex: line.end_vertex })) else if line.start_vertex == line.end_vertex Err(DegenerateLinedef(index)) else {
				validate_side_ref(line.right_sidedef, raw.sidedefs, index, Bool.True)?
				validate_side_ref(line.left_sidedef, raw.sidedefs, index, Bool.False)?
				has_left = match line.left_sidedef {
					Ok(_) => Bool.True
					Err(Null) => Bool.False
				}
				if bit_set(line.flags, 0x0004) != has_left Err(TwoSidedMismatch(index)) else validate_linedefs(raw, index + 1)
			}
		}
	}

validate_side_ref = |side, sidedefs, linedef, required|
	match side {
		Err(Null) => if required Err(MissingRightSidedef(linedef)) else Ok({})
		Ok(index) => if index >= List.len(sidedefs) Err(SidedefOutOfRange({ linedef, sidedef: index })) else Ok({})
	}

validate_sidedefs = |raw, index|
	match List.get(raw.sidedefs, index) {
		Err(_) => Ok({})
		Ok(side) => if side.sector >= List.len(raw.sectors) Err(SectorOutOfRange({ sidedef: index, sector: side.sector })) else validate_sidedefs(raw, index + 1)
	}

validate_sectors = |sectors, index|
	match List.get(sectors, index) {
		Err(_) => Ok({})
		Ok(sector) => if sector.light_level < 0 or sector.light_level > 255 Err(InvalidLight({ sector: index, light: sector.light_level })) else validate_sectors(sectors, index + 1)
	}

validate_things = |things, index|
	match List.get(things, index) {
		Err(_) => Ok({})
		Ok(thing) => if thing.angle < 0 or thing.angle >= 360 Err(InvalidThingAngle({ thing: index, angle: thing.angle })) else validate_things(things, index + 1)
	}

validate_segs = |raw, index|
	match List.get(raw.segs, index) {
		Err(_) => Ok({})
		Ok(seg) => if seg.start_vertex >= List.len(raw.vertices) Err(SegVertexOutOfRange({ seg: index, vertex: seg.start_vertex })) else if seg.end_vertex >= List.len(raw.vertices) Err(SegVertexOutOfRange({ seg: index, vertex: seg.end_vertex })) else if seg.start_vertex == seg.end_vertex Err(DegenerateSeg(index)) else if seg.linedef >= List.len(raw.linedefs) Err(SegLinedefOutOfRange({ seg: index, linedef: seg.linedef })) else if seg.direction > 1 Err(InvalidSegDirection({ seg: index, direction: seg.direction })) else validate_segs(raw, index + 1)
	}

validate_subsectors = |raw, index|
	match List.get(raw.subsectors, index) {
		Err(_) => Ok({})
		Ok(subsector) => {
			seg_len = List.len(raw.segs)
			if subsector.seg_count == 0 Err(EmptySubsector(index)) else if subsector.first_seg > seg_len or subsector.seg_count > seg_len - subsector.first_seg Err(SubsectorSegRange(index)) else validate_subsectors(raw, index + 1)
		}
	}

validate_polygons = |raw, index, seen|
	match List.get(raw.subsector_polygons, index) {
		Err(_) => if List.len(seen) == List.len(raw.subsectors) Ok({}) else Err(MissingSubsectorPolygon(List.len(seen)))
		Ok(polygon) => if polygon.subsector >= List.len(raw.subsectors) Err(PolygonSubsectorOutOfRange(polygon.subsector)) else if polygon.sector >= List.len(raw.sectors) Err(PolygonSectorOutOfRange({ subsector: polygon.subsector, sector: polygon.sector })) else if List.contains(seen, polygon.subsector) Err(DuplicateSubsectorPolygon(polygon.subsector)) else if List.len(polygon.points) < 3 or signed_area(polygon.points) <= 0 or !polygon_is_convex(polygon.points, 0) Err(InvalidSubsectorPolygon(polygon.subsector)) else validate_polygons(raw, index + 1, List.prepend(seen, polygon.subsector))
	}

validate_nodes = |raw, index|
	match List.get(raw.nodes, index) {
		Err(_) => Ok({})
		Ok(node) => {
			validate_child(raw, index, node.right_child)?
			validate_child(raw, index, node.left_child)?
			validate_nodes(raw, index + 1)
		}
	}

validate_child = |raw, node_index, child|
	if child.kind == "node" {
		if child.index >= List.len(raw.nodes) Err(NodeChildOutOfRange({ node: node_index, kind: child.kind, index: child.index })) else Ok({})
	} else if child.kind == "subsector" {
		if child.index >= List.len(raw.subsectors) Err(NodeChildOutOfRange({ node: node_index, kind: child.kind, index: child.index })) else Ok({})
	} else Err(InvalidNodeChildKind({ node: node_index, kind: child.kind }))

derive_surfaces = |raw, index|
	match List.get(raw.subsector_polygons, index) {
		Err(_) => []
		Ok(polygon) => {
			sector = List.get(raw.sectors, polygon.sector) ?? crash "validated polygon sector missing"
			ceiling_points = reverse_list(polygon.points, [])
			polygons = [
				{ subsector: polygon.subsector, sector: polygon.sector, orientation: Floor, vertices: polygon.points, height: sector.floor_height, flat: sector.floor_flat, light_level: sector.light_level },
				{ subsector: polygon.subsector, sector: polygon.sector, orientation: Ceiling, vertices: ceiling_points, height: sector.ceiling_height, flat: sector.ceiling_flat, light_level: sector.light_level },
			]
			List.concat(polygons, derive_surfaces(raw, index + 1))
		}
	}

signed_area = |points| signed_area_from(points, 0)

signed_area_from = |points, index|
	if index >= List.len(points) 0 else {
		next_index = (index + 1) % List.len(points)
		a = List.get(points, index) ?? crash "polygon point missing"
		b = List.get(points, next_index) ?? crash "polygon point missing"
		a.x * b.y - a.y * b.x + signed_area_from(points, index + 1)
	}

polygon_is_convex = |points, index|
	if index >= List.len(points) Bool.True else {
		a = List.get(points, index) ?? crash "polygon point missing"
		b = List.get(points, (index + 1) % List.len(points)) ?? crash "polygon point missing"
		c = List.get(points, (index + 2) % List.len(points)) ?? crash "polygon point missing"
		cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
		cross > 0 and polygon_is_convex(points, index + 1)
	}

reverse_list = |remaining, reversed|
	match remaining {
		[] => reversed
		[first, .. as rest] => reverse_list(rest, List.prepend(reversed, first))
	}

derive_blocking_segments = |raw, index|
	match List.get(raw.linedefs, index) {
		Err(_) => []
		Ok(line) => {
			flags = DoomMap.line_flags(line.flags)
			rest = derive_blocking_segments(raw, index + 1)
			if flags.blocks_players or line.left_sidedef == Err(Null) {
				start = List.get(raw.vertices, line.start_vertex) ?? crash "validated vertex missing"
				end = List.get(raw.vertices, line.end_vertex) ?? crash "validated vertex missing"
				special = if line.special == 0 NoSpecial else Special({ number: line.special, tag: line.tag })
				List.prepend(rest, { linedef: index, start, end, flags, special })
			} else rest
		}
	}

find_player_start = |things, index, found|
	match List.get(things, index) {
		Err(_) => found
		Ok(thing) => if thing.type != 1 find_player_start(things, index + 1, found) else {
			start = { position: { x: thing.x, y: thing.y }, angle: thing.angle, flags: thing.flags }
			match found {
				Err(PlayerStartMissing) => find_player_start(things, index + 1, Ok(start))
				Ok(_) => Err(MultiplePlayerStarts)
				Err(MultiplePlayerStarts) => Err(MultiplePlayerStarts)
			}
		}
	}

derive_all_spans = |raw| derive_spans_from(raw, 0)

resolve_sector_heights = |sectors, heights, index, resolved|
	match List.get(sectors, index) {
		Err(_) => resolved
		Ok(sector) => {
			height = List.get(heights, index) ?? crash "sector height cardinality checked"
			resolve_sector_heights(sectors, heights, index + 1, List.append(resolved, { ..sector, floor_height: height.floor, ceiling_height: height.ceiling }))
		}
	}

derive_spans_from = |raw, index|
	match List.get(raw.linedefs, index) {
		Err(_) => []
		Ok(line) => List.concat(derive_line_spans(raw, line, index), derive_spans_from(raw, index + 1))
	}

derive_line_spans = |raw, line, index| {
	right = side_spans(raw, line, index, Right, line.right_sidedef, line.left_sidedef)
	left = side_spans(raw, line, index, Left, line.left_sidedef, line.right_sidedef)
	List.concat(right, left)
}

# A two-sided middle texture occupies the portal opening geometrically. Exact
# Doom pegging/cropping additionally depends on decoded texture dimensions;
# this span deliberately preserves offsets and heights rather than guessing it.
side_spans = |raw, line, line_index, side_name, own_ref, other_ref|
	match own_ref {
		Err(Null) => []
		Ok(own_index) => {
			own = List.get(raw.sidedefs, own_index) ?? crash "validated sidedef missing"
			sector = List.get(raw.sectors, own.sector) ?? crash "validated sector missing"
			raw_start = List.get(raw.vertices, line.start_vertex) ?? crash "validated vertex missing"
			raw_end = List.get(raw.vertices, line.end_vertex) ?? crash "validated vertex missing"
			start = if side_name == Right raw_start else raw_end
			end = if side_name == Right raw_end else raw_start
			common : SpanCommon
			common = { linedef: line_index, side: side_name, start, end, x_offset: own.x_offset, y_offset: own.y_offset, sector: own.sector, light_level: sector.light_level, flags: DoomMap.line_flags(line.flags), special: if line.special == 0 NoSpecial else Special({ number: line.special, tag: line.tag }) }
			match other_ref {
				Err(Null) => {
					peg = if common.flags.lower_unpegged BottomAt(sector.floor_height) else TopAt(sector.ceiling_height)
					texture_span(own.middle_texture, common, Middle, sector.floor_height, sector.ceiling_height, peg)
				}
				Ok(other_index) => {
					other = List.get(raw.sidedefs, other_index) ?? crash "validated sidedef missing"
					other_sector = List.get(raw.sectors, other.sector) ?? crash "validated sector missing"
					upper_peg = if common.flags.upper_unpegged TopAt(sector.ceiling_height) else BottomAt(other_sector.ceiling_height)
					lower_peg = if common.flags.lower_unpegged TopAt(sector.ceiling_height) else TopAt(other_sector.floor_height)
					upper = if sector.ceiling_height > other_sector.ceiling_height texture_span(own.upper_texture, common, Upper, other_sector.ceiling_height, sector.ceiling_height, upper_peg) else []
					lower = if sector.floor_height < other_sector.floor_height texture_span(own.lower_texture, common, Lower, sector.floor_height, other_sector.floor_height, lower_peg) else []
					opening_bottom = I64.max(sector.floor_height, other_sector.floor_height)
					opening_top = I64.min(sector.ceiling_height, other_sector.ceiling_height)
					middle_peg = if common.flags.lower_unpegged BottomAt(opening_bottom) else TopAt(opening_top)
					middle = if opening_top > opening_bottom texture_span(own.middle_texture, common, Middle, opening_bottom, opening_top, middle_peg) else []
					List.concat(List.concat(lower, middle), upper)
				}
			}
		}
	}

SpanCommon : { linedef : U64, side : DoomMap.Side, start : DoomMap.Vertex, end : DoomMap.Vertex, x_offset : I64, y_offset : I64, sector : U64, light_level : I64, flags : DoomMap.LineFlags, special : DoomMap.Special }

texture_span : Try(Str, [Null]), SpanCommon, DoomMap.WallKind, I64, I64, DoomMap.VerticalPeg -> List(DoomMap.WallSpan)
texture_span = |texture, common, kind, bottom, top, vertical_peg|
	match texture {
		Err(Null) => []
		Ok(name) => if top <= bottom [] else [{ linedef: common.linedef, side: common.side, kind, start: common.start, end: common.end, bottom, top, texture: name, x_offset: common.x_offset, y_offset: common.y_offset, vertical_peg, sector: common.sector, light_level: common.light_level, flags: common.flags, special: common.special }]
	}

fixture_sector = |floor_height, ceiling_height, light_level| { floor_height, ceiling_height, floor_flat: "FLOOR", ceiling_flat: "CEIL", light_level, special: 0, tag: 0 }

fixture_side = |sector, upper_texture, lower_texture, middle_texture| { x_offset: 8, y_offset: -4, upper_texture, lower_texture, middle_texture, sector }

fixture_line = |flags, left_sidedef| { start_vertex: 0, end_vertex: 1, flags, special: 1, tag: 7, right_sidedef: Ok(0), left_sidedef }

fixture = |line, sides, sectors| { format: "doom", map: "E1M1", vertices: [{ x: 0, y: 0 }, { x: 128, y: 0 }], linedefs: [line], sidedefs: sides, sectors, things: [{ x: 32, y: 16, angle: 90, type: 1, flags: 7 }], segs: [], subsectors: [], nodes: [], subsector_polygon_bounds: { min_x: 0, min_y: 0, max_x: 128, max_y: 0 }, subsector_polygons: [] }

surface_fixture = {
	format: "doom",
	map: "SQUARE",
	vertices: [{ x: 0, y: 0 }, { x: 64, y: 0 }, { x: 64, y: 64 }, { x: 0, y: 64 }],
	linedefs: [
		{ ..fixture_line(0, Err(Null)), start_vertex: 0, end_vertex: 1, right_sidedef: Ok(0) },
		{ ..fixture_line(0, Err(Null)), start_vertex: 1, end_vertex: 2, right_sidedef: Ok(1) },
		{ ..fixture_line(0, Err(Null)), start_vertex: 2, end_vertex: 3, right_sidedef: Ok(2) },
		{ ..fixture_line(0, Err(Null)), start_vertex: 3, end_vertex: 0, right_sidedef: Ok(3) },
	],
	sidedefs: [
		fixture_side(0, Err(Null), Err(Null), Ok("WALL")),
		fixture_side(0, Err(Null), Err(Null), Ok("WALL")),
		fixture_side(0, Err(Null), Err(Null), Ok("WALL")),
		fixture_side(0, Err(Null), Err(Null), Ok("WALL")),
	],
	sectors: [fixture_sector(-16, 112, 144)],
	things: [{ x: 16, y: 24, angle: 90, type: 1, flags: 7 }],
	segs: [
		{ start_vertex: 0, end_vertex: 1, angle: 0, linedef: 0, direction: 0, offset: 0 },
		{ start_vertex: 1, end_vertex: 2, angle: 16384, linedef: 1, direction: 0, offset: 0 },
		{ start_vertex: 2, end_vertex: 3, angle: 32768, linedef: 2, direction: 0, offset: 0 },
		{ start_vertex: 3, end_vertex: 0, angle: 49152, linedef: 3, direction: 0, offset: 0 },
	],
	subsectors: [{ seg_count: 4, first_seg: 0 }],
	nodes: [],
	subsector_polygon_bounds: { min_x: 0, min_y: 0, max_x: 64, max_y: 64 },
	subsector_polygons: [{ subsector: 0, sector: 0, points: [{ x: 0, y: 0 }, { x: 64, y: 0 }, { x: 64, y: 64 }, { x: 0, y: 64 }] }],
}

expect {
	raw = fixture(fixture_line(0, Err(Null)), [fixture_side(0, Err(Null), Err(Null), Ok("STONE"))], [fixture_sector(0, 128, 160)])
	map = DoomMap.validate(raw) ?? crash "fixture should validate"
	spans = map.wall_spans()
	span = List.get(spans, 0) ?? crash "one-sided wall missing"
	List.len(spans) == 1 and span.kind == Middle and span.bottom == 0 and span.top == 128 and span.texture == "STONE" and span.vertical_peg == TopAt(128) and span.special == Special({ number: 1, tag: 7 })
}

expect {
	plain = DoomMap.validate(fixture(fixture_line(0, Err(Null)), [fixture_side(0, Err(Null), Err(Null), Ok("STONE"))], [fixture_sector(-16, 112, 160)])) ?? crash "plain wall"
	unpegged = DoomMap.validate(fixture(fixture_line(0x0010, Err(Null)), [fixture_side(0, Err(Null), Err(Null), Ok("STONE"))], [fixture_sector(-16, 112, 160)])) ?? crash "unpegged wall"
	plain_span = List.get(plain.wall_spans(), 0) ?? crash "plain span"
	unpegged_span = List.get(unpegged.wall_spans(), 0) ?? crash "unpegged span"
	plain_span.vertical_peg == TopAt(112) and unpegged_span.vertical_peg == BottomAt(-16)
}

expect {
	raw = fixture(
		fixture_line(0x0004, Ok(1)),
		[fixture_side(0, Ok("UPPER_A"), Ok("LOWER_A"), Ok("MASK_A")), fixture_side(1, Ok("UPPER_B"), Ok("LOWER_B"), Err(Null))],
		[fixture_sector(0, 192, 192), fixture_sector(32, 128, 96)],
	)
	map = DoomMap.validate(raw) ?? crash "fixture should validate"
	spans = map.wall_spans()
	List.len(spans) == 3
		and List.any(spans, |span| span.side == Right and span.kind == Lower and span.bottom == 0 and span.top == 32 and span.texture == "LOWER_A" and span.vertical_peg == TopAt(32))
			and List.any(spans, |span| span.side == Right and span.kind == Middle and span.bottom == 32 and span.top == 128 and span.texture == "MASK_A" and span.vertical_peg == TopAt(128))
				and List.any(spans, |span| span.side == Right and span.kind == Upper and span.bottom == 128 and span.top == 192 and span.texture == "UPPER_A" and span.vertical_peg == BottomAt(128))
					and !(List.any(spans, |span| span.side == Left))
}

expect {
	raw = fixture(
		fixture_line(0x001c, Ok(1)),
		[fixture_side(0, Ok("UPPER_A"), Ok("LOWER_A"), Ok("MASK_A")), fixture_side(1, Err(Null), Err(Null), Err(Null))],
		[fixture_sector(0, 192, 192), fixture_sector(32, 128, 96)],
	)
	map = DoomMap.validate(raw) ?? crash "unpegged portal should validate"
	spans = map.wall_spans()
	List.any(spans, |span| span.kind == Upper and span.vertical_peg == TopAt(192))
		and List.any(spans, |span| span.kind == Lower and span.vertical_peg == TopAt(192))
			and List.any(spans, |span| span.kind == Middle and span.vertical_peg == BottomAt(32))
}

expect {
	bad_vertex = fixture({ ..fixture_line(0, Err(Null)), end_vertex: 9 }, [fixture_side(0, Err(Null), Err(Null), Ok("STONE"))], [fixture_sector(0, 128, 160)])
	bad_sector = fixture(fixture_line(0, Err(Null)), [fixture_side(4, Err(Null), Err(Null), Ok("STONE"))], [fixture_sector(0, 128, 160)])
	bad_light = fixture(fixture_line(0, Err(Null)), [fixture_side(0, Err(Null), Err(Null), Ok("STONE"))], [fixture_sector(0, 128, 300)])
	match DoomMap.validate(bad_vertex) {
		Err(VertexOutOfRange(_)) => Bool.True
		_ => Bool.False
	}
		and match DoomMap.validate(bad_sector) {
			Err(SectorOutOfRange(_)) => Bool.True
			_ => Bool.False
		}
			and match DoomMap.validate(bad_light) {
				Err(InvalidLight(_)) => Bool.True
				_ => Bool.False
			}
}

expect {
	flags = DoomMap.line_flags(0x01ff)
	flags.blocks_players and flags.blocks_monsters and flags.two_sided and flags.upper_unpegged and flags.lower_unpegged and flags.secret and flags.blocks_sound and flags.hidden_on_map and flags.shown_on_map
}

expect {
	json = "{\"format\":\"doom\",\"map\":\"E1M1\",\"vertices\":[{\"x\":0,\"y\":0},{\"x\":64,\"y\":0}],\"linedefs\":[{\"start_vertex\":0,\"end_vertex\":1,\"flags\":0,\"special\":0,\"tag\":0,\"right_sidedef\":0,\"left_sidedef\":null}],\"sidedefs\":[{\"x_offset\":0,\"y_offset\":0,\"upper_texture\":null,\"lower_texture\":null,\"middle_texture\":\"STONE\",\"sector\":0}],\"sectors\":[{\"floor_height\":0,\"ceiling_height\":128,\"floor_flat\":\"FLOOR\",\"ceiling_flat\":\"CEIL\",\"light_level\":160,\"special\":0,\"tag\":0}],\"things\":[],\"segs\":[],\"subsectors\":[],\"nodes\":[],\"subsector_polygon_bounds\":{\"min_x\":0,\"min_y\":0,\"max_x\":64,\"max_y\":0},\"subsector_polygons\":[] }"
	match DoomMap.decode(json) {
		Ok(map) => List.len(map.wall_spans()) == 1
		Err(_) => Bool.False
	}
}

expect {
	base = fixture(fixture_line(0, Err(Null)), [fixture_side(0, Err(Null), Err(Null), Ok("STONE"))], [fixture_sector(0, 128, 160)])
	missing_right = { ..base, linedefs: [{ ..fixture_line(0, Err(Null)), right_sidedef: Err(Null) }] }
	bad_side = { ..base, linedefs: [{ ..fixture_line(0, Err(Null)), right_sidedef: Ok(9) }] }
	bad_two_sided = { ..base, linedefs: [fixture_line(0x0004, Err(Null))] }
	match DoomMap.validate(missing_right) {
		Err(MissingRightSidedef(_)) => Bool.True
		_ => Bool.False
	}
		and match DoomMap.validate(bad_side) {
			Err(SidedefOutOfRange(_)) => Bool.True
			_ => Bool.False
		}
			and match DoomMap.validate(bad_two_sided) {
				Err(TwoSidedMismatch(_)) => Bool.True
				_ => Bool.False
			}
}

expect {
	raw = fixture(
		fixture_line(0x0004, Ok(1)),
		[fixture_side(0, Err(Null), Err(Null), Ok("MASK_A")), fixture_side(1, Err(Null), Err(Null), Ok("MASK_B"))],
		[fixture_sector(0, 128, 160), fixture_sector(0, 128, 128)],
	)
	map = DoomMap.validate(raw) ?? crash "fixture should validate"
	left = List.find_first(map.wall_spans(), |span| span.side == Left) ?? crash "left span missing"
	left.start == { x: 128, y: 0 } and left.end == { x: 0, y: 0 } and left.light_level == 128
}

expect {
	base = fixture(fixture_line(0, Err(Null)), [fixture_side(0, Err(Null), Err(Null), Ok("STONE"))], [fixture_sector(0, 128, 160)])
	bad_format = { ..base, format: "hexen" }
	empty_name = { ..base, map: "" }
	degenerate = { ..base, linedefs: [{ ..fixture_line(0, Err(Null)), end_vertex: 0 }] }
	bad_angle = { ..base, things: [{ x: 0, y: 0, angle: 360, type: 1, flags: 0 }] }
	match DoomMap.validate(bad_format) {
		Err(InvalidFormat(_)) => Bool.True
		_ => Bool.False
	}
		and match DoomMap.validate(empty_name) {
			Err(EmptyMapName) => Bool.True
			_ => Bool.False
		}
			and match DoomMap.validate(degenerate) {
				Err(DegenerateLinedef(_)) => Bool.True
				_ => Bool.False
			}
				and match DoomMap.validate(bad_angle) {
					Err(InvalidThingAngle(_)) => Bool.True
					_ => Bool.False
				}
}

expect {
	map = DoomMap.validate(surface_fixture) ?? crash "surface fixture should validate"
	surfaces = map.surface_polygons()
	floor = List.find_first(surfaces, |surface| surface.orientation == Floor) ?? crash "floor missing"
	ceiling = List.find_first(surfaces, |surface| surface.orientation == Ceiling) ?? crash "ceiling missing"
	start = map.player_start() ?? crash "player start missing"
	List.len(surfaces) == 2
		and floor.flat == "FLOOR"
			and floor.height == -16
				and floor.light_level == 144
					and signed_area(floor.vertices) > 0
						and ceiling.flat == "CEIL"
							and ceiling.height == 112
								and signed_area(ceiling.vertices) < 0
									and List.len(map.blocking_segments()) == 4
										and start.position == { x: 16, y: 24 }
											and start.angle == 90
}

expect {
	duplicate_polygon = { ..surface_fixture, subsector_polygons: List.concat(surface_fixture.subsector_polygons, surface_fixture.subsector_polygons) }
	bad_direction = { ..surface_fixture, segs: (List.replace(surface_fixture.segs, 0, { start_vertex: 0, end_vertex: 1, angle: 0, linedef: 0, direction: 2, offset: 0 }) ?? crash "fixture index").list }
	bad_child = { ..surface_fixture, nodes: [{ x: 0, y: 0, dx: 1, dy: 0, right_bbox: { top: 64, bottom: 0, left: 0, right: 64 }, left_bbox: { top: 64, bottom: 0, left: 0, right: 64 }, right_child: { kind: "subsector", index: 0 }, left_child: { kind: "portal", index: 0 } }] }
	match DoomMap.validate(duplicate_polygon) {
		Err(DuplicateSubsectorPolygon(_)) => Bool.True
		_ => Bool.False
	}
		and match DoomMap.validate(bad_direction) {
			Err(InvalidSegDirection(_)) => Bool.True
			_ => Bool.False
		}
			and match DoomMap.validate(bad_child) {
				Err(InvalidNodeChildKind(_)) => Bool.True
				_ => Bool.False
			}
}

expect {
	map = DoomMap.e1m1
	surfaces = map.surface_polygons()
	walls = map.wall_spans()
	line48 = List.find_first(walls, |span| span.linedef == 48 and span.side == Right) ?? crash "real lower-unpegged middle missing"
	line76 = List.find_first(walls, |span| span.linedef == 76 and span.side == Right and span.kind == Upper) ?? crash "real upper-unpegged upper missing"
	line133_upper = List.find_first(walls, |span| span.linedef == 133 and span.side == Right and span.kind == Upper) ?? crash "real doubly-unpegged upper missing"
	line133_lower = List.find_first(walls, |span| span.linedef == 133 and span.side == Right and span.kind == Lower) ?? crash "real doubly-unpegged lower missing"
	List.len(surfaces) == 1364
		and List.len(map.blocking_segments()) > 100
			and line48.vertical_peg == BottomAt(-128)
				and line76.vertical_peg == TopAt(128)
					and line133_upper.vertical_peg == TopAt(384)
						and line133_lower.vertical_peg == TopAt(384)
							and match map.player_start() {
								Ok(start) => start.angle >= 0 and start.angle < 360
								Err(_) => Bool.False
							}
}
