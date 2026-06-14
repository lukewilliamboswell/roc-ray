app [Model, program] { rr: platform "../platform/main.roc" }

import rr.App
import rr.Assets
import rr.Audio
import rr.Camera
import rr.Color
import rr.Draw
import rr.Host
import rr.Keys
import rr.Math
import rr.Sprite

Spark : {
	id : U64,
	pos : Math.Vec2,
}

Hazard : {
	center : Math.Vec2,
	span : F32,
	vertical : Bool,
	offset : F32,
	radius : F32,
	color : Color,
}

Decoration : {
	pos : Math.Vec2,
	tile : U64,
	scale : F32,
	rotation : F32,
}

GameState := [Playing, Won, GameOver]

Sounds : {
	collect : Audio.Sound,
	hurt : Audio.Sound,
	win : Audio.Sound,
	lose : Audio.Sound,
	gate : Audio.Sound,
	dash : Audio.Sound,
	sparkle : Audio.Sound,
	music : Audio.Music,
}

Model : {
	characters : Assets.Texture,
	tiles : Assets.Texture,
	sounds : Sounds,
	player : Math.Vec2,
	sparks : List(Spark),
	score : U64,
	lives : U64,
	phase : F32,
	invuln : F32,
	dash_cooldown : F32,
	dash_timer : F32,
	shake : F32,
	flash : F32,
	burst_pos : Math.Vec2,
	burst_timer : F32,
	animation : Sprite.Animation,
	facing : F32,
	gate_open : Bool,
	gate_flash : F32,
	state : GameState,
}

program = { init!, render! }

screen_w : F32
screen_w = 800

screen_h : F32
screen_h = 600

world_left : F32
world_left = -720

world_top : F32
world_top = -520

world_right : F32
world_right = 1360

world_bottom : F32
world_bottom = 1120

player_radius : F32
player_radius = 22

player_speed : F32
player_speed = 330

dash_speed : F32
dash_speed = 760

dash_duration : F32
dash_duration = 0.18

dash_cooldown_time : F32
dash_cooldown_time = 0.62

spark_radius : F32
spark_radius = 24

spark_total : U64
spark_total = 10

characters_path : Str
characters_path = "examples/assets/kenney-topdown/characters.png"

tiles_path : Str
tiles_path = "examples/assets/kenney-topdown/tiles.png"

collect_path : Str
collect_path = "examples/assets/kenney-audio/sfx/collect.ogg"

hurt_path : Str
hurt_path = "examples/assets/kenney-audio/sfx/hurt.ogg"

win_path : Str
win_path = "examples/assets/kenney-audio/sfx/win.ogg"

lose_path : Str
lose_path = "examples/assets/kenney-audio/sfx/lose.ogg"

gate_path : Str
gate_path = "examples/assets/kenney-audio/sfx/gate.ogg"

dash_path : Str
dash_path = "examples/assets/kenney-audio/sfx/dash.ogg"

music_path : Str
music_path = "examples/assets/kenney-audio/music/spark_loop.wav"

spawn : Math.Vec2
spawn = { x: -560, y: -360 }

exit_center : Math.Vec2
exit_center = { x: 1185, y: 920 }

exit_radius : F32
exit_radius = 58

burst_duration : F32
burst_duration = 0.36

init! : App.Init(Model)
init! = App.init(
	{
		..App.default,
		title: "RocRay Spark Run",
		target_fps: 120,
	},
	|_host| {
		match Assets.load_texture!(characters_path) {
			Ok(characters) =>
				match Assets.load_texture!(tiles_path) {
					Ok(tiles) => {
						sounds = make_sounds!()
						Audio.play_music!(sounds.music)
						Ok(new_game(characters, tiles, sounds))
					}
					Err(_) => Err(Exit(1))
				}
			Err(_) => Err(Exit(1))
		}
	},
)

make_sound : Audio.Waveform, F32, F32, I32, F32 => Audio.Sound
make_sound = |waveform, from, to, ms, volume|
	Audio.gen_sound!(
		{
			waveform,
			freq_start: from,
			freq_end: to,
			ms,
			attack_ms: 2,
			decay_ms: 24,
			sustain: 0.45,
			release_ms: 45,
			volume,
		},
	)

load_sound_or! : Str, Audio.Sound => Audio.Sound
load_sound_or! = |path, fallback|
	match Audio.load_sound!(path) {
		Ok(sound) => sound
		Err(_) => fallback
	}

load_music_or_invalid! : Str => Audio.Music
load_music_or_invalid! = |path|
	match Audio.load_music!(path) {
		Ok(music) => music
		Err(_) => Box.box(0)
	}

