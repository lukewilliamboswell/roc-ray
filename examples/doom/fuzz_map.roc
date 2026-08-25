app [target] { fuzz: platform "../../../roc-fuzz/platform/main.roc" }

## Property fuzz target for DoomMap validation + DoomLevel spatial queries.
## Core property: anything `DoomMap.validate` accepts must be safe to query.

import fuzz.Fuzz
import DoomMap
import DoomLevel

# The map bugs this target found (FUZZ_FINDINGS.md M1-M3) are fixed: cyclic
# node graphs and coordinate-equal endpoints are now rejected by validation
# (checked below as properties), and orphan tagged sectors are safe to query.

## WORKAROUND for compiler bug T1 (FUZZ_FINDINGS.md): the native build of
## DoomLevel.dynamic_sectors returns garbage indices for some maps while the
## interpreter is correct. The range assertion stays off until that is fixed.
guard_dynamic_sectors = Bool.True

# ---- seeds ----

VertexSeed : { x : U64, y : U64 }

LineSeed : { sv : U64, ev : U64, flags : U64, special : U8, tag : U64, right : U64, left_present : U8, left : U64, perturb : U8 }

SideSeed : { xo : U64, yo : U64, up : U8, lo : U8, mid : U8, sector : U64, perturb : U8 }

SectorSeed : { floor : U64, ceil : U64, light : U64, special : U8, tag : U64 }

ThingSeed : { x : U64, y : U64, angle : U64, type : U8, flags : U64 }

SegSeed : { sv : U64, ev : U64, angle : U64, linedef : U64, direction : U8, offset : U64, perturb : U8 }

SubsectorSeed : { count : U64, first : U64, perturb : U8 }

NodeSeed : { x : U64, y : U64, dx : U64, dy : U64, rk : U8, ri : U64, lk : U8, li : U64, perturb : U8 }

PolySeed : { sector : U64, kind : U8, x : U64, y : U64, w : U64, h : U64, pts : List(VertexSeed), perturb : U8 }

QuerySeed : { px : U64, py : U64, qx : U64, qy : U64, qmode : U8, vertex : U64, line : U64, sector : U64, keys : U8, ticks : U8 }

Input := {
	map_name : U8,
	vertices : List(VertexSeed),
	linedefs : List(LineSeed),
	sidedefs : List(SideSeed),
	sectors : List(SectorSeed),
	things : List(ThingSeed),
	segs : List(SegSeed),
	subsectors : List(SubsectorSeed),
	nodes : List(NodeSeed),
	polys : List(PolySeed),
	drop_polygon : U8,
	query : QuerySeed,
}.{
	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		coord = Fuzz.u64_in(0, 8)
		idx = Fuzz.u64_in(0, 15)
		vertex_gen = { x: coord, y: coord }.Fuzz
		line_gen = { sv: idx, ev: idx, flags: Fuzz.u64_in(0, 0x1ff), special: Fuzz.u8, tag: Fuzz.u64_in(0, 3), right: idx, left_present: Fuzz.u8, left: idx, perturb: Fuzz.u8 }.Fuzz
		side_gen = { xo: Fuzz.u64_in(0, 300), yo: Fuzz.u64_in(0, 300), up: Fuzz.u8, lo: Fuzz.u8, mid: Fuzz.u8, sector: idx, perturb: Fuzz.u8 }.Fuzz
		sector_gen = { floor: Fuzz.u64_in(0, 400), ceil: Fuzz.u64_in(0, 400), light: Fuzz.u64_in(0, 270), special: Fuzz.u8, tag: Fuzz.u64_in(0, 3) }.Fuzz
		thing_gen = { x: coord, y: coord, angle: Fuzz.u64_in(0, 370), type: Fuzz.u8_in(0, 3), flags: Fuzz.u64_in(0, 31) }.Fuzz
		seg_gen = { sv: idx, ev: idx, angle: Fuzz.u64_in(0, 65535), linedef: idx, direction: Fuzz.u8_in(0, 2), offset: Fuzz.u64_in(0, 64), perturb: Fuzz.u8 }.Fuzz
		subsector_gen = { count: Fuzz.u64_in(0, 7), first: Fuzz.u64_in(0, 7), perturb: Fuzz.u8 }.Fuzz
		node_gen = { x: coord, y: coord, dx: coord, dy: coord, rk: Fuzz.u8, ri: idx, lk: Fuzz.u8, li: idx, perturb: Fuzz.u8 }.Fuzz
		poly_gen = { sector: idx, kind: Fuzz.u8, x: coord, y: coord, w: Fuzz.u64_in(0, 4), h: Fuzz.u64_in(0, 4), pts: Fuzz.list(vertex_gen, 5), perturb: Fuzz.u8 }.Fuzz
		query_gen = { px: Fuzz.u64_in(0, 160), py: Fuzz.u64_in(0, 160), qx: Fuzz.u64, qy: Fuzz.u64, qmode: Fuzz.u8, vertex: idx, line: idx, sector: idx, keys: Fuzz.u8, ticks: Fuzz.u8_in(0, 40) }.Fuzz
		{
			map_name: Fuzz.u8,
			vertices: Fuzz.list(vertex_gen, 6),
			linedefs: Fuzz.list(line_gen, 6),
			sidedefs: Fuzz.list(side_gen, 6),
			sectors: Fuzz.list(sector_gen, 4),
			things: Fuzz.list(thing_gen, 4),
			segs: Fuzz.list(seg_gen, 6),
			subsectors: Fuzz.list(subsector_gen, 3),
			nodes: Fuzz.list(node_gen, 3),
			polys: Fuzz.list(poly_gen, 3),
			drop_polygon: Fuzz.u8,
			query: query_gen,
		}.Fuzz
	}
}

