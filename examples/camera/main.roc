## Shows a movable camera over a larger 2D world with a fixed on-screen HUD.
## Move with WASD or the arrow keys, zoom with the mouse wheel, rotate with
## Q/E, reset with R, and quit with Escape. This example demonstrates camera
## drawing and converting positions between world and screen coordinates.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/3vVeddfDE6rraq5j8v1cGHtFNaQhC6dij1zGRN63NGP1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Camera
import rr.Color
import rr.Draw
import rr.Devices
import rr.Math
import rr.Text

## The Model is the app state kept between updates: the player's world
## position, camera settings, latest pointer position, and prepared HUD text.
## Coordinate conversions are calculated while drawing, so they always use
## the camera being drawn with.
Model : {
	player : Math.Vec2,
	zoom : F32,
	rotation : F32,
	mouse : Math.Vec2,
	hud : Box({ title : Text.Prepared, subtitle : Text.Prepared, help : Text.Prepared }),
}

program = { init!, update!, render! }

screen_w = 800.F32

screen_h = 600.F32

world_left = -800.F32

world_right = 1600.F32

world_top = -600.F32

world_bottom = 1200.F32

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default.with_title("RocRay Camera").with_frame_pacing(Capped(120)),
	|_startup| {
		font = Draw.default_font!()
		Ok({
			player: { x: 400, y: 300 },
			zoom: 1,
			rotation: 0,
			mouse: { x: 0, y: 0 },
			hud: Box.box({
				title: Text.from("Camera world", font).size(24).prepare!()?,
				subtitle: Text.from("world-space draw + screen-space HUD", font).size(18).prepare!()?,
				help: Text.from("WASD move, wheel zoom, Q/E rotate, R reset", font).size(14).prepare!()?,
			}),
		})
	},
)

axis : Bool, Bool -> F32
axis = |negative, positive| if negative -1 else if positive 1 else 0

## Moves the player from the current keyboard state and elapsed time. Passing
## only these values keeps the movement rules easy to test separately.
move_player : Math.Vec2, Devices.Snapshot, F32 -> Math.Vec2
move_player = |player, input, dt| {
	left = input.key_down(KeyLeft) or input.key_down(KeyA)
	right = input.key_down(KeyRight) or input.key_down(KeyD)
	up = input.key_down(KeyUp) or input.key_down(KeyW)
	down = input.key_down(KeyDown) or input.key_down(KeyS)

	speed = 360
	{
		x: Math.clamp(player.x + axis(left, right) * speed * dt, world_left + 40, world_right - 40),
		y: Math.clamp(player.y + axis(up, down) * speed * dt, world_top + 40, world_bottom - 40),
	}
}

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	input = program_input.devices
	dt = program_input.time.elapsed_seconds

	player = move_player(model.player, input, dt)
	zoom = Math.clamp(model.zoom + input.mouse.wheel * 0.1, 0.5, 2.5)
	rotation_dir = axis(input.key_down(KeyQ), input.key_down(KeyE))
	rotation = if input.key_pressed(KeyR) 0 else model.rotation + rotation_dir * 90 * dt

	if input.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		Ok({ ..model, player, zoom, rotation, mouse: input.mouse.position() })
	}
}

