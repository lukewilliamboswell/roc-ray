app [Model, program] { rr: platform "../platform/main.roc" }

import rr.App
import rr.Assets
import rr.Camera
import rr.Color
import rr.Draw
import rr.Host
import rr.Keys
import rr.Math
import rr.Physics
import rr.Sprite
import rr.Tilemap

GameState := [Playing, Won, GameOver]

Gem : {
	id : U64,
	pos : Physics.Point,
	taken : Bool,
}

Danger : {
	pos : Physics.Point,
	radius : F32,
}

Level : {
	tilemap : Tilemap,
	spawn : Physics.Point,
	goal : Physics.Point,
	gems : List(Gem),
	hazards : List(Danger),
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
	checkpoint : Physics.Point,
	lives : U64,
	state : GameState,
	phase : F32,
	flash : F32,
}

Model : {
	tiles : Assets.Texture,
	characters : Assets.Texture,
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
										Ok({ tiles, characters, background, level, world: new_world(level) })
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

new_world : Level -> World
new_world = |level| {
	player: new_player(level.spawn),
	gems: level.gems,
	collected: 0,
	checkpoint: level.spawn,
	lives: 3,
	state: Playing,
	phase: 0,
	flash: 0,
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

ping_pong : F32 -> F32
ping_pong = |phase| if phase < 0.5 phase * 2 else (1 - phase) * 2

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
	}
}

advance_player : Level, Player, F32, Bool, F32 -> Player
advance_player = |level, player, move_axis, jump_pressed, dt| {
	jumping = jump_pressed and player.grounded
	current_velocity = Physics.components(player.velocity)
	accelerated = Physics.apply_acceleration(Physics.body(player.pos, player.velocity), Physics.vector(0, gravity, 0), dt)
	velocity_y = if jumping jump_velocity else (Physics.components(Physics.clamp_y(accelerated.velocity, max_fall_speed, jump_velocity))).y
	velocity_x = move_axis * move_speed
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

advance_world : Level, World, F32, Bool, F32 -> World
advance_world = |level, world, move_axis, jump_pressed, dt| {
	player = advance_player(level, world.player, move_axis, jump_pressed, dt)
	collect = collect_gems(world.gems, player.pos)
	collected = world.collected + collect.taken
	checkpoint = match checkpoint_hit(level.checkpoints, player.pos) {
		Ok(point) => point
		Err(_) => world.checkpoint
	}
	phase = wrap_unit(world.phase + dt * 0.55)
	base = {
		..world,
		player,
		gems: collect.gems,
		collected,
		checkpoint,
		phase,
		flash: tick_timer(world.flash, dt),
	}

	if goal_reached(level, base) {
		{ ..base, state: Won }
	} else if player.invuln <= 0 and (touches_hazard(level.hazards, player.pos) or (world_to_map(player.pos)).y > Math.bottom(level.bounds) + 96) {
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
	next_world = match model.world.state {
		Playing => advance_world(
			model.level,
			model.world,
			input_axis(host),
			Keys.key_pressed(host.keys_pressed, KeySpace) or Keys.key_pressed(host.keys_pressed, KeyUp) or Keys.key_pressed(host.keys_pressed, KeyW),
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
				|| draw_world!(next.level, next.background, next.tiles, next.characters, next.world),
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

draw_world! : Level, Assets.Texture, Assets.Texture, Assets.Texture, World => {}
draw_world! = |level, background, tiles, characters, world| {
	Draw.rectangle_gradient_v!({ x: level.bounds.x, y: level.bounds.y, width: level.bounds.width, height: level.bounds.height, color_top: Color.from_hex_rgb(0x27394a), color_bottom: Color.from_hex_rgb(0x141820) })
	Draw.texture!({ texture: background, source: Assets.rect(background), dest: level.bounds, origin: Math.zero, rotation: 0, tint: Color.with_alpha(Color.white, 130) })
	Tilemap.draw_all!(level.tilemap)
	draw_checkpoints!(tiles, level, world)
	draw_goal!(tiles, level, world)
	draw_gems!(tiles, world.gems, world.phase)
	draw_hazard_marks!(tiles, level.hazards, world.phase)
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

player_source : Player -> Math.Rect
player_source = |player| {
	velocity = Physics.components(player.velocity)
	if !(player.grounded) {
		player_jump_source
	} else if velocity.x != 0 {
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
