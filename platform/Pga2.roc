## Pga2 module - small 2D projective geometry primitives.
##
## This is intentionally geometry-only: points, vectors, lines, circles,
## affine transforms, projections, intersections, and Math.Vec2 conversion.
import Math

Pga2 := [].{

	Point : {
		x : F32,
		y : F32,
	}

	Vector : {
		x : F32,
		y : F32,
	}

	Line : {
		normal : Vector,
		distance : F32,
	}

	Circle : {
		center : Point,
		radius : F32,
	}

	Transform : {
		x_axis : Vector,
		y_axis : Vector,
		offset : Vector,
	}

	LineIntersection := [Parallel, Intersects(Point)]

	CircleLineIntersection := [NoIntersection, Tangent(Point), Two(Point, Point)]

	point : F32, F32 -> Point
	point = |x, y| { x, y }

	vector : F32, F32 -> Vector
	vector = |x, y| { x, y }

	from_vec2 : Math.Vec2 -> Point
	from_vec2 = |v| { x: v.x, y: v.y }

	to_vec2 : Point -> Math.Vec2
	to_vec2 = |p| { x: p.x, y: p.y }

	vector_from_vec2 : Math.Vec2 -> Vector
	vector_from_vec2 = |v| { x: v.x, y: v.y }

	vector_to_vec2 : Vector -> Math.Vec2
	vector_to_vec2 = |v| { x: v.x, y: v.y }

	add : Point, Vector -> Point
	add = |p, v| { x: p.x + v.x, y: p.y + v.y }

	sub : Point, Point -> Vector
	sub = |a, b| { x: a.x - b.x, y: a.y - b.y }

	add_vec : Vector, Vector -> Vector
	add_vec = |a, b| { x: a.x + b.x, y: a.y + b.y }

	sub_vec : Vector, Vector -> Vector
	sub_vec = |a, b| { x: a.x - b.x, y: a.y - b.y }

	scale : Vector, F32 -> Vector
	scale = |v, amount| { x: v.x * amount, y: v.y * amount }

	dot : Vector, Vector -> F32
	dot = |a, b| a.x * b.x + a.y * b.y

	cross : Vector, Vector -> F32
	cross = |a, b| a.x * b.y - a.y * b.x

	length_squared : Vector -> F32
	length_squared = |v| Pga2.dot(v, v)

	length : Vector -> F32
	length = |v| Math.sqrt(Pga2.length_squared(v))

	normalize : Vector -> Vector
	normalize = |v| {
		len = Pga2.length(v)
		if len == 0 { x: 0, y: 0 } else Pga2.scale(v, 1 / len)
	}

	perp : Vector -> Vector
	perp = |v| { x: -v.y, y: v.x }

	distance : Point, Point -> F32
	distance = |a, b| Pga2.length(Pga2.sub(a, b))

	line : Vector, F32 -> Line
	line = |normal, distance_to_origin| {
		len = Pga2.length(normal)
		if len == 0 {
			{ normal: { x: 0, y: 0 }, distance: 0 }
		} else {
			{ normal: Pga2.scale(normal, 1 / len), distance: distance_to_origin / len }
		}
	}

	line_from_points : Point, Point -> Line
	line_from_points = |a, b| {
		dir = Pga2.sub(b, a)
		n = Pga2.normalize(Pga2.perp(dir))
		{ normal: n, distance: Pga2.dot(n, Pga2.sub(a, { x: 0, y: 0 })) }
	}

	signed_distance : Line, Point -> F32
	signed_distance = |line_value, point_value| Pga2.dot(line_value.normal, Pga2.sub(point_value, { x: 0, y: 0 })) - line_value.distance

	distance_to_line : Line, Point -> F32
	distance_to_line = |line_value, point_value| F32.abs(Pga2.signed_distance(line_value, point_value))

	project_point_line : Line, Point -> Point
	project_point_line = |line_value, point_value| Pga2.add(point_value, Pga2.scale(line_value.normal, 0 - Pga2.signed_distance(line_value, point_value)))

	intersect_lines : Line, Line -> LineIntersection
	intersect_lines = |a, b| {
		det = a.normal.x * b.normal.y - a.normal.y * b.normal.x
		if F32.abs(det) < 0.000001 {
			Parallel
		} else {
			Intersects(
				{
					x: (a.distance * b.normal.y - a.normal.y * b.distance) / det,
					y: (a.normal.x * b.distance - a.distance * b.normal.x) / det,
				},
			)
		}
	}

	circle : Point, F32 -> Circle
	circle = |center, radius| { center, radius }

	circle_contains : Circle, Point -> Bool
	circle_contains = |circle_value, point_value| Pga2.distance(circle_value.center, point_value) <= circle_value.radius

	circle_intersects : Circle, Circle -> Bool
	circle_intersects = |a, b| Pga2.distance(a.center, b.center) <= a.radius + b.radius

	intersect_circle_line : Circle, Line -> CircleLineIntersection
	intersect_circle_line = |circle_value, line_value| {
		projection = Pga2.project_point_line(line_value, circle_value.center)
		dist = Pga2.distance(circle_value.center, projection)
		if dist > circle_value.radius {
			NoIntersection
		} else if F32.abs(dist - circle_value.radius) < 0.000001 {
			Tangent(projection)
		} else {
			half = Math.sqrt(circle_value.radius * circle_value.radius - dist * dist)
			dir = Pga2.perp(line_value.normal)
			Two(Pga2.add(projection, Pga2.scale(dir, half)), Pga2.add(projection, Pga2.scale(dir, 0 - half)))
		}
	}

	identity : Transform
	identity = {
		x_axis: { x: 1, y: 0 },
		y_axis: { x: 0, y: 1 },
		offset: { x: 0, y: 0 },
	}

	translation : Vector -> Transform
	translation = |offset| { ..Pga2.identity, offset }

	uniform_scale : F32 -> Transform
	uniform_scale = |amount| {
		x_axis: { x: amount, y: 0 },
		y_axis: { x: 0, y: amount },
		offset: { x: 0, y: 0 },
	}

	apply_vector : Transform, Vector -> Vector
	apply_vector = |transform, vector_value| {
		x: transform.x_axis.x * vector_value.x + transform.y_axis.x * vector_value.y,
		y: transform.x_axis.y * vector_value.x + transform.y_axis.y * vector_value.y,
	}

	apply_point : Transform, Point -> Point
	apply_point = |transform, point_value| {
		v = Pga2.apply_vector(transform, { x: point_value.x, y: point_value.y })
		{ x: v.x + transform.offset.x, y: v.y + transform.offset.y }
	}

	compose : Transform, Transform -> Transform
	compose = |outer, inner| {
		x_axis: Pga2.apply_vector(outer, inner.x_axis),
		y_axis: Pga2.apply_vector(outer, inner.y_axis),
		offset: Pga2.add_vec(Pga2.apply_vector(outer, inner.offset), outer.offset),
	}

}