make_sounds! : () => Sounds
make_sounds! = || {
	collect = load_sound_or!(collect_path, make_sound(Sine, 880, 1160, 110, 0.55))
	hurt = load_sound_or!(hurt_path, make_sound(Noise, 180, 70, 220, 0.7))
	win = load_sound_or!(win_path, make_sound(Square, 640, 1280, 520, 0.45))
	lose = load_sound_or!(lose_path, make_sound(Saw, 120, 45, 520, 0.5))
	gate = load_sound_or!(gate_path, make_sound(Square, 220, 390, 240, 0.45))
	dash = load_sound_or!(dash_path, make_sound(Noise, 520, 120, 130, 0.38))
	sparkle = make_sound(Sine, 980, 1620, 140, 0.36)
	music = load_music_or_invalid!(music_path)

	Audio.set_volume!(collect, 0.58)
	Audio.set_volume!(hurt, 0.55)
	Audio.set_volume!(win, 0.48)
	Audio.set_volume!(lose, 0.58)
	Audio.set_volume!(gate, 0.46)
	Audio.set_volume!(dash, 0.3)
	Audio.set_volume!(sparkle, 0.16)
	Audio.set_music_volume!(music, 0.13)
	Audio.set_music_looping!(music, Bool.True)

	{ collect, hurt, win, lose, gate, dash, sparkle, music }
}

new_game : Assets.Texture, Assets.Texture, Sounds -> Model
new_game = |characters, tiles, sounds| {
	characters,
	tiles,
	sounds,
	player: spawn,
	sparks: fresh_sparks,
	score: 0,
	lives: 3,
	phase: 0,
	invuln: 0,
	dash_cooldown: 0,
	dash_timer: 0,
	shake: 0,
	flash: 0,
	burst_pos: spawn,
	burst_timer: 0,
	animation: Sprite.animation({ frame_count: 4, fps: 10 }),
	facing: 90,
	gate_open: Bool.False,
	gate_flash: 0,
	state: Playing,
}

spark_at : U64, F32, F32 -> Spark
spark_at = |id, x, y| { id, pos: { x, y } }

fresh_sparks : List(Spark)
fresh_sparks = [
	spark_at(0, -430, -150),
	spark_at(1, -55, -350),
	spark_at(2, 315, -295),
	spark_at(3, 760, -405),
	spark_at(4, 1110, -65),
	spark_at(5, 910, 350),
	spark_at(6, 560, 820),
	spark_at(7, 105, 640),
	spark_at(8, -280, 895),
	spark_at(9, -540, 410),
]

obstacles : List(Math.Rect)
obstacles = [
	Math.rect(-305, -300, 150, 440),
	Math.rect(85, -430, 150, 295),
	Math.rect(210, -45, 510, 120),
	Math.rect(705, 150, 140, 425),
	Math.rect(5, 505, 480, 115),
	Math.rect(-535, 515, 340, 105),
	Math.rect(965, -300, 145, 450),
]

hazards : List(Hazard)
hazards = [
	{ center: { x: -445, y: 165 }, span: 520, vertical: Bool.False, offset: 0, radius: 30, color: Color.from_hex_rgb(0xf94144) },
	{ center: { x: 25, y: 320 }, span: 650, vertical: Bool.True, offset: 0.22, radius: 34, color: Color.from_hex_rgb(0xf3722c) },
	{ center: { x: 600, y: -255 }, span: 650, vertical: Bool.False, offset: 0.48, radius: 32, color: Color.from_hex_rgb(0xf8961e) },
	{ center: { x: 1035, y: 455 }, span: 700, vertical: Bool.True, offset: 0.72, radius: 36, color: Color.from_hex_rgb(0xf94144) },
]

decorations : List(Decoration)
decorations = [
	{ pos: { x: -640, y: 80 }, tile: 237, scale: 1.35, rotation: 0 },
	{ pos: { x: -575, y: 585 }, tile: 238, scale: 1.2, rotation: 0 },
	{ pos: { x: -85, y: -455 }, tile: 183, scale: 1.35, rotation: 0 },
	{ pos: { x: 190, y: 185 }, tile: 158, scale: 1.15, rotation: 0 },
	{ pos: { x: 780, y: -210 }, tile: 156, scale: 1.1, rotation: 12 },
	{ pos: { x: 1110, y: 190 }, tile: 181, scale: 1.45, rotation: 0 },
	{ pos: { x: 1035, y: 785 }, tile: 157, scale: 1.2, rotation: -14 },
	{ pos: { x: 315, y: 975 }, tile: 213, scale: 1.05, rotation: 0 },
	{ pos: { x: -395, y: 960 }, tile: 214, scale: 0.9, rotation: 0 },
	{ pos: { x: 1185, y: 735 }, tile: 239, scale: 0.7, rotation: 20 },
	{ pos: { x: 1280, y: -395 }, tile: 240, scale: 0.72, rotation: -18 },
	{ pos: { x: -615, y: -405 }, tile: 184, scale: 1.1, rotation: 0 },
]

