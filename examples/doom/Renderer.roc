## The only place the slice knows RocRay's immediate 3D API spelling. Gameplay
## produces a world; this adapter turns it into a camera and one borrowed batch.
import rr.Camera
import rr.Color
import rr.Draw
import rr.Math
import Game
import "assets/freedoom/generated/atlas.json" as atlas_json : Str

AtlasSprite : {
	x : U64,
	y : U64,
	width : U64,
	height : U64,
	source : Str,
	source_sha256 : Str,
}

AtlasMetadata : {
	width : U64,
	height : U64,
	sprites : {
		wall_concrete : AtlasSprite,
		door : AtlasSprite,
		door_locked : AtlasSprite,
		exit_sign : AtlasSprite,
		floor : AtlasSprite,
		ceiling : AtlasSprite,
		enemy_walk_0 : AtlasSprite,
		enemy_walk_1 : AtlasSprite,
		enemy_attack_0 : AtlasSprite,
		enemy_attack_1 : AtlasSprite,
		enemy_die_4 : AtlasSprite,
		ammo : AtlasSprite,
		health : AtlasSprite,
		key_blue_a : AtlasSprite,
		pistol_0 : AtlasSprite,
		pistol_2 : AtlasSprite,
		hud_bar : AtlasSprite,
	},
}

## Importing and decoding at the top level makes the generated manifest part of
## the program. Its JSON and the fields this renderer depends on are validated
## while the app is built, with no runtime filesystem lookup or parser state.
atlas_metadata : AtlasMetadata
atlas_metadata = decode_atlas(atlas_json)

decode_atlas : Str -> AtlasMetadata
decode_atlas = |json|
	match Json.parse(json) {
		Ok(metadata) => metadata
		Err(_) => crash "Freedoom generated/atlas.json is malformed or its schema changed"
	}

