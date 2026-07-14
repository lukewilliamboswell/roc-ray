app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.7/8gdZaHEpySPZUzMBCT6RkEF9CBpcbi5F3E7QmNu4NTCU.tar.zst" }

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
import rr.Tilemap

Facing := [North, NorthEast, East, SouthEast, South, SouthWest, West, NorthWest]

GateState := [GateLocked, GateOpen]

Lane := [Horizontal, Vertical]

Tile := [
	TileFloor,
	TileBlockA,
	TileBlockB,
	TileMarker,
	TileRockA,
	TilePlantA,
	TilePlantB,
	TileFlowerA,
	TileFlowerB,
	TileCrystalA,
	TileCrystalB,
	TileSparkA,
	TileSparkB,
]

Decoration : {
	pos : Math.Vec2,
	tile : Tile,
	scale : F32,
	rotation : F32,
}

Level : {
	tilemap : Tilemap,
	spawn : Math.Vec2,
	exit_center : Math.Vec2,
	exit_radius : F32,
	sparks : List(World.Spark),
	spark_total : U64,
	obstacles : List(World.Obstacle),
	hazards : List(World.Hazard),
	decorations : List(Decoration),
	bounds : Math.Rect,
}

GameState := [Playing, Won, GameOver]

World := {
	player : World.Player,
	sparks : List(World.Spark),
	score : U64,
	lives : U64,
	phase : F32,
	shake : F32,
	flash : F32,
	burst_pos : Math.Vec2,
	burst_timer : F32,
	gate : GateState,
	gate_flash : F32,
	state : GameState,
}.{
	PlayerStep : {
		pos : Math.Vec2,
		raw_dir : Math.Vec2,
		move_dir : Math.Vec2,
		dash_started : Bool,
		dash_active : Bool,
		dt : F32,
	}

	Player := {
		pos : Math.Vec2,
		invuln : F32,
		dash_cooldown : F32,
		dash_timer : F32,
		animation : Sprite.Animation,
		facing : Facing,
	}.{
		new : Math.Vec2 -> Player
		new = |pos| {
			pos,
			invuln: 0,
			dash_cooldown: 0,
			dash_timer: 0,
			animation: Sprite.animation({ frame_count: 4, fps: 10 }),
			facing: East,
		}

		circle : Player -> Math.Circle
		circle = |player| Math.circle(player.pos, player_radius)

		facing_dir : Player -> Math.Vec2
		facing_dir = |player| facing_to_vec(player.facing)

		rotation : Player -> F32
		rotation = |player| facing_to_rotation(player.facing)

		dash_ready : Player -> Bool
		dash_ready = |player| player.dash_cooldown <= 0

		dash_active : Player -> Bool
		dash_active = |player| player.dash_timer > 0

		dash_charge : Player -> F32
		dash_charge = |player| if player.dash_ready() 1 else 1 - player.dash_cooldown / dash_cooldown_time

		step : Player, PlayerStep -> Player
		step = |player, frame| {
			raw_moving = is_moving(frame.raw_dir)
			move_moving = is_moving(frame.move_dir)

			{
				..player,
				pos: frame.pos,
				invuln: tick_timer(player.invuln, frame.dt),
				dash_cooldown: if frame.dash_started dash_cooldown_time else tick_timer(player.dash_cooldown, frame.dt),
				dash_timer: if frame.dash_started dash_duration else tick_timer(player.dash_timer, frame.dt),
				animation: if move_moving Sprite.step(player.animation, frame.dt) else idle_animation(player.animation),
				facing: if frame.dash_active and !(raw_moving) player.facing else facing_from_input(frame.raw_dir, player.facing),
			}
		}

		damage_respawn : Player, Math.Vec2 -> Player
		damage_respawn = |player, respawn_pos| {
			..player,
			pos: respawn_pos,
			invuln: 1.2,
			dash_timer: 0,
			facing: East,
		}
	}

	Spark := {
		id : U64,
		pos : Math.Vec2,
	}.{
		new : U64, F32, F32 -> Spark
		new = |id, x, y| { id, pos: { x, y } }

		circle : Spark -> Math.Circle
		circle = |spark| Math.circle(spark.pos, spark_radius)

		hit_by : Spark, Math.Circle -> Bool
		hit_by = |spark, other| Math.circle_overlaps(other, spark.circle())
	}

	Obstacle := {
		rect : Math.Rect,
		tile : Tile,
		rotation : F32,
	}.{
		new : F32, F32, F32, F32, Tile, F32 -> Obstacle
		new = |x, y, width, height, tile, rotation| {
			rect: Math.rect(x, y, width, height),
			tile,
			rotation,
		}

		center : Obstacle -> Math.Vec2
		center = |obstacle| Math.center(obstacle.rect)

		hit_by : Obstacle, Math.Circle -> Bool
		hit_by = |obstacle, circle| Math.circle_rect(circle, obstacle.rect)
	}

	Hazard := {
		center : Math.Vec2,
		span : F32,
		lane : Lane,
		offset : F32,
		radius : F32,
		color : Color,
	}.{
		pos : Hazard, F32 -> Math.Vec2
		pos = |hazard, phase| {
			amount = ping_pong(wrap_unit(phase + hazard.offset))
			match hazard.lane {
				Vertical => { x: hazard.center.x, y: hazard.center.y - hazard.span * 0.5 + hazard.span * amount }
				Horizontal => { x: hazard.center.x - hazard.span * 0.5 + hazard.span * amount, y: hazard.center.y }
			}
		}

		circle : Hazard, F32 -> Math.Circle
		circle = |hazard, phase| Math.circle(hazard.pos(phase), hazard.radius)

		lane_start : Hazard -> Math.Vec2
		lane_start = |hazard|
			match hazard.lane {
				Vertical => { x: hazard.center.x, y: hazard.center.y - hazard.span * 0.5 }
				Horizontal => { x: hazard.center.x - hazard.span * 0.5, y: hazard.center.y }
			}

		lane_end : Hazard -> Math.Vec2
		lane_end = |hazard|
			match hazard.lane {
				Vertical => { x: hazard.center.x, y: hazard.center.y + hazard.span * 0.5 }
				Horizontal => { x: hazard.center.x + hazard.span * 0.5, y: hazard.center.y }
			}

		hit_by : Hazard, Math.Circle, F32 -> Bool
		hit_by = |hazard, other, phase| Math.circle_overlaps(other, hazard.circle(phase))
	}

	StepInput : {
		raw_dir : Math.Vec2,
		dash_pressed : Bool,
		dt : F32,
	}

	StepEvent := [DashStarted(Math.Vec2), SparkCollected(Spark), GateOpened, Escaped, Damaged(GameState)]

	StepResult : {
		world : World,
		events : List(StepEvent),
	}

	CollectResult : {
		world : World,
		collected : Try(Spark, [NoSpark]),
		gate_opened : Bool,
	}

	EscapeResult : {
		world : World,
		escaped : Bool,
	}

	DamageResult : {
		world : World,
		damaged : Bool,
	}

	new : Level -> World
	new = |level| {
		player: Player.new(level.spawn),
		sparks: level.sparks,
		score: 0,
		lives: 3,
		phase: 0,
		shake: 0,
		flash: 0,
		burst_pos: level.spawn,
		burst_timer: 0,
		gate: GateLocked,
		gate_flash: 0,
		state: Playing,
	}
}

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
	level : Level,
	sounds : Sounds,
	world : World,
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
world_right = 1456

