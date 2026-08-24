## Small 2D vector and rectangle helpers.
##
## Coordinates follow `Draw`: x increases rightward and y downward. Rectangles
## use a top-left position, width, and height.
##
## ```roc
## next = model.position.add(model.velocity.scale(input.time.elapsed_seconds))
## ```
##
Math := [].{

	## Two-dimensional floating-point vector. `Math.Vec2` and `Draw.Vector2` on
	## the platform are this same type, re-exported.
	Vec2 := {
		x : F32,
		y : F32,
	}.{

		## Compare two of these values.
		is_eq : _
	}

	## Axis-aligned rectangle represented by top-left position and size.
	Rect := {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
	}.{

		## Compare two of these values.
		is_eq : _
	}

	## Circle represented by center and radius.
	Circle := {
		center : Vec2,
		radius : F32,
	}.{

		## Compare two of these values.
		is_eq : _
	}

	## Construct a two-dimensional vector.
	vec2 : F32, F32 -> Vec2
	vec2 = |x, y| { x, y }

	## The zero vector.
	zero : Vec2
	zero = { x: 0, y: 0 }

	## Construct an axis-aligned rectangle.
	rect : F32, F32, F32, F32 -> Rect
	rect = |x, y, width, height| { x, y, width, height }

	## Construct a circle.
	circle : Vec2, F32 -> Circle
	circle = |center, radius| { center, radius }

	## Clamp a value to inclusive lower and upper bounds.
	clamp : F32, F32, F32 -> F32
	clamp = |value, lo, hi| if value < lo lo else if value > hi hi else value

	## Clamp a value to the inclusive 0-to-1 range.
	clamp01 : F32 -> F32
	clamp01 = |value| Math.clamp(value, 0, 1)

	## Linearly interpolate between two scalars; amounts outside 0 to 1 extrapolate.
	lerp : F32, F32, F32 -> F32
	lerp = |from, to, amount| from + (to - from) * amount

	## Square root for game-scale F32 values.
	## Roc's pinned builtins do not expose sqrt yet, so keep this pure Roc.
	sqrt : F32 -> F32
	sqrt = |value|
		if value <= 0 {
			0
		} else {
			step = |guess| (guess + value / guess) * 0.5
			guess0 = if value >= 1 value else 1
			guess1 = step(guess0)
			guess2 = step(guess1)
			guess3 = step(guess2)
			guess4 = step(guess3)
			guess5 = step(guess4)
			guess6 = step(guess5)
			guess7 = step(guess6)
			guess8 = step(guess7)
			guess9 = step(guess8)
			guess10 = step(guess9)
			guess11 = step(guess10)
			guess12 = step(guess11)
			guess13 = step(guess12)
			guess14 = step(guess13)
			guess15 = step(guess14)
			step(guess15)
		}

	## Add two vectors component-wise.
	add : Vec2, Vec2 -> Vec2
	add = |a, b| { x: a.x + b.x, y: a.y + b.y }

	## Subtract two vectors component-wise.
	sub : Vec2, Vec2 -> Vec2
	sub = |a, b| { x: a.x - b.x, y: a.y - b.y }

	## Multiply both vector components by a scalar.
	scale : Vec2, F32 -> Vec2
	scale = |v, amount| { x: v.x * amount, y: v.y * amount }

	## Compute the vector dot product.
	dot : Vec2, Vec2 -> F32
	dot = |a, b| a.x * b.x + a.y * b.y

	## Squared vector length, avoiding a square root.
	length_squared : Vec2 -> F32
	length_squared = |v| Math.dot(v, v)

	## Euclidean vector length.
	length : Vec2 -> F32
	length = |v| Math.sqrt(Math.length_squared(v))

	## Squared distance between two points.
	distance_squared : Vec2, Vec2 -> F32
	distance_squared = |a, b| Math.length_squared(Math.sub(a, b))

	## Euclidean distance between two points.
	distance : Vec2, Vec2 -> F32
	distance = |a, b| Math.sqrt(Math.distance_squared(a, b))

	## Return a unit vector, or zero when the input has zero length.
	normalize : Vec2 -> Vec2
	normalize = |v| {
		len = Math.length(v)
		if len == 0 Math.zero else Math.scale(v, 1 / len)
	}

	## Linearly interpolate between two vectors.
	lerp_vec2 : Vec2, Vec2, F32 -> Vec2
	lerp_vec2 = |from, to, amount| {
		x: Math.lerp(from.x, to.x, amount),
		y: Math.lerp(from.y, to.y, amount),
	}

	## Left edge of a rectangle.
	left : Rect -> F32
	left = |r| r.x

	## Right edge of a rectangle.
	right : Rect -> F32
	right = |r| r.x + r.width

	## Top edge of a rectangle.
	top : Rect -> F32
	top = |r| r.y

	## Bottom edge of a rectangle.
	bottom : Rect -> F32
	bottom = |r| r.y + r.height

	## Center point of a rectangle.
	center : Rect -> Vec2
	center = |r| {
		x: r.x + r.width * 0.5,
		y: r.y + r.height * 0.5,
	}

	## Closest point in or on a rectangle.
	closest_point : Rect, Vec2 -> Vec2
	closest_point = |r, point| {
		x: Math.clamp(point.x, Math.left(r), Math.right(r)),
		y: Math.clamp(point.y, Math.top(r), Math.bottom(r)),
	}

	## Whether a rectangle contains a point, including its edges.
	contains : Rect, Vec2 -> Bool
	contains = |r, point| point.x >= Math.left(r) and point.x <= Math.right(r) and point.y >= Math.top(r) and point.y <= Math.bottom(r)

	## Whether a circle contains a point, including its edge.
	circle_contains : Circle, Vec2 -> Bool
	circle_contains = |c, point| Math.distance_squared(c.center, point) <= c.radius * c.radius

	## Whether two rectangles overlap or touch.
	overlaps : Rect, Rect -> Bool
	overlaps = |a, b| Math.left(a) <= Math.right(b) and Math.right(a) >= Math.left(b) and Math.top(a) <= Math.bottom(b) and Math.bottom(a) >= Math.top(b)

	## Whether two circles overlap or touch.
	circle_overlaps : Circle, Circle -> Bool
	circle_overlaps = |a, b| {
		radius_sum = a.radius + b.radius
		Math.distance_squared(a.center, b.center) <= radius_sum * radius_sum
	}

	## Whether a circle and rectangle overlap or touch.
	circle_rect : Circle, Rect -> Bool
	circle_rect = |c, r| Math.circle_contains(c, Math.closest_point(r, c.center))

	## Receiver-friendly aliases for circle queries. The longer names avoid
	## ambiguity with the corresponding rectangle methods.
	contains_point : Circle, Vec2 -> Bool
	contains_point = |circle_value, point| Math.circle_contains(circle_value, point)

	overlaps_circle : Circle, Circle -> Bool
	overlaps_circle = |circle_value, other| Math.circle_overlaps(circle_value, other)

	overlaps_rect : Circle, Rect -> Bool
	overlaps_rect = |circle_value, rectangle| Math.circle_rect(circle_value, rectangle)

}