axis : Bool, Bool -> F32
axis = |negative, positive| if negative -1 else if positive 1 else 0

input_axis : Host -> Math.Vec2
input_axis = |host| {
	left = Keys.key_down(host.keys, KeyLeft) or Keys.key_down(host.keys, KeyA)
	right = Keys.key_down(host.keys, KeyRight) or Keys.key_down(host.keys, KeyD)
	up = Keys.key_down(host.keys, KeyUp) or Keys.key_down(host.keys, KeyW)
	down = Keys.key_down(host.keys, KeyDown) or Keys.key_down(host.keys, KeyS)

	{ x: axis(left, right), y: axis(up, down) }
}

facing_for : Math.Vec2, F32 -> F32
facing_for = |dir, fallback| {
	if dir.y < 0 and dir.x == 0 {
		0
	} else if dir.y < 0 and dir.x > 0 {
		45
	} else if dir.x > 0 and dir.y == 0 {
		90
	} else if dir.x > 0 and dir.y > 0 {
		135
	} else if dir.y > 0 and dir.x == 0 {
		180
	} else if dir.x < 0 and dir.y > 0 {
		225
	} else if dir.x < 0 and dir.y == 0 {
		270
	} else if dir.x < 0 and dir.y < 0 {
		315
	} else {
		fallback
	}
}

clamp_to_world : Math.Vec2 -> Math.Vec2
clamp_to_world = |pos| {
	x: Math.clamp(pos.x, world_left + player_radius, world_right - player_radius),
	y: Math.clamp(pos.y, world_top + player_radius, world_bottom - player_radius),
}

any_obstacle_hit : Math.Vec2, U64 -> Bool
any_obstacle_hit = |pos, index|
	match List.get(obstacles, index) {
		Ok(obstacle) =>
			if Math.circle_rect(Math.circle(pos, player_radius), obstacle) {
				Bool.True
			} else {
				any_obstacle_hit(pos, index + 1)
			}
		Err(_) => Bool.False
	}

move_player_speed : Math.Vec2, Math.Vec2, F32, F32 -> Math.Vec2
move_player_speed = |player, raw_dir, dt, speed| {
	dir = Math.normalize(raw_dir)
	candidate = clamp_to_world(Math.add(player, Math.scale(dir, speed * dt)))

	if any_obstacle_hit(candidate, 0) player else candidate
}

wrap_unit : F32 -> F32
wrap_unit = |value| if value >= 1 value - 1 else if value < 0 value + 1 else value

ping_pong : F32 -> F32
ping_pong = |phase| if phase < 0.5 phase * 2 else (1 - phase) * 2

hazard_pos : Hazard, F32 -> Math.Vec2
hazard_pos = |hazard, phase| {
	amount = ping_pong(wrap_unit(phase + hazard.offset))
	if hazard.vertical {
		{ x: hazard.center.x, y: hazard.center.y - hazard.span * 0.5 + hazard.span * amount }
	} else {
		{ x: hazard.center.x - hazard.span * 0.5 + hazard.span * amount, y: hazard.center.y }
	}
}

find_hit_spark : List(Spark), Math.Vec2, U64 -> Try(Spark, [NotFound])
find_hit_spark = |sparks, player, index|
	match List.get(sparks, index) {
		Ok(spark) =>
			if Math.circle_overlaps(Math.circle(player, player_radius), Math.circle(spark.pos, spark_radius)) {
				Ok(spark)
			} else {
				find_hit_spark(sparks, player, index + 1)
			}
		Err(_) => Err(NotFound)
	}

play_if! : Bool, Audio.Sound => {}
play_if! = |cond, sound| if cond Audio.play!(sound) else {}

pan_for_world_x : F32 -> F32
pan_for_world_x = |x| Math.clamp((x - world_left) / (world_right - world_left) * 2 - 1, -1, 1)

collect_spark! : Model => Model
collect_spark! = |model|
	match find_hit_spark(model.sparks, model.player, 0) {
		Ok(spark) => {
			remaining = List.keep_if(model.sparks, |item| item.id != spark.id)
			next_score = model.score + 1
			gate_open = List.len(remaining) == 0
			just_opened = gate_open and !(model.gate_open)

			Audio.set_pan!(model.sounds.collect, pan_for_world_x(spark.pos.x))
			Audio.set_pitch!(model.sounds.sparkle, 0.92 + U64.to_f32(next_score) * 0.045)
			Audio.play!(model.sounds.collect)
			play_if!(next_score % 3 == 0, model.sounds.sparkle)
			play_if!(just_opened, model.sounds.gate)

			{
				..model,
				sparks: remaining,
				score: next_score,
				shake: 0,
				flash: 0,
				burst_pos: spark.pos,
				burst_timer: burst_duration,
				gate_open,
				gate_flash: if just_opened 1 else model.gate_flash,
				state: Playing,
			}
		}
		Err(_) => model
	}

