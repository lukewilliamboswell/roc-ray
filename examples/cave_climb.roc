app [Model, program] { rr: platform "../platform/main.roc" }

import rr.App
import rr.Assets
import rr.Camera
import rr.Color
import rr.Draw
import rr.Host
import rr.Keys
import rr.Math
import rr.Mouse
import rr.Physics
import rr.Sprite
import rr.Tilemap

GameState := [Playing, Won, GameOver]

LaserSegment : {
	start : Physics.Point,
	end : Physics.Point,
}

LaserState : {
	active : Bool,
	segments : List(LaserSegment),
}

LaserTrace : {
	segments : List(LaserSegment),
	killed : List(U64),
	hit_player : Bool,
}

HookProjectile : {
	pos : Physics.Point,
	velocity : Physics.Vector,
	age : F32,
}

HookLatch : {
	anchor : Physics.Point,
	rest_length : F32,
}

HookState := [HookIdle, HookFlying(HookProjectile), HookLatched(HookLatch)]

Mirror : {
	id : U64,
	pos : Physics.Point,
	length : F32,
	base_turn : F32,
	spin : F32,
}

MirrorHit : {
	point : Physics.Point,
	normal : Physics.Vector,
}

LaserHit := [HitSolid(Physics.Point), HitMirror(MirrorHit), HitEnemy({ point : Physics.Point, id : U64 }), HitPlayer(Physics.Point), HitNone(Physics.Point)]

ToolInput : {
	aim : Physics.Point,
	laser_down : Bool,
	hook_down : Bool,
	hook_pressed : Bool,
}

Gem : {
	id : U64,
	pos : Physics.Point,
	taken : Bool,
}

Danger : {
	pos : Physics.Point,
	radius : F32,
}

Enemy : {
	id : U64,
	pos : Physics.Point,
	radius : F32,
	alive : Bool,
}

Level : {
	tilemap : Tilemap,
	spawn : Physics.Point,
	goal : Physics.Point,
	gems : List(Gem),
	hazards : List(Danger),
	mirrors : List(Mirror),
	enemy_spawns : List(Enemy),
	checkpoints : List(Physics.Point),
	bounds : Math.Rect,
}

Player : {
	pos : Physics.Point,
	velocity : Physics.Vector,
	grounded : Bool,
	facing : F32,
	animation : Sprite.Animation,
	invuln : F32,
}

World : {
	player : Player,
	gems : List(Gem),
	collected : U64,
	enemies : List(Enemy),
	checkpoint : Physics.Point,
	lives : U64,
	state : GameState,
	phase : F32,
	flash : F32,
	laser : LaserState,
	hook : HookState,
}

Model : {
	tiles : Assets.Texture,
	characters : Assets.Texture,
	enemies_texture : Assets.Texture,
	background : Assets.Texture,
	level : Level,
	world : World,
}

program = { init!, render! }

screen_w : F32
screen_w = 800

screen_h : F32
screen_h = 600

map_path : Str
map_path = "examples/assets/cave_climb.tmx"

tiles_path : Str
tiles_path = "examples/assets/kenney-platformer/spritesheet-tiles-default.png"

characters_path : Str
characters_path = "examples/assets/kenney-platformer/spritesheet-characters-default.png"

enemies_path : Str
enemies_path = "examples/assets/kenney-platformer/spritesheet-enemies-default.png"

background_path : Str
background_path = "examples/assets/kenney-platformer/background_color_hills.png"

player_width : F32
player_width = 42

player_height : F32
player_height = 58

half_player_w : F32
half_player_w = player_width * 0.5

half_player_h : F32
half_player_h = player_height * 0.5

move_speed : F32
move_speed = 315

gravity : F32
gravity = -2100

jump_velocity : F32
jump_velocity = 920

max_fall_speed : F32
max_fall_speed = -980

gem_radius : F32
gem_radius = 34

checkpoint_radius : F32
checkpoint_radius = 38

goal_radius : F32
goal_radius = 54

laser_range : F32
laser_range = 780

laser_step : F32
laser_step = 10

laser_bounce_limit : U64
laser_bounce_limit = 5

laser_player_radius : F32
laser_player_radius = 17

laser_reflect_nudge : F32
laser_reflect_nudge = 12

mirror_thickness : F32
mirror_thickness = 9

hook_launch_speed : F32
hook_launch_speed = 1040

hook_max_range : F32
hook_max_range = 980

hook_max_age : F32
hook_max_age = 1.35

hook_collision_step : F32
hook_collision_step = 9

hook_spring_strength : F32
hook_spring_strength = 18

hook_damping : F32
hook_damping = 3.2

hook_max_acceleration : F32
hook_max_acceleration = 3200

ground_control : F32
ground_control = 90

air_control : F32
air_control = 20

ground_friction : F32
ground_friction = 70

air_drag : F32
air_drag = 0.35

init! : App.Init(Model)
init! = App.init(
	{
		..App.default,
		title: "RocRay Cave Climb",
		target_fps: 120,
	},
	|_host| {
		# TODO(roc#9655): replace these nested matches with `?` once App.Init
		# can expose open init error rows through platform module aliases.
		match Assets.load_texture!(tiles_path) {
			Ok(tiles) =>
				match Assets.load_texture!(characters_path) {
					Ok(characters) =>
						match Assets.load_texture!(enemies_path) {
							Ok(enemies_texture) =>
								match Assets.load_texture!(background_path) {
									Ok(background) =>
										match Tilemap.load_tmx!(map_path) {
											Ok(raw_map) => {
												tilemap = Tilemap.from_raw(raw_map)
													.with_tileset_texture(
														1,
														tiles,
													)
													.layer_role(
														"Platforms",
														Solid,
													)
													.layer_role(
														"Hazards",
														Drawn,
													)
													.object_role(
														"spawn",
														Spawn,
													)
													.object_role(
														"gem",
														Collectible,
													)
													.object_role(
														"hazard",
														Hazard,
													)
													.object_role(
														"checkpoint",
														Checkpoint,
													)
													.object_role(
														"goal",
														Goal,
													)
													.build()
												level = level_from_tilemap(tilemap)
												Ok({ tiles, characters, enemies_texture, background, level, world: new_world(level) })
											}
											Err(_) => Err(Exit(1))
										}
									Err(_) => Err(Exit(1))
								}
							Err(_) => Err(Exit(1))
						}
					Err(_) => Err(Exit(1))
				}
			Err(_) => Err(Exit(1))
		}
	},
)