expect Math.clamp(12, 0, 10) == 10
expect Math.clamp(-2, 0, 10) == 0
expect Math.lerp(10, 20, 0.25) == 12.5
expect Math.length({ x: 3, y: 4 }) == 5
expect Math.distance({ x: 10, y: 10 }, { x: 13, y: 14 }) == 5
expect Math.normalize(Math.zero) == Math.zero
expect F32.abs(Math.normalize({ x: 3, y: 4 }).x - 0.6) < 0.0001
expect F32.abs(Math.normalize({ x: 3, y: 4 }).y - 0.8) < 0.0001
expect Math.contains(Math.rect(10, 20, 30, 40), { x: 10, y: 20 })
expect Math.contains(Math.rect(10, 20, 30, 40), { x: 40, y: 60 })
expect !(Math.contains(Math.rect(10, 20, 30, 40), { x: 41, y: 60 }))
expect Math.overlaps(Math.rect(0, 0, 10, 10), Math.rect(10, 10, 5, 5))
expect !(Math.overlaps(Math.rect(0, 0, 10, 10), Math.rect(11, 10, 5, 5)))
expect Math.circle_overlaps(Math.circle({ x: 0, y: 0 }, 5), Math.circle({ x: 8, y: 0 }, 3))
expect !(Math.circle_overlaps(Math.circle({ x: 0, y: 0 }, 5), Math.circle({ x: 9, y: 0 }, 3)))
expect Math.circle_rect(Math.circle({ x: 15, y: 5 }, 5), Math.rect(20, 0, 10, 10))
expect !(Math.circle_rect(Math.circle({ x: 14, y: 5 }, 5), Math.rect(20, 0, 10, 10)))
expect Math.vec2(3, 4).length() == 5
expect Math.rect(10, 20, 30, 40).contains(Math.vec2(10, 20))
expect Math.circle(Math.zero, 5).contains_point(Math.vec2(3, 4))
