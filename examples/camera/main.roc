app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-12-606470f" }

import rr.App
import rr.Camera
import rr.Color
import rr.Draw
import rr.Input
import rr.Math
import rr.Program
import rr.Text

Model : {
	player : Math.Vec2,
	zoom : F32,
	rotation : F32,
	mouse : Math.Vec2,
	hud : Box({ title : Text.Prepared, subtitle : Text.Prepared, help : Text.Prepared }),
}

program = { init!, update, render! }

screen_w = 800.F32

screen_h = 600.F32

world_left = -800.F32

world_right = 1600.F32

world_top = -600.F32

world_bottom = 1200.F32

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.static_config(App.default.with_title("RocRay Camera").with_frame_pacing(Capped(120))),
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

## Movement is input plus a duration, so that is exactly what it asks for: the
## sampled devices, and the seconds the caller wants integrated over.
move_player : Math.Vec2, Input.Snapshot, F32 -> Math.Vec2
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

update : Model, Program.Step(Msg) -> Program.Update(Model, Msg)
update = |model, step| {
	input = step.input
	dt = step.time.elapsed_seconds

	player = move_player(model.player, input, dt)
	zoom = Math.clamp(model.zoom + input.mouse.wheel * 0.1, 0.5, 2.5)
	rotation_dir = axis(input.key_down(KeyQ), input.key_down(KeyE))
	rotation = if input.key_pressed(KeyR) 0 else model.rotation + rotation_dir * 90 * dt

	Program.static({ ..model, player, zoom, rotation, mouse: input.mouse.position() })
		.with_actions(if input.key_pressed(KeyEscape) [Program.exit(0)] else [])
}

## The camera and both mouse projections are derived rather than stored: they
## are a pure function of the model, so keeping them out of it means there is
## one less thing that can disagree with itself.
render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ZeroZoom, NonFiniteZoom, NonFiniteTarget, NonFiniteOffset, NonFiniteRotation, ..])
render! = |model, frame| {
	camera = (Camera.follow(model.player, { screen: { x: screen_w, y: screen_h }, zoom: model.zoom })?).with_rotation(model.rotation)?
	mouse_world = camera.screen_to_world(model.mouse)
	mouse_screen = camera.world_to_screen(mouse_world)

	frame.clear!(Color.ray_white)
	frame.with_camera!(
		camera,
		|world_frame| {
			draw_world!(world_frame, model.player, mouse_world)
			Ok({})
		},
	)?
	frame.circle!({ center: mouse_screen, radius: 5, style: Draw.outlined(Color.yellow, 2) })
	draw_hud!(frame, model)

	Ok({})
}

draw_world! : Draw.Frame, Math.Vec2, Math.Vec2 => {}
draw_world! = |frame, player, mouse_world| {
	frame.rectangle!({ x: world_left, y: world_top, width: world_right - world_left, height: world_bottom - world_top, style: Draw.filled(Color.from_hex_rgb(0x23323a)) })
	draw_grid_x!(frame, world_left)
	draw_grid_y!(frame, world_top)

	frame.rectangle!({ x: -320, y: -160, width: 360, height: 260, style: Draw.filled(Color.from_hex_rgb(0x3b5f6f)) })
	frame.rectangle!({ x: 280, y: 120, width: 520, height: 340, style: Draw.filled(Color.from_hex_rgb(0x4c6f4f)) })
	frame.rectangle!({ x: 860, y: -280, width: 420, height: 460, style: Draw.filled(Color.from_hex_rgb(0x6f5540)) })

	frame.line!({ start: { x: world_left, y: 0 }, end: { x: world_right, y: 0 }, stroke: Draw.stroke(Color.yellow, 3) })
	frame.line!({ start: { x: 0, y: world_top }, end: { x: 0, y: world_bottom }, stroke: Draw.stroke(Color.yellow, 3) })

	frame.circle!({ center: player, radius: 26, style: Draw.filled_and_outlined(Color.red, Color.white, 4) })
	frame.line!({ start: { x: player.x - 42, y: player.y }, end: { x: player.x + 42, y: player.y }, stroke: Draw.stroke(Color.white, 3) })
	frame.line!({ start: { x: player.x, y: player.y - 42 }, end: { x: player.x, y: player.y + 42 }, stroke: Draw.stroke(Color.white, 3) })
	frame.circle!({ center: mouse_world, radius: 8, style: Draw.outlined(Color.yellow, 2) })
}

draw_grid_x! : Draw.Frame, F32 => {}
draw_grid_x! = |frame, x| {
	if x > world_right {
		{}
	} else {
		frame.line!({ start: { x, y: world_top }, end: { x, y: world_bottom }, stroke: Draw.stroke(Color.with_alpha(Color.white, 55), 1) })
		draw_grid_x!(frame, x + 80)
	}
}

draw_grid_y! : Draw.Frame, F32 => {}
draw_grid_y! = |frame, y| {
	if y > world_bottom {
		{}
	} else {
		frame.line!({ start: { x: world_left, y }, end: { x: world_right, y }, stroke: Draw.stroke(Color.with_alpha(Color.white, 55), 1) })
		draw_grid_y!(frame, y + 80)
	}
}

draw_hud! : Draw.Frame, Model => {}
draw_hud! = |frame, model| {
	hud = Box.unbox(model.hud)
	frame.rectangle!({ x: 16, y: 16, width: 320, height: 92, style: Draw.filled(Color.with_alpha(Color.black, 180)) })
	hud.title.draw!(frame, { pos: { x: 30, y: 28 }, color: Color.white, align: Text.align_top_left })
	hud.subtitle.draw!(frame, { pos: { x: 30, y: 62 }, color: Color.light_gray, align: Text.align_top_left })
	hud.help.draw!(frame, { pos: { x: 30, y: 84 }, color: Color.light_gray, align: Text.align_top_left })
}
