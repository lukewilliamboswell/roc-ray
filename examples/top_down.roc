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

GameState := [Playing, Won, GameOver]

Sounds : {
	collect : Audio.Sound,
	hurt : Audio.Sound,
	win : Audio.Sound,
	lose : Audio.Sound,
	start : Audio.Sound,
	bass_c : Audio.Sound,
	bass_f : Audio.Sound,
	bass_g : Audio.Sound,
	bass_a : Audio.Sound,
	lead_e : Audio.Sound,
	lead_g : Audio.Sound,
	lead_a : Audio.Sound,
	lead_b : Audio.Sound,
	lead_c : Audio.Sound,
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
	beat_timer : F32,
	beat_index : U64,
	animation : Sprite.Animation,
	facing : F32,
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

spark_radius : F32
spark_radius = 24

spark_total : U64
spark_total = 10

characters_path : Str
characters_path = "examples/assets/kenney-topdown/characters.png"

tiles_path : Str
tiles_path = "examples/assets/kenney-topdown/tiles.png"

spawn : Math.Vec2
spawn = { x: -560, y: -360 }

music_volume : F32
music_volume = 0.22

init! : App.Init(Model)
init! = App.init(
	{
		title: "RocRay Spark Run",
		width: 800,
		height: 600,
		target_fps: 120,
		resizable: Bool.False,
		fullscreen: Bool.False,
		vsync: Bool.False,
		cursor_visible: Bool.True,
	},
	|_host| {
		match Assets.load_texture!(characters_path) {
			Ok(characters) =>
				match Assets.load_texture!(tiles_path) {
					Ok(tiles) => {
						sounds = {
							collect: Audio.gen_tone!({ freq: 880, ms: 55 }),
							hurt: Audio.gen_tone!({ freq: 130, ms: 170 }),
							win: Audio.gen_tone!({ freq: 1040, ms: 180 }),
							lose: Audio.gen_tone!({ freq: 90, ms: 260 }),
							start: Audio.gen_tone!({ freq: 520, ms: 90 }),
							bass_c: Audio.gen_tone!({ freq: 131, ms: 70 }),
							bass_f: Audio.gen_tone!({ freq: 175, ms: 70 }),
							bass_g: Audio.gen_tone!({ freq: 196, ms: 70 }),
							bass_a: Audio.gen_tone!({ freq: 220, ms: 70 }),
							lead_e: Audio.gen_tone!({ freq: 659, ms: 34 }),
							lead_g: Audio.gen_tone!({ freq: 784, ms: 34 }),
							lead_a: Audio.gen_tone!({ freq: 880, ms: 34 }),
							lead_b: Audio.gen_tone!({ freq: 988, ms: 34 }),
							lead_c: Audio.gen_tone!({ freq: 1047, ms: 48 }),
						}

						quiet_music!(sounds)
						Ok(new_game(characters, tiles, sounds))
					}
					Err(_) => Err(Exit(1))
				}
			Err(_) => Err(Exit(1))
		}
	},
)

quiet_music! : Sounds => {}
quiet_music! = |sounds| {
	Audio.set_volume!(sounds.bass_c, music_volume)
	Audio.set_volume!(sounds.bass_f, music_volume)
	Audio.set_volume!(sounds.bass_g, music_volume)
	Audio.set_volume!(sounds.bass_a, music_volume)
	Audio.set_volume!(sounds.lead_e, music_volume)
	Audio.set_volume!(sounds.lead_g, music_volume)
	Audio.set_volume!(sounds.lead_a, music_volume)
	Audio.set_volume!(sounds.lead_b, music_volume)
	Audio.set_volume!(sounds.lead_c, music_volume)
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
	beat_timer: 0,
	beat_index: 0,
	animation: Sprite.animation({ frame_count: 4, fps: 8 }),
	facing: 90,
	state: Playing,
}

replace_model : Model, Math.Vec2, List(Spark), U64, U64, F32, F32, F32, U64, Sprite.Animation, F32, GameState -> Model
replace_model = |model, player, sparks, score, lives, phase, invuln, beat_timer, beat_index, animation, facing, state| {
	characters: model.characters,
	tiles: model.tiles,
	sounds: model.sounds,
	player,
	sparks,
	score,
	lives,
	phase,
	invuln,
	beat_timer,
	beat_index,
	animation,
	facing,
	state,
}

spark_at : U64, F32, F32 -> Spark
spark_at = |id, x, y| { id, pos: { x, y } }

fresh_sparks : List(Spark)
fresh_sparks = [
	spark_at(0, -430, -150),
	spark_at(1, -40, -330),
	spark_at(2, 335, -235),
	spark_at(3, 790, -410),
	spark_at(4, 1110, -30),
	spark_at(5, 880, 360),
	spark_at(6, 510, 830),
	spark_at(7, 90, 615),
	spark_at(8, -270, 890),
	spark_at(9, -515, 390),
]

obstacles : List(Math.Rect)
obstacles = [
	Math.rect(-255, -280, 160, 520),
	Math.rect(125, -50, 530, 120),
	Math.rect(260, 365, 150, 420),
	Math.rect(705, 165, 135, 405),
	Math.rect(-510, 530, 405, 110),
]

hazards : List(Hazard)
hazards = [
	{ center: { x: -420, y: 160 }, span: 520, vertical: Bool.False, offset: 0, radius: 30, color: Color.from_hex_rgb(0xf94144) },
	{ center: { x: 40, y: 330 }, span: 620, vertical: Bool.True, offset: 0.28, radius: 34, color: Color.from_hex_rgb(0xf3722c) },
	{ center: { x: 570, y: -255 }, span: 610, vertical: Bool.False, offset: 0.52, radius: 32, color: Color.from_hex_rgb(0xf8961e) },
	{ center: { x: 1045, y: 430 }, span: 640, vertical: Bool.True, offset: 0.76, radius: 36, color: Color.from_hex_rgb(0xf94144) },
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

move_player : Math.Vec2, Math.Vec2, F32 -> Math.Vec2
move_player = |player, raw_dir, dt| {
	dir = Math.normalize(raw_dir)
	candidate = clamp_to_world(Math.add(player, Math.scale(dir, player_speed * dt)))

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

collect_spark! : Model => Model
collect_spark! = |model|
	match find_hit_spark(model.sparks, model.player, 0) {
		Ok(spark) => {
			Audio.play!(model.sounds.collect)
			remaining = List.keep_if(model.sparks, |item| item.id != spark.id)
			next_score = model.score + 1
			next_state = if List.len(remaining) == 0 Won else Playing
			play_if!(next_state == Won, model.sounds.win)
			replace_model(model, model.player, remaining, next_score, model.lives, model.phase, model.invuln, model.beat_timer, model.beat_index, model.animation, model.facing, next_state)
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
		replace_model(model, spawn, model.sparks, model.score, next_lives, model.phase, 1.2, model.beat_timer, model.beat_index, model.animation, 90, next_state)
	} else {
		model
	}
}

is_moving : Math.Vec2 -> Bool
is_moving = |dir| dir.x != 0 or dir.y != 0

idle_animation : Sprite.Animation -> Sprite.Animation
idle_animation = |animation| {
	frame: 0,
	frame_count: animation.frame_count,
	fps: animation.fps,
	elapsed: 0,
}

beat_interval : F32
beat_interval = 0.18

music_step : Model -> U64
music_step = |model| model.beat_index % 16

music_bass : Model -> Audio.Sound
music_bass = |model| {
	match music_step(model) {
		0 => model.sounds.bass_c
		4 => model.sounds.bass_g
		8 => model.sounds.bass_a
		12 => model.sounds.bass_f
		_ => model.sounds.bass_c
	}
}

music_lead : Model -> Audio.Sound
music_lead = |model| {
	match music_step(model) {
		1 => model.sounds.lead_e
		3 => model.sounds.lead_g
		5 => model.sounds.lead_b
		6 => model.sounds.lead_a
		9 => model.sounds.lead_g
		11 => model.sounds.lead_c
		13 => model.sounds.lead_b
		15 => model.sounds.lead_g
		_ => model.sounds.lead_e
	}
}

lead_step : U64 -> Bool
lead_step = |step| step == 1 or step == 3 or step == 5 or step == 6 or step == 9 or step == 11 or step == 13 or step == 15

play_music_step! : Model => {}
play_music_step! = |model| {
	step = music_step(model)
	play_if!(step % 4 == 0, music_bass(model))
	play_if!(lead_step(step), music_lead(model))
}

advance_playing! : Model, Host => Model
advance_playing! = |model, host| {
	raw_dir = input_axis(host)
	player = move_player(model.player, raw_dir, host.frame_time)
	phase = wrap_unit(model.phase + host.frame_time * 0.18)
	invuln = Math.clamp(model.invuln - host.frame_time, 0, 10)
	beat_timer0 = model.beat_timer + host.frame_time
	beat_due = beat_timer0 >= beat_interval
	if beat_due {
		play_music_step!(model)
	} else {
		{}
	}
	beat_timer = if beat_due beat_timer0 - beat_interval else beat_timer0
	beat_index = if beat_due model.beat_index + 1 else model.beat_index
	animation = if is_moving(raw_dir) Sprite.step(model.animation, host.frame_time) else idle_animation(model.animation)
	facing = facing_for(raw_dir, model.facing)
	moved = replace_model(model, player, model.sparks, model.score, model.lives, phase, invuln, beat_timer, beat_index, animation, facing, Playing)
	collected = collect_spark!(moved)

	if collected.state == Won collected else damage_if_needed!(collected)
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
				Audio.play!(model.sounds.start)
				new_game(model.characters, model.tiles, model.sounds)
			} else {
				model
			}
		GameOver =>
			if Keys.key_pressed(host.keys_pressed, KeySpace) {
				Audio.play!(model.sounds.start)
				new_game(model.characters, model.tiles, model.sounds)
			} else {
				model
			}
		}

	camera = Camera.follow(next.player, { screen: { x: screen_w, y: screen_h }, zoom: 0.82 })

	Draw.draw!(
		Color.from_hex_rgb(0x08151c),
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

draw_world! : Model => {}
draw_world! = |model| {
	Draw.rectangle!({ x: world_left, y: world_top, width: world_right - world_left, height: world_bottom - world_top, style: Draw.filled(Color.from_hex_rgb(0x12313a)) })
	draw_floor_y!(model.tiles, world_top)
	draw_props!(model.tiles, 0)
	Draw.rectangle!({ x: world_left, y: world_top, width: world_right - world_left, height: world_bottom - world_top, style: Draw.outlined(Color.with_alpha(Color.white, 100), 6) })

	Draw.circle!({ center: spawn, radius: 42, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x2a9d8f), Color.white, 4) })
	draw_obstacles!(model.tiles, 0)
	draw_sparks!(model.tiles, model.sparks, model.phase, 0)
	draw_hazards!(model.characters, model.phase, 0)
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

draw_obstacles! : Assets.Texture, U64 => {}
draw_obstacles! = |tiles, index|
	match List.get(obstacles, index) {
		Ok(obstacle) => {
			Draw.rounded_rectangle!({ x: obstacle.x, y: obstacle.y, width: obstacle.width, height: obstacle.height, radius: 12, segments: 8, style: Draw.filled_and_outlined(Color.with_alpha(Color.from_hex_rgb(0x283b34), 225), Color.from_hex_rgb(0xa3b18a), 4) })
			draw_tile_centered!(tiles, 156, Math.center(obstacle), 1.35, 0)
			draw_obstacles!(tiles, index + 1)
		}
		Err(_) => {}
	}

draw_props! : Assets.Texture, U64 => {}
draw_props! = |tiles, index| {
	match List.get(decorations, index) {
		Ok(decoration) => {
			draw_tile_centered!(tiles, decoration.tile, decoration.pos, decoration.scale, decoration.rotation)
			draw_props!(tiles, index + 1)
		}
		Err(_) => {}
	}
}

Decoration : {
	pos : Math.Vec2,
	tile : U64,
	scale : F32,
	rotation : F32,
}

decorations : List(Decoration)
decorations = [
	{ pos: { x: -620, y: 75 }, tile: 237, scale: 1.35, rotation: 0 },
	{ pos: { x: -560, y: 585 }, tile: 238, scale: 1.2, rotation: 0 },
	{ pos: { x: -70, y: -455 }, tile: 183, scale: 1.35, rotation: 0 },
	{ pos: { x: 190, y: 185 }, tile: 158, scale: 1.15, rotation: 0 },
	{ pos: { x: 770, y: -200 }, tile: 156, scale: 1.1, rotation: 12 },
	{ pos: { x: 1100, y: 190 }, tile: 181, scale: 1.45, rotation: 0 },
	{ pos: { x: 1025, y: 770 }, tile: 157, scale: 1.2, rotation: -14 },
	{ pos: { x: 320, y: 975 }, tile: 213, scale: 1.05, rotation: 0 },
	{ pos: { x: -395, y: 960 }, tile: 214, scale: 0.9, rotation: 0 },
]

draw_spark! : Assets.Texture, Spark, F32 => {}
draw_spark! = |tiles, spark, phase| {
	tile = if spark.id % 2 == 0 239 else 240
	rotation = phase * 360 + U64.to_f32(spark.id) * 23
	Draw.circle!({ center: spark.pos, radius: spark_radius, style: Draw.outlined(Color.with_alpha(Color.white, 130), 3) })
	draw_tile_centered!(tiles, tile, spark.pos, 0.72, rotation)
}

draw_sparks! : Assets.Texture, List(Spark), F32, U64 => {}
draw_sparks! = |tiles, sparks, phase, index|
	match List.get(sparks, index) {
		Ok(spark) => {
			draw_spark!(tiles, spark, phase)
			draw_sparks!(tiles, sparks, phase, index + 1)
		}
		Err(_) => {}
	}

robot_source : Math.Rect
robot_source = Math.rect(458, 88, 33, 43)

draw_hazard! : Assets.Texture, Hazard, F32 => {}
draw_hazard! = |characters, hazard, phase| {
	pos = hazard_pos(hazard, phase)
	start = if hazard.vertical { x: hazard.center.x, y: hazard.center.y - hazard.span * 0.5 } else { x: hazard.center.x - hazard.span * 0.5, y: hazard.center.y }
	end = if hazard.vertical { x: hazard.center.x, y: hazard.center.y + hazard.span * 0.5 } else { x: hazard.center.x + hazard.span * 0.5, y: hazard.center.y }
	sprite = Sprite.with_rotation(
		Sprite.with_origin_center(
			Sprite.with_scale(
				Sprite.with_pos(
					Sprite.with_source(Sprite.from_texture(characters), robot_source),
					pos,
				),
				1.35,
			),
		),
		phase * 720 + hazard.offset * 360,
	)

	Draw.line!({ start, end, stroke: Draw.stroke(Color.with_alpha(Color.white, 64), 4) })
	Draw.circle!({ center: pos, radius: hazard.radius + 9, style: Draw.filled(Color.with_alpha(hazard.color, 70)) })
	Sprite.draw!(sprite)
	Draw.circle!({ center: pos, radius: hazard.radius, style: Draw.outlined(Color.with_alpha(Color.white, 160), 3) })
}

draw_hazards! : Assets.Texture, F32, U64 => {}
draw_hazards! = |characters, phase, index|
	match List.get(hazards, index) {
		Ok(hazard) => {
			draw_hazard!(characters, hazard, phase)
			draw_hazards!(characters, phase, index + 1)
		}
		Err(_) => {}
	}

player_source : U64 -> Math.Rect
player_source = |frame| {
	match frame % 4 {
		0 => Math.rect(390, 176, 35, 43)
		1 => Math.rect(352, 176, 37, 43)
		2 => Math.rect(112, 88, 51, 43)
		_ => Math.rect(110, 176, 51, 43)
	}
}

player_rotation : F32 -> F32
player_rotation = |facing| facing - 90

draw_player! : Model => {}
draw_player! = |model| {
	source = player_source(model.animation.frame)
	tint = if model.invuln > 0 Color.with_alpha(Color.white, 150) else Color.white
	sprite = Sprite.with_tint(
		Sprite.with_rotation(
			Sprite.with_origin_center(
				Sprite.with_scale(
					Sprite.with_pos(
						Sprite.with_source(Sprite.from_texture(model.characters), source),
						model.player,
					),
					1.25,
				),
			),
			player_rotation(model.facing),
		),
		tint,
	)

	Draw.circle!({ center: { x: model.player.x + 5, y: model.player.y + 7 }, radius: player_radius + 5, style: Draw.filled(Color.with_alpha(Color.black, 80)) })
	Sprite.draw!(sprite)
	Draw.circle!({ center: model.player, radius: player_radius, style: Draw.outlined(Color.with_alpha(Color.white, 180), 2) })
}

draw_hud! : Model => {}
draw_hud! = |model| {
	Draw.rectangle!({ x: 0, y: 0, width: screen_w, height: 64, style: Draw.filled(Color.with_alpha(Color.black, 175)) })
	Draw.text_at!({ pos: { x: 22, y: 18 }, text: "Spark Run", size: 26, color: Color.white })
	Draw.text_at!({ pos: { x: 220, y: 22 }, text: Str.concat("Sparks ", Str.concat(U64.to_str(model.score), Str.concat("/", U64.to_str(spark_total)))), size: 20, color: Color.from_hex_rgb(0xf9c74f) })
	Draw.text_at!({ pos: { x: 410, y: 22 }, text: Str.concat("Lives ", U64.to_str(model.lives)), size: 20, color: Color.light_gray })
	Draw.text_at!({ pos: { x: 548, y: 22 }, text: "WASD/Arrows", size: 20, color: Color.light_gray })
	Draw.fps!({ pos: { x: 735, y: 22 }, size: 18, color: Color.gray })

	match model.state {
		Playing => {}
		Won => {
			Draw.rectangle!({ x: 190, y: 238, width: 420, height: 132, style: Draw.filled(Color.with_alpha(Color.black, 220)) })
			Draw.text_centered!({ pos: { x: screen_w * 0.5, y: 282 }, text: "All sparks recovered", size: 30, color: Color.white })
			Draw.text_centered!({ pos: { x: screen_w * 0.5, y: 328 }, text: "Press SPACE to run again", size: 21, color: Color.light_gray })
		}
		GameOver => {
			Draw.rectangle!({ x: 190, y: 238, width: 420, height: 132, style: Draw.filled(Color.with_alpha(Color.black, 220)) })
			Draw.text_centered!({ pos: { x: screen_w * 0.5, y: 282 }, text: "Spark Run ended", size: 30, color: Color.white })
			Draw.text_centered!({ pos: { x: screen_w * 0.5, y: 328 }, text: "Press SPACE to restart", size: 21, color: Color.light_gray })
		}
	}
}
