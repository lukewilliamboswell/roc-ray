## Pure 2D camera settings for world-space drawing.
##
## A camera is a value, not a host-owned resource. Build the camera you want
## for the current frame and pass it to `Draw.with_camera!`, which applies it
## for the duration of a nested scope.
##
## ```roc
## camera = Camera.centered(model.player, Math.vec2(800, 600))
## frame.with_camera!(camera, |world| {
##     world.circle!({ center: model.player, radius: 12, style: Draw.filled(Color.white) })
##     Ok({})
## })?
## ```
##
## Every constructor and builder here is total: it answers with a `Camera2D`
## rather than a `Try`. A camera has exactly two invariants -- every transform
## field is finite, and the zoom is non-zero so `screen_to_world` can invert it
## -- and the only inputs that can break them are inputs no caller means to
## pass. Rather than make every app carry an unreachable `Err` branch for
## those, they are sanitized on the way in. A `target` or `offset` component
## that is not finite becomes `0`, as does a `rotation` that is not finite; a
## `zoom` that is zero or not finite becomes `fallback_zoom`, keeping its sign
## so a mirrored camera stays mirrored.
##
## Nothing else is touched. Sanitizing only ever rewrites a value a validating
## API would have refused outright, so a camera built from ordinary numbers
## comes back with its fields unchanged -- negative, axis-mirroring zooms
## included.
import Math