map_to_world : Math.Vec2 -> Physics.Point
map_to_world = |point| Physics.point(point.x, 0 - point.y, 0)

world_to_map : Physics.Point -> Math.Vec2
world_to_map = |point| {
	coords = Physics.coords(point)
	{ x: coords.x, y: 0 - coords.y }
}

new_player : Physics.Point -> Player
new_player = |pos| {
	pos,
	velocity: Physics.zero,
	grounded: Bool.False,
	facing: 1,
	animation: Sprite.animation({ frame_count: 2, fps: 8 }),
	invuln: 0,
}

inactive_laser : LaserState
inactive_laser = { active: Bool.False, segments: [] }

new_world : Level -> World
new_world = |level| {
	player: new_player(level.spawn),
	gems: level.gems,
	collected: 0,
	enemies: level.enemy_spawns,
	checkpoint: level.spawn,
	lives: 3,
	state: Playing,
	phase: 0,
	flash: 0,
	laser: inactive_laser,
	hook: HookIdle,
}

level_from_tilemap : Tilemap -> Level
level_from_tilemap = |tilemap| {
	raw = Tilemap.raw_map(tilemap)
	spawn = map_to_world(object_role_center_or(tilemap, Spawn, { x: 160, y: 2520 }))
	goal = map_to_world(object_role_center_or(tilemap, Goal, { x: 832, y: 260 }))

	{
		tilemap,
		spawn,
		goal,
		gems: gems_from_tilemap(tilemap),
		hazards: hazards_from_tilemap(raw, tilemap),
		mirrors: mirrors_from_tilemap(raw, tilemap),
		enemy_spawns: enemies_from_tilemap(raw, tilemap),
		checkpoints: checkpoints_from_tilemap(tilemap),
		bounds: Math.rect(0, 0, U64.to_f32(raw.width) * raw.tile_width, U64.to_f32(raw.height) * raw.tile_height),
	}
}

object_role_center_or : Tilemap, Tilemap.ObjectRole, Math.Vec2 -> Math.Vec2
object_role_center_or = |tilemap, role, fallback|
	match Tilemap.first_object(tilemap, role) {
		Ok(object) => Tilemap.object_world_center(tilemap, object)
		Err(_) => fallback
	}

gems_from_tilemap : Tilemap -> List(Gem)
gems_from_tilemap = |tilemap| {
	var $gems = []
	for object in Tilemap.objects_with_role(tilemap, Collectible) {
		$gems = List.append($gems, { id: object.id, pos: map_to_world(Tilemap.object_world_center(tilemap, object)), taken: Bool.False })
	}
	$gems
}

hazards_from_tilemap : Tilemap.RawMap, Tilemap -> List(Danger)
hazards_from_tilemap = |raw, tilemap| {
	var $hazards = []
	for object in Tilemap.objects_with_role(tilemap, Hazard) {
		$hazards = List.append(
			$hazards,
			{
				pos: map_to_world(Tilemap.object_world_center(tilemap, object)),
				radius: Tilemap.property_f32(raw, object, "radius", 30),
			},
		)
	}
	$hazards
}

mirrors_from_tilemap : Tilemap.RawMap, Tilemap -> List(Mirror)
mirrors_from_tilemap = |raw, tilemap| {
	var $mirrors = []
	for object in Tilemap.objects_typed(tilemap, "mirror") {
		center = Tilemap.object_world_center(tilemap, object)
		length = Tilemap.property_f32(raw, object, "length", F32.max(F32.max(object.width, object.height), 88))
		$mirrors = List.append(
			$mirrors,
			{
				id: object.id,
				pos: map_to_world(center),
				length,
				base_turn: Tilemap.property_f32(raw, object, "turn", object.rotation / 360),
				spin: Tilemap.property_f32(raw, object, "spin", 0.22),
			},
		)
	}
	if List.len($mirrors) == 0 default_mirrors else $mirrors
}

enemies_from_tilemap : Tilemap.RawMap, Tilemap -> List(Enemy)
enemies_from_tilemap = |raw, tilemap| {
	var $enemies = []
	for object in Tilemap.objects_typed(tilemap, "enemy") {
		$enemies = List.append(
			$enemies,
			{
				id: object.id,
				pos: map_to_world(Tilemap.object_world_center(tilemap, object)),
				radius: Tilemap.property_f32(raw, object, "radius", 28),
				alive: Bool.True,
			},
		)
	}
	if List.len($enemies) == 0 default_enemies else $enemies
}

default_mirrors : List(Mirror)
default_mirrors = [
	{ id: 900, pos: map_to_world({ x: 365, y: 2295 }), length: 118, base_turn: 0.08, spin: 0.18 },
	{ id: 901, pos: map_to_world({ x: 600, y: 1880 }), length: 104, base_turn: 0.32, spin: -0.16 },
	{ id: 902, pos: map_to_world({ x: 700, y: 1240 }), length: 108, base_turn: 0.16, spin: 0.22 },
]

default_enemies : List(Enemy)
default_enemies = [
	{ id: 920, pos: map_to_world({ x: 705, y: 2260 }), radius: 24, alive: Bool.True },
	{ id: 921, pos: map_to_world({ x: 760, y: 1370 }), radius: 24, alive: Bool.True },
	{ id: 922, pos: map_to_world({ x: 570, y: 820 }), radius: 24, alive: Bool.True },
]

checkpoints_from_tilemap : Tilemap -> List(Physics.Point)
checkpoints_from_tilemap = |tilemap| {
	var $checkpoints = []
	for object in Tilemap.objects_with_role(tilemap, Checkpoint) {
		$checkpoints = List.append($checkpoints, map_to_world(Tilemap.object_world_center(tilemap, object)))
	}
	$checkpoints
}