# ---- building a mostly-consistent Raw map ----

## Resolve a raw index into `count`, except for a 1-in-8 perturbation that keeps it raw.
resolve : U64, U64, U8 -> U64
resolve = |raw, count, perturb| if perturb % 8 == 0 or count == 0 raw else raw % count

coord_of : U64 -> I64
coord_of = |v| U64.to_i64_wrap(v) * 8 - 32

texture_of : U8 -> Try(Str, [Null])
texture_of = |b| if b % 4 == 0 Err(Null) else if b % 4 == 1 Ok("STONE") else if b % 4 == 2 Ok("DOOR") else Ok("")

special_of : U8 -> U64
special_of = |b| match b % 12 {
	0 => 0
	1 => 0
	2 => 1
	3 => 2
	4 => 11
	5 => 23
	6 => 26
	7 => 62
	8 => 88
	9 => 117
	10 => 0
	_ => U8.to_u64(b)
}

child_of : U8, U64, U64, U64, U8 -> DoomMap.Child
child_of = |kind, raw, node_count, subsector_count, perturb| {
	if perturb % 16 == 0 {
		{ kind: "bogus", index: raw }
	} else if kind % 3 == 0 {
		{ kind: "node", index: resolve(raw, node_count, perturb) }
	} else {
		{ kind: "subsector", index: resolve(raw, subsector_count, perturb) }
	}
}

polygon_points : PolySeed -> List(DoomMap.SurfacePoint)
polygon_points = |seed| {
	x = I64.to_f64(coord_of(seed.x))
	y = I64.to_f64(coord_of(seed.y))
	w = U64.to_f64(seed.w + 1) * 8
	h = U64.to_f64(seed.h + 1) * 8
	match seed.kind % 3 {
		0 => [{ x, y }, { x: x + w, y }, { x: x + w, y: y + h }, { x, y: y + h }]
		1 => [{ x, y }, { x: x + w, y }, { x, y: y + h }]
		_ => List.map(seed.pts, |p| { x: I64.to_f64(coord_of(p.x)), y: I64.to_f64(coord_of(p.y)) })
	}
}