world_bottom : F32
world_bottom = 1144

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

top_down_map_path : Str
top_down_map_path = "examples/assets/top_down.tmx"

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

fallback_spawn : Math.Vec2
fallback_spawn = { x: -560, y: -360 }

fallback_exit_center : Math.Vec2
fallback_exit_center = { x: 1185, y: 920 }

fallback_exit_radius : F32
fallback_exit_radius = 58

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
					Ok(tiles) =>
						match Tilemap.load_tmx!(top_down_map_path) {
							Ok(raw_map) => {
								tilemap = Tilemap.from_raw(raw_map)
									.with_origin(
										{ x: world_left, y: world_top },
									)
									.with_tileset_texture(
										1,
										tiles,
									)
									.layer_role(
										"Ground",
										Drawn,
									)
									.layer_role(
										"Decor",
										Drawn,
									)
									.layer_role(
										"Walls",
										Solid,
									)
									.object_role(
										"spawn",
										Spawn,
									)
									.object_role(
										"spark",
										Collectible,
									)
									.object_role(
										"hazard",
										Hazard,
									)
									.object_role(
										"exit",
										Exit,
									)
									.build()
								level = level_from_tilemap(tilemap)
								sounds = make_sounds!()
								Audio.play_music!(sounds.music)
								Ok(new_game(characters, tiles, level, sounds))
							}
							Err(_) => Err(Exit(1))
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

new_game : Assets.Texture, Assets.Texture, Level, Sounds -> Model
new_game = |characters, tiles, level, sounds| {
	characters,
	tiles,
	level,
	sounds,
	world: World.new(level),
}

fallback_sparks : List(World.Spark)
fallback_sparks = [
	World.Spark.new(0, -430, -150),
	World.Spark.new(1, -55, -350),
	World.Spark.new(2, 315, -295),
	World.Spark.new(3, 760, -405),
	World.Spark.new(4, 1110, -65),
	World.Spark.new(5, 910, 350),
	World.Spark.new(6, 560, 820),
	World.Spark.new(7, 105, 640),
	World.Spark.new(8, -280, 895),
	World.Spark.new(9, -540, 410),
]

fallback_obstacles : List(World.Obstacle)
fallback_obstacles = [
	World.Obstacle.new(-305, -300, 150, 440, TileBlockA, 0),
	World.Obstacle.new(85, -430, 150, 295, TileBlockB, 11),
	World.Obstacle.new(210, -45, 510, 120, TileBlockA, 22),
	World.Obstacle.new(705, 150, 140, 425, TileBlockB, 33),
	World.Obstacle.new(5, 505, 480, 115, TileBlockA, 44),
	World.Obstacle.new(-535, 515, 340, 105, TileBlockB, 55),
	World.Obstacle.new(965, -300, 145, 450, TileBlockA, 66),
]

fallback_hazards : List(World.Hazard)
fallback_hazards = [
	{ center: { x: -445, y: 165 }, span: 520, lane: Horizontal, offset: 0, radius: 30, color: Color.from_hex_rgb(0xf94144) },
	{ center: { x: 25, y: 320 }, span: 650, lane: Vertical, offset: 0.22, radius: 34, color: Color.from_hex_rgb(0xf3722c) },
	{ center: { x: 600, y: -255 }, span: 650, lane: Horizontal, offset: 0.48, radius: 32, color: Color.from_hex_rgb(0xf8961e) },
	{ center: { x: 1035, y: 455 }, span: 700, lane: Vertical, offset: 0.72, radius: 36, color: Color.from_hex_rgb(0xf94144) },
]

fallback_decorations : List(Decoration)
fallback_decorations = [
	{ pos: { x: -640, y: 80 }, tile: TileCrystalA, scale: 1.35, rotation: 0 },
	{ pos: { x: -575, y: 585 }, tile: TileCrystalB, scale: 1.2, rotation: 0 },
	{ pos: { x: -85, y: -455 }, tile: TilePlantA, scale: 1.35, rotation: 0 },
	{ pos: { x: 190, y: 185 }, tile: TileMarker, scale: 1.15, rotation: 0 },
	{ pos: { x: 780, y: -210 }, tile: TileBlockA, scale: 1.1, rotation: 12 },
	{ pos: { x: 1110, y: 190 }, tile: TileRockA, scale: 1.45, rotation: 0 },
	{ pos: { x: 1035, y: 785 }, tile: TileBlockB, scale: 1.2, rotation: -14 },
	{ pos: { x: 315, y: 975 }, tile: TileFlowerA, scale: 1.05, rotation: 0 },
	{ pos: { x: -395, y: 960 }, tile: TileFlowerB, scale: 0.9, rotation: 0 },
	{ pos: { x: 1185, y: 735 }, tile: TileSparkA, scale: 0.7, rotation: 20 },
	{ pos: { x: 1280, y: -395 }, tile: TileSparkB, scale: 0.72, rotation: -18 },
	{ pos: { x: -615, y: -405 }, tile: TilePlantB, scale: 1.1, rotation: 0 },
]

fallback_level : Level
fallback_level = {
	tilemap: Tilemap.from_raw(Tilemap.empty_raw_map).build(),
	spawn: fallback_spawn,
	exit_center: fallback_exit_center,
	exit_radius: fallback_exit_radius,
	sparks: fallback_sparks,
	spark_total,
	obstacles: fallback_obstacles,
	hazards: fallback_hazards,
	decorations: fallback_decorations,
	bounds: Math.rect(world_left, world_top, world_right - world_left, world_bottom - world_top),
}

level_from_tilemap : Tilemap -> Level
level_from_tilemap = |tilemap| {
	raw = Tilemap.raw_map(tilemap)
	spawn_object = first_typed_object(tilemap, "spawn")
	exit_object = first_typed_object(tilemap, "exit")
	sparks = sparks_from_tilemap(tilemap)

	{
		tilemap,
		spawn: object_center_or(tilemap, spawn_object, fallback_spawn),
		exit_center: object_center_or(tilemap, exit_object, fallback_exit_center),
		exit_radius: object_radius_or(exit_object, fallback_exit_radius),
		sparks,
		spark_total: List.len(sparks),
		obstacles: obstacles_from_tilemap(raw, tilemap),
		hazards: hazards_from_tilemap(raw, tilemap),
		decorations: decorations_from_tilemap(raw, tilemap),
		bounds: Math.rect(world_left, world_top, world_right - world_left, world_bottom - world_top),
	}
}

first_typed_object : Tilemap, Str -> Try(Tilemap.RawObject, [NotFound])
first_typed_object = |tilemap, type_name|
	match List.first(Tilemap.objects_typed(tilemap, type_name)) {
		Ok(object) => Ok(object)
		Err(_) => Err(NotFound)
	}

object_center_or : Tilemap, Try(Tilemap.RawObject, [NotFound]), Math.Vec2 -> Math.Vec2
object_center_or = |tilemap, object_result, fallback|
	match object_result {
		Ok(object) => Tilemap.object_world_center(tilemap, object)
		Err(_) => fallback
	}

object_radius_or : Try(Tilemap.RawObject, [NotFound]), F32 -> F32
object_radius_or = |object_result, fallback|
	match object_result {
		Ok(object) => if object.width == 0 and object.height == 0 fallback else F32.max(object.width, object.height) * 0.5
		Err(_) => fallback
	}

sparks_from_tilemap : Tilemap -> List(World.Spark)
sparks_from_tilemap = |tilemap| {
	var $sparks = []
	for object in Tilemap.objects_typed(tilemap, "spark") {
		pos = Tilemap.object_world_center(tilemap, object)
		$sparks = List.append($sparks, World.Spark.new(object.id, pos.x, pos.y))
	}
	if List.len($sparks) == 0 fallback_sparks else $sparks
}

obstacles_from_tilemap : Tilemap.RawMap, Tilemap -> List(World.Obstacle)
obstacles_from_tilemap = |raw, tilemap| {
	var $items = []
	for object in Tilemap.objects_typed(tilemap, "obstacle") {
		rect = Tilemap.object_world_rect(tilemap, object)
		tile = tile_from_name(Tilemap.property_str(raw, object, "tile", "TileBlockA"))
		rotation = Tilemap.property_f32(raw, object, "rotation", object.rotation)
		$items = List.append($items, World.Obstacle.new(rect.x, rect.y, rect.width, rect.height, tile, rotation))
	}
	if List.len($items) == 0 fallback_obstacles else $items
}

hazards_from_tilemap : Tilemap.RawMap, Tilemap -> List(World.Hazard)
hazards_from_tilemap = |raw, tilemap| {
	var $items = []
	for object in Tilemap.objects_typed(tilemap, "hazard") {
		center = Tilemap.object_world_center(tilemap, object)
		lane = lane_from_name(Tilemap.property_str(raw, object, "lane", "Horizontal"))
		span = Tilemap.property_f32(raw, object, "span", 520)
		offset = Tilemap.property_f32(raw, object, "offset", 0)
		radius = Tilemap.property_f32(raw, object, "radius", 30)
		$items = List.append($items, { center, span, lane, offset, radius, color: hazard_color(object.id) })
	}
	if List.len($items) == 0 fallback_hazards else $items
}

decorations_from_tilemap : Tilemap.RawMap, Tilemap -> List(Decoration)
decorations_from_tilemap = |raw, tilemap| {
	var $items = []
	for object in Tilemap.objects_typed(tilemap, "decoration") {
		$items = List.append(
			$items,
			{
				pos: Tilemap.object_world_center(tilemap, object),
				tile: tile_from_name(Tilemap.property_str(raw, object, "tile", "TilePlantA")),
				scale: Tilemap.property_f32(raw, object, "scale", 1),
				rotation: Tilemap.property_f32(raw, object, "rotation", object.rotation),
			},
		)
	}
	if List.len($items) == 0 fallback_decorations else $items
}

tile_from_name : Str -> Tile
tile_from_name = |name|
	if name == "TileBlockB" {
		TileBlockB
	} else if name == "TileMarker" {
		TileMarker
	} else if name == "TileRockA" {
		TileRockA
	} else if name == "TilePlantA" {
		TilePlantA
	} else if name == "TilePlantB" {
		TilePlantB
	} else if name == "TileFlowerA" {
		TileFlowerA
	} else if name == "TileFlowerB" {
		TileFlowerB
	} else if name == "TileCrystalA" {
		TileCrystalA
	} else if name == "TileCrystalB" {
		TileCrystalB
	} else if name == "TileSparkA" {
		TileSparkA
	} else if name == "TileSparkB" {
		TileSparkB
	} else {
		TileBlockA
	}

lane_from_name : Str -> Lane
lane_from_name = |name| if name == "Vertical" Vertical else Horizontal

hazard_color : U64 -> Color
hazard_color = |id|
	match id % 4 {
		0 => Color.from_hex_rgb(0xf94144)
		1 => Color.from_hex_rgb(0xf3722c)
		2 => Color.from_hex_rgb(0xf8961e)
		_ => Color.from_hex_rgb(0xf94144)
	}

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

facing_from_input : Math.Vec2, Facing -> Facing
facing_from_input = |dir, fallback| {
	if dir.y < 0 and dir.x == 0 {
		North
	} else if dir.y < 0 and dir.x > 0 {
		NorthEast
	} else if dir.x > 0 and dir.y == 0 {
		East
	} else if dir.x > 0 and dir.y > 0 {
		SouthEast
	} else if dir.y > 0 and dir.x == 0 {
		South
	} else if dir.x < 0 and dir.y > 0 {
		SouthWest
	} else if dir.x < 0 and dir.y == 0 {
		West
	} else if dir.x < 0 and dir.y < 0 {
		NorthWest
	} else {
		fallback
	}
}

clamp_to_world : Level, Math.Vec2 -> Math.Vec2
clamp_to_world = |level, pos| {
	x: Math.clamp(pos.x, Math.left(level.bounds) + player_radius, Math.right(level.bounds) - player_radius),
	y: Math.clamp(pos.y, Math.top(level.bounds) + player_radius, Math.bottom(level.bounds) - player_radius),
}

any_obstacle_hit : Level, Math.Circle -> Bool
any_obstacle_hit = |level, circle| {
	var $hit = Bool.False
	for obstacle in level.obstacles {
		if obstacle.hit_by(circle) {
			$hit = Bool.True
		}
	}
	if Tilemap.circle_touches_solid(level.tilemap, circle) {
		$hit = Bool.True
	}
	$hit
}

move_player_speed : Level, Math.Vec2, Math.Vec2, F32, F32 -> Math.Vec2
move_player_speed = |level, player, raw_dir, dt, speed| {
	dir = Math.normalize(raw_dir)
	candidate = clamp_to_world(level, Math.add(player, Math.scale(dir, speed * dt)))

	if any_obstacle_hit(level, Math.circle(candidate, player_radius)) player else candidate
}

wrap_unit : F32 -> F32
wrap_unit = |value| if value >= 1 value - 1 else if value < 0 value + 1 else value

ping_pong : F32 -> F32
ping_pong = |phase| if phase < 0.5 phase * 2 else (1 - phase) * 2

tick_timer : F32, F32 -> F32
tick_timer = |timer, dt| if timer <= dt 0 else timer - dt

find_hit_spark : List(World.Spark), Math.Circle, U64 -> Try(World.Spark, [NoSpark])
find_hit_spark = |sparks, player_circle, index|
	match List.get(sparks, index) {
		Ok(spark) =>
			if spark.hit_by(player_circle) {
				Ok(spark)
			} else {
				find_hit_spark(sparks, player_circle, index + 1)
			}
		Err(_) => Err(NoSpark)
	}

play_if! : Bool, Audio.Sound => {}
play_if! = |cond, sound| if cond Audio.play!(sound) else {}

pan_for_world_x : F32 -> F32
pan_for_world_x = |x| Math.clamp((x - world_left) / (world_right - world_left) * 2 - 1, -1, 1)

gate_is_open : GateState -> Bool
gate_is_open = |gate|
	match gate {
		GateLocked => Bool.False
		GateOpen => Bool.True
	}

gate_after_collect : List(World.Spark) -> GateState
gate_after_collect = |remaining| if List.len(remaining) == 0 GateOpen else GateLocked

collect_spark : World -> World.CollectResult
collect_spark = |world|
	match find_hit_spark(world.sparks, world.player.circle(), 0) {
		Ok(spark) => {
			remaining = List.keep_if(world.sparks, |item| item.id != spark.id)
			next_score = world.score + 1
			next_gate = gate_after_collect(remaining)
			gate_opened = next_gate == GateOpen and !(gate_is_open(world.gate))

			{
				world: {
					..world,
					sparks: remaining,
					score: next_score,
					shake: 0,
					flash: 0,
					burst_pos: spark.pos,
					burst_timer: burst_duration,
					gate: next_gate,
					gate_flash: if gate_opened 1 else world.gate_flash,
					state: Playing,
				},
				collected: Ok(spark),
				gate_opened,
			}
		}
		Err(_) => { world, collected: Err(NoSpark), gate_opened: Bool.False }
	}

any_hazard_hit : Level, Math.Circle, F32 -> Bool
any_hazard_hit = |level, circle, phase| {
	var $hit = Bool.False
	for hazard in level.hazards {
		if hazard.hit_by(circle, phase) {
			$hit = Bool.True
		}
	}
	$hit
}

damage_if_needed : Level, World -> World.DamageResult
damage_if_needed = |level, world| {
	if world.player.invuln <= 0 and any_hazard_hit(level, world.player.circle(), world.phase) {
		next_lives = if world.lives > 0 world.lives - 1 else 0
		next_state = if world.lives <= 1 GameOver else Playing
		{
			world: {
				..world,
				player: world.player.damage_respawn(level.spawn),
				lives: next_lives,
				shake: 10,
				flash: 0.28,
				burst_pos: world.player.pos,
				burst_timer: burst_duration,
				state: next_state,
			},
			damaged: Bool.True,
		}
	} else {
		{ world, damaged: Bool.False }
	}
}

escape_if_needed : Level, World -> World.EscapeResult
escape_if_needed = |level, world| {
	if gate_is_open(world.gate) and Math.circle_overlaps(world.player.circle(), Math.circle(level.exit_center, level.exit_radius)) {
		{
			world: {
				..world,
				shake: 10,
				flash: 0,
				burst_pos: level.exit_center,
				burst_timer: burst_duration,
				gate_flash: 1,
				state: Won,
			},
			escaped: Bool.True,
		}
	} else {
		{ world, escaped: Bool.False }
	}
}

is_moving : Math.Vec2 -> Bool
is_moving = |dir| dir.x != 0 or dir.y != 0

facing_to_vec : Facing -> Math.Vec2
facing_to_vec = |facing|
	match facing {
		North => { x: 0, y: -1 }
		NorthEast => { x: 0.7, y: -0.7 }
		East => { x: 1, y: 0 }
		SouthEast => { x: 0.7, y: 0.7 }
		South => { x: 0, y: 1 }
		SouthWest => { x: -0.7, y: 0.7 }
		West => { x: -1, y: 0 }
		NorthWest => { x: -0.7, y: -0.7 }
	}

facing_to_rotation : Facing -> F32
facing_to_rotation = |facing|
	match facing {
		North => -90
		NorthEast => -45
		East => 0
		SouthEast => 45
		South => 90
		SouthWest => 135
		West => 180
		NorthWest => 225
	}

idle_animation : Sprite.Animation -> Sprite.Animation
idle_animation = |animation| {
	frame: 0,
	frame_count: animation.frame_count,
	fps: animation.fps,
	elapsed: 0,
}

event_when : Bool, World.StepEvent -> List(World.StepEvent)
event_when = |condition, event| if condition [event] else []

spark_collected_events : Try(World.Spark, [NoSpark]) -> List(World.StepEvent)
spark_collected_events = |collected|
	match collected {
		Ok(spark) => [SparkCollected(spark)]
		Err(_) => []
	}

step_events : Bool, Try(World.Spark, [NoSpark]), Bool, Bool, Bool, GameState, Math.Vec2 -> List(World.StepEvent)
step_events = |dash_started, collected, gate_opened, escaped, damaged, damage_state, dash_pos|
	List.concat(
		event_when(dash_started, DashStarted(dash_pos)),
		List.concat(
			spark_collected_events(collected),
			List.concat(
				event_when(gate_opened, GateOpened),
				List.concat(
					event_when(escaped, Escaped),
					event_when(damaged, Damaged(damage_state)),
				),
			),
		),
	)

advance_playing : Level, World, World.StepInput -> World.StepResult
advance_playing = |level, world, input| {
	moving = is_moving(input.raw_dir)
	dash_started = input.dash_pressed and world.player.dash_ready()
	dash_active = dash_started or world.player.dash_active()
	move_dir = if dash_active and !(moving) world.player.facing_dir() else input.raw_dir
	speed = if dash_active dash_speed else player_speed
	player_pos = move_player_speed(level, world.player.pos, move_dir, input.dt, speed)
	player = world.player.step({ pos: player_pos, raw_dir: input.raw_dir, move_dir, dash_started, dash_active, dt: input.dt })
	hazard_speed = 0.15 + U64.to_f32(world.score) * 0.012
	phase = wrap_unit(world.phase + input.dt * hazard_speed)

	moved = {
		..world,
		player,
		phase,
		shake: Math.clamp(world.shake - input.dt * 36, 0, 99),
		flash: tick_timer(world.flash, input.dt * 1.8),
		burst_timer: tick_timer(world.burst_timer, input.dt),
		gate_flash: tick_timer(world.gate_flash, input.dt * 1.15),
		state: Playing,
	}
	collect_result = collect_spark(moved)
	escape_result = escape_if_needed(level, collect_result.world)
	damage_result = if escape_result.world.state == Won { world: escape_result.world, damaged: Bool.False } else damage_if_needed(level, escape_result.world)

	{
		world: damage_result.world,
		events: step_events(
			dash_started,
			collect_result.collected,
			collect_result.gate_opened,
			escape_result.escaped,
			damage_result.damaged,
			damage_result.world.state,
			world.player.pos,
		),
	}
}

play_step_events! : Model, World.StepResult => {}
play_step_events! = |model, result| {
	sounds = model.sounds

	for event in result.events {
		match event {
			DashStarted(pos) => {
				Audio.set_pan!(sounds.dash, pan_for_world_x(pos.x))
				Audio.set_pitch!(sounds.dash, 0.95 + U64.to_f32(model.world.score) * 0.015)
				Audio.play!(sounds.dash)
			}
			SparkCollected(spark) => {
				Audio.set_pan!(sounds.collect, pan_for_world_x(spark.pos.x))
				Audio.set_pitch!(sounds.sparkle, 0.92 + U64.to_f32(result.world.score) * 0.045)
				Audio.play!(sounds.collect)
				play_if!(result.world.score % 3 == 0, sounds.sparkle)
			}
			GateOpened => Audio.play!(sounds.gate)
			Escaped => {
				Audio.set_music_volume!(sounds.music, 0.08)
				Audio.play!(sounds.win)
			}
			Damaged(state) => Audio.play!(if state == GameOver sounds.lose else sounds.hurt)
		}
	}
}

advance_playing! : Model, Host => Model
advance_playing! = |model, host| {
	result = advance_playing(
		model.level,
		model.world,
		{
			raw_dir: input_axis(host),
			dash_pressed: Keys.key_pressed(host.keys_pressed, KeySpace),
			dt: host.frame_time,
		},
	)
	play_step_events!(model, result)
	{ ..model, world: result.world }
}

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {
	if Keys.key_pressed(host.keys_pressed, KeyEscape) {
		Host.exit!(0)
	}

	next = match model.world.state {
		Playing => advance_playing!(model, host)
		Won =>
			if Keys.key_pressed(host.keys_pressed, KeySpace) {
				Audio.set_music_volume!(model.sounds.music, 0.13)
				new_game(model.characters, model.tiles, model.level, model.sounds)
			} else {
				model
			}
		GameOver =>
			if Keys.key_pressed(host.keys_pressed, KeySpace) {
				Audio.set_music_volume!(model.sounds.music, 0.13)
				new_game(model.characters, model.tiles, model.level, model.sounds)
			} else {
				model
			}
		}

	camera = Camera.follow(shaken_target(next.world), { screen: { x: screen_w, y: screen_h }, zoom: 0.82 })

	Draw.draw!(
		Color.from_hex_rgb(0x071018),
		|| {
			Draw.with_camera!(
				camera,
				|| draw_world!(next.level, next.characters, next.tiles, next.world),
			)

			draw_hud!(next.level, next.world)
		},
	)

	Ok(next)
}

shaken_target : World -> Math.Vec2
shaken_target = |world| {
	amount = world.shake
	x_phase = ping_pong(wrap_unit(world.phase * 9.7))
	y_phase = ping_pong(wrap_unit(world.phase * 13.1 + 0.31))
	{
		x: world.player.pos.x + (x_phase - 0.5) * amount,
		y: world.player.pos.y + (y_phase - 0.5) * amount,
	}
}

draw_world! : Level, Assets.Texture, Assets.Texture, World => {}
draw_world! = |level, characters, tiles, world| {
	Draw.rectangle_gradient_v!({ x: level.bounds.x, y: level.bounds.y, width: level.bounds.width, height: level.bounds.height, color_top: Color.from_hex_rgb(0x173833), color_bottom: Color.from_hex_rgb(0x132821) })
	Tilemap.draw_all!(level.tilemap)
	draw_hazard_lanes!(level, world.phase)
	draw_props!(level, tiles)
	Draw.rectangle!({ x: level.bounds.x, y: level.bounds.y, width: level.bounds.width, height: level.bounds.height, style: Draw.outlined(Color.with_alpha(Color.white, 90), 6) })

	draw_spawn!(level)
	draw_exit!(level, world)
	draw_obstacles!(level, tiles)
	draw_sparks!(tiles, world.sparks, world.phase)
	draw_hazards!(level, characters, world.phase)
	draw_burst!(world)
	draw_player!(characters, world.player)
}

tile_cols : U64
tile_cols = 27

tile_id : Tile -> U64
tile_id = |tile|
	match tile {
		TileFloor => 1
		TileBlockA => 156
		TileBlockB => 157
		TileMarker => 158
		TileRockA => 181
		TilePlantA => 183
		TilePlantB => 184
		TileFlowerA => 213
		TileFlowerB => 214
		TileCrystalA => 237
		TileCrystalB => 238
		TileSparkA => 239
		TileSparkB => 240
	}

tile_source : Tile -> Math.Rect
tile_source = |tile| {
	index = tile_id(tile) - 1
	Sprite.sheet_frame({ frame_size: { x: 64, y: 64 }, row: index // tile_cols, col: index % tile_cols })
}

tile_sprite : Assets.Texture, Tile, Math.Vec2, F32 -> Sprite.Sprite
tile_sprite = |tiles, tile, pos, scale|
	Sprite.from_texture(tiles)
		.source(
			tile_source(tile),
		)
		.pos(
			pos,
		)
		.scale(
			scale,
		)

draw_tile! : Assets.Texture, Tile, Math.Vec2, F32 => {}
draw_tile! = |tiles, tile, pos, scale| tile_sprite(tiles, tile, pos, scale).draw!()

draw_tile_centered! : Assets.Texture, Tile, Math.Vec2, F32, F32 => {}
draw_tile_centered! = |tiles, tile, pos, scale, rotation| tile_sprite(tiles, tile, pos, scale).centered().rotation(rotation).draw!()

draw_spawn! : Level => {}
draw_spawn! = |level| {
	Draw.circle_gradient!({ center: level.spawn, radius: 72, color_inner: Color.with_alpha(Color.from_hex_rgb(0x2a9d8f), 120), color_outer: Color.with_alpha(Color.from_hex_rgb(0x2a9d8f), 0) })
	Draw.circle!({ center: level.spawn, radius: 42, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x2a9d8f), Color.white, 4) })
	Draw.text!({ pos: { x: level.spawn.x, y: level.spawn.y + 63 }, text: "START", size: 18, spacing: Draw.default_spacing, color: Color.with_alpha(Color.white, 190), font: Draw.default_font, align: Draw.align_top_center })
}

draw_exit! : Level, World => {}
draw_exit! = |level, world| {
	is_open = gate_is_open(world.gate)
	color = if is_open Color.from_hex_rgb(0xf9c74f) else Color.from_hex_rgb(0x576066)
	halo = if is_open Color.with_alpha(color, 95) else Color.with_alpha(Color.black, 70)
	Draw.circle_gradient!({ center: level.exit_center, radius: 82 + world.gate_flash * 28, color_inner: halo, color_outer: Color.with_alpha(color, 0) })
	Draw.circle!({ center: level.exit_center, radius: level.exit_radius, style: Draw.filled_and_outlined(Color.with_alpha(color, 190), Color.white, 4) })
	Draw.text!({ pos: { x: level.exit_center.x, y: level.exit_center.y + 74 }, text: if is_open "EXIT OPEN" else "LOCKED EXIT", size: 19, spacing: Draw.default_spacing, color: Color.white, font: Draw.default_font, align: Draw.align_top_center })
}

draw_obstacle! : Assets.Texture, World.Obstacle => {}
draw_obstacle! = |tiles, obstacle| {
	rect = obstacle.rect
	Draw.rounded_rectangle!({ x: rect.x, y: rect.y, width: rect.width, height: rect.height, radius: 14, segments: 8, style: Draw.filled_and_outlined(Color.with_alpha(Color.from_hex_rgb(0x23342d), 235), Color.from_hex_rgb(0xa3b18a), 4) })
	draw_tile_centered!(tiles, obstacle.tile, obstacle.center(), 1.25, obstacle.rotation)
}

draw_obstacles! : Level, Assets.Texture => {}
draw_obstacles! = |level, tiles| {
	for obstacle in level.obstacles {
		draw_obstacle!(tiles, obstacle)
	}
}

draw_props! : Level, Assets.Texture => {}
draw_props! = |level, tiles| {
	for decoration in level.decorations {
		draw_tile_centered!(tiles, decoration.tile, decoration.pos, decoration.scale, decoration.rotation)
	}
}

draw_spark! : Assets.Texture, World.Spark, F32 => {}
draw_spark! = |tiles, spark, phase| {
	tile = if spark.id % 2 == 0 TileSparkA else TileSparkB
	rotation = phase * 160 + U64.to_f32(spark.id) * 19
	pulse = 1 + ping_pong(wrap_unit(phase * 2 + U64.to_f32(spark.id) * 0.09)) * 0.1
	Draw.circle_gradient!({ center: spark.pos, radius: spark_radius * 2 * pulse, color_inner: Color.with_alpha(Color.from_hex_rgb(0xf9c74f), 55), color_outer: Color.with_alpha(Color.from_hex_rgb(0xf9c74f), 0) })
	Draw.circle!({ center: spark.pos, radius: spark_radius + 4 * pulse, style: Draw.outlined(Color.with_alpha(Color.white, 110), 3) })
	draw_tile_centered!(tiles, tile, spark.pos, 0.72 * pulse, rotation)
}

draw_sparks! : Assets.Texture, List(World.Spark), F32 => {}
draw_sparks! = |tiles, sparks, phase| {
	for spark in sparks {
		draw_spark!(tiles, spark, phase)
	}
}

draw_hazard_lanes! : Level, F32 => {}
draw_hazard_lanes! = |level, phase| {
	for hazard in level.hazards {
		pos = hazard.pos(phase)
		Draw.line!({ start: hazard.lane_start(), end: hazard.lane_end(), stroke: Draw.stroke(Color.with_alpha(hazard.color, 48), 10) })
		Draw.circle_gradient!({ center: pos, radius: hazard.radius * 1.9, color_inner: Color.with_alpha(hazard.color, 54), color_outer: Color.with_alpha(hazard.color, 0) })
	}
}

robot_source : Math.Rect
robot_source = Math.rect(458, 88, 33, 43)

draw_hazard! : Assets.Texture, World.Hazard, F32 => {}
draw_hazard! = |characters, hazard, phase| {
	pos = hazard.pos(phase)
	sprite = Sprite.from_texture(characters)
		.source(
			robot_source,
		)
		.pos(
			pos,
		)
		.scale(
			1.38,
		)
		.centered()

	sprite.draw!()
	Draw.circle!({ center: pos, radius: hazard.radius, style: Draw.outlined(Color.with_alpha(Color.white, 170), 3) })
}

draw_hazards! : Level, Assets.Texture, F32 => {}
draw_hazards! = |level, characters, phase| {
	for hazard in level.hazards {
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

draw_burst_particle! : World, U64 => {}
draw_burst_particle! = |world, index| {
	if index >= 6 or world.burst_timer <= 0 {
		{}
	} else {
		progress = 1 - world.burst_timer / burst_duration
		dir = burst_dir(index)
		pos = Math.add(world.burst_pos, Math.scale(dir, 18 + progress * 58))
		size = 6 + ping_pong(wrap_unit(world.phase * 5 + U64.to_f32(index) * 0.11)) * 3
		Draw.circle!({ center: pos, radius: size, style: Draw.filled(Color.with_alpha(Color.from_hex_rgb(0xf9c74f), if world.burst_timer > 0.18 135 else 70)) })
		draw_burst_particle!(world, index + 1)
	}
}

draw_burst! : World => {}
draw_burst! = |world| draw_burst_particle!(world, 0)

player_source : Math.Rect
player_source = Math.rect(0, 0, 52, 43)

draw_player! : Assets.Texture, World.Player => {}
draw_player! = |characters, player| {
	tint = if player.invuln > 0 Color.with_alpha(Color.white, 150) else Color.white
	scale = if player.dash_active() 1.3 else 1.22
	sprite = Sprite.from_texture(characters)
		.source(
			player_source,
		)
		.pos(
			player.pos,
		)
		.scale(
			scale,
		)
		.centered()
		.rotation(
			player.rotation(),
		)
		.tint(
			tint,
		)

	Draw.circle!({ center: { x: player.pos.x + 5, y: player.pos.y + 7 }, radius: player_radius + 6, style: Draw.filled(Color.with_alpha(Color.black, 85)) })
	if player.dash_active() {
		trail_center = Math.add(player.pos, Math.scale(player.facing_dir(), -38))
		Draw.circle_gradient!({ center: trail_center, radius: 44, color_inner: Color.with_alpha(Color.from_hex_rgb(0x43aa8b), 55), color_outer: Color.with_alpha(Color.from_hex_rgb(0x43aa8b), 0) })
		Draw.circle_gradient!({ center: player.pos, radius: 54, color_inner: Color.with_alpha(Color.from_hex_rgb(0x43aa8b), 70), color_outer: Color.with_alpha(Color.from_hex_rgb(0x43aa8b), 0) })
	} else {
		{}
	}
	sprite.draw!()
	Draw.circle!({ center: player.pos, radius: player_radius, style: Draw.outlined(Color.with_alpha(Color.white, 180), 2) })
}

draw_bar! : F32, F32, F32, F32, F32, Color => {}
draw_bar! = |x, y, width, height, amount, color| {
	Draw.rounded_rectangle!({ x, y, width, height, radius: 5, segments: 6, style: Draw.filled(Color.with_alpha(Color.black, 130)) })
	Draw.rounded_rectangle!({ x, y, width: width * Math.clamp(amount, 0, 1), height, radius: 5, segments: 6, style: Draw.filled(color) })
}

draw_hud! : Level, World => {}
draw_hud! = |level, world| {
	is_open = gate_is_open(world.gate)

	Draw.rectangle_gradient_v!({ x: 0, y: 0, width: screen_w, height: 76, color_top: Color.with_alpha(Color.black, 220), color_bottom: Color.with_alpha(Color.black, 125) })
	Draw.text!({ pos: { x: 22, y: 16 }, text: "Spark Run", size: 27, spacing: Draw.default_spacing, color: Color.white, font: Draw.default_font, align: Draw.align_top_left })
	Draw.text!({ pos: { x: 195, y: 18 }, text: Str.concat("Sparks ", Str.concat(U64.to_str(world.score), Str.concat("/", U64.to_str(level.spark_total)))), size: 20, spacing: Draw.default_spacing, color: Color.from_hex_rgb(0xf9c74f), font: Draw.default_font, align: Draw.align_top_left })
	Draw.text!({ pos: { x: 382, y: 18 }, text: Str.concat("Lives ", U64.to_str(world.lives)), size: 20, spacing: Draw.default_spacing, color: Color.light_gray, font: Draw.default_font, align: Draw.align_top_left })
	Draw.text!({ pos: { x: 510, y: 18 }, text: if is_open "Gate open" else "Collect all sparks", size: 20, spacing: Draw.default_spacing, color: if is_open Color.from_hex_rgb(0x90be6d) else Color.light_gray, font: Draw.default_font, align: Draw.align_top_left })
	Draw.fps!({ pos: { x: 735, y: 20 }, size: 18, color: Color.gray })
	draw_bar!(196, 48, 170, 9, U64.to_f32(world.score) / U64.to_f32(level.spark_total), Color.from_hex_rgb(0xf9c74f))
	draw_bar!(510, 48, 120, 9, world.player.dash_charge(), Color.from_hex_rgb(0x43aa8b))
	Draw.text!({ pos: { x: 640, y: 43 }, text: if world.player.dash_ready() "SPACE dash" else "charging", size: 16, spacing: Draw.default_spacing, color: Color.light_gray, font: Draw.default_font, align: Draw.align_top_left })

	if world.flash > 0 {
		Draw.rectangle!({ x: 0, y: 0, width: screen_w, height: screen_h, style: Draw.filled(Color.with_alpha(Color.red, if world.flash > 0.45 120 else 70)) })
	} else {
		{}
	}

	match world.state {
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

approx : F32, F32 -> Bool
approx = |a, b| F32.abs(a - b) < 0.0001

approx_vec : Math.Vec2, Math.Vec2 -> Bool
approx_vec = |a, b| approx(a.x, b.x) and approx(a.y, b.y)

test_hazard : World.Hazard
test_hazard = { center: { x: 0, y: 0 }, span: 20, lane: Horizontal, offset: 0, radius: 5, color: Color.white }

expect World.Player.new(fallback_spawn).circle().radius == player_radius
expect World.Player.new(fallback_spawn).facing_dir() == { x: 1, y: 0 }
expect World.Player.new(fallback_spawn).facing == East
expect facing_to_rotation(East) == 0
expect facing_to_vec(NorthWest) == { x: -0.7, y: -0.7 }
expect gate_is_open(GateOpen)
expect !(gate_is_open(GateLocked))
expect tile_id(TileBlockA) == 156
expect tile_id(TileSparkB) == 240
expect World.Player.new({ x: 10, y: 20 }).damage_respawn(fallback_spawn).pos == fallback_spawn
expect World.Obstacle.new(0, 0, 10, 10, TileBlockA, 0).hit_by(Math.circle({ x: 5, y: 5 }, 1))
expect !(World.Obstacle.new(0, 0, 10, 10, TileBlockA, 0).hit_by(Math.circle({ x: 30, y: 30 }, 1)))
expect approx_vec(test_hazard.pos(0), { x: -10, y: 0 })
expect approx_vec(test_hazard.pos(0.25), { x: 0, y: 0 })

expect {
	spark = World.Spark.new(7, 10, 20)
	find_hit_spark([spark], Math.circle({ x: 10, y: 20 }, 1), 0) == Ok(spark)
}

expect {
	world = { ..World.new(fallback_level), player: World.Player.new({ x: -430, y: -150 }) }
	result = collect_spark(world)
	result.world.score == 1 and result.collected == Ok(World.Spark.new(0, -430, -150))
}

expect {
	spark = World.Spark.new(99, 0, 0)
	world = { ..World.new(fallback_level), player: World.Player.new({ x: 0, y: 0 }), sparks: [spark], score: 9 }
	result = collect_spark(world)
	result.gate_opened and result.world.gate == GateOpen and result.world.score == 10
}

expect {
	world = { ..World.new(fallback_level), player: World.Player.new({ x: -705, y: 165 }) }
	result = damage_if_needed(fallback_level, world)
	result.damaged and result.world.lives == 2 and result.world.player.pos == fallback_spawn
}

expect {
	world = { ..World.new(fallback_level), gate: GateOpen, player: World.Player.new(fallback_exit_center) }
	result = escape_if_needed(fallback_level, world)
	result.escaped and result.world.state == Won
}

expect {
	result = advance_playing(fallback_level, World.new(fallback_level), { raw_dir: { x: 1, y: 0 }, dash_pressed: Bool.True, dt: 0.01 })
	List.first(result.events) == Ok(DashStarted(fallback_spawn)) and result.world.player.dash_timer == dash_duration
}
