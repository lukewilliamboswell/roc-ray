## A libre Doom-style vertical slice built to stress RocRay's real application
## boundary: WASD moves, the locked mouse turns, click or Space fires, E uses
## doors, and R restarts after death or reaching the exit. Freedoom supplies
## the art; the authored level and all game policy remain ordinary Roc data.
app [Model, program] {
	rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst",
	roc: "nightly-2026-08-23-fb208ba",
}

import rr.App
import rr.Assets
import rr.Audio
import rr.Color
import rr.Draw
import rr.Mouse
import Game
import Renderer
import "sprite_cutout.fs" as sprite_fragment_shader : Str

Model : {
	world : Game.World,
	atlas : Draw.Texture,
	room : Renderer.Geometry,
	pistol_sound : Audio.Sound,
	pickup_sound : Audio.Sound,
	enemy_die_sound : Audio.Sound,
	door_sound : Audio.Sound,
	sprite_shader : Draw.Shader,
}

Msg : []

program = { init!, update!, render! }

init! : App.Init(Model, _)
init! = App.init(
	App.default
		.with_title("RocRay: Libre Doom Slice")
		.with_size({ width: 1280, height: 720 })
		.with_frame_pacing(VSync)
		.with_cursor_mode(Locked),
	|startup| {
		# App.Config currently transports Hidden and Locked as the same initial
		# visibility bit. Reapply the full mode once the native window exists so
		# first-person mouse movement cannot escape the window.
		App.set_cursor_mode!(startup, Locked)
		store = Assets.Store.open!(Assets.working_directory("examples/doom/assets"))?
		atlas = Assets.load_texture!(store, "freedoom/generated/atlas.png")?
		Assets.set_texture_filter!(atlas, Point)
		pistol_sound = Audio.load_sound!("examples/doom/assets/freedoom/generated/audio/pistol.wav")?
		pickup_sound = Audio.load_sound!("examples/doom/assets/freedoom/generated/audio/pickup.wav")?
		enemy_die_sound = Audio.load_sound!("examples/doom/assets/freedoom/generated/audio/enemy_die.wav")?
		door_sound = Audio.load_sound!("examples/doom/assets/freedoom/generated/audio/door_move.wav")?
		sprite_shader = Draw.Shader.from_source!({ vertex_source: "", fragment_source: sprite_fragment_shader })?
		Ok({ world: Game.initial, atlas, room: Renderer.build_room, pistol_sound, pickup_sound, enemy_die_sound, door_sound, sprite_shader })
	},
)

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	if input.devices.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		forward = axis(input.devices.key_down(KeyW) or input.devices.key_down(KeyUp), input.devices.key_down(KeyS) or input.devices.key_down(KeyDown))
		strafe = axis(input.devices.key_down(KeyD) or input.devices.key_down(KeyRight), input.devices.key_down(KeyA) or input.devices.key_down(KeyLeft))
		mouse = input.devices.mouse
		world = Game.step(
			model.world,
			{
				forward,
				strafe,
				turn: mouse.delta().x * mouse_sensitivity,
				shoot: mouse.button_pressed(Left) or input.devices.key_pressed(KeySpace),
				use: input.devices.key_pressed(KeyE),
				restart: input.devices.key_pressed(KeyR),
				dt: input.time.elapsed_seconds,
			},
		)
		if world.player.shot_flash > model.world.player.shot_flash model.pistol_sound.play!()
		if taken_count(world.pickups) > taken_count(model.world.pickups) model.pickup_sound.play!()
		if alive_count(world.enemies) < alive_count(model.world.enemies) model.enemy_die_sound.play!()
		if world.door.open and !(model.world.door.open) model.door_sound.play!()
		Ok({ ..model, world })
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ScopeUnavailable, ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x151318))
	Renderer.draw_world!(frame, model.atlas, model.sprite_shader, model.room, model.world)?
	draw_hud!(frame, model.atlas, model.world)
	Ok({})
}

