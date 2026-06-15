## Physics module - friendly 3D projective geometric algebra primitives.
##
## This module uses compact grade-specific PGA storage. The public API stays
## geometric, but each object stores coefficients for its PGA subspace rather
## than plain graphics vectors.
import Math

Physics := [].{

	## A finite 3D PGA point stored as compact grade-3 homogeneous coefficients.
	Point := {
		e032 : F32,
		e013 : F32,
		e021 : F32,
		e123 : F32,
	}

	## A free 3D direction or translation stored as the ideal part of a point.
	Vector := {
		e032 : F32,
		e013 : F32,
		e021 : F32,
	}

	## A 3D PGA plane stored as grade-1 coefficients.
	Plane := {
		e0 : F32,
		e1 : F32,
		e2 : F32,
		e3 : F32,
	}

	## A 3D PGA line stored as six grade-2 Plucker-style coefficients.
	Line := {
		e01 : F32,
		e02 : F32,
		e03 : F32,
		e23 : F32,
		e31 : F32,
		e12 : F32,
	}

	## A 3D PGA motor stored as compact even-subalgebra coefficients.
	Motor := {
		s : F32,
		e23 : F32,
		e31 : F32,
		e12 : F32,
		e01 : F32,
		e02 : F32,
		e03 : F32,
		e0123 : F32,
	}

	## A simple particle body with a PGA point position and vector velocity.
	Body : {
		position : Point,
		velocity : Vector,
	}

	## Plain coordinate view returned by accessors.
	Coords : {
		x : F32,
		y : F32,
		z : F32,
	}

	## Read-only coefficient view for a point.
	PointCoeffs : {
		e032 : F32,
		e013 : F32,
		e021 : F32,
		e123 : F32,
	}

	## Read-only coefficient view for a vector.
	VectorCoeffs : {
		e032 : F32,
		e013 : F32,
		e021 : F32,
	}

	## Read-only coefficient view for a plane.
	PlaneCoeffs : {
		e0 : F32,
		e1 : F32,
		e2 : F32,
		e3 : F32,
	}

	## Read-only coefficient view for a line.
	LineCoeffs : {
		e01 : F32,
		e02 : F32,
		e03 : F32,
		e23 : F32,
		e31 : F32,
		e12 : F32,
	}

	## Read-only coefficient view for a motor.
	MotorCoeffs : {
		s : F32,
		e23 : F32,
		e31 : F32,
		e12 : F32,
		e01 : F32,
		e02 : F32,
		e03 : F32,
		e0123 : F32,
	}

	## Construct a finite point from x, y, and z coordinates.
	point : F32, F32, F32 -> Point
	point = |x, y, z| { e032: x, e013: y, e021: z, e123: 1 }

	## Construct a finite point on the z=0 plane.
	point_xy : F32, F32 -> Point
	point_xy = |x, y| Physics.point(x, y, 0)

	## The finite point at the coordinate origin.
	origin : Point
	origin = Physics.point(0, 0, 0)

	## Construct a free vector from x, y, and z components.
	vector : F32, F32, F32 -> Vector
	vector = |x, y, z| { e032: x, e013: y, e021: z }

	## Construct a free vector on the z=0 plane.
	vector_xy : F32, F32 -> Vector
	vector_xy = |x, y| Physics.vector(x, y, 0)

	## The zero vector.
	zero : Vector
	zero = Physics.vector(0, 0, 0)

	## Return normalized x, y, and z coordinates for a point.
	coords : Point -> Coords
	coords = |p| {
		w = if p.e123 == 0 1 else p.e123
		{ x: p.e032 / w, y: p.e013 / w, z: p.e021 / w }
	}

	## Return x, y, and z components for a free vector.
	components : Vector -> Coords
	components = |v| { x: v.e032, y: v.e013, z: v.e021 }

	## Return the x/y components of a point for 2D drawing boundaries.
	xy : Point -> Math.Vec2
	xy = |p| {
		c = Physics.coords(p)
		{ x: c.x, y: c.y }
	}

	## Return the x/y components of a vector for 2D drawing boundaries.
	vector_xy_components : Vector -> Math.Vec2
	vector_xy_components = |v| { x: v.e032, y: v.e013 }

	## Return a read-only point coefficient record.
	point_coeffs : Point -> PointCoeffs
	point_coeffs = |p| { e032: p.e032, e013: p.e013, e021: p.e021, e123: p.e123 }

	## Return a read-only vector coefficient record.
	vector_coeffs : Vector -> VectorCoeffs
	vector_coeffs = |v| { e032: v.e032, e013: v.e013, e021: v.e021 }

	## Return a read-only plane coefficient record.
	plane_coeffs : Plane -> PlaneCoeffs
	plane_coeffs = |p| { e0: p.e0, e1: p.e1, e2: p.e2, e3: p.e3 }

	## Return a read-only line coefficient record.
	line_coeffs : Line -> LineCoeffs
	line_coeffs = |l| { e01: l.e01, e02: l.e02, e03: l.e03, e23: l.e23, e31: l.e31, e12: l.e12 }

	## Return a read-only motor coefficient record.
	motor_coeffs : Motor -> MotorCoeffs
	motor_coeffs = |m| { s: m.s, e23: m.e23, e31: m.e31, e12: m.e12, e01: m.e01, e02: m.e02, e03: m.e03, e0123: m.e0123 }

	## Translate a point by a free vector.
	add : Point, Vector -> Point
	add = |p, v| {
		c = Physics.coords(p)
		Physics.point(c.x + v.e032, c.y + v.e013, c.z + v.e021)
	}

	## Return the free vector from the second point to the first point.
	sub : Point, Point -> Vector
	sub = |a, b| {
		ac = Physics.coords(a)
		bc = Physics.coords(b)
		Physics.vector(ac.x - bc.x, ac.y - bc.y, ac.z - bc.z)
	}

	## Add two free vectors.
	add_vec : Vector, Vector -> Vector
	add_vec = |a, b| Physics.vector(a.e032 + b.e032, a.e013 + b.e013, a.e021 + b.e021)

	## Subtract the second free vector from the first.
	sub_vec : Vector, Vector -> Vector
	sub_vec = |a, b| Physics.vector(a.e032 - b.e032, a.e013 - b.e013, a.e021 - b.e021)

	## Scale a free vector by a scalar amount.
	scale : Vector, F32 -> Vector
	scale = |v, amount| Physics.vector(v.e032 * amount, v.e013 * amount, v.e021 * amount)

	## Compute the Euclidean dot product of two free vectors.
	dot : Vector, Vector -> F32
	dot = |a, b| a.e032 * b.e032 + a.e013 * b.e013 + a.e021 * b.e021

	## Compute the Euclidean cross product of two free vectors.
	cross : Vector, Vector -> Vector
	cross = |a, b| {
		Physics.vector(
			a.e013 * b.e021 - a.e021 * b.e013,
			a.e021 * b.e032 - a.e032 * b.e021,
			a.e032 * b.e013 - a.e013 * b.e032,
		)
	}

	## Compute the squared Euclidean length of a free vector.
	length_squared : Vector -> F32
	length_squared = |v| Physics.dot(v, v)

	## Compute the Euclidean length of a free vector.
	length : Vector -> F32
	length = |v| Math.sqrt(Physics.length_squared(v))

	## Return a unit-length vector, or zero for a zero-length input.
	normalize : Vector -> Vector
	normalize = |v| {
		len = Physics.length(v)
		if len == 0 Physics.zero else Physics.scale(v, 1 / len)
	}

	## Compute the Euclidean distance between two finite points.
	distance : Point, Point -> F32
	distance = |a, b| Physics.length(Physics.sub(a, b))

	## Construct a normalized plane from a normal and signed distance to origin.
	plane : Vector, F32 -> Plane
	plane = |normal, distance_to_origin| {
		n = Physics.normalize(normal)
		len = Physics.length(normal)
		d = if len == 0 0 else distance_to_origin / len
		{ e0: 0 - d, e1: n.e032, e2: n.e013, e3: n.e021 }
	}

	## Construct a plane through a point with the given normal direction.
	plane_from_point_normal : Point, Vector -> Plane
	plane_from_point_normal = |point_value, normal| {
		n = Physics.normalize(normal)
		c = Physics.coords(point_value)
		Physics.plane(n, n.e032 * c.x + n.e013 * c.y + n.e021 * c.z)
	}

	## Compute the signed Euclidean distance from a normalized plane to a point.
	signed_distance : Plane, Point -> F32
	signed_distance = |plane_value, point_value| {
		c = Physics.coords(point_value)
		plane_value.e1 * c.x + plane_value.e2 * c.y + plane_value.e3 * c.z + plane_value.e0
	}

	## Project a point onto a normalized plane.
	project_point_plane : Plane, Point -> Point
	project_point_plane = |plane_value, point_value| {
		offset = Physics.scale(Physics.vector(plane_value.e1, plane_value.e2, plane_value.e3), 0 - Physics.signed_distance(plane_value, point_value))
		Physics.add(point_value, offset)
	}

	## Construct a PGA line passing through two finite points.
	line_from_points : Point, Point -> Line
	line_from_points = |a, b| {
		ac = Physics.coords(a)
		bc = Physics.coords(b)
		direction = Physics.sub(b, a)
		moment = Physics.cross(Physics.vector(ac.x, ac.y, ac.z), Physics.vector(bc.x, bc.y, bc.z))
		{
			e01: moment.e032,
			e02: moment.e013,
			e03: moment.e021,
			e23: direction.e032,
			e31: direction.e013,
			e12: direction.e021,
		}
	}

	## The identity motor.
	motor_identity : Motor
	motor_identity = { s: 1, e23: 0, e31: 0, e12: 0, e01: 0, e02: 0, e03: 0, e0123: 0 }

	## Construct a translation motor from a free offset vector.
	translation : Vector -> Motor
	translation = |offset| {
		{
			s: 1,
			e23: 0,
			e31: 0,
			e12: 0,
			e01: -0.5 * offset.e032,
			e02: -0.5 * offset.e013,
			e03: -0.5 * offset.e021,
			e0123: 0,
		}
	}

	## Extract the translation offset represented by a translation motor.
	translation_vector : Motor -> Vector
	translation_vector = |motor| Physics.vector(-2 * motor.e01, -2 * motor.e02, -2 * motor.e03)

	## Apply a translation motor to a finite point.
	apply_motor_point : Motor, Point -> Point
	apply_motor_point = |motor, point_value| Physics.add(point_value, Physics.translation_vector(motor))

	## Construct a simple particle body.
	body : Point, Vector -> Body
	body = |position, velocity| { position, velocity }

	## Integrate acceleration into a body's velocity over a time step.
	apply_acceleration : Body, Vector, F32 -> Body
	apply_acceleration = |body_value, acceleration, dt| {
		..body_value,
		velocity: Physics.add_vec(body_value.velocity, Physics.scale(acceleration, dt)),
	}

	## Integrate velocity into a body's position over a time step.
	integrate_body : Body, F32 -> Body
	integrate_body = |body_value, dt| {
		..body_value,
		position: Physics.add(body_value.position, Physics.scale(body_value.velocity, dt)),
	}

	## Clamp only the y component of a free vector.
	clamp_y : Vector, F32, F32 -> Vector
	clamp_y = |value, lo, hi| Physics.vector(value.e032, Math.clamp(value.e013, lo, hi), value.e021)

}

