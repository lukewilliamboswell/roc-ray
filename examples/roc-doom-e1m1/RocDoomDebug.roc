## Build-time geometry diagnostics for the Doom example. This module is pure:
## it traces the player's crosshair ray through validated map data and explains
## the nearest linedef in the same vocabulary used by rendering and collision.
import RocDoomLevel
import RocDoomMap
import RocDoomSim

RocDoomDebug := [].{
	Hit : { linedef : U64, distance : F64, start : RocDoomMap.Vertex, end : RocDoomMap.Vertex, lines : List(Str) }

	trace : RocDoomMap.Map, RocDoomLevel.State, RocDoomSim.Vec2, RocDoomSim.Angle -> Try(Hit, [NoRayHit, OutsideMap])
	trace = |map, level, pos, angle| {
		raw = map.raw()
		origin = { x: F32.to_f64(pos.x), y: F32.to_f64(pos.y) }
		forward = angle.forward()
		direction = { x: F32.to_f64(forward.x), y: F32.to_f64(forward.y) }
		var $nearest = Err(NoRayHit)
		for entry in List.map_with_index(raw.linedefs, |line, index| { line, index }) {
			start = List.get(raw.vertices, entry.line.start_vertex) ?? crash "validated debug start missing"
			end = List.get(raw.vertices, entry.line.end_vertex) ?? crash "validated debug end missing"
			match ray_segment(origin, direction, start, end) {
				Ok(distance) => match $nearest {
					Err(NoRayHit) => {
						$nearest = Ok({ linedef: entry.index, distance, start, end })
					}
					Ok(found) => if distance < found.distance {
						$nearest = Ok({ linedef: entry.index, distance, start, end })
					}
				}
				Err(NoIntersection) => {}
			}
		}
		found = match $nearest {
			Ok(value) => value
			Err(NoRayHit) => return Err(NoRayHit)
		}
		sector = match RocDoomLevel.sector_at(map, origin) {
			Ok(value) => value
			Err(OutsideMap) => return Err(OutsideMap)
		}
		line = List.get(raw.linedefs, found.linedef) ?? crash "debug linedef missing"
		spans = List.keep_if(map.wall_spans_at(level.heights), |span| span.linedef == found.linedef)
		right = side_description(raw, level, line.right_sidedef, "R")
		left = side_description(raw, level, line.left_sidedef, "L")
		dynamic = line_dynamic(raw, found.linedef, RocDoomLevel.dynamic_sectors(map))
		masked = List.len(List.keep_if(spans, |span| span.kind == Middle and span.flags.two_sided))
		portal_text = match RocDoomLevel.portal(map, level, found.linedef, sector) {
			Ok(portal) => "portal to=${U64.to_str(portal.to_sector)} bottom=${I64.to_str(portal.bottom)} top=${I64.to_str(portal.top)} step=${I64.to_str(portal.step)} traversable=${if portal.traversable "yes" else "NO"}"
			Err(_) => "portal n/a (one-sided or current sector not incident)"
		}
		lines = [
			"GEOMETRY DEBUG  x=${F32.to_str(pos.x)} y=${F32.to_str(pos.y)} angle=${F32.to_str(angle.turns())} sector=${U64.to_str(sector)}",
			"ray line=${U64.to_str(found.linedef)} distance=${F64.to_str(found.distance)} flags=${U64.to_str(line.flags)} special=${U64.to_str(line.special)}",
			right,
			left,
			"derived spans=${U64.to_str(List.len(spans))} (${span_descriptions(spans)})",
			"batch=${if dynamic "dynamic" else "static"} opaque=${U64.to_str(List.len(spans) - masked)} masked=${U64.to_str(masked)}",
			portal_text,
		]
		Ok({ linedef: found.linedef, distance: found.distance, start: found.start, end: found.end, lines })
	}
}

ray_segment = |origin, direction, start, end| {
	segment = { x: I64.to_f64(end.x - start.x), y: I64.to_f64(end.y - start.y) }
	denominator = cross(direction, segment)
	if F64.abs(denominator) < 0.0000001 return Err(NoIntersection)
	offset = { x: I64.to_f64(start.x) - origin.x, y: I64.to_f64(start.y) - origin.y }
	distance = cross(offset, segment) / denominator
	along = cross(offset, direction) / denominator
	if distance >= 0 and along >= 0 and along <= 1 Ok(distance) else Err(NoIntersection)
}

cross = |a, b| a.x * b.y - a.y * b.x

side_description = |raw, level, side_ref, label|
	match side_ref {
		Err(Null) => "${label} side=null"
		Ok(index) => {
			side = List.get(raw.sidedefs, index) ?? crash "validated debug side missing"
			heights = RocDoomLevel.heights_for(level, side.sector) ?? crash "debug sector state missing"
			"${label} side=${U64.to_str(index)} sector=${U64.to_str(side.sector)} floor=${I64.to_str(heights.floor)} ceil=${I64.to_str(heights.ceiling)} U=${texture_name(side.upper_texture)} L=${texture_name(side.lower_texture)} M=${texture_name(side.middle_texture)}"
		}
	}

texture_name = |texture| match texture {
	Ok(name) => name
	Err(Null) => "-"
}

line_dynamic = |raw, linedef, dynamic| {
	line = List.get(raw.linedefs, linedef) ?? crash "debug line missing"
	right = List.get(raw.sidedefs, line.right_sidedef ?? crash "validated right side missing") ?? crash "debug right side missing"
	left_dynamic = match line.left_sidedef {
		Ok(index) => List.contains(dynamic, (List.get(raw.sidedefs, index) ?? crash "debug left side missing").sector)
		Err(Null) => Bool.False
	}
	List.contains(dynamic, right.sector) or left_dynamic
}

span_descriptions = |spans| {
	var $text = ""
	for entry in List.map_with_index(spans, |span, index| { span, index }) {
		kind = match entry.span.kind {
			Middle => "M"
			Upper => "U"
			Lower => "L"
		}
		part = "${if entry.index == 0 "" else ","}${kind}:${I64.to_str(entry.span.bottom)}..${I64.to_str(entry.span.top)}:${entry.span.texture}:s${U64.to_str(entry.span.sector)}"
		$text = Str.concat($text, part)
	}
	$text
}

expect {
	result = ray_segment({ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 10, y: -5 }, { x: 10, y: 5 })
	behind = ray_segment({ x: 0, y: 0 }, { x: 1, y: 0 }, { x: -10, y: -5 }, { x: -10, y: 5 })
	result == Ok(10) and behind == Err(NoIntersection)
}