any_hazard_hit : Math.Vec2, F32, U64 -> Bool
any_hazard_hit = |player, phase, index|
	match List.get(hazards, index) {
		Ok(hazard) =>
			if Math.circle_overlaps(Math.circle(player, player_radius), Math.circle(hazard_pos(hazard, phase), hazard.radius)) {
				Bool.True
			} else {
				any_hazard_hit(player, phase, index + 1)
			}
		Err(_) => Bool.False
	}

damage_if_needed! : Model => Model
damage_if_needed! = |model| {
	if model.invuln <= 0 and any_hazard_hit(model.player, model.phase, 0) {
		next_lives = if model.lives > 0 model.lives - 1 else 0
		next_state = if model.lives <= 1 GameOver else Playing
		Audio.play!(if next_state == GameOver model.sounds.lose else model.sounds.hurt)
		{
			..model,
			player: spawn,
			lives: next_lives,
			invuln: 1.2,
			dash_timer: 0,
			shake: 10,
			flash: 0.28,
			burst_pos: model.player,
			burst_timer: burst_duration,
			facing: 90,
			state: next_state,
		}
	} else {
		model
	}
}

escape_if_needed! : Model => Model
escape_if_needed! = |model| {
	if model.gate_open and Math.circle_overlaps(Math.circle(model.player, player_radius), Math.circle(exit_center, exit_radius)) {
		Audio.set_music_volume!(model.sounds.music, 0.08)
		Audio.play!(model.sounds.win)
		{
			..model,
			shake: 10,
			flash: 0,
			burst_pos: exit_center,
			burst_timer: burst_duration,
			gate_flash: 1,
			state: Won,
		}
	} else {
		model
	}
}

is_moving : Math.Vec2 -> Bool
is_moving = |dir| dir.x != 0 or dir.y != 0

direction_for_facing : F32 -> Math.Vec2
direction_for_facing = |facing| {
	if facing == 0 {
		{ x: 0, y: -1 }
	} else if facing == 45 {
		{ x: 0.7, y: -0.7 }
	} else if facing == 90 {
		{ x: 1, y: 0 }
	} else if facing == 135 {
		{ x: 0.7, y: 0.7 }
	} else if facing == 180 {
		{ x: 0, y: 1 }
	} else if facing == 225 {
		{ x: -0.7, y: 0.7 }
	} else if facing == 270 {
		{ x: -1, y: 0 }
	} else if facing == 315 {
		{ x: -0.7, y: -0.7 }
	} else {
		{ x: 1, y: 0 }
	}
}

idle_animation : Sprite.Animation -> Sprite.Animation
idle_animation = |animation| {
	frame: 0,
	frame_count: animation.frame_count,
	fps: animation.fps,
	elapsed: 0,
}

