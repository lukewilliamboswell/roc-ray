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
	## Its representation is opaque so a non-invertible zero zoom cannot be
	## constructed without going through a validating operation.
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

		## Return a copy focused on a new world-space target.
		with_target : Camera2D, Math.Vec2 -> Camera2D
		with_target = |camera, new_target| { ..camera, target: new_target }

		## Return a copy with a new logical screen-space offset.
		with_offset : Camera2D, Math.Vec2 -> Camera2D
		with_offset = |camera, new_offset| { ..camera, offset: new_offset }

		## Return a copy with a new clockwise rotation in degrees.
		with_rotation : Camera2D, F32 -> Camera2D
		with_rotation = |camera, new_rotation| { ..camera, rotation: new_rotation }

		## Return a copy with a validated non-zero zoom factor.
		with_zoom : Camera2D, F32 -> Try(Camera2D, [ZeroZoom, ..])
		with_zoom = |camera, new_zoom|
			if new_zoom == 0 {
				Err(ZeroZoom)
			} else {
				Ok({ ..camera, zoom: new_zoom })
			}

		## Clamp zoom to inclusive limits, reporting a range that produces zero.
		clamp_zoom : Camera2D, { min : F32, max : F32 } -> Try(Camera2D, [ZeroZoom, ..])
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

	## Construct a camera from explicit settings, rejecting zero zoom.
	new : Settings -> Try(Camera2D, [ZeroZoom, ..])
	new = |settings|
		if settings.zoom == 0 {
			Err(ZeroZoom)
		} else {
			Ok(settings)
		}

	## Place `target` at the center of a screen with unit zoom.
	centered : Math.Vec2, Math.Vec2 -> Camera2D
	centered = |target_value, screen_size| {
		target: target_value,
		offset: screen_size.scale(0.5),
		rotation: 0,
		zoom: 1,
	}

	## A common player-follow camera with a validated configurable zoom.
	follow : Math.Vec2, { screen : Math.Vec2, zoom : F32 } -> Try(Camera2D, [ZeroZoom, ..])
	follow = |target_value, cfg| Camera.new({
		target: target_value,
		offset: cfg.screen.scale(0.5),
		rotation: 0,
		zoom: cfg.zoom,
	})
}

expect Camera.centered({ x: 10, y: 20 }, { x: 800, y: 600 }).offset() == { x: 400, y: 300 }
expect match Camera.default.with_zoom(0) {
	Err(ZeroZoom) => True
	_ => False
}
expect Camera.default.world_to_screen({ x: 12, y: 34 }) == { x: 12, y: 34 }
expect Camera.centered({ x: 10, y: 20 }, { x: 800, y: 600 }).world_to_screen({ x: 10, y: 20 }) == { x: 400, y: 300 }
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
