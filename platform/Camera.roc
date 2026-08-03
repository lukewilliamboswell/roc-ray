## Camera module - pure 2D camera settings for world-space drawing.
##
## A camera is a value, not a host-owned resource. Build the camera you want
## for the current frame and pass it to `Draw.with_camera!`.
import Math

Camera := [].{

	Settings : {
		target : Math.Vec2,
		offset : Math.Vec2,
		rotation : F32,
		zoom : F32,
	}

	Camera2D : Settings

	default : Camera2D
	default = {
		target: Math.zero,
		offset: Math.zero,
		rotation: 0,
		zoom: 1,
	}

	new : Settings -> Camera2D
	new = |settings| settings

	## Place `target` at the center of a screen with the given size.
	centered : Math.Vec2, Math.Vec2 -> Camera2D
	centered = |target, screen_size| {
		target,
		offset: Math.scale(screen_size, 0.5),
		rotation: 0,
		zoom: 1,
	}

	## A common player-follow camera with a configurable zoom.
	follow : Math.Vec2, { screen : Math.Vec2, zoom : F32 } -> Camera2D
	follow = |target, cfg| {
		target,
		offset: Math.scale(cfg.screen, 0.5),
		rotation: 0,
		zoom: cfg.zoom,
	}

	with_target : Camera2D, Math.Vec2 -> Camera2D
	with_target = |camera, target| {
		target,
		offset: camera.offset,
		rotation: camera.rotation,
		zoom: camera.zoom,
	}

	with_offset : Camera2D, Math.Vec2 -> Camera2D
	with_offset = |camera, offset| {
		target: camera.target,
		offset,
		rotation: camera.rotation,
		zoom: camera.zoom,
	}

	with_rotation : Camera2D, F32 -> Camera2D
	with_rotation = |camera, rotation| {
		target: camera.target,
		offset: camera.offset,
		rotation,
		zoom: camera.zoom,
	}

	with_zoom : Camera2D, F32 -> Camera2D
	with_zoom = |camera, zoom| {
		target: camera.target,
		offset: camera.offset,
		rotation: camera.rotation,
		zoom,
	}

	clamp_zoom : Camera2D, { min : F32, max : F32 } -> Camera2D
	clamp_zoom = |camera, limits| Camera.with_zoom(camera, Math.clamp(camera.zoom, limits.min, limits.max))

	## Convert a world-space point to logical screen coordinates.
	## Rotation uses degrees, matching raylib and `Draw.with_camera!`.
	world_to_screen : Camera2D, Math.Vec2 -> Math.Vec2
	world_to_screen = |camera, world| {
		radians = camera.rotation * 0.017453292519943295
		cos_rotation = F32.cos(radians)
		sin_rotation = F32.sin(radians)
		relative = Math.sub(world, camera.target)
		{
			x: (relative.x * cos_rotation - relative.y * sin_rotation) * camera.zoom + camera.offset.x,
			y: (relative.x * sin_rotation + relative.y * cos_rotation) * camera.zoom + camera.offset.y,
		}
	}

	## Convert logical screen coordinates back to world space. A zero-zoom
	## camera has no inverse and returns the camera target deterministically.
	screen_to_world : Camera2D, Math.Vec2 -> Math.Vec2
	screen_to_world = |camera, screen| {
		if camera.zoom == 0 {
			camera.target
		} else {
			radians = 0 - camera.rotation * 0.017453292519943295
			cos_rotation = F32.cos(radians)
			sin_rotation = F32.sin(radians)
			relative = Math.scale(Math.sub(screen, camera.offset), 1 / camera.zoom)
			Math.add(
				camera.target,
				{
					x: relative.x * cos_rotation - relative.y * sin_rotation,
					y: relative.x * sin_rotation + relative.y * cos_rotation,
				},
			)
		}
	}

}

expect Camera.centered({ x: 10, y: 20 }, { x: 800, y: 600 }).offset == { x: 400, y: 300 }
expect Camera.clamp_zoom(Camera.with_zoom(Camera.default, 0.05), { min: 0.25, max: 4 }).zoom == 0.25
expect Camera.world_to_screen(Camera.default, { x: 12, y: 34 }) == { x: 12, y: 34 }
expect Camera.world_to_screen(Camera.centered({ x: 10, y: 20 }, { x: 800, y: 600 }), { x: 10, y: 20 }) == { x: 400, y: 300 }
expect {
	camera = Camera.new({ target: { x: 10, y: -5 }, offset: { x: 320, y: 240 }, rotation: 37, zoom: 2.5 })
	world = { x: 42, y: 11 }
	round_trip = Camera.screen_to_world(camera, Camera.world_to_screen(camera, world))
	F32.abs(round_trip.x - world.x) < 0.001 and F32.abs(round_trip.y - world.y) < 0.001
}