advance_playing! : Model, Host => Model
advance_playing! = |model, host| {
	raw_dir = input_axis(host)
	moving = is_moving(raw_dir)
	dash_pressed = Keys.key_pressed(host.keys_pressed, KeySpace)
	dash_started = dash_pressed and model.dash_cooldown <= 0
	dash_active = dash_started or model.dash_timer > 0
	move_dir = if dash_active and !(moving) direction_for_facing(model.facing) else raw_dir
	speed = if dash_active dash_speed else player_speed
	player = move_player_speed(model.player, move_dir, host.frame_time, speed)
	hazard_speed = 0.15 + U64.to_f32(model.score) * 0.012
	phase = wrap_unit(model.phase + host.frame_time * hazard_speed)
	invuln = Math.clamp(model.invuln - host.frame_time, 0, 10)
	dash_cooldown = if dash_started dash_cooldown_time else Math.clamp(model.dash_cooldown - host.frame_time, 0, 10)
	dash_timer = if dash_started dash_duration else Math.clamp(model.dash_timer - host.frame_time, 0, 10)
	shake = Math.clamp(model.shake - host.frame_time * 36, 0, 99)
	flash = Math.clamp(model.flash - host.frame_time * 1.8, 0, 1)
	burst_timer = Math.clamp(model.burst_timer - host.frame_time, 0, 1)
	gate_flash = Math.clamp(model.gate_flash - host.frame_time * 1.15, 0, 1)
	animation = if is_moving(move_dir) Sprite.step(model.animation, host.frame_time) else idle_animation(model.animation)
	facing = if dash_active and !(moving) model.facing else facing_for(raw_dir, model.facing)

	if dash_started {
		Audio.set_pan!(model.sounds.dash, pan_for_world_x(model.player.x))
		Audio.set_pitch!(model.sounds.dash, 0.95 + U64.to_f32(model.score) * 0.015)
		Audio.play!(model.sounds.dash)
	} else {
		{}
	}

	moved = {
		..model,
		player,
		phase,
		invuln,
		dash_cooldown,
		dash_timer,
		shake,
		flash,
		burst_timer,
		animation,
		facing,
		gate_flash,
		state: Playing,
	}
	collected = collect_spark!(moved)
	escaped = escape_if_needed!(collected)

	if escaped.state == Won escaped else damage_if_needed!(escaped)
}

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {
	if Keys.key_pressed(host.keys_pressed, KeyEscape) {
		Host.exit!(0)
	}

	next = match model.state {
		Playing => advance_playing!(model, host)
		Won =>
			if Keys.key_pressed(host.keys_pressed, KeySpace) {
				Audio.set_music_volume!(model.sounds.music, 0.13)
				new_game(model.characters, model.tiles, model.sounds)
			} else {
				model
			}
		GameOver =>
			if Keys.key_pressed(host.keys_pressed, KeySpace) {
				Audio.set_music_volume!(model.sounds.music, 0.13)
				new_game(model.characters, model.tiles, model.sounds)
			} else {
				model
			}
		}

	camera = Camera.follow(shaken_target(next), { screen: { x: screen_w, y: screen_h }, zoom: 0.82 })

	Draw.draw!(
		Color.from_hex_rgb(0x071018),
		|| {
			Draw.with_camera!(
				camera,
				|| draw_world!(next),
			)

			draw_hud!(next)
		},
	)

	Ok(next)
}

shaken_target : Model -> Math.Vec2
shaken_target = |model| {
	amount = model.shake
	x_phase = ping_pong(wrap_unit(model.phase * 9.7))
	y_phase = ping_pong(wrap_unit(model.phase * 13.1 + 0.31))
	{
		x: model.player.x + (x_phase - 0.5) * amount,
		y: model.player.y + (y_phase - 0.5) * amount,
	}
}

draw_world! : Model => {}
draw_world! = |model| {
	Draw.rectangle_gradient_v!({ x: world_left, y: world_top, width: world_right - world_left, height: world_bottom - world_top, color_top: Color.from_hex_rgb(0x173833), color_bottom: Color.from_hex_rgb(0x132821) })
	draw_floor_y!(model.tiles, world_top)
	draw_path_network!()
	draw_hazard_lanes!(model.phase)
	draw_props!(model.tiles)
	Draw.rectangle!({ x: world_left, y: world_top, width: world_right - world_left, height: world_bottom - world_top, style: Draw.outlined(Color.with_alpha(Color.white, 90), 6) })

	draw_spawn!()
	draw_exit!(model)
	draw_obstacles!(model.tiles, 0)
	draw_sparks!(model.tiles, model.sparks, model.phase)
	draw_hazards!(model.characters, model.phase)
	draw_burst!(model)
	draw_player!(model)
}

tile_cols : U64
tile_cols = 27