build_raw : Input -> DoomMap.Raw
build_raw = |input| {
	nv = List.len(input.vertices)
	nl = List.len(input.linedefs)
	nsd = List.len(input.sidedefs)
	nsec = List.len(input.sectors)
	nseg = List.len(input.segs)
	nss = List.len(input.subsectors)
	nn = List.len(input.nodes)
	vertices = List.map(input.vertices, |v| { x: coord_of(v.x), y: coord_of(v.y) })
	linedefs = List.map(
		input.linedefs,
		|l| {
			has_left = l.left_present % 2 == 0
			left_sidedef = if has_left Ok(resolve(l.left, nsd, l.perturb)) else Err(Null)
			# keep the two-sided flag consistent with the left sidedef 7 times out of 8
			base_flags = U64.bitwise_and(l.flags, 0x1fb)
			flags = if l.perturb % 8 == 1 l.flags else if has_left U64.bitwise_or(base_flags, 0x0004) else base_flags
			{ start_vertex: resolve(l.sv, nv, l.perturb), end_vertex: resolve(l.ev, nv, l.perturb), flags, special: special_of(l.special), tag: l.tag, right_sidedef: if l.perturb % 8 == 2 Err(Null) else Ok(resolve(l.right, nsd, l.perturb)), left_sidedef }
		},
	)
	sidedefs = List.map(input.sidedefs, |s| { x_offset: U64.to_i64_wrap(s.xo) - 150, y_offset: U64.to_i64_wrap(s.yo) - 150, upper_texture: texture_of(s.up), lower_texture: texture_of(s.lo), middle_texture: texture_of(s.mid), sector: resolve(s.sector, nsec, s.perturb) })
	sectors = List.map(input.sectors, |s| { floor_height: U64.to_i64_wrap(s.floor) - 200, ceiling_height: U64.to_i64_wrap(s.ceil) - 200, floor_flat: "FLOOR", ceiling_flat: "CEIL", light_level: U64.to_i64_wrap(s.light) - 8, special: U8.to_u64(s.special % 16), tag: s.tag })
	things = List.map(input.things, |t| { x: coord_of(t.x), y: coord_of(t.y), angle: U64.to_i64_wrap(t.angle) - 5, type: U8.to_u64(t.type), flags: t.flags })
	segs = List.map(input.segs, |s| { start_vertex: resolve(s.sv, nv, s.perturb), end_vertex: resolve(s.ev, nv, s.perturb), angle: s.angle, linedef: resolve(s.linedef, nl, s.perturb), direction: U8.to_u64(s.direction), offset: s.offset })
	subsectors = List.map(
		input.subsectors,
		|s| {
			first_seg = if nseg == 0 or s.perturb % 8 == 0 s.first else s.first % nseg
			room = if nseg > first_seg nseg - first_seg else 1
			seg_count = if s.perturb % 8 == 1 s.count else 1 + s.count % room
			{ seg_count, first_seg }
		},
	)
	nodes = List.map(
		input.nodes,
		|n| {
			bbox = { top: 32, bottom: -32, left: -32, right: 32 }
			{ x: coord_of(n.x), y: coord_of(n.y), dx: coord_of(n.dx), dy: coord_of(n.dy), right_bbox: bbox, left_bbox: bbox, right_child: child_of(n.rk, n.ri, nn, nss, n.perturb), left_child: child_of(n.lk, n.li, nn, nss, n.perturb) }
		},
	)
	default_poly : PolySeed
	default_poly = { sector: 0, kind: 0, x: 0, y: 0, w: 2, h: 2, pts: [], perturb: 1 }
	npoly = if input.drop_polygon % 8 == 0 and nss > 0 nss - 1 else if input.drop_polygon % 8 == 1 nss + 1 else nss
	subsector_polygons = List.map(
		indices(npoly),
		|i| {
			seed = if List.is_empty(input.polys) default_poly else List.get(input.polys, i % List.len(input.polys)) ?? default_poly
			subsector = if seed.perturb % 8 == 0 seed.x else i
			{ subsector, sector: resolve(seed.sector, nsec, seed.perturb), points: polygon_points(seed) }
		},
	)
	{
		format: if input.map_name % 32 == 0 "hexen" else "doom",
		map: if input.map_name % 32 == 1 "" else "FUZZ",
		vertices,
		linedefs,
		sidedefs,
		sectors,
		things,
		segs,
		subsectors,
		nodes,
		subsector_polygon_bounds: { min_x: -32, min_y: -32, max_x: 32, max_y: 32 },
		subsector_polygons,
	}
}

# ---- structural predicates validation must agree with ----

## Static acyclicity: every "node" child must have a smaller index than its parent
## (the classic Doom BSP builds nodes bottom-up with the root last).
nodes_acyclic : DoomMap.Raw -> Bool
nodes_acyclic = |raw| {
	List.all(
		List.map_with_index(raw.nodes, |node, index| { node, index }),
		|entry| {
			ok = |child| child.kind != "node" or child.index < entry.index
			ok(entry.node.right_child) and ok(entry.node.left_child)
		},
	)
}