axis : Bool, Bool -> F32
axis = |negative, positive| if negative -1 else if positive 1 else 0

input_axis : Host -> F32
input_axis = |host| {
	left = Keys.key_down(host.keys, KeyLeft) or Keys.key_down(host.keys, KeyA)
	right = Keys.key_down(host.keys, KeyRight) or Keys.key_down(host.keys, KeyD)
	axis(left, right)
}

physics_distance : Physics.Point, Physics.Point -> F32
physics_distance = |a, b| Physics.distance(a, b)

tick_timer : F32, F32 -> F32
tick_timer = |timer, dt| if timer <= dt 0 else timer - dt

wrap_unit : F32 -> F32
wrap_unit = |value| if value >= 1 value - 1 else if value < 0 value + 1 else value

wrap_turn : F32 -> F32
wrap_turn = |value| if value >= 1 wrap_turn(value - 1) else if value < 0 wrap_turn(value + 1) else value

ping_pong : F32 -> F32
ping_pong = |phase| if phase < 0.5 phase * 2 else (1 - phase) * 2

quarter_wave : F32 -> F32
quarter_wave = |amount| {
	t = Math.clamp01(amount)
	t * (2 - t)
}

sin_turn : F32 -> F32
sin_turn = |turn| {
	t = wrap_turn(turn)
	if t < 0.25 {
		quarter_wave(t * 4)
	} else if t < 0.5 {
		quarter_wave((0.5 - t) * 4)
	} else if t < 0.75 {
		0 - quarter_wave((t - 0.5) * 4)
	} else {
		0 - quarter_wave((1 - t) * 4)
	}
}

cos_turn : F32 -> F32
cos_turn = |turn| sin_turn(turn + 0.25)

unit_from_turn : F32 -> Physics.Vector
unit_from_turn = |turn| Physics.normalize(Physics.vector(cos_turn(turn), sin_turn(turn), 0))

screen_to_map : Camera.Camera2D, Math.Vec2 -> Math.Vec2
screen_to_map = |camera, screen| {
	x: camera.target.x + (screen.x - camera.offset.x) / camera.zoom,
	y: camera.target.y + (screen.y - camera.offset.y) / camera.zoom,
}

tool_input : Host, Camera.Camera2D -> ToolInput
tool_input = |host, camera| {
	aim = map_to_world(screen_to_map(camera, { x: host.mouse.x, y: host.mouse.y }))
	{
		aim,
		laser_down: Mouse.button_down(host.mouse, Left),
		hook_down: Mouse.button_down(host.mouse, Right),
		hook_pressed: Mouse.button_pressed(host.mouse, Right),
	}
}

player_rect_at : Physics.Point -> Math.Rect
player_rect_at = |pos| {
	map_pos = world_to_map(pos)
	Math.rect(map_pos.x - half_player_w, map_pos.y - half_player_h, player_width, player_height)
}

solid_probe : Level, Physics.Point -> Bool
solid_probe = |level, point| Tilemap.solid_at_world(level.tilemap, world_to_map(point))

player_hits_solid : Level, Physics.Point, F32 -> Bool
player_hits_solid = |level, pos, bottom_inset| {
	coords = Physics.coords(pos)
	left = coords.x - half_player_w + 4
	right = coords.x + half_player_w - 4
	top = coords.y + half_player_h - 4
	bottom = coords.y - half_player_h + bottom_inset

	solid_probe(level, Physics.point(left, top, 0))
		or solid_probe(level, Physics.point(right, top, 0))
			or solid_probe(level, Physics.point(left, bottom, 0))
				or solid_probe(level, Physics.point(right, bottom, 0))
}

MoveYResult : {
	pos : Physics.Point,
	velocity_y : F32,
	grounded : Bool,
}

move_x : Level, Physics.Point, F32 -> Physics.Point
move_x = |level, pos, dx| {
	candidate = Physics.add(pos, Physics.vector(dx, 0, 0))
	if player_hits_solid(level, candidate, 2) pos else candidate
}

move_y : Level, Physics.Point, F32, F32 -> MoveYResult
move_y = |level, pos, dy, velocity_y| {
	candidate = Physics.add(pos, Physics.vector(0, dy, 0))
	if player_hits_solid(level, candidate, 0) {
		{ pos, velocity_y: 0, grounded: velocity_y < 0 }
	} else {
		{ pos: candidate, velocity_y, grounded: Bool.False }
	}
}

direction_to : Physics.Point, Physics.Point, F32 -> Physics.Vector
direction_to = |origin, target, fallback_facing| {
	offset = Physics.sub(target, origin)
	if Physics.length(offset) == 0 {
		Physics.normalize(Physics.vector(fallback_facing, 0.18, 0))
	} else {
		Physics.normalize(offset)
	}
}

point_along : Physics.Point, Physics.Vector, F32 -> Physics.Point
point_along = |origin, direction, distance| Physics.add(origin, Physics.scale(direction, distance))

solid_hit_along : Level, Physics.Point, Physics.Vector, F32, F32 -> Try(Physics.Point, [NoHit])
solid_hit_along = |level, origin, direction, max_distance, step| solid_hit_at(level, origin, direction, max_distance, step, step)

solid_hit_at : Level, Physics.Point, Physics.Vector, F32, F32, F32 -> Try(Physics.Point, [NoHit])
solid_hit_at = |level, origin, direction, max_distance, step, distance| {
	if distance >= max_distance {
		end = point_along(origin, direction, max_distance)
		if solid_probe(level, end) Ok(end) else Err(NoHit)
	} else {
		probe = point_along(origin, direction, distance)
		if solid_probe(level, probe) {
			Ok(probe)
		} else {
			solid_hit_at(level, origin, direction, max_distance, step, distance + step)
		}
	}
}

mirror_axis : Mirror, F32 -> Physics.Vector
mirror_axis = |mirror, phase| unit_from_turn(mirror.base_turn + phase * mirror.spin)

mirror_normal : Mirror, F32 -> Physics.Vector
mirror_normal = |mirror, phase| {
	axis_vector = Physics.components(mirror_axis(mirror, phase))
	Physics.normalize(Physics.vector(0 - axis_vector.y, axis_vector.x, 0))
}

