app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.7/8gdZaHEpySPZUzMBCT6RkEF9CBpcbi5F3E7QmNu4NTCU.tar.zst" }

import rr.App
import rr.Camera
import rr.Color
import rr.Draw
import rr.Host
import rr.Keys
import rr.Math

Model : {
	player : Math.Vec2,
	zoom : F32,
	rotation : F32,
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

init! : App.Init(Model)
init! = App.init(
	{
		..App.default,
		title: "RocRay Camera",
		target_fps: 120,
	},
	|_host| Ok({ player: { x: 400, y: 300 }, zoom: 1, rotation: 0 }),
)

axis : Bool, Bool -> F32
axis = |negative, positive| if negative -1 else if positive 1 else 0

move_player : Math.Vec2, Host -> Math.Vec2
move_player = |player, host| {
	left = Keys.key_down(host.keys, KeyLeft) or Keys.key_down(host.keys, KeyA)
	right = Keys.key_down(host.keys, KeyRight) or Keys.key_down(host.keys, KeyD)
	up = Keys.key_down(host.keys, KeyUp) or Keys.key_down(host.keys, KeyW)
	down = Keys.key_down(host.keys, KeyDown) or Keys.key_down(host.keys, KeyS)

	speed = 360
	dt = host.frame_time
	{
		x: Math.clamp(player.x + axis(left, right) * speed * dt, world_left + 40, world_right - 40),
		y: Math.clamp(player.y + axis(up, down) * speed * dt, world_top + 40, world_bottom - 40),
	}
}

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {
	if Keys.key_pressed(host.keys_pressed, KeyEscape) {
		Host.exit!(0)
	}

	player = move_player(model.player, host)
	zoom = Math.clamp(model.zoom + host.mouse.wheel * 0.1, 0.5, 2.5)
	rotation_dir = axis(Keys.key_down(host.keys, KeyQ), Keys.key_down(host.keys, KeyE))
	rotation = if Keys.key_pressed(host.keys_pressed, KeyR) 0 else model.rotation + rotation_dir * 90 * host.frame_time

	camera = Camera.with_rotation(
		Camera.follow(player, { screen: { x: screen_w, y: screen_h }, zoom }),
		rotation,
	)

	next = { player, zoom, rotation }

	Draw.draw!(
		Color.ray_white,
		|| {
			Draw.with_camera!(
				camera,
				|| {
					draw_world!(player)
				},
			)

			draw_hud!(next)
		},
	)

	Ok(next)
}

draw_world! : Math.Vec2 => {}
draw_world! = |player| {
	Draw.rectangle!({ x: world_left, y: world_top, width: world_right - world_left, height: world_bottom - world_top, style: Draw.filled(Color.from_hex_rgb(0x23323a)) })
	draw_grid_x!(world_left)
	draw_grid_y!(world_top)

	Draw.rectangle!({ x: -320, y: -160, width: 360, height: 260, style: Draw.filled(Color.from_hex_rgb(0x3b5f6f)) })
	Draw.rectangle!({ x: 280, y: 120, width: 520, height: 340, style: Draw.filled(Color.from_hex_rgb(0x4c6f4f)) })
	Draw.rectangle!({ x: 860, y: -280, width: 420, height: 460, style: Draw.filled(Color.from_hex_rgb(0x6f5540)) })

	Draw.line!({ start: { x: world_left, y: 0 }, end: { x: world_right, y: 0 }, stroke: Draw.stroke(Color.yellow, 3) })
	Draw.line!({ start: { x: 0, y: world_top }, end: { x: 0, y: world_bottom }, stroke: Draw.stroke(Color.yellow, 3) })

	Draw.circle!({ center: player, radius: 26, style: Draw.filled_and_outlined(Color.red, Color.white, 4) })
	Draw.line!({ start: { x: player.x - 42, y: player.y }, end: { x: player.x + 42, y: player.y }, stroke: Draw.stroke(Color.white, 3) })
	Draw.line!({ start: { x: player.x, y: player.y - 42 }, end: { x: player.x, y: player.y + 42 }, stroke: Draw.stroke(Color.white, 3) })
}

draw_grid_x! : F32 => {}
draw_grid_x! = |x| {
	if x > world_right {
		{}
	} else {
		Draw.line!({ start: { x, y: world_top }, end: { x, y: world_bottom }, stroke: Draw.stroke(Color.with_alpha(Color.white, 55), 1) })
		draw_grid_x!(x + 80)
	}
}

draw_grid_y! : F32 => {}
draw_grid_y! = |y| {
	if y > world_bottom {
		{}
	} else {
		Draw.line!({ start: { x: world_left, y }, end: { x: world_right, y }, stroke: Draw.stroke(Color.with_alpha(Color.white, 55), 1) })
		draw_grid_y!(y + 80)
	}
}

draw_hud! : Model => {}
draw_hud! = |_model| {
	Draw.rectangle!({ x: 16, y: 16, width: 320, height: 92, style: Draw.filled(Color.with_alpha(Color.black, 180)) })
	Draw.text!({ pos: { x: 30, y: 28 }, text: "Camera world", size: 24, spacing: Draw.default_spacing, color: Color.white, font: Draw.default_font, align: Draw.align_top_left })
	Draw.text!({ pos: { x: 30, y: 62 }, text: "world-space draw + screen-space HUD", size: 18, spacing: Draw.default_spacing, color: Color.light_gray, font: Draw.default_font, align: Draw.align_top_left })
	Draw.text!({ pos: { x: 30, y: 84 }, text: "WASD move, wheel zoom, Q/E rotate, R reset", size: 14, spacing: Draw.default_spacing, color: Color.light_gray, font: Draw.default_font, align: Draw.align_top_left })
}
