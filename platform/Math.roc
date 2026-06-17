## Math module - small 2D helpers for examples and simple games.
##
## Coordinates use the same screen-space convention as Draw: x grows to the
## right, y grows downward, and rectangles are top-left plus width/height.
Math := [].{

	Vec2 : {
		x : F32,
		y : F32,
	}

	Rect : {
		x : F32,
		y : F32,
		width : F32,
		height : F32,
	}

	Circle : {
		center : Vec2,
		radius : F32,
	}

	vec2 : F32, F32 -> Vec2
	vec2 = |x, y| { x, y }

	zero : Vec2
	zero = { x: 0, y: 0 }

	rect : F32, F32, F32, F32 -> Rect
	rect = |x, y, width, height| { x, y, width, height }

	circle : Vec2, F32 -> Circle
	circle = |center, radius| { center, radius }

	clamp : F32, F32, F32 -> F32
	clamp = |value, lo, hi| if value < lo lo else if value > hi hi else value

	clamp01 : F32 -> F32
	clamp01 = |value| Math.clamp(value, 0, 1)

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

	add : Vec2, Vec2 -> Vec2
	add = |a, b| { x: a.x + b.x, y: a.y + b.y }

	sub : Vec2, Vec2 -> Vec2
	sub = |a, b| { x: a.x - b.x, y: a.y - b.y }

	scale : Vec2, F32 -> Vec2
	scale = |v, amount| { x: v.x * amount, y: v.y * amount }

	dot : Vec2, Vec2 -> F32
	dot = |a, b| a.x * b.x + a.y * b.y

	length_squared : Vec2 -> F32
	length_squared = |v| Math.dot(v, v)

	length : Vec2 -> F32
	length = |v| Math.sqrt(Math.length_squared(v))

	distance_squared : Vec2, Vec2 -> F32
	distance_squared = |a, b| Math.length_squared(Math.sub(a, b))

	distance : Vec2, Vec2 -> F32
	distance = |a, b| Math.sqrt(Math.distance_squared(a, b))

	normalize : Vec2 -> Vec2
	normalize = |v| {
		len = Math.length(v)
		if len == 0 Math.zero else Math.scale(v, 1 / len)
	}

	lerp_vec2 : Vec2, Vec2, F32 -> Vec2
	lerp_vec2 = |from, to, amount| {
		x: Math.lerp(from.x, to.x, amount),
		y: Math.lerp(from.y, to.y, amount),
	}

	left : Rect -> F32
	left = |r| r.x

	right : Rect -> F32
	right = |r| r.x + r.width

	top : Rect -> F32
	top = |r| r.y

	bottom : Rect -> F32
	bottom = |r| r.y + r.height

	center : Rect -> Vec2
	center = |r| {
		x: r.x + r.width * 0.5,
		y: r.y + r.height * 0.5,
	}

	closest_point : Rect, Vec2 -> Vec2
	closest_point = |r, point| {
		x: Math.clamp(point.x, Math.left(r), Math.right(r)),
		y: Math.clamp(point.y, Math.top(r), Math.bottom(r)),
	}

	contains : Rect, Vec2 -> Bool
	contains = |r, point| point.x >= Math.left(r) and point.x <= Math.right(r) and point.y >= Math.top(r) and point.y <= Math.bottom(r)

	circle_contains : Circle, Vec2 -> Bool
	circle_contains = |c, point| Math.distance_squared(c.center, point) <= c.radius * c.radius

	overlaps : Rect, Rect -> Bool
	overlaps = |a, b| Math.left(a) <= Math.right(b) and Math.right(a) >= Math.left(b) and Math.top(a) <= Math.bottom(b) and Math.bottom(a) >= Math.top(b)

	circle_overlaps : Circle, Circle -> Bool
	circle_overlaps = |a, b| {
		radius_sum = a.radius + b.radius
		Math.distance_squared(a.center, b.center) <= radius_sum * radius_sum
	}

	circle_rect : Circle, Rect -> Bool
	circle_rect = |c, r| Math.circle_contains(c, Math.closest_point(r, c.center))

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