draw_hud! : Draw.Frame, Draw.Texture, Game.World => {}
draw_hud! = |frame, atlas, world| {
	size = frame.size!()
	hud_source = Renderer.hud_bar_source
	frame.texture!({ texture: atlas, source: hud_source, dest: { x: size.width * 0.5 - hud_source.width, y: size.height - hud_source.height * 2, width: hud_source.width * 2, height: hud_source.height * 2 }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
	frame.text_at!({ pos: { x: 28, y: size.height - 54 }, text: "HEALTH ${I64.to_str(world.player.health)}", size: 25, color: if world.player.hurt_flash > 0 Color.red else Color.ray_white })
	frame.text_at!({ pos: { x: size.width - 180, y: size.height - 54 }, text: "AMMO ${I64.to_str(world.player.ammo)}", size: 25, color: Color.from_hex_rgb(0xf1cc62) })
	frame.text_at!({ pos: { x: size.width * 0.5 - 70, y: size.height - 54 }, text: "HOSTILES ${U64.to_str(alive_count(world.enemies))}", size: 18, color: Color.from_hex_rgb(0xf18b62) })
	if world.player.has_blue_key {
		frame.text_at!({ pos: { x: 28, y: size.height - 82 }, text: "BLUE KEY", size: 16, color: Color.from_hex_rgb(0x4da6ff) })
	}

	# The weapon overlay remains screen-space while the room uses perspective.
	weapon_source = Renderer.pistol_source(world.player.shot_flash > 0)
	weapon_width = weapon_source.width * 2.7
	weapon_height = weapon_source.height * 2.7
	frame.texture!({ texture: atlas, source: weapon_source, dest: { x: size.width * 0.5 - weapon_width * 0.5, y: size.height - weapon_height, width: weapon_width, height: weapon_height }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
	frame.line!({ start: { x: size.width * 0.5 - 8, y: size.height * 0.5 }, end: { x: size.width * 0.5 + 8, y: size.height * 0.5 }, stroke: Draw.stroke(Color.with_alpha(Color.white, 190), 2) })
	frame.line!({ start: { x: size.width * 0.5, y: size.height * 0.5 - 8 }, end: { x: size.width * 0.5, y: size.height * 0.5 + 8 }, stroke: Draw.stroke(Color.with_alpha(Color.white, 190), 2) })

	match world.phase {
		Playing => {
			objective = if !(world.player.has_blue_key) "Find the blue key" else if !(world.door.open) "Press E at the blue door" else if alive_count(world.enemies) > 0 "Clear the remaining hostiles" else "Reach the marked exit"
			frame.text_at!({ pos: { x: 24, y: 22 }, text: objective, size: 18, color: Color.with_alpha(Color.ray_white, 210) })
		}
		Won => overlay!(frame, size, "SECTOR CLEAR", "Press R to run it again")
		Dead => overlay!(frame, size, "YOU DIED", "Press R to restart")
	}
}

overlay! = |frame, size, title, subtitle| {
	frame.rectangle!({ x: 0, y: 0, width: size.width, height: size.height, style: Draw.filled(Color.with_alpha(Color.black, 145)) })
	frame.text_at!({ pos: { x: size.width * 0.5 - 110, y: size.height * 0.42 }, text: title, size: 38, color: Color.from_hex_rgb(0xd7433f) })
	frame.text_at!({ pos: { x: size.width * 0.5 - 105, y: size.height * 0.42 + 52 }, text: subtitle, size: 18, color: Color.ray_white })
}

axis : Bool, Bool -> F32
axis = |positive, negative| if positive and !(negative) 1 else if negative and !(positive) -1 else 0

alive_count : List(Game.Enemy) -> U64
alive_count = |enemies| List.count_if(enemies, |enemy| enemy.alive())

taken_count : List(Game.Pickup) -> U64
taken_count = |pickups| List.count_if(pickups, |pickup| pickup.taken)

mouse_sensitivity = 0.0025

expect axis(Bool.True, Bool.False) == 1 and axis(Bool.True, Bool.True) == 0 and axis(Bool.False, Bool.True) == -1