mirror_segment : Mirror, F32 -> LaserSegment
mirror_segment = |mirror, phase| {
	axis_vector = mirror_axis(mirror, phase)
	offset = Physics.scale(axis_vector, mirror.length * 0.5)
	{
		start: Physics.add(mirror.pos, Physics.scale(offset, -1)),
		end: Physics.add(mirror.pos, offset),
	}
}

point_segment_distance : Physics.Point, LaserSegment -> F32
point_segment_distance = |point, segment| {
	ab = Physics.sub(segment.end, segment.start)
	len_sq = Physics.length_squared(ab)
	if len_sq == 0 {
		physics_distance(point, segment.start)
	} else {
		t = Math.clamp(Physics.dot(Physics.sub(point, segment.start), ab) / len_sq, 0, 1)
		physics_distance(point, Physics.add(segment.start, Physics.scale(ab, t)))
	}
}

mirror_hit_at : List(Mirror), F32, Physics.Point -> Try(MirrorHit, [NoHit])
mirror_hit_at = |mirrors, phase, point| {
	var $hit = Err(NoHit)
	for mirror in mirrors {
		match $hit {
			Ok(_) => {}
			Err(_) => {
				segment = mirror_segment(mirror, phase)
				if point_segment_distance(point, segment) <= mirror_thickness {
					$hit = Ok({ point, normal: mirror_normal(mirror, phase) })
				}
			}
		}
	}
	$hit
}

enemy_hit_at : List(Enemy), Physics.Point -> Try({ point : Physics.Point, id : U64 }, [NoHit])
enemy_hit_at = |enemies, point| {
	var $hit = Err(NoHit)
	for enemy in enemies {
		match $hit {
			Ok(_) => {}
			Err(_) => if enemy.alive and physics_distance(enemy.pos, point) <= enemy.radius {
				$hit = Ok({ point, id: enemy.id })
			}
		}
	}
	$hit
}

laser_probe_hit : Level, List(Enemy), Player, Physics.Point, F32, Bool -> LaserHit
laser_probe_hit = |level, enemies, player, probe, phase, can_hit_player| {
	if can_hit_player and physics_distance(player.pos, probe) <= laser_player_radius {
		HitPlayer(probe)
	} else {
		match enemy_hit_at(enemies, probe) {
			Ok(hit) => HitEnemy(hit)
			Err(_) =>
				match mirror_hit_at(level.mirrors, phase, probe) {
					Ok(hit) => HitMirror(hit)
					Err(_) => if solid_probe(level, probe) HitSolid(probe) else HitNone(probe)
				}
			}
	}
}

cast_laser : Level, List(Enemy), Player, Physics.Point, Physics.Vector, F32, F32, Bool, F32 -> LaserHit
cast_laser = |level, enemies, player, origin, direction, phase, remaining, can_hit_player, distance| {
	if distance >= remaining {
		HitNone(point_along(origin, direction, remaining))
	} else {
		probe = point_along(origin, direction, distance)
		hit = laser_probe_hit(level, enemies, player, probe, phase, can_hit_player)
		match hit {
			HitNone(_) => cast_laser(level, enemies, player, origin, direction, phase, remaining, can_hit_player, distance + laser_step)
			_ => hit
		}
	}
}

laser_trace_from : Level, List(Enemy), Player, Physics.Point, Physics.Vector, F32, F32, U64, Bool, List(LaserSegment), List(U64), Bool -> LaserTrace
laser_trace_from = |level, enemies, player, origin, direction, phase, remaining, bounces, can_hit_player, segments, killed, hit_player| {
	if remaining <= 0 {
		{ segments, killed, hit_player }
	} else {
		match cast_laser(level, enemies, player, origin, direction, phase, remaining, can_hit_player, laser_step) {
			HitNone(end) => { segments: List.append(segments, { start: origin, end }), killed, hit_player }
			HitSolid(end) => { segments: List.append(segments, { start: origin, end }), killed, hit_player }
			HitEnemy(hit) => { segments: List.append(segments, { start: origin, end: hit.point }), killed: List.append(killed, hit.id), hit_player }
			HitPlayer(end) => { segments: List.append(segments, { start: origin, end }), killed, hit_player: Bool.True }
			HitMirror(hit) => {
				next_segments = List.append(segments, { start: origin, end: hit.point })
				remaining_after_hit = remaining - physics_distance(origin, hit.point)
				reflected = Physics.normalize(Physics.reflect(direction, hit.normal))

				if bounces >= laser_bounce_limit or remaining_after_hit <= laser_reflect_nudge or Physics.length(reflected) == 0 {
					{ segments: next_segments, killed, hit_player }
				} else {
					next_origin = point_along(hit.point, reflected, laser_reflect_nudge)
					laser_trace_from(level, enemies, player, next_origin, reflected, phase, remaining_after_hit - laser_reflect_nudge, bounces + 1, Bool.True, next_segments, killed, hit_player)
				}
			}
		}
	}
}

advance_laser : Level, Player, List(Enemy), ToolInput, F32 -> LaserTrace
advance_laser = |level, player, enemies, input, phase| {
	if input.laser_down {
		direction = direction_to(player.pos, input.aim, player.facing)
		laser_trace_from(level, enemies, player, player.pos, direction, phase, laser_range, 0, Bool.False, [], [], Bool.False)
	} else {
		{ segments: [], killed: [], hit_player: Bool.False }
	}
}

laser_state_from_trace : ToolInput, LaserTrace -> LaserState
laser_state_from_trace = |input, trace| {
	active: input.laser_down,
	segments: trace.segments,
}

kill_laser_enemies : List(Enemy), List(U64) -> List(Enemy)
kill_laser_enemies = |enemies, killed| {
	var $next = []
	for enemy in enemies {
		dead = enemy.alive and List.contains(killed, enemy.id)
		$next = List.append($next, { ..enemy, alive: enemy.alive and !(dead) })
	}
	$next
}