expect Physics.coords(Physics.point(3, 4, 5)) == { x: 3, y: 4, z: 5 }
expect Physics.xy(Physics.point_xy(3, 4)) == { x: 3, y: 4 }
expect Physics.components(Physics.vector(3, 4, 5)) == { x: 3, y: 4, z: 5 }
expect Physics.length(Physics.vector(3, 4, 0)) == 5
expect Physics.distance(Physics.origin, Physics.point(2, 3, 6)) == 7
expect Physics.components(Physics.normalize(Physics.vector(0, 3, 4))) == { x: 0, y: 0.6, z: 0.8 }
expect Physics.point_coeffs(Physics.point(3, 4, 5)) == { e032: 3, e013: 4, e021: 5, e123: 1 }
expect Physics.vector_coeffs(Physics.vector(3, 4, 5)) == { e032: 3, e013: 4, e021: 5 }
expect {
	ground = Physics.plane(Physics.vector(0, 1, 0), 0)
	Physics.signed_distance(ground, Physics.point(2, 5, 3)) == 5
}
expect Physics.coords(Physics.project_point_plane(Physics.plane(Physics.vector(0, 1, 0), 0), Physics.point(2, 5, 3))) == { x: 2, y: 0, z: 3 }
expect Physics.line_coeffs(Physics.line_from_points(Physics.origin, Physics.point(4, 0, 0))) == { e01: 0, e02: 0, e03: 0, e23: 4, e31: 0, e12: 0 }
expect Physics.coords(Physics.apply_motor_point(Physics.translation(Physics.vector(2, 3, 4)), Physics.point(1, 1, 1))) == { x: 3, y: 4, z: 5 }
expect {
	body0 = Physics.body(Physics.origin, Physics.vector(10, 0, 0))
	body1 = Physics.apply_acceleration(body0, Physics.vector(0, -2, 0), 0.5)
	body2 = Physics.integrate_body(body1, 2)
	Physics.coords(body2.position) == { x: 20, y: -2, z: 0 }
}