Camera := [].{

	## Target, screen offset, clockwise rotation in degrees, and zoom factor.
	Settings : {
		target : Math.Vec2,
		offset : Math.Vec2,
		rotation : F32,
		zoom : F32,
	}

	## Immutable camera value accepted by drawing and coordinate transforms.
	## Its representation is opaque so non-finite transform fields or a
	## non-invertible zero zoom cannot bypass the sanitizing below.
	Camera2D :: {
		target : Math.Vec2,
		offset : Math.Vec2,
		rotation : F32,
		zoom : F32,
	}.{

		## World-space point placed at the camera offset.
		target : Camera2D -> Math.Vec2
		target = |camera| camera.target

		## Logical screen-space offset of the target.
		offset : Camera2D -> Math.Vec2
		offset = |camera| camera.offset

		## Clockwise camera rotation in degrees.
		rotation : Camera2D -> F32
		rotation = |camera| camera.rotation

		## Non-zero camera zoom factor. Negative values intentionally mirror axes.
		zoom : Camera2D -> F32
		zoom = |camera| camera.zoom

		## Return a copy focused on `new_target`.
		##
		## Total: a component of `new_target` that is not finite becomes `0`,
		## and every finite coordinate is kept exactly.
		with_target : Camera2D, Math.Vec2 -> Camera2D
		with_target = |camera, new_target| { ..camera, target: sane_vec(new_target) }

		## Return a copy with `new_offset` as its logical screen-space offset.
		##
		## Total: a component of `new_offset` that is not finite becomes `0`,
		## and every finite coordinate is kept exactly.
		with_offset : Camera2D, Math.Vec2 -> Camera2D
		with_offset = |camera, new_offset| { ..camera, offset: sane_vec(new_offset) }

		## Return a copy rotated `new_rotation` degrees clockwise.
		##
		## Total: a `new_rotation` that is not finite becomes `0`. Any finite
		## angle is kept exactly, including one outside 0 to 360 -- degrees wrap
		## through the sine and cosine, so there is no range to clamp to.
		with_rotation : Camera2D, F32 -> Camera2D
		with_rotation = |camera, new_rotation| { ..camera, rotation: sane_scalar(new_rotation) }

		## Return a copy zoomed by `new_zoom`.
		##
		## Total: a `new_zoom` of zero has no inverse and one that is not finite
		## has no meaning, so either becomes `fallback_zoom` with the same sign.
		## Every other zoom is kept exactly, so a negative zoom still mirrors
		## both axes.
		with_zoom : Camera2D, F32 -> Camera2D
		with_zoom = |camera, new_zoom| { ..camera, zoom: sane_zoom(new_zoom) }

		## Clamp zoom to inclusive limits.
		##
		## Total: limits that produce a zero or non-finite zoom fall back to
		## `fallback_zoom`, exactly as `with_zoom` does.
		clamp_zoom : Camera2D, { min : F32, max : F32 } -> Camera2D
		clamp_zoom = |camera, limits| camera.with_zoom(Math.clamp(camera.zoom, limits.min, limits.max))

		## Convert a world-space point to logical screen coordinates.
		## Rotation uses degrees, matching raylib and `Draw.with_camera!`.
		world_to_screen : Camera2D, Math.Vec2 -> Math.Vec2
		world_to_screen = |camera, world| {
			radians = camera.rotation * 0.017453292519943295
			cos_rotation = F32.cos(radians)
			sin_rotation = F32.sin(radians)
			relative = world.sub(camera.target)
			{
				x: (relative.x * cos_rotation - relative.y * sin_rotation) * camera.zoom + camera.offset.x,
				y: (relative.x * sin_rotation + relative.y * cos_rotation) * camera.zoom + camera.offset.y,
			}
		}

		## Convert logical screen coordinates back to world space. Every Camera2D
		## is invertible because no constructor lets a zoom of zero through.
		screen_to_world : Camera2D, Math.Vec2 -> Math.Vec2
		screen_to_world = |camera, screen| {
			radians = 0 - camera.rotation * 0.017453292519943295
			cos_rotation = F32.cos(radians)
			sin_rotation = F32.sin(radians)
			relative = screen.sub(camera.offset).scale(1 / camera.zoom)
			camera.target.add({
				x: relative.x * cos_rotation - relative.y * sin_rotation,
				y: relative.x * sin_rotation + relative.y * cos_rotation,
			})
		}

		## World-space axis-aligned bounds visible through this camera. This handles
		## non-centered offsets, rotation, and mirrored (negative) zoom.
		viewport : Camera2D, Math.Vec2 -> Math.Rect
		viewport = |camera, screen_size| {
			top_left = camera.screen_to_world(Math.zero)
			top_right = camera.screen_to_world({ x: screen_size.x, y: 0 })
			bottom_left = camera.screen_to_world({ x: 0, y: screen_size.y })
			bottom_right = camera.screen_to_world(screen_size)
			left = F32.min(F32.min(top_left.x, top_right.x), F32.min(bottom_left.x, bottom_right.x))
			top = F32.min(F32.min(top_left.y, top_right.y), F32.min(bottom_left.y, bottom_right.y))
			right = F32.max(F32.max(top_left.x, top_right.x), F32.max(bottom_left.x, bottom_right.x))
			bottom = F32.max(F32.max(top_left.y, top_right.y), F32.max(bottom_left.y, bottom_right.y))
			Math.rect(left, top, right - left, bottom - top)
		}
	}

	## The zoom substituted for a zoom that cannot be used, meaning zero (which
	## has no inverse) or a non-finite one (which has no meaning).
	##
	## Deliberately tiny rather than `1`: a camera that had to be rescued
	## collapses the world to a dot at its offset, which reads on screen as the
	## mistake it is, instead of quietly looking plausible.
	fallback_zoom : F32
	fallback_zoom = 0.000001

	## Identity camera: no offset or rotation, with unit zoom.
	default : Camera2D
	default = { target: Math.zero, offset: Math.zero, rotation: 0, zoom: 1 }

	## Construct a camera from explicit settings.
	##
	## Total: non-finite `target`, `offset`, and `rotation` components become
	## `0`, and a `zoom` of zero or one that is not finite becomes
	## `fallback_zoom` with the same sign. Every usable setting is kept exactly.
	new : Settings -> Camera2D
	new = |settings| {
		target: sane_vec(settings.target),
		offset: sane_vec(settings.offset),
		rotation: sane_scalar(settings.rotation),
		zoom: sane_zoom(settings.zoom),
	}

	## Place `target` at the center of a screen with unit zoom.
	##
	## Total: a non-finite component of either vector becomes `0`.
	centered : Math.Vec2, Math.Vec2 -> Camera2D
	centered = |target_value, screen_size| {
		target: sane_vec(target_value),
		offset: sane_vec(screen_size.scale(0.5)),
		rotation: 0,
		zoom: 1,
	}

	## A common player-follow camera with a configurable zoom.
	##
	## Total: a non-finite `target` or `screen` component becomes `0`, and a
	## `zoom` of zero or one that is not finite becomes `fallback_zoom` with the
	## same sign.
	follow : Math.Vec2, { screen : Math.Vec2, zoom : F32 } -> Camera2D
	follow = |target_value, cfg| {
		target: sane_vec(target_value),
		offset: sane_vec(cfg.screen.scale(0.5)),
		rotation: 0,
		zoom: sane_zoom(cfg.zoom),
	}
}

## A finite scalar is itself; anything else is `0`.
sane_scalar : F32 -> F32
sane_scalar = |value| if F32.is_finite(value) value else 0

## Sanitizing is per component, so one bad axis does not discard the good one.
sane_vec : Math.Vec2 -> Math.Vec2
sane_vec = |vec| { x: sane_scalar(vec.x), y: sane_scalar(vec.y) }

## Zero has no inverse and a non-finite zoom has no meaning, so both become the
## fallback. The sign is kept, so `-inf` still comes back mirrored; NaN has no
## sign to keep and comes back positive.
sane_zoom : F32 -> F32
sane_zoom = |zoom|
	if F32.is_finite(zoom) and zoom != 0 {
		zoom
	} else if zoom < 0 {
		0 - Camera.fallback_zoom
	} else {
		Camera.fallback_zoom
	}

# --- Sanitizing leaves usable values alone ----------------------------------