launch_hook : Player, Physics.Point -> HookState
launch_hook = |player, aim| {
	direction = direction_to(player.pos, aim, player.facing)
	HookFlying(
		{
			pos: player.pos,
			velocity: Physics.add_vec(player.velocity, Physics.scale(direction, hook_launch_speed)),
			age: 0,
		},
	)
}

solid_hit_between : Level, Physics.Point, Physics.Point -> Try(Physics.Point, [NoHit])
solid_hit_between = |level, from, to| {
	offset = Physics.sub(to, from)
	distance = Physics.length(offset)
	if distance == 0 {
		if solid_probe(level, to) Ok(to) else Err(NoHit)
	} else {
		solid_hit_along(level, from, Physics.scale(offset, 1 / distance), distance, hook_collision_step)
	}
}

advance_hook_projectile : Level, Player, HookProjectile, F32 -> HookState
advance_hook_projectile = |level, player, hook, dt| {
	accelerated = Physics.apply_acceleration(Physics.body(hook.pos, hook.velocity), Physics.vector(0, gravity, 0), dt)
	next_pos = Physics.add(hook.pos, Physics.scale(accelerated.velocity, dt))
	next_age = hook.age + dt
	too_far = physics_distance(player.pos, next_pos) > hook_max_range
	expired = next_age > hook_max_age

	if too_far or expired {
		HookIdle
	} else {
		match solid_hit_between(level, hook.pos, next_pos) {
			Ok(anchor) => HookLatched({ anchor, rest_length: physics_distance(player.pos, anchor) })
			Err(_) => HookFlying({ pos: next_pos, velocity: accelerated.velocity, age: next_age })
		}
	}
}

advance_hook : Level, Player, HookState, ToolInput, F32 -> HookState
advance_hook = |level, player, hook, input, dt| {
	if !(input.hook_down) {
		HookIdle
	} else {
		match hook {
			HookIdle => if input.hook_pressed launch_hook(player, input.aim) else HookIdle
			HookFlying(projectile) => advance_hook_projectile(level, player, projectile, dt)
			HookLatched(latch) => HookLatched(latch)
		}
	}
}

hook_acceleration : HookState, Player -> Physics.Vector
hook_acceleration = |hook, player| {
	match hook {
		HookLatched(latch) => {
			offset = Physics.sub(latch.anchor, player.pos)
			distance = Physics.length(offset)
			stretch = distance - latch.rest_length
			if distance == 0 or stretch <= 0 {
				Physics.zero
			} else {
				direction = Physics.scale(offset, 1 / distance)
				velocity_along = Physics.dot(player.velocity, direction)
				pull = Math.clamp(stretch * hook_spring_strength - velocity_along * hook_damping, 0, hook_max_acceleration)
				Physics.scale(direction, pull)
			}
		}
		_ => Physics.zero
	}
}

steered_x_velocity : F32, F32, Bool, F32 -> F32
steered_x_velocity = |velocity_x, move_axis, grounded, dt| {
	if move_axis != 0 {
		target = move_axis * move_speed
		rate = if grounded ground_control else air_control
		Math.lerp(velocity_x, target, Math.clamp01(rate * dt))
	} else if grounded {
		Math.lerp(velocity_x, 0, Math.clamp01(ground_friction * dt))
	} else {
		Math.lerp(velocity_x, 0, Math.clamp01(air_drag * dt))
	}
}

CollectResult : {
	gems : List(Gem),
	taken : U64,
}

collect_gems : List(Gem), Physics.Point -> CollectResult
collect_gems = |gems, player_pos| {
	var $next = []
	var $taken = 0
	for gem in gems {
		hit = !(gem.taken) and physics_distance(gem.pos, player_pos) <= gem_radius
		$next = List.append($next, { ..gem, taken: gem.taken or hit })
		if hit {
			$taken = $taken + 1
		}
	}
	{ gems: $next, taken: $taken }
}

checkpoint_hit : List(Physics.Point), Physics.Point -> Try(Physics.Point, [NoCheckpoint])
checkpoint_hit = |checkpoints, player_pos| {
	var $hit = Err(NoCheckpoint)
	for checkpoint in checkpoints {
		if physics_distance(checkpoint, player_pos) <= checkpoint_radius {
			$hit = Ok(checkpoint)
		}
	}
	$hit
}

touches_hazard : List(Danger), Physics.Point -> Bool
touches_hazard = |hazards, player_pos| {
	var $hit = Bool.False
	for hazard in hazards {
		if physics_distance(hazard.pos, player_pos) <= hazard.radius + half_player_w {
			$hit = Bool.True
		}
	}
	$hit
}

goal_reached : Level, World -> Bool
goal_reached = |level, world| {
	world.collected == List.len(level.gems) and physics_distance(world.player.pos, level.goal) <= goal_radius
}

damage_player : World, Physics.Point -> World
damage_player = |world, respawn| {
	next_lives = if world.lives > 0 world.lives - 1 else 0
	{
		..world,
		player: { ..new_player(respawn), invuln: 1.4 },
		lives: next_lives,
		flash: 0.32,
		state: if next_lives == 0 GameOver else Playing,
		laser: inactive_laser,
		hook: HookIdle,
	}
}

advance_player : Level, Player, F32, Bool, Physics.Vector, F32 -> Player
advance_player = |level, player, move_axis, jump_pressed, extra_acceleration, dt| {
	jumping = jump_pressed and player.grounded
	current_velocity = Physics.components(player.velocity)
	extra = Physics.components(extra_acceleration)
	accelerated = Physics.apply_acceleration(Physics.body(player.pos, player.velocity), Physics.vector(extra.x, gravity + extra.y, extra.z), dt)
	accelerated_velocity = Physics.components(accelerated.velocity)
	velocity_y = if jumping jump_velocity else Math.clamp(accelerated_velocity.y, max_fall_speed, jump_velocity)
	velocity_x = steered_x_velocity(accelerated_velocity.x, move_axis, player.grounded, dt)
	after_x = move_x(level, player.pos, velocity_x * dt)
	after_y = move_y(level, after_x, velocity_y * dt, velocity_y)
	moving = move_axis != 0

	{
		..player,
		pos: after_y.pos,
		velocity: Physics.vector(velocity_x, after_y.velocity_y, current_velocity.z),
		grounded: after_y.grounded,
		facing: if moving move_axis else player.facing,
		animation: if moving Sprite.step(player.animation, dt) else player.animation,
		invuln: tick_timer(player.invuln, dt),
	}
}