expect Pga2.to_vec2(Pga2.from_vec2({ x: 3, y: 4 })) == { x: 3, y: 4 }
expect Pga2.length({ x: 3, y: 4 }) == 5
expect Pga2.distance({ x: 0, y: 0 }, { x: 3, y: 4 }) == 5
expect Pga2.project_point_line(Pga2.line_from_points({ x: 0, y: 0 }, { x: 10, y: 0 }), { x: 4, y: 7 }) == { x: 4, y: 0 }
expect Pga2.signed_distance(Pga2.line({ x: 0, y: 2 }, 10), { x: 0, y: 7 }) == 2
expect {
	match Pga2.intersect_lines(Pga2.line_from_points({ x: 0, y: 0 }, { x: 10, y: 0 }), Pga2.line_from_points({ x: 5, y: -5 }, { x: 5, y: 5 })) {
		Intersects(point) => point == { x: 5, y: 0 }
		Parallel => Bool.False
	}
}
expect {
	match Pga2.intersect_circle_line(Pga2.circle({ x: 0, y: 0 }, 5), Pga2.line_from_points({ x: -10, y: 0 }, { x: 10, y: 0 })) {
		Two(a, b) => F32.abs(Pga2.distance(a, b) - 10) < 0.0001
		Tangent(_) => Bool.False
		NoIntersection => Bool.False
	}
}
expect Pga2.apply_point(Pga2.translation({ x: 2, y: 3 }), { x: 4, y: 5 }) == { x: 6, y: 8 }