tile_source : U64 -> Math.Rect
tile_source = |tile_id| {
	index = tile_id - 1
	Sprite.sheet_frame({ frame_size: { x: 64, y: 64 }, row: index // tile_cols, col: index % tile_cols })
}

draw_tile! : Assets.Texture, U64, Math.Vec2, F32 => {}
draw_tile! = |tiles, tile_id, pos, scale| {
	Sprite.draw!(
		Sprite.with_scale(
			Sprite.with_pos(
				Sprite.with_source(Sprite.from_texture(tiles), tile_source(tile_id)),
				pos,
			),
			scale,
		),
	)
}

draw_tile_centered! : Assets.Texture, U64, Math.Vec2, F32, F32 => {}
draw_tile_centered! = |tiles, tile_id, pos, scale, rotation| {
	Sprite.draw!(
		Sprite.with_rotation(
			Sprite.with_origin_center(
				Sprite.with_scale(
					Sprite.with_pos(
						Sprite.with_source(Sprite.from_texture(tiles), tile_source(tile_id)),
						pos,
					),
					scale,
				),
			),
			rotation,
		),
	)
}

draw_floor_y! : Assets.Texture, F32 => {}
draw_floor_y! = |tiles, y| {
	if y > world_bottom {
		{}
	} else {
		draw_floor_x!(tiles, world_left, y)
		draw_floor_y!(tiles, y + 128)
	}
}

draw_floor_x! : Assets.Texture, F32, F32 => {}
draw_floor_x! = |tiles, x, y| {
	if x > world_right {
		{}
	} else {
		draw_tile!(tiles, 1, { x, y }, 2)
		draw_floor_x!(tiles, x + 128, y)
	}
}

draw_path_network! : () => {}
draw_path_network! = || {
	path = Color.with_alpha(Color.from_hex_rgb(0x303d36), 210)
	edge = Color.with_alpha(Color.from_hex_rgb(0x8fa87d), 90)
	Draw.rounded_rectangle!({ x: -625, y: -420, width: 1750, height: 110, radius: 18, segments: 8, style: Draw.filled_and_outlined(path, edge, 3) })
	Draw.rounded_rectangle!({ x: -625, y: 300, width: 1725, height: 112, radius: 18, segments: 8, style: Draw.filled_and_outlined(path, edge, 3) })
	Draw.rounded_rectangle!({ x: -575, y: 820, width: 1790, height: 120, radius: 18, segments: 8, style: Draw.filled_and_outlined(path, edge, 3) })
	Draw.rounded_rectangle!({ x: -565, y: -430, width: 112, height: 1325, radius: 18, segments: 8, style: Draw.filled_and_outlined(path, edge, 3) })
	Draw.rounded_rectangle!({ x: 455, y: -410, width: 120, height: 1270, radius: 18, segments: 8, style: Draw.filled_and_outlined(path, edge, 3) })
	Draw.rounded_rectangle!({ x: 1130, y: -80, width: 125, height: 1045, radius: 18, segments: 8, style: Draw.filled_and_outlined(path, edge, 3) })
}

draw_spawn! : () => {}
draw_spawn! = || {
	Draw.circle_gradient!({ center: spawn, radius: 72, color_inner: Color.with_alpha(Color.from_hex_rgb(0x2a9d8f), 120), color_outer: Color.with_alpha(Color.from_hex_rgb(0x2a9d8f), 0) })
	Draw.circle!({ center: spawn, radius: 42, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x2a9d8f), Color.white, 4) })
	Draw.text!({ pos: { x: spawn.x, y: spawn.y + 63 }, text: "START", size: 18, spacing: Draw.default_spacing, color: Color.with_alpha(Color.white, 190), font: Draw.default_font, align: Draw.align_top_center })
}

draw_exit! : Model => {}
draw_exit! = |model| {
	color = if model.gate_open Color.from_hex_rgb(0xf9c74f) else Color.from_hex_rgb(0x576066)
	halo = if model.gate_open Color.with_alpha(color, 95) else Color.with_alpha(Color.black, 70)
	Draw.circle_gradient!({ center: exit_center, radius: 82 + model.gate_flash * 28, color_inner: halo, color_outer: Color.with_alpha(color, 0) })
	Draw.circle!({ center: exit_center, radius: exit_radius, style: Draw.filled_and_outlined(Color.with_alpha(color, 190), Color.white, 4) })
	Draw.text!({ pos: { x: exit_center.x, y: exit_center.y + 74 }, text: if model.gate_open "EXIT OPEN" else "LOCKED EXIT", size: 19, spacing: Draw.default_spacing, color: Color.white, font: Draw.default_font, align: Draw.align_top_center })
}

draw_obstacles! : Assets.Texture, U64 => {}
draw_obstacles! = |tiles, index|
	match List.get(obstacles, index) {
		Ok(obstacle) => {
			Draw.rounded_rectangle!({ x: obstacle.x, y: obstacle.y, width: obstacle.width, height: obstacle.height, radius: 14, segments: 8, style: Draw.filled_and_outlined(Color.with_alpha(Color.from_hex_rgb(0x23342d), 235), Color.from_hex_rgb(0xa3b18a), 4) })
			draw_tile_centered!(tiles, if index % 2 == 0 156 else 157, Math.center(obstacle), 1.25, U64.to_f32(index) * 11)
			draw_obstacles!(tiles, index + 1)
		}
		Err(_) => {}
	}

draw_props! : Assets.Texture => {}
draw_props! = |tiles| {
	for decoration in decorations {
		draw_tile_centered!(tiles, decoration.tile, decoration.pos, decoration.scale, decoration.rotation)
	}
}

draw_spark! : Assets.Texture, Spark, F32 => {}
draw_spark! = |tiles, spark, phase| {
	tile = if spark.id % 2 == 0 239 else 240
	rotation = phase * 160 + U64.to_f32(spark.id) * 19
	pulse = 1 + ping_pong(wrap_unit(phase * 2 + U64.to_f32(spark.id) * 0.09)) * 0.1
	Draw.circle_gradient!({ center: spark.pos, radius: spark_radius * 2 * pulse, color_inner: Color.with_alpha(Color.from_hex_rgb(0xf9c74f), 55), color_outer: Color.with_alpha(Color.from_hex_rgb(0xf9c74f), 0) })
	Draw.circle!({ center: spark.pos, radius: spark_radius + 4 * pulse, style: Draw.outlined(Color.with_alpha(Color.white, 110), 3) })
	draw_tile_centered!(tiles, tile, spark.pos, 0.72 * pulse, rotation)
}