advance_world : Level, World, F32, Bool, ToolInput, F32 -> World
advance_world = |level, world, move_axis, jump_pressed, input, dt| {
	held_hook = if input.hook_down world.hook else HookIdle
	player = advance_player(level, world.player, move_axis, jump_pressed, hook_acceleration(held_hook, world.player), dt)
	hook = advance_hook(level, player, held_hook, input, dt)
	phase = wrap_unit(world.phase + dt * 0.55)
	laser_trace = advance_laser(level, player, world.enemies, input, phase)
	laser = laser_state_from_trace(input, laser_trace)
	enemies = kill_laser_enemies(world.enemies, laser_trace.killed)
	collect = collect_gems(world.gems, player.pos)
	collected = world.collected + collect.taken
	checkpoint = match checkpoint_hit(level.checkpoints, player.pos) {
		Ok(point) => point
		Err(_) => world.checkpoint
	}
	base = {
		..world,
		player,
		gems: collect.gems,
		enemies,
		collected,
		checkpoint,
		phase,
		flash: tick_timer(world.flash, dt),
		laser,
		hook,
	}

	if goal_reached(level, base) {
		{ ..base, state: Won, laser: inactive_laser, hook: HookIdle }
	} else if player.invuln <= 0 and (laser_trace.hit_player or touches_hazard(level.hazards, player.pos) or (world_to_map(player.pos)).y > Math.bottom(level.bounds) + 96) {
		damage_player(base, checkpoint)
	} else {
		base
	}
}

render! : Model, Host => Try(Model, [Exit(I64), ..])
render! = |model, host| {
	if Keys.key_pressed(host.keys_pressed, KeyEscape) {
		Host.exit!(0)
	}

	restart = Keys.key_pressed(host.keys_pressed, KeySpace)
	input_camera = camera_for(model.level, model.world.player.pos)
	input = tool_input(host, input_camera)
	next_world = match model.world.state {
		Playing => advance_world(
			model.level,
			model.world,
			input_axis(host),
			Keys.key_pressed(host.keys_pressed, KeySpace) or Keys.key_pressed(host.keys_pressed, KeyUp) or Keys.key_pressed(host.keys_pressed, KeyW),
			input,
			host.frame_time,
		)
		Won => if restart new_world(model.level) else model.world
		GameOver => if restart new_world(model.level) else model.world
	}

	next = { ..model, world: next_world }
	camera = camera_for(model.level, next_world.player.pos)

	Draw.draw!(
		Color.from_hex_rgb(0x101820),
		|| {
			Draw.with_camera!(
				camera,
				|| draw_world!(next.level, next.background, next.tiles, next.characters, next.enemies_texture, next.world),
			)
			draw_hud!(next.level, next.world)
		},
	)

	Ok(next)
}

camera_for : Level, Physics.Point -> Camera.Camera2D
camera_for = |level, target| {
	map_target = world_to_map(target)
	zoom = 0.96
	half_w = screen_w * 0.5 / zoom
	half_h = screen_h * 0.5 / zoom
	clamped = {
		x: Math.clamp(map_target.x, half_w, Math.right(level.bounds) - half_w),
		y: Math.clamp(map_target.y, half_h, Math.bottom(level.bounds) - half_h),
	}
	Camera.follow(clamped, { screen: { x: screen_w, y: screen_h }, zoom })
}

draw_world! : Level, Assets.Texture, Assets.Texture, Assets.Texture, Assets.Texture, World => {}
draw_world! = |level, background, tiles, characters, enemies_texture, world| {
	Draw.rectangle_gradient_v!({ x: level.bounds.x, y: level.bounds.y, width: level.bounds.width, height: level.bounds.height, color_top: Color.from_hex_rgb(0x27394a), color_bottom: Color.from_hex_rgb(0x141820) })
	Draw.texture!({ texture: background, source: Assets.rect(background), dest: level.bounds, origin: Math.zero, rotation: 0, tint: Color.with_alpha(Color.white, 130) })
	Tilemap.draw_all!(level.tilemap)
	draw_checkpoints!(tiles, level, world)
	draw_goal!(tiles, level, world)
	draw_gems!(tiles, world.gems, world.phase)
	draw_hazard_marks!(tiles, level.hazards, world.phase)
	draw_mirrors!(level.mirrors, world.phase)
	draw_enemies!(enemies_texture, world.enemies, world.phase)
	draw_tools!(world)
	draw_player!(characters, world.player)
}

gem_source : Math.Rect
gem_source = Math.rect(896, 320, 64, 64)

saw_source : Math.Rect
saw_source = Math.rect(640, 896, 64, 64)

goal_source : Math.Rect
goal_source = Math.rect(896, 768, 64, 64)

checkpoint_source : Math.Rect
checkpoint_source = Math.rect(896, 448, 64, 64)

enemy_fly_a_source : Math.Rect
enemy_fly_a_source = Math.rect(320, 256, 64, 64)

enemy_fly_b_source : Math.Rect
enemy_fly_b_source = Math.rect(320, 192, 64, 64)

player_idle_source : Math.Rect
player_idle_source = Math.rect(384, 768, 128, 128)

player_jump_source : Math.Rect
player_jump_source = Math.rect(384, 640, 128, 128)

player_walk_a_source : Math.Rect
player_walk_a_source = Math.rect(384, 512, 128, 128)

player_walk_b_source : Math.Rect
player_walk_b_source = Math.rect(384, 384, 128, 128)

draw_tile_sprite! : Assets.Texture, Math.Rect, Math.Vec2, F32, F32 => {}
draw_tile_sprite! = |texture, source, pos, scale, rotation|
	Sprite.from_texture(texture)
		.source(
			source,
		)
		.pos(
			pos,
		)
		.scale(
			scale,
		)
		.centered()
		.rotation(
			rotation,
		)
		.draw!()