## Builds the camera and coordinate conversions from the latest Model. This
## avoids storing calculated values that could become inconsistent.
render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ..])
render! = |model, frame| {
	draw = App.effects().render(frame)
	camera = Camera.follow(model.player, { screen: { x: screen_w, y: screen_h }, zoom: model.zoom }).with_rotation(model.rotation)
	mouse_world = camera.screen_to_world(model.mouse)
	mouse_screen = camera.world_to_screen(mouse_world)
	view = camera_world_bounds(camera)

	draw.rectangle_gradient_v!({ x: 0, y: 0, width: screen_w, height: screen_h, color_top: Color.from_hex_rgb(0x101a24), color_bottom: Color.from_hex_rgb(0x060a0f) })
	frame.with_camera!(
		camera,
		|world_frame| {
			draw_world!(world_frame, model.player, mouse_world, view)
			Ok({})
		},
	)?
	# Drawn outside the camera scope: `world_to_screen` is what puts a
	# screen-space mark back on top of a world-space point.
	draw.circle!({ center: mouse_screen, radius: 7, style: Draw.outlined(Color.from_hex_rgb(0xffd166), 2) })
	draw.line!({ start: { x: mouse_screen.x - 14, y: mouse_screen.y }, end: { x: mouse_screen.x + 14, y: mouse_screen.y }, stroke: Draw.stroke(Color.with_alpha(Color.from_hex_rgb(0xffd166), 140), 1) })
	draw.line!({ start: { x: mouse_screen.x, y: mouse_screen.y - 14 }, end: { x: mouse_screen.x, y: mouse_screen.y + 14 }, stroke: Draw.stroke(Color.with_alpha(Color.from_hex_rgb(0xffd166), 140), 1) })
	draw_hud!(frame, model, mouse_world)

	Ok({})
}

camera_world_bounds : Camera.Camera2D -> Math.Rect
camera_world_bounds = |camera| {
	top_left = camera.screen_to_world({ x: 0, y: 0 })
	top_right = camera.screen_to_world({ x: screen_w, y: 0 })
	bottom_left = camera.screen_to_world({ x: 0, y: screen_h })
	bottom_right = camera.screen_to_world({ x: screen_w, y: screen_h })
	left = F32.min(F32.min(top_left.x, top_right.x), F32.min(bottom_left.x, bottom_right.x))
	right = F32.max(F32.max(top_left.x, top_right.x), F32.max(bottom_left.x, bottom_right.x))
	top = F32.min(F32.min(top_left.y, top_right.y), F32.min(bottom_left.y, bottom_right.y))
	bottom = F32.max(F32.max(top_left.y, top_right.y), F32.max(bottom_left.y, bottom_right.y))
	Math.rect(left, top, right - left, bottom - top)
}

draw_world! : Draw.Frame, Math.Vec2, Math.Vec2, Math.Rect => {}
draw_world! = |frame, player, mouse_world, view| {
	draw = App.effects().render(frame)
	draw.rectangle!({ x: world_left, y: world_top, width: world_right - world_left, height: world_bottom - world_top, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x16222b), Color.with_alpha(Color.from_hex_rgb(0x5fa8d3), 90), 3) })
	draw_grid_x!(frame, world_left, view)
	draw_grid_y!(frame, world_top, view)

	landmark!(frame, { x: -320, y: -160, width: 360, height: 260 }, Color.from_hex_rgb(0x3b6f8f))
	landmark!(frame, { x: 280, y: 120, width: 520, height: 340 }, Color.from_hex_rgb(0x4c8f5f))
	landmark!(frame, { x: 860, y: -280, width: 420, height: 460 }, Color.from_hex_rgb(0x8f6540))

	axis_color = Color.with_alpha(Color.from_hex_rgb(0xffd166), 200)
	draw.line!({ start: { x: world_left, y: 0 }, end: { x: world_right, y: 0 }, stroke: Draw.stroke(axis_color, 3) })
	draw.line!({ start: { x: 0, y: world_top }, end: { x: 0, y: world_bottom }, stroke: Draw.stroke(axis_color, 3) })

	draw.circle!({ center: { x: player.x, y: player.y + 6 }, radius: 26, style: Draw.filled(Color.with_alpha(Color.black, 110)) })
	draw.circle!({ center: player, radius: 26, style: Draw.filled_and_outlined(Color.from_hex_rgb(0xef476f), Color.white, 4) })
	draw.line!({ start: { x: player.x - 42, y: player.y }, end: { x: player.x + 42, y: player.y }, stroke: Draw.stroke(Color.white, 3) })
	draw.line!({ start: { x: player.x, y: player.y - 42 }, end: { x: player.x, y: player.y + 42 }, stroke: Draw.stroke(Color.white, 3) })
	draw.circle!({ center: mouse_world, radius: 10, style: Draw.outlined(Color.from_hex_rgb(0xffd166), 2) })
}