draw_sparks! : Assets.Texture, List(Spark), F32 => {}
draw_sparks! = |tiles, sparks, phase| {
	for spark in sparks {
		draw_spark!(tiles, spark, phase)
	}
}

draw_hazard_lanes! : F32 => {}
draw_hazard_lanes! = |phase| {
	for hazard in hazards {
		pos = hazard_pos(hazard, phase)
		start = if hazard.vertical { x: hazard.center.x, y: hazard.center.y - hazard.span * 0.5 } else { x: hazard.center.x - hazard.span * 0.5, y: hazard.center.y }
		end = if hazard.vertical { x: hazard.center.x, y: hazard.center.y + hazard.span * 0.5 } else { x: hazard.center.x + hazard.span * 0.5, y: hazard.center.y }
		Draw.line!({ start, end, stroke: Draw.stroke(Color.with_alpha(hazard.color, 48), 10) })
		Draw.circle_gradient!({ center: pos, radius: hazard.radius * 1.9, color_inner: Color.with_alpha(hazard.color, 54), color_outer: Color.with_alpha(hazard.color, 0) })
	}
}

robot_source : Math.Rect
robot_source = Math.rect(458, 88, 33, 43)

draw_hazard! : Assets.Texture, Hazard, F32 => {}
draw_hazard! = |characters, hazard, phase| {
	pos = hazard_pos(hazard, phase)
	sprite = Sprite.with_rotation(
		Sprite.with_origin_center(
			Sprite.with_scale(
				Sprite.with_pos(
					Sprite.with_source(Sprite.from_texture(characters), robot_source),
					pos,
				),
				1.38,
			),
		),
		0,
	)

	Sprite.draw!(sprite)
	Draw.circle!({ center: pos, radius: hazard.radius, style: Draw.outlined(Color.with_alpha(Color.white, 170), 3) })
}

draw_hazards! : Assets.Texture, F32 => {}
draw_hazards! = |characters, phase| {
	for hazard in hazards {
		draw_hazard!(characters, hazard, phase)
	}
}

burst_dir : U64 -> Math.Vec2
burst_dir = |index|
	match index % 8 {
		0 => { x: 1, y: 0 }
		1 => { x: 0.7, y: 0.7 }
		2 => { x: 0, y: 1 }
		3 => { x: -0.7, y: 0.7 }
		4 => { x: -1, y: 0 }
		5 => { x: -0.7, y: -0.7 }
		6 => { x: 0, y: -1 }
		_ => { x: 0.7, y: -0.7 }
	}

draw_burst_particle! : Model, U64 => {}
draw_burst_particle! = |model, index| {
	if index >= 6 or model.burst_timer <= 0 {
		{}
	} else {
		progress = 1 - model.burst_timer / burst_duration
		dir = burst_dir(index)
		pos = Math.add(model.burst_pos, Math.scale(dir, 18 + progress * 58))
		size = 6 + ping_pong(wrap_unit(model.phase * 5 + U64.to_f32(index) * 0.11)) * 3
		Draw.circle!({ center: pos, radius: size, style: Draw.filled(Color.with_alpha(Color.from_hex_rgb(0xf9c74f), if model.burst_timer > 0.18 135 else 70)) })
		draw_burst_particle!(model, index + 1)
	}
}

draw_burst! : Model => {}
draw_burst! = |model| draw_burst_particle!(model, 0)

player_source : Math.Rect
player_source = Math.rect(0, 0, 52, 43)

player_rotation : F32 -> F32
player_rotation = |facing| facing - 90

draw_player! : Model => {}
draw_player! = |model| {
	tint = if model.invuln > 0 Color.with_alpha(Color.white, 150) else Color.white
	scale = if model.dash_timer > 0 1.3 else 1.22
	sprite = Sprite.with_tint(
		Sprite.with_rotation(
			Sprite.with_origin_center(
				Sprite.with_scale(
					Sprite.with_pos(
						Sprite.with_source(Sprite.from_texture(model.characters), player_source),
						model.player,
					),
					scale,
				),
			),
			player_rotation(model.facing),
		),
		tint,
	)

	Draw.circle!({ center: { x: model.player.x + 5, y: model.player.y + 7 }, radius: player_radius + 6, style: Draw.filled(Color.with_alpha(Color.black, 85)) })
	if model.dash_timer > 0 {
		trail_center = Math.add(model.player, Math.scale(direction_for_facing(model.facing), -38))
		Draw.circle_gradient!({ center: trail_center, radius: 44, color_inner: Color.with_alpha(Color.from_hex_rgb(0x43aa8b), 55), color_outer: Color.with_alpha(Color.from_hex_rgb(0x43aa8b), 0) })
		Draw.circle_gradient!({ center: model.player, radius: 54, color_inner: Color.with_alpha(Color.from_hex_rgb(0x43aa8b), 70), color_outer: Color.with_alpha(Color.from_hex_rgb(0x43aa8b), 0) })
	} else {
		{}
	}
	Sprite.draw!(sprite)
	Draw.circle!({ center: model.player, radius: player_radius, style: Draw.outlined(Color.with_alpha(Color.white, 180), 2) })
}