draw_gems! : Assets.Texture, List(Gem), F32 => {}
draw_gems! = |tiles, gems, phase| {
	for gem in gems {
		if !(gem.taken) {
			pos = world_to_map(gem.pos)
			pulse = 0.86 + ping_pong(wrap_unit(phase + U64.to_f32(gem.id) * 0.07)) * 0.12
			Draw.circle_gradient!({ center: pos, radius: 42 * pulse, color_inner: Color.with_alpha(Color.from_hex_rgb(0x55c7ff), 80), color_outer: Color.with_alpha(Color.from_hex_rgb(0x55c7ff), 0) })
			draw_tile_sprite!(tiles, gem_source, pos, 0.72 * pulse, phase * 60)
		}
	}
}

draw_hazard_marks! : Assets.Texture, List(Danger), F32 => {}
draw_hazard_marks! = |tiles, hazards, phase| {
	for hazard in hazards {
		pos = world_to_map(hazard.pos)
		Draw.circle_gradient!({ center: pos, radius: hazard.radius * 1.8, color_inner: Color.with_alpha(Color.from_hex_rgb(0xf94144), 60), color_outer: Color.with_alpha(Color.from_hex_rgb(0xf94144), 0) })
		draw_tile_sprite!(tiles, saw_source, pos, 0.78, phase * 260)
	}
}

draw_checkpoints! : Assets.Texture, Level, World => {}
draw_checkpoints! = |tiles, level, world| {
	for checkpoint in level.checkpoints {
		checkpoint_pos = world_to_map(checkpoint)
		reached = checkpoint_pos.y >= (world_to_map(world.checkpoint)).y
		tint = if reached Color.white else Color.with_alpha(Color.white, 120)
		sprite = Sprite.from_texture(tiles)
			.source(
				checkpoint_source,
			)
			.pos(
				checkpoint_pos,
			)
			.scale(
				0.74,
			)
			.centered()
			.tint(
				tint,
			)
		sprite.draw!()
	}
}

draw_goal! : Assets.Texture, Level, World => {}
draw_goal! = |tiles, level, world| {
	ready = world.collected == List.len(level.gems)
	pos = world_to_map(level.goal)
	color = if ready Color.from_hex_rgb(0x90be6d) else Color.from_hex_rgb(0xadb5bd)
	Draw.circle_gradient!({ center: pos, radius: if ready 86 else 54, color_inner: Color.with_alpha(color, 95), color_outer: Color.with_alpha(color, 0) })
	draw_tile_sprite!(tiles, goal_source, pos, if ready 1.0 else 0.82, 0)
}

draw_mirrors! : List(Mirror), F32 => {}
draw_mirrors! = |mirrors, phase| {
	for mirror in mirrors {
		segment = mirror_segment(mirror, phase)
		start = world_to_map(segment.start)
		end = world_to_map(segment.end)
		center = world_to_map(mirror.pos)
		glass = Color.from_hex_rgb(0xbaf2ff)
		edge = Color.from_hex_rgb(0x3a506b)
		Draw.line!({ start, end, stroke: Draw.stroke(Color.with_alpha(edge, 235), 15) })
		Draw.line!({ start, end, stroke: Draw.stroke(Color.with_alpha(glass, 245), 8) })
		Draw.line!({ start, end, stroke: Draw.stroke(Color.white, 2) })
		Draw.circle!({ center: start, radius: 6, style: Draw.filled(edge) })
		Draw.circle!({ center: end, radius: 6, style: Draw.filled(edge) })
		Draw.circle!({ center, radius: 5, style: Draw.filled(Color.with_alpha(Color.white, 230)) })
	}
}

enemy_source : Enemy, F32 -> Math.Rect
enemy_source = |enemy, phase| {
	flutter = wrap_unit(phase * 2 + U64.to_f32(enemy.id) * 0.11)
	if flutter < 0.5 enemy_fly_a_source else enemy_fly_b_source
}

draw_enemies! : Assets.Texture, List(Enemy), F32 => {}
draw_enemies! = |texture, enemies, phase| {
	for enemy in enemies {
		if enemy.alive {
			pos = world_to_map(enemy.pos)
			pulse = 0.9 + ping_pong(wrap_unit(phase + U64.to_f32(enemy.id) * 0.09)) * 0.08
			Draw.circle!({ center: pos, radius: enemy.radius + 3, style: Draw.outlined(Color.with_alpha(Color.from_hex_rgb(0xffba08), 150), 2) })
			draw_tile_sprite!(texture, enemy_source(enemy, phase), pos, 0.72 * pulse, 0)
		}
	}
}

draw_tools! : World => {}
draw_tools! = |world| {
	draw_laser!(world.laser)
	draw_hook!(world.player, world.hook)
}

draw_laser! : LaserState => {}
draw_laser! = |laser| {
	if laser.active {
		laser_color = Color.from_hex_rgb(0x72f7ff)
		for segment in laser.segments {
			start = world_to_map(segment.start)
			end = world_to_map(segment.end)
			Draw.line!({ start, end, stroke: Draw.stroke(Color.with_alpha(laser_color, 85), 8) })
			Draw.line!({ start, end, stroke: Draw.stroke(Color.white, 2) })
			Draw.circle_gradient!({ center: end, radius: 18, color_inner: Color.with_alpha(laser_color, 160), color_outer: Color.with_alpha(laser_color, 0) })
		}
	}
}

