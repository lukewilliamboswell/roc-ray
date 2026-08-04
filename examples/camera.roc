app [Model, program] { rr: platform "../platform/main-default.roc" }

import rr.App
import rr.Camera
import rr.Color
import rr.Draw
import rr.Host
import rr.Math
import rr.Text

Model : {
	player : Math.Vec2,
	zoom : F32,
	rotation : F32,
	hud : Box({ title : Text.Prepared, subtitle : Text.Prepared, help : Text.Prepared }),
}

program = { init!, render! }

screen_w : F32
screen_w = 800

screen_h : F32
screen_h = 600

world_left : F32
world_left = -800

world_right : F32
world_right = 1600

world_top : F32
world_top = -600

world_bottom : F32
world_bottom = 1200

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default.with_title("RocRay Camera").with_frame_pacing(Capped(120)),
	|_host|
		Ok({
			player: { x: 400, y: 300 },
			zoom: 1,
			rotation: 0,
			hud: Box.box({
				title: Text.from("Camera world").size(24).prepare!()?,
				subtitle: Text.from("world-space draw + screen-space HUD").size(18).prepare!()?,
				help: Text.from("WASD move, wheel zoom, Q/E rotate, R reset").size(14).prepare!()?,
			}),
		}),
)

axis : Bool, Bool -> F32
axis = |negative, positive| if negative -1 else if positive 1 else 0

move_player : Math.Vec2, Host -> Math.Vec2
move_player = |player, host| {
	left = host.key_down(KeyLeft) or host.key_down(KeyA)
	right = host.key_down(KeyRight) or host.key_down(KeyD)
	up = host.key_down(KeyUp) or host.key_down(KeyW)
	down = host.key_down(KeyDown) or host.key_down(KeyS)

	speed = 360
	dt = host.frame_time
	{
		x: Math.clamp(player.x + axis(left, right) * speed * dt, world_left + 40, world_right - 40),
		y: Math.clamp(player.y + axis(up, down) * speed * dt, world_top + 40, world_bottom - 40),
	}
}

render! : Model, Host, Draw.Frame => Try(Model, [Exit(I64), ScopeLimit, ZeroZoom, NonFiniteZoom, NonFiniteTarget, NonFiniteOffset, NonFiniteRotation, ..])
render! = |model, host, frame| {
	if host.key_pressed(KeyEscape) {
		host.exit!(0)
	}

	player = move_player(model.player, host)
	zoom = Math.clamp(model.zoom + host.mouse.wheel * 0.1, 0.5, 2.5)
	rotation_dir = axis(host.key_down(KeyQ), host.key_down(KeyE))
	rotation = if host.key_pressed(KeyR) 0 else model.rotation + rotation_dir * 90 * host.frame_time

	camera = (Camera.follow(player, { screen: { x: screen_w, y: screen_h }, zoom })?).with_rotation(rotation)?
	mouse_world = camera.screen_to_world({ x: host.mouse.x, y: host.mouse.y })
	mouse_screen = camera.world_to_screen(mouse_world)

	next = { ..model, player, zoom, rotation }

	frame.clear!(Color.ray_white)
	frame.with_camera!(
		camera,
		|world_frame| {
			draw_world!(world_frame, player, mouse_world)
			Ok({})
		},
	)?
	frame.circle!({ center: mouse_screen, radius: 5, style: Draw.outlined(Color.yellow, 2) })
	draw_hud!(frame, next)

	Ok(next)
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