draw_bar! : F32, F32, F32, F32, F32, Color => {}
draw_bar! = |x, y, width, height, amount, color| {
	Draw.rounded_rectangle!({ x, y, width, height, radius: 5, segments: 6, style: Draw.filled(Color.with_alpha(Color.black, 130)) })
	Draw.rounded_rectangle!({ x, y, width: width * Math.clamp(amount, 0, 1), height, radius: 5, segments: 6, style: Draw.filled(color) })
}

draw_hud! : Model => {}
draw_hud! = |model| {
	Draw.rectangle_gradient_v!({ x: 0, y: 0, width: screen_w, height: 76, color_top: Color.with_alpha(Color.black, 220), color_bottom: Color.with_alpha(Color.black, 125) })
	Draw.text!({ pos: { x: 22, y: 16 }, text: "Spark Run", size: 27, spacing: Draw.default_spacing, color: Color.white, font: Draw.default_font, align: Draw.align_top_left })
	Draw.text!({ pos: { x: 195, y: 18 }, text: Str.concat("Sparks ", Str.concat(U64.to_str(model.score), Str.concat("/", U64.to_str(spark_total)))), size: 20, spacing: Draw.default_spacing, color: Color.from_hex_rgb(0xf9c74f), font: Draw.default_font, align: Draw.align_top_left })
	Draw.text!({ pos: { x: 382, y: 18 }, text: Str.concat("Lives ", U64.to_str(model.lives)), size: 20, spacing: Draw.default_spacing, color: Color.light_gray, font: Draw.default_font, align: Draw.align_top_left })
	Draw.text!({ pos: { x: 510, y: 18 }, text: if model.gate_open "Gate open" else "Collect all sparks", size: 20, spacing: Draw.default_spacing, color: if model.gate_open Color.from_hex_rgb(0x90be6d) else Color.light_gray, font: Draw.default_font, align: Draw.align_top_left })
	Draw.fps!({ pos: { x: 735, y: 20 }, size: 18, color: Color.gray })
	draw_bar!(196, 48, 170, 9, U64.to_f32(model.score) / U64.to_f32(spark_total), Color.from_hex_rgb(0xf9c74f))
	draw_bar!(510, 48, 120, 9, if model.dash_cooldown <= 0 1 else 1 - model.dash_cooldown / dash_cooldown_time, Color.from_hex_rgb(0x43aa8b))
	Draw.text!({ pos: { x: 640, y: 43 }, text: if model.dash_cooldown <= 0 "SPACE dash" else "charging", size: 16, spacing: Draw.default_spacing, color: Color.light_gray, font: Draw.default_font, align: Draw.align_top_left })

	if model.flash > 0 {
		Draw.rectangle!({ x: 0, y: 0, width: screen_w, height: screen_h, style: Draw.filled(Color.with_alpha(Color.red, if model.flash > 0.45 120 else 70)) })
	} else {
		{}
	}

	match model.state {
		Playing => {}
		Won => draw_modal!("All sparks recovered", "Press SPACE to run again", Color.from_hex_rgb(0x43aa8b))
		GameOver => draw_modal!("Spark Run ended", "Press SPACE to restart", Color.from_hex_rgb(0xf94144))
	}
}

draw_modal! : Str, Str, Color => {}
draw_modal! = |title, subtitle, accent| {
	Draw.rectangle!({ x: 0, y: 0, width: screen_w, height: screen_h, style: Draw.filled(Color.with_alpha(Color.black, 120)) })
	Draw.rounded_rectangle!({ x: 185, y: 226, width: 430, height: 152, radius: 8, segments: 8, style: Draw.filled_and_outlined(Color.with_alpha(Color.black, 230), accent, 4) })
	Draw.text_centered!({ pos: { x: screen_w * 0.5, y: 276 }, text: title, size: 30, color: Color.white })
	Draw.text_centered!({ pos: { x: screen_w * 0.5, y: 326 }, text: subtitle, size: 21, color: Color.light_gray })
}