Renderer := [].{
	Geometry : { vertices : List(Draw.TexturedVertex3D), indices : List(U32) }

	hud_bar_source : Math.Rect
	hud_bar_source = source_rect(atlas_metadata.sprites.hud_bar)

	pistol_source : Bool -> Math.Rect
	pistol_source = |firing|
		if firing source_rect(atlas_metadata.sprites.pistol_2) else source_rect(atlas_metadata.sprites.pistol_0)

	build_room : Geometry
	build_room = {
		floor = quad_region(
			{ x: 0, y: 0, z: 0 },
			{ x: 24, y: 0, z: 0 },
			{ x: 24, y: 0, z: 16 },
			{ x: 0, y: 0, z: 16 },
			Color.from_hex_rgb(0x777064),
			floor_uv,
		)
		ceiling = quad_region(
			{ x: 0, y: 2.8, z: 16 },
			{ x: 24, y: 2.8, z: 16 },
			{ x: 24, y: 2.8, z: 0 },
			{ x: 0, y: 2.8, z: 0 },
			Color.from_hex_rgb(0x504b48),
			ceiling_uv,
		)
		wall_vertices = List.join_map(Game.walls, wall_box)
		vertices = List.concat(List.concat(List.concat(floor, ceiling), wall_vertices), exit_sign_geometry)
		{ vertices, indices: sequential_indices(vertices) }
	}

	draw_world! : Draw.Frame, Draw.Texture, Draw.Shader, Geometry, Game.World => Try({}, [ScopeLimit, ScopeUnavailable, ..])
	draw_world! = |frame, atlas, sprite_shader, room, world| {
		player = world.player
		forward = { x: F32.cos(player.yaw), z: F32.sin(player.yaw) }
		camera = Camera.perspective({
			position: { x: player.pos.x, y: eye_height, z: player.pos.y },
			target: { x: player.pos.x + forward.x, y: eye_height, z: player.pos.y + forward.z },
			up: { x: 0, y: 1, z: 0 },
			fovy: 72,
		})

		enemy_vertices = List.join_map(world.enemies, |enemy| enemy_billboard(enemy, player.pos, world.elapsed))
		pickup_vertices = List.join_map(world.pickups, |pickup| if pickup.taken [] else pickup_billboard(pickup, player.pos))
		dynamic_vertices = List.concat(enemy_vertices, pickup_vertices)
		door_vertices = if world.door.open [] else door_geometry(world.door, world.player.has_blue_key)
		frame.with_camera_3d!(
			camera,
			|scene| {
				# Retained level geometry crosses directly. Only the small door and
				# billboard batches are rebuilt as application state changes.
				scene.textured_triangles_3d!({ texture: atlas, vertices: room.vertices, indices: room.indices })
				scene.textured_triangles_3d!({ texture: atlas, vertices: door_vertices, indices: sequential_indices(door_vertices) })
				scene.with_shader!(
					sprite_shader,
					|sprites| {
						sprites.textured_triangles_3d!({ texture: atlas, vertices: dynamic_vertices, indices: sequential_indices(dynamic_vertices) })
						Ok({})
					},
				)?
				Ok({})
			},
		)
	}

	wall_box : Math.Rect -> List(Draw.TexturedVertex3D)
	wall_box = |wall| wall_box_with_uv(wall, wall_uv)

	wall_box_with_uv : Math.Rect, Uv -> List(Draw.TexturedVertex3D)
	wall_box_with_uv = |wall, uv| {
		x0 = wall.x
		x1 = wall.x + wall.width
		z0 = wall.y
		z1 = wall.y + wall.height
		shade = Color.from_hex_rgb(0x9a7860)
		List.concat(
			List.concat(
				quad_region({ x: x0, y: 0, z: z0 }, { x: x1, y: 0, z: z0 }, { x: x1, y: wall_height, z: z0 }, { x: x0, y: wall_height, z: z0 }, shade, uv),
				quad_region({ x: x1, y: 0, z: z1 }, { x: x0, y: 0, z: z1 }, { x: x0, y: wall_height, z: z1 }, { x: x1, y: wall_height, z: z1 }, shade, uv),
			),
			List.concat(
				quad_region({ x: x0, y: 0, z: z1 }, { x: x0, y: 0, z: z0 }, { x: x0, y: wall_height, z: z0 }, { x: x0, y: wall_height, z: z1 }, Color.from_hex_rgb(0x765b4d), uv),
				quad_region({ x: x1, y: 0, z: z0 }, { x: x1, y: 0, z: z1 }, { x: x1, y: wall_height, z: z1 }, { x: x1, y: wall_height, z: z0 }, Color.from_hex_rgb(0x765b4d), uv),
			),
		)
	}

	door_geometry : Game.Door, Bool -> List(Draw.TexturedVertex3D)
	door_geometry = |door, has_key| wall_box_with_uv(door.rect, if door.requires_key and !has_key door_locked_uv else door_uv)

	exit_sign_geometry : List(Draw.TexturedVertex3D)
	exit_sign_geometry = quad_region(
		{ x: 22.98, y: 1.45, z: 14.15 },
		{ x: 22.98, y: 1.45, z: 12.35 },
		{ x: 22.98, y: 2.35, z: 12.35 },
		{ x: 22.98, y: 2.35, z: 14.15 },
		Color.white,
		exit_uv,
	)

	enemy_billboard : Game.Enemy, Math.Vec2, F32 -> List(Draw.TexturedVertex3D)
	enemy_billboard = |enemy, viewer, elapsed|
		if enemy.alive() {
			billboard(enemy.pos, viewer, 1.35, 1.85, Color.white, enemy_uv(enemy, elapsed))
		} else {
			billboard(enemy.pos, viewer, 1.45, 0.6, Color.white, enemy_uv(enemy, elapsed))
		}

	pickup_billboard : Game.Pickup, Math.Vec2 -> List(Draw.TexturedVertex3D)
	pickup_billboard = |pickup, viewer| {
		config = match pickup.kind {
			Ammo => { width: 0.6, height: 0.7, uv: ammo_uv }
			Health => { width: 0.75, height: 0.65, uv: health_uv }
			BlueKey => { width: 0.5, height: 0.75, uv: blue_key_uv }
		}
		billboard(pickup.pos, viewer, config.width, config.height, Color.white, config.uv)
	}

	billboard : Math.Vec2, Math.Vec2, F32, F32, Color.Rgba, Uv -> List(Draw.TexturedVertex3D)
	billboard = |pos, viewer, width, height, tint, uv| {
		to_viewer = Math.normalize(Math.sub(viewer, pos))
		right = { x: 0 - to_viewer.y, y: to_viewer.x }
		half = Math.scale(right, width * 0.5)
		quad_region(
			{ x: pos.x - half.x, y: 0, z: pos.y - half.y },
			{ x: pos.x + half.x, y: 0, z: pos.y + half.y },
			{ x: pos.x + half.x, y: height, z: pos.y + half.y },
			{ x: pos.x - half.x, y: height, z: pos.y - half.y },
			tint,
			uv,
		)
	}

	Uv : { left : F32, top : F32, right : F32, bottom : F32 }

	quad_region : Math.Vec3, Math.Vec3, Math.Vec3, Math.Vec3, Color.Rgba, Uv -> List(Draw.TexturedVertex3D)
	quad_region = |a, b, c, d, tint, uv| [
		{ position: a, uv: { x: uv.left, y: uv.bottom }, tint },
		{ position: b, uv: { x: uv.right, y: uv.bottom }, tint },
		{ position: c, uv: { x: uv.right, y: uv.top }, tint },
		{ position: a, uv: { x: uv.left, y: uv.bottom }, tint },
		{ position: c, uv: { x: uv.right, y: uv.top }, tint },
		{ position: d, uv: { x: uv.left, y: uv.top }, tint },
	]

	sequential_indices : List(a) -> List(U32)
	sequential_indices = |vertices| List.map_with_index(vertices, |_vertex, index| U64.to_u32_wrap(index))

	eye_height = 1.55
	wall_height = 2.8

	# Stable names in generated/atlas.json are deliberately mapped here rather
	# than leaking asset-pipeline coordinates through gameplay or drawing code.
	wall_uv : Uv
	wall_uv = atlas_uv(atlas_metadata.sprites.wall_concrete)
	floor_uv : Uv
	floor_uv = atlas_uv(atlas_metadata.sprites.floor)
	ceiling_uv : Uv
	ceiling_uv = atlas_uv(atlas_metadata.sprites.ceiling)
	enemy_uv : Game.Enemy, F32 -> Uv
	enemy_uv = |enemy, elapsed|
		if !(enemy.alive()) {
			atlas_uv(atlas_metadata.sprites.enemy_die_4)
		} else if enemy.cooldown > 0.62 {
			if F32.sin(elapsed * 18) >= 0 atlas_uv(atlas_metadata.sprites.enemy_attack_0) else atlas_uv(atlas_metadata.sprites.enemy_attack_1)
		} else if F32.sin(elapsed * 8 + U64.to_f32(enemy.id)) >= 0 {
			atlas_uv(atlas_metadata.sprites.enemy_walk_0)
		} else {
			atlas_uv(atlas_metadata.sprites.enemy_walk_1)
		}
	ammo_uv : Uv
	ammo_uv = atlas_uv(atlas_metadata.sprites.ammo)
	health_uv : Uv
	health_uv = atlas_uv(atlas_metadata.sprites.health)
	blue_key_uv : Uv
	blue_key_uv = atlas_uv(atlas_metadata.sprites.key_blue_a)
	door_uv : Uv
	door_uv = atlas_uv(atlas_metadata.sprites.door)
	door_locked_uv : Uv
	door_locked_uv = atlas_uv(atlas_metadata.sprites.door_locked)
	exit_uv : Uv
	exit_uv = atlas_uv(atlas_metadata.sprites.exit_sign)

	atlas_uv : AtlasSprite -> Uv
	atlas_uv = |sprite| {
		x = U64.to_f32(sprite.x)
		y = U64.to_f32(sprite.y)
		width = U64.to_f32(sprite.width)
		height = U64.to_f32(sprite.height)
		atlas_width = U64.to_f32(atlas_metadata.width)
		atlas_height = U64.to_f32(atlas_metadata.height)
		{
			left: (x + 0.5) / atlas_width,
			top: (y + 0.5) / atlas_height,
			right: (x + width - 0.5) / atlas_width,
			bottom: (y + height - 0.5) / atlas_height,
		}
	}

	source_rect : AtlasSprite -> Math.Rect
	source_rect = |sprite|
		Math.rect(U64.to_f32(sprite.x), U64.to_f32(sprite.y), U64.to_f32(sprite.width), U64.to_f32(sprite.height))
}