expect Camera.centered({ x: 10, y: 20 }, { x: 800, y: 600 }).offset() == { x: 400, y: 300 }
expect Camera.follow({ x: 100, y: 200 }, { screen: { x: 800, y: 600 }, zoom: 2 }).offset() == { x: 400, y: 300 }
expect {
	camera = Camera.new({ target: { x: 10, y: -5 }, offset: { x: 320, y: 240 }, rotation: 37, zoom: 2.5 })
	camera.target()
		== { x: 10, y: -5 }
		and camera.offset() == { x: 320, y: 240 }
			and camera.rotation() == 37
				and camera.zoom() == 2.5
}
expect Camera.default.with_target({ x: 3, y: -4 }).target() == { x: 3, y: -4 }
expect Camera.default.with_offset({ x: 3, y: -4 }).offset() == { x: 3, y: -4 }
expect Camera.default.with_rotation(720).rotation() == 720
expect Camera.default.with_zoom(2.5).zoom() == 2.5

## A negative zoom is a deliberate axis mirror, not a mistake, so it survives.
expect Camera.default.with_zoom(0 - 2).zoom() == 0 - 2
expect Camera.new({ target: Math.zero, offset: Math.zero, rotation: 0, zoom: 0 - 2 }).zoom() == 0 - 2

# --- A zoom that cannot be used becomes `fallback_zoom` ---------------------

expect Camera.default.with_zoom(0).zoom() == Camera.fallback_zoom
expect Camera.default.with_zoom(F32.nan).zoom() == Camera.fallback_zoom
expect Camera.default.with_zoom(F32.infinity).zoom() == Camera.fallback_zoom
expect Camera.default.with_zoom(0 - F32.infinity).zoom() == 0 - Camera.fallback_zoom
expect Camera.new({ target: Math.zero, offset: Math.zero, rotation: 0, zoom: 0 }).zoom() == Camera.fallback_zoom
expect Camera.follow({ x: 1, y: 2 }, { screen: { x: 800, y: 600 }, zoom: 0 }).zoom() == Camera.fallback_zoom
expect Camera.follow({ x: 1, y: 2 }, { screen: { x: 800, y: 600 }, zoom: F32.nan }).zoom() == Camera.fallback_zoom

## `clamp_zoom` inherits the rule: limits that cannot produce a usable zoom
## land on the fallback rather than refusing.
expect Camera.default.clamp_zoom({ min: 2, max: 4 }).zoom() == 2
expect Camera.default.clamp_zoom({ min: 0, max: 0 }).zoom() == Camera.fallback_zoom

# --- A coordinate that is not finite becomes 0, one component at a time -----

expect Camera.default.with_target({ x: F32.nan, y: 7 }).target() == { x: 0, y: 7 }
expect Camera.default.with_offset({ x: 3, y: F32.infinity }).offset() == { x: 3, y: 0 }
expect Camera.default.with_rotation(F32.nan).rotation() == 0
expect Camera.default.with_rotation(0 - F32.infinity).rotation() == 0
expect {
	camera = Camera.new({ target: { x: F32.nan, y: 7 }, offset: { x: 3, y: F32.infinity }, rotation: F32.nan, zoom: 1 })
	camera.target() == { x: 0, y: 7 } and camera.offset() == { x: 3, y: 0 } and camera.rotation() == 0
}
expect Camera.centered({ x: F32.nan, y: 20 }, { x: 800, y: F32.infinity }).target() == { x: 0, y: 20 }
expect Camera.centered({ x: F32.nan, y: 20 }, { x: 800, y: F32.infinity }).offset() == { x: 400, y: 0 }
expect Camera.follow({ x: F32.infinity, y: 2 }, { screen: { x: 800, y: 600 }, zoom: 2 }).target() == { x: 0, y: 2 }

# --- Whatever goes in, the camera that comes out is still usable ------------

## The point of sanitizing rather than refusing: every camera a caller can
## build transforms both ways without dividing by zero or producing a NaN.
expect {
	camera = Camera.new({ target: { x: F32.nan, y: 0 }, offset: { x: 0, y: F32.infinity }, rotation: F32.nan, zoom: 0 })
	world = Math.vec2(42, 11)
	round_trip = camera.screen_to_world(camera.world_to_screen(world))
	F32.abs(round_trip.x - world.x) < 0.001 and F32.abs(round_trip.y - world.y) < 0.001
}

# --- The transforms themselves ----------------------------------------------

expect Camera.default.world_to_screen({ x: 12, y: 34 }) == { x: 12, y: 34 }
expect Camera.centered({ x: 10, y: 20 }, { x: 800, y: 600 }).world_to_screen({ x: 10, y: 20 }) == { x: 400, y: 300 }
expect {
	camera = Camera.new({ target: { x: 10, y: -5 }, offset: { x: 320, y: 240 }, rotation: 37, zoom: 2.5 })
	world = Math.vec2(42, 11)
	round_trip = camera.screen_to_world(camera.world_to_screen(world))
	F32.abs(round_trip.x - world.x) < 0.001 and F32.abs(round_trip.y - world.y) < 0.001
}
expect Camera.default.viewport({ x: 80, y: 40 }) == Math.rect(0, 0, 80, 40)