## A world landmark: a soft shadow, the slab, and a lighter cap so the world
## reads as depth rather than as three flat swatches.
landmark! : Draw.Frame, { x : F32, y : F32, width : F32, height : F32 }, Color.Rgba => {}
landmark! = |frame, rect, color| {
	draw = App.effects().render(frame)
	draw.rectangle!({ x: rect.x + 10, y: rect.y + 14, width: rect.width, height: rect.height, style: Draw.filled(Color.with_alpha(Color.black, 90)) })
	draw.rectangle!({ x: rect.x, y: rect.y, width: rect.width, height: rect.height, style: Draw.filled(color) })
	draw.rectangle!({ x: rect.x, y: rect.y, width: rect.width, height: 10, style: Draw.filled(Color.with_alpha(Color.white, 45)) })
}

draw_grid_x! : Draw.Frame, F32, Math.Rect => {}
draw_grid_x! = |frame, x, view| {
	draw = App.effects().render(frame)
	if x > world_right {
		{}
	} else {
		if x >= view.x and x <= view.x + view.width {
			draw.line!({ start: { x, y: world_top }, end: { x, y: world_bottom }, stroke: Draw.stroke(Color.with_alpha(Color.white, 55), 1) })
		}
		draw_grid_x!(frame, x + 80, view)
	}
}

draw_grid_y! : Draw.Frame, F32, Math.Rect => {}
draw_grid_y! = |frame, y, view| {
	draw = App.effects().render(frame)
	if y > world_bottom {
		{}
	} else {
		if y >= view.y and y <= view.y + view.height {
			draw.line!({ start: { x: world_left, y }, end: { x: world_right, y }, stroke: Draw.stroke(Color.with_alpha(Color.white, 55), 1) })
		}
		draw_grid_y!(frame, y + 80, view)
	}
}

draw_hud! : Draw.Frame, Model, Math.Vec2 => {}
draw_hud! = |frame, model, mouse_world| {
	draw = App.effects().render(frame)
	hud = Box.unbox(model.hud)
	draw.rounded_rectangle!({ x: 16, y: 16, width: 340, height: 122, radius: 12, segments: 8, style: Draw.filled_and_outlined(Color.with_alpha(Color.from_hex_rgb(0x0b1219), 215), Color.with_alpha(Color.white, 40), 1) })
	hud.title.draw!(frame, { pos: { x: 32, y: 28 }, color: Color.white })
	hud.subtitle.draw!(frame, { pos: { x: 32, y: 60 }, color: Color.from_hex_rgb(0x8fa3b8) })
	draw.line!({ start: { x: 32, y: 84 }, end: { x: 340, y: 84 }, stroke: Draw.stroke(Color.with_alpha(Color.white, 30), 1) })
	# Show the pointer coordinates in both spaces for direct comparison.
	draw.text_at!({ pos: { x: 32, y: 92 }, text: "world ${coord(mouse_world.x)}, ${coord(mouse_world.y)}   zoom ${coord(model.zoom * 100)}%", size: 14, color: Color.from_hex_rgb(0xffd166) })
	hud.help.draw!(frame, { pos: { x: 32, y: 114 }, color: Color.from_hex_rgb(0x8fa3b8) })
}

## Whole units, so the readout does not jitter its own width every frame.
coord : F32 -> Str
coord = |value| I32.to_str(F32.to_i32_wrap(value))

expect axis(Bool.True, Bool.False) == -1
expect axis(Bool.False, Bool.False) == 0

## Movement integrates over the seconds it is handed, and stops at the world
## edge rather than running off it.
expect move_player({ x: 0, y: 0 }, Devices.none.with_key_down(KeyD), 0.5) == { x: 180, y: 0 }
expect move_player({ x: world_right, y: 0 }, Devices.none.with_key_down(KeyD), 1) == { x: world_right - 40, y: 0 }