has_zero_length_line : DoomMap.Raw -> Bool
has_zero_length_line = |raw| {
	List.any(
		raw.linedefs,
		|line| {
			a = List.get(raw.vertices, line.start_vertex) ?? { x: 0, y: 0 }
			b = List.get(raw.vertices, line.end_vertex) ?? { x: 1, y: 1 }
			a == b
		},
	)
}

sector_of_side : DoomMap.Raw, Try(U64, [Null]) -> Try(U64, [None])
sector_of_side = |raw, side| match side {
	Err(Null) => Err(None)
	Ok(i) => match List.get(raw.sidedefs, i) {
		Ok(s) => Ok(s.sector)
		Err(_) => Err(None)
	}
}

sector_has_two_sided_line : DoomMap.Raw, U64 -> Bool
sector_has_two_sided_line = |raw, sector| {
	List.any(
		raw.linedefs,
		|line| match line.left_sidedef {
			Err(Null) => Bool.False
			Ok(_) => sector_of_side(raw, line.right_sidedef) == Ok(sector) or sector_of_side(raw, line.left_sidedef) == Ok(sector)
		},
	)
}

# ---- queries ----

ensure : Bool, Str -> {}
ensure = |condition, message| if condition {} else crash message

has_duplicates : List(U64), List(U64) -> Bool
has_duplicates = |items, seen| match items {
	[] => Bool.False
	[first, .. as rest] => List.contains(seen, first) or has_duplicates(rest, List.append(seen, first))
}

nan : F64
nan = F64.from_bits(0x7ff8000000000000)

query_point : DoomMap.Raw, QuerySeed -> DoomLevel.Point
query_point = |raw, q| match q.qmode % 8 {
	0 => { x: nan, y: U64.to_f64(q.py) }
	1 => { x: F64.from_bits(0x7ff0000000000000), y: -F64.from_bits(0x7ff0000000000000) }
	2 => { x: F64.from_bits(q.qx), y: F64.from_bits(q.qy) }
	3 => match List.get(raw.vertices, if List.is_empty(raw.vertices) 0 else q.vertex % List.len(raw.vertices)) {
		Ok(v) => { x: I64.to_f64(v.x), y: I64.to_f64(v.y) }
		Err(_) => { x: 0, y: 0 }
	}
	_ => { x: U64.to_f64(q.px) * 0.5 - 40, y: U64.to_f64(q.py) * 0.5 - 40 }
}

second_point : QuerySeed -> DoomLevel.Point
second_point = |q| { x: U64.to_f64(q.py) * 0.5 - 40, y: U64.to_f64(q.px) * 0.5 - 40 }

keys_of : U8 -> DoomLevel.Keys
keys_of = |k| { blue: k % 2 == 1, yellow: k % 4 >= 2, red: k % 8 >= 4 }

check_spans : DoomMap.Raw, List(DoomMap.WallSpan), Str -> {}
check_spans = |raw, spans, label| {
	for span in spans {
		ensure(!(span.top <= span.bottom), "PROPERTY: ${label}: span with top <= bottom ${Str.inspect(span)}")
		ensure(!(span.sector >= List.len(raw.sectors)), "PROPERTY: ${label}: span sector out of range")
		ensure(!(span.linedef >= List.len(raw.linedefs)), "PROPERTY: ${label}: span linedef out of range")
	}
	{}
}

tick_n : DoomLevel.State, U8 -> DoomLevel.State
tick_n = |state, n| if n == 0 state else tick_n(DoomLevel.tick(state), n - 1)

exercise_state : DoomMap.Map, DoomMap.Raw, DoomLevel.State, DoomLevel.State, QuerySeed, Str -> {}
exercise_state = |map, raw, base, state, q, label| {
	nsec = List.len(raw.sectors)
	ensure(!(List.len(state.heights) != nsec), "PROPERTY: ${label}: heights cardinality changed")
	ticked = tick_n(state, q.ticks)
	ensure(!(List.len(ticked.heights) != nsec), "PROPERTY: ${label}: heights cardinality changed by tick")
	_ = DoomLevel.render_changed(map, base, ticked)
	_ = map.wall_spans_at(ticked.heights)
	for sector in indices(nsec) {
		_ = DoomLevel.light_for(map, ticked, sector)
		_ = DoomLevel.heights_for(ticked, sector)
		for segment in DoomLevel.collision_segments(map, ticked, sector) {
			incident = List.get(ticked.incident_lines, sector) ?? []
			ensure(!(!List.contains(incident, segment.linedef)), "PROPERTY: ${label}: collision segment not incident to sector")
		}
	}
	{}
}