draw_hook! : Player, HookState => {}
draw_hook! = |player, hook| {
	start = world_to_map(player.pos)
	match hook {
		HookIdle => {}
		HookFlying(projectile) => {
			end = world_to_map(projectile.pos)
			cord = Color.from_hex_rgb(0xd7dee8)
			hook_color = Color.from_hex_rgb(0xffc857)
			Draw.line!({ start, end, stroke: Draw.stroke(Color.with_alpha(cord, 190), 2) })
			Draw.circle!({ center: end, radius: 7, style: Draw.filled(hook_color) })
			Draw.circle!({ center: end, radius: 10, style: Draw.outlined(Color.with_alpha(hook_color, 135), 2) })
		}
		HookLatched(latch) => {
			end = world_to_map(latch.anchor)
			cord = Color.from_hex_rgb(0xd7dee8)
			anchor_color = Color.from_hex_rgb(0xf9c74f)
			Draw.line!({ start, end, stroke: Draw.stroke(Color.with_alpha(Color.black, 120), 5) })
			Draw.line!({ start, end, stroke: Draw.stroke(cord, 3) })
			Draw.circle_gradient!({ center: end, radius: 20, color_inner: Color.with_alpha(anchor_color, 150), color_outer: Color.with_alpha(anchor_color, 0) })
			Draw.circle!({ center: end, radius: 6, style: Draw.filled(anchor_color) })
		}
	}
}

player_source : Player -> Math.Rect
player_source = |player| {
	velocity = Physics.components(player.velocity)
	if !(player.grounded) {
		player_jump_source
	} else if F32.abs(velocity.x) > 8 {
		if player.animation.frame % 2 == 0 player_walk_a_source else player_walk_b_source
	} else {
		player_idle_source
	}
}

draw_player! : Assets.Texture, Player => {}
draw_player! = |characters, player| {
	tint = if player.invuln > 0 Color.with_alpha(Color.white, 145) else Color.white
	pos = world_to_map(player.pos)
	Sprite.from_texture(characters)
		.source(
			player_source(player),
		)
		.pos(
			pos,
		)
		.scale(
			0.58,
		)
		.centered()
		.tint(
			tint,
		)
		.draw!()
	Draw.rectangle!({ x: pos.x - half_player_w, y: pos.y - half_player_h, width: player_width, height: player_height, style: Draw.outlined(Color.with_alpha(Color.white, 90), 2) })
}

draw_hud! : Level, World => {}
draw_hud! = |level, world| {
	Draw.rectangle_gradient_v!({ x: 0, y: 0, width: screen_w, height: 76, color_top: Color.with_alpha(Color.black, 220), color_bottom: Color.with_alpha(Color.black, 110) })
	Draw.text!({ pos: { x: 22, y: 16 }, text: "Cave Climb", size: 27, spacing: Draw.default_spacing, color: Color.white, font: Draw.default_font, align: Draw.align_top_left })
	Draw.text!({ pos: { x: 220, y: 18 }, text: Str.concat("Gems ", Str.concat(U64.to_str(world.collected), Str.concat("/", U64.to_str(List.len(level.gems))))), size: 20, spacing: Draw.default_spacing, color: Color.from_hex_rgb(0x55c7ff), font: Draw.default_font, align: Draw.align_top_left })
	Draw.text!({ pos: { x: 380, y: 18 }, text: Str.concat("Lives ", U64.to_str(world.lives)), size: 20, spacing: Draw.default_spacing, color: Color.light_gray, font: Draw.default_font, align: Draw.align_top_left })
	Draw.text!({ pos: { x: 505, y: 18 }, text: if world.collected == List.len(level.gems) "Goal open" else "Collect every gem", size: 20, spacing: Draw.default_spacing, color: if world.collected == List.len(level.gems) Color.from_hex_rgb(0x90be6d) else Color.light_gray, font: Draw.default_font, align: Draw.align_top_left })
	Draw.fps!({ pos: { x: 735, y: 20 }, size: 18, color: Color.gray })

	if world.flash > 0 {
		Draw.rectangle!({ x: 0, y: 0, width: screen_w, height: screen_h, style: Draw.filled(Color.with_alpha(Color.red, 80)) })
	}

	match world.state {
		Playing => {}
		Won => draw_modal!("Summit reached", "Press SPACE to climb again", Color.from_hex_rgb(0x90be6d))
		GameOver => draw_modal!("Climb failed", "Press SPACE to restart", Color.from_hex_rgb(0xf94144))
	}
}

draw_modal! : Str, Str, Color => {}
draw_modal! = |title, subtitle, accent| {
	Draw.rectangle!({ x: 0, y: 0, width: screen_w, height: screen_h, style: Draw.filled(Color.with_alpha(Color.black, 125)) })
	Draw.rounded_rectangle!({ x: 182, y: 226, width: 436, height: 152, radius: 8, segments: 8, style: Draw.filled_and_outlined(Color.with_alpha(Color.black, 232), accent, 4) })
	Draw.text_centered!({ pos: { x: screen_w * 0.5, y: 276 }, text: title, size: 30, color: Color.white })
	Draw.text_centered!({ pos: { x: screen_w * 0.5, y: 326 }, text: subtitle, size: 21, color: Color.light_gray })
}

expect physics_distance(Physics.point_xy(0, 0), Physics.point_xy(3, 4)) == 5
expect world_to_map(map_to_world({ x: 10, y: 20 })) == { x: 10, y: 20 }
expect player_rect_at(map_to_world({ x: 10, y: 20 })) == Math.rect(-11, -9, player_width, player_height)
expect tick_timer(0.1, 0.2) == 0
expect F32.abs(wrap_unit(1.2) - 0.2) < 0.0001
expect screen_to_map(Camera.follow({ x: 100, y: 200 }, { screen: { x: screen_w, y: screen_h }, zoom: 2 }), { x: screen_w * 0.5, y: screen_h * 0.5 }) == { x: 100, y: 200 }
expect Physics.components(direction_to(Physics.point_xy(0, 0), Physics.point_xy(3, 4), 1)) == { x: 0.6, y: 0.8, z: 0 }
expect steered_x_velocity(0, 1, Bool.True, 1) == move_speed
expect steered_x_velocity(20, 0, Bool.True, 1) == 0
expect wrap_turn(1.25) == 0.25
expect Physics.components(unit_from_turn(0)) == { x: 1, y: 0, z: 0 }
expect point_segment_distance(Physics.point_xy(5, 3), { start: Physics.point_xy(0, 0), end: Physics.point_xy(10, 0) }) == 3
expect match List.first(kill_laser_enemies([{ id: 1, pos: Physics.origin, radius: 4, alive: Bool.True }], [1])) {
	Ok(enemy) => !(enemy.alive)
	Err(_) => Bool.False
}
