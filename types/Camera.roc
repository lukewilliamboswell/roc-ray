## Camera module - pure 2D camera settings for world-space drawing.
##
## A camera is a value, not a host-owned resource. Build the camera you want
## for the current frame and pass it to `Draw.with_camera!`.
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
	## non-invertible zero zoom cannot bypass validation.
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

		## Return a copy focused on a finite world-space target.
		with_target : Camera2D, Math.Vec2 -> Try(Camera2D, [NonFiniteTarget, ..])
		with_target = |camera, new_target|
			if vec_is_finite(new_target) Ok({ ..camera, target: new_target }) else Err(NonFiniteTarget)

		## Return a copy with a finite logical screen-space offset.
		with_offset : Camera2D, Math.Vec2 -> Try(Camera2D, [NonFiniteOffset, ..])
		with_offset = |camera, new_offset|
			if vec_is_finite(new_offset) Ok({ ..camera, offset: new_offset }) else Err(NonFiniteOffset)

		## Return a copy with a finite clockwise rotation in degrees.
		with_rotation : Camera2D, F32 -> Try(Camera2D, [NonFiniteRotation, ..])
		with_rotation = |camera, new_rotation|
			if F32.is_finite(new_rotation) Ok({ ..camera, rotation: new_rotation }) else Err(NonFiniteRotation)

		## Return a copy with a validated finite, non-zero zoom factor.
		with_zoom : Camera2D, F32 -> Try(Camera2D, [ZeroZoom, NonFiniteZoom, ..])
		with_zoom = |camera, new_zoom|
			if new_zoom == 0 {
				Err(ZeroZoom)
			} else if !(F32.is_finite(new_zoom)) {
				Err(NonFiniteZoom)
			} else {
				Ok({ ..camera, zoom: new_zoom })
			}

		## Clamp zoom to inclusive limits, reporting a range that produces zero.
		clamp_zoom : Camera2D, { min : F32, max : F32 } -> Try(Camera2D, [ZeroZoom, NonFiniteZoom, ..])
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
		## is invertible because construction rejects zero zoom.
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

	## Identity camera: no offset or rotation, with unit zoom.
	default : Camera2D
	default = { target: Math.zero, offset: Math.zero, rotation: 0, zoom: 1 }

	## Construct a camera from explicit settings, rejecting every non-finite
	## transform field and zero zoom.
	new : Settings -> Try(Camera2D, [ZeroZoom, NonFiniteZoom, NonFiniteTarget, NonFiniteOffset, NonFiniteRotation, ..])
	new = |settings|
		if settings.zoom == 0 {
			Err(ZeroZoom)
		} else if !(F32.is_finite(settings.zoom)) {
			Err(NonFiniteZoom)
		} else if !(vec_is_finite(settings.target)) {
			Err(NonFiniteTarget)
		} else if !(vec_is_finite(settings.offset)) {
			Err(NonFiniteOffset)
		} else if !(F32.is_finite(settings.rotation)) {
			Err(NonFiniteRotation)
		} else {
			Ok(settings)
		}

	## Place `target` at the center of a screen with unit zoom.
	centered : Math.Vec2, Math.Vec2 -> Try(Camera2D, [NonFiniteTarget, NonFiniteOffset, ..])
	centered = |target_value, screen_size|
		if !(vec_is_finite(target_value)) {
			Err(NonFiniteTarget)
		} else if !(vec_is_finite(screen_size)) {
			Err(NonFiniteOffset)
		} else {
			Ok({
				target: target_value,
				offset: screen_size.scale(0.5),
				rotation: 0,
				zoom: 1,
			})
		}

	## A common player-follow camera with a validated configurable zoom.
	follow : Math.Vec2, { screen : Math.Vec2, zoom : F32 } -> Try(Camera2D, [ZeroZoom, NonFiniteZoom, NonFiniteTarget, NonFiniteOffset, ..])
	follow = |target_value, cfg|
		if cfg.zoom == 0 {
			Err(ZeroZoom)
		} else if !(F32.is_finite(cfg.zoom)) {
			Err(NonFiniteZoom)
		} else if !(vec_is_finite(target_value)) {
			Err(NonFiniteTarget)
		} else if !(vec_is_finite(cfg.screen)) {
			Err(NonFiniteOffset)
		} else {
			Ok({
				target: target_value,
				offset: cfg.screen.scale(0.5),
				rotation: 0,
				zoom: cfg.zoom,
			})
		}
}

vec_is_finite : Math.Vec2 -> Bool
vec_is_finite = |vec| F32.is_finite(vec.x) and F32.is_finite(vec.y)

expect match Camera.centered({ x: 10, y: 20 }, { x: 800, y: 600 }) {
	Ok(camera) => camera.offset() == { x: 400, y: 300 }
	Err(_) => False
}
expect match Camera.default.with_zoom(0) {
	Err(ZeroZoom) => True
	_ => False
}
expect match Camera.default.with_zoom(F32.nan) {
	Err(NonFiniteZoom) => True
	_ => False
}
expect match Camera.default.with_zoom(F32.infinity) {
	Err(NonFiniteZoom) => True
	_ => False
}
expect match Camera.default.with_zoom(0 - F32.infinity) {
	Err(NonFiniteZoom) => True
	_ => False
}
expect match Camera.default.with_target({ x: F32.nan, y: 0 }) {
	Err(NonFiniteTarget) => True
	_ => False
}
expect match Camera.default.with_offset({ x: 0, y: F32.infinity }) {
	Err(NonFiniteOffset) => True
	_ => False
}
expect match Camera.default.with_rotation(F32.nan) {
	Err(NonFiniteRotation) => True
	_ => False
}
expect Camera.default.world_to_screen({ x: 12, y: 34 }) == { x: 12, y: 34 }
expect match Camera.centered({ x: 10, y: 20 }, { x: 800, y: 600 }) {
	Ok(camera) => camera.world_to_screen({ x: 10, y: 20 }) == { x: 400, y: 300 }
	Err(_) => False
}
expect {
	result = Camera.new({ target: { x: 10, y: -5 }, offset: { x: 320, y: 240 }, rotation: 37, zoom: 2.5 })
	match result {
		Ok(camera) => {
			world = Math.vec2(42, 11)
			round_trip = camera.screen_to_world(camera.world_to_screen(world))
			F32.abs(round_trip.x - world.x) < 0.001 and F32.abs(round_trip.y - world.y) < 0.001
		}
		Err(_) => False
	}
}
expect Camera.default.viewport({ x: 80, y: 40 }) == Math.rect(0, 0, 80, 40)