test : Input -> Fuzz.Outcome
test = |input| {
	raw = build_raw(input)
	match DoomMap.validate(raw) {
		Err(_) => Fuzz.reject
		Ok(map) => {
			if !nodes_acyclic(raw) {
				crash "PROPERTY: validate accepted a cyclic node graph"
			} else if has_zero_length_line(raw) {
				crash "PROPERTY: validate accepted a zero-length linedef or seg"
			} else {
				q = input.query
				nsec = List.len(raw.sectors)
				nl = List.len(raw.linedefs)

				# Map derivations
				spans = map.wall_spans()
				check_spans(raw, spans, "wall_spans")
				state = DoomLevel.initial(map)
				spans_at = map.wall_spans_at(state.heights)
				ensure(!(spans_at != spans), "PROPERTY: wall_spans_at(initial heights) != wall_spans")
				surfaces = map.surface_polygons()
				ensure(!(List.len(surfaces) != 2 * List.len(raw.subsector_polygons)), "PROPERTY: surface count != 2 * polygons")
				for surface in surfaces {
					ensure(!(surface.sector >= nsec), "PROPERTY: surface sector out of range")
					ensure(!(List.len(surface.vertices) < 3), "PROPERTY: surface with < 3 vertices")
				}
				for segment in map.blocking_segments() {
					ensure(!(segment.linedef >= nl), "PROPERTY: blocking segment linedef out of range")
					ensure(!(segment.start == segment.end), "PROPERTY: zero-length blocking segment ${Str.inspect(segment)}")
				}
				_ = map.player_start()

				# Spatial queries
				point = query_point(raw, q)
				match DoomLevel.sector_at(map, point) {
					Ok(sector) => ensure(sector < nsec, "PROPERTY: sector_at returned out-of-range sector")
					Err(OutsideMap) => {}
				}
				for line in DoomLevel.crossed_lines(map, point, second_point(q)) {
					l = List.get(raw.linedefs, line) ?? crash "PROPERTY: crossed line out of range"
					ensure(!(l.special == 0), "PROPERTY: crossed_lines returned a non-special line")
				}
				dynamic = DoomLevel.dynamic_sectors(map)
				for sector in dynamic {
					ensure(guard_dynamic_sectors or !(sector >= nsec), "PROPERTY: dynamic sector out of range: ${Str.inspect(dynamic)} with ${Str.inspect(nsec)} sectors")
				}
				dyn = DoomLevel.dynamic_sectors(map)
				ensure(!(List.len(dyn) != List.len(List.map_with_index(dyn, |s, i| { s, i }) |> List.keep_if(|e| List.contains(List.take_first(dyn, e.i), e.s) == Bool.False))), "PROPERTY: dynamic_sectors has duplicates")
				_ = DoomLevel.portal(map, state, q.line, q.sector)
				_ = DoomLevel.collision_candidate_count(state, q.sector)

				# Activation vocabulary over every linedef
				for line in indices(nl) {
					for sector in indices(nsec) {
						_ = DoomLevel.portal(map, state, line, sector)
					}
					match DoomLevel.use_line(map, state, line, keys_of(q.keys)) {
						Activated(next) => exercise_state(map, raw, state, next, q, "use_line")
						_ => {}
					}
					match DoomLevel.cross_line(map, state, line) {
						Activated(next) => exercise_state(map, raw, state, next, q, "cross_line")
						_ => {}
					}
				}
				exercise_state(map, raw, state, state, q, "initial")
				Fuzz.keep
			}
		}
	}
}

target = Fuzz.target({
	name: "doom-map",
	test,
	show: |input| "raw = ${Str.inspect(build_raw(input))}\nquery = ${Str.inspect(input.query)}",
})

indices : U64 -> List(U64)
indices = |count| List.map_with_index(List.repeat({}, count), |_, index| index)
