## The only place the slice knows RocRay's immediate 3D API spelling. Gameplay
## produces a world; this adapter turns it into a camera and one borrowed batch.
import rr.Camera
import rr.Color
import rr.Draw
import rr.Math
import Game

Renderer := [].{
	Geometry : { vertices : List(Draw.TexturedVertex3D), indices : List(U32) }

	build_room : Geometry
	build_room = {
		floor = quad_region(
			{ x: 0, y: 0, z: 0 },
			{ x: 14, y: 0, z: 0 },
			{ x: 14, y: 0, z: 11 },
			{ x: 0, y: 0, z: 11 },
			Color.from_hex_rgb(0x777064),
			floor_uv,
		)
		ceiling = quad_region(
			{ x: 0, y: 2.8, z: 11 },
			{ x: 14, y: 2.8, z: 11 },
			{ x: 14, y: 2.8, z: 0 },
			{ x: 0, y: 2.8, z: 0 },
			Color.from_hex_rgb(0x504b48),
			ceiling_uv,
		)
		wall_vertices = List.join_map(Game.walls, wall_box)
		vertices = List.concat(List.concat(floor, ceiling), wall_vertices)
		{ vertices, indices: sequential_indices(vertices) }
	}

	draw_world! : Draw.Frame, Draw.Texture, Geometry, Game.World => Try({}, [ScopeLimit, ..])
	draw_world! = |frame, atlas, room, world| {
		player = world.player
		forward = { x: F32.cos(player.yaw), z: F32.sin(player.yaw) }
		camera = Camera.perspective({
			position: { x: player.pos.x, y: eye_height, z: player.pos.y },
			target: { x: player.pos.x + forward.x, y: eye_height, z: player.pos.y + forward.z },
			up: { x: 0, y: 1, z: 0 },
			fovy: 72,
		})

		dynamic = List.concat(
			if world.enemy.alive() enemy_billboard(world.enemy.pos, player.pos) else [],
			if world.pickup.taken [] else pickup_billboard(world.pickup.pos, player.pos),
		)
		vertices = List.concat(room.vertices, dynamic)
		frame.with_camera_3d!(
			camera,
			|scene| {
				scene.textured_triangles_3d!({ texture: atlas, vertices, indices: sequential_indices(vertices) })
				Ok({})
			},
		)
	}

	wall_box : Math.Rect -> List(Draw.TexturedVertex3D)
	wall_box = |wall| {
		x0 = wall.x
		x1 = wall.x + wall.width
		z0 = wall.y
		z1 = wall.y + wall.height
		shade = Color.from_hex_rgb(0x9a7860)
		List.concat(
			List.concat(
				quad({ x: x0, y: 0, z: z0 }, { x: x1, y: 0, z: z0 }, { x: x1, y: wall_height, z: z0 }, { x: x0, y: wall_height, z: z0 }, shade),
				quad({ x: x1, y: 0, z: z1 }, { x: x0, y: 0, z: z1 }, { x: x0, y: wall_height, z: z1 }, { x: x1, y: wall_height, z: z1 }, shade),
			),
			List.concat(
				quad({ x: x0, y: 0, z: z1 }, { x: x0, y: 0, z: z0 }, { x: x0, y: wall_height, z: z0 }, { x: x0, y: wall_height, z: z1 }, Color.from_hex_rgb(0x765b4d)),
				quad({ x: x1, y: 0, z: z0 }, { x: x1, y: 0, z: z1 }, { x: x1, y: wall_height, z: z1 }, { x: x1, y: wall_height, z: z0 }, Color.from_hex_rgb(0x765b4d)),
			),
		)
	}

	enemy_billboard : Math.Vec2, Math.Vec2 -> List(Draw.TexturedVertex3D)
	enemy_billboard = |pos, viewer| billboard(pos, viewer, 1.35, 1.85, Color.white, enemy_uv)

	pickup_billboard : Math.Vec2, Math.Vec2 -> List(Draw.TexturedVertex3D)
	pickup_billboard = |pos, viewer| billboard(pos, viewer, 0.6, 0.7, Color.from_hex_rgb(0x6de1ff), ammo_uv)

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

	quad : Math.Vec3, Math.Vec3, Math.Vec3, Math.Vec3, Color.Rgba -> List(Draw.TexturedVertex3D)
	quad = |a, b, c, d, tint| quad_region(a, b, c, d, tint, wall_uv)

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
	wall_uv = atlas_uv(2, 2, 128, 128)
	floor_uv : Uv
	floor_uv = atlas_uv(524, 2, 64, 64)
	ceiling_uv : Uv
	ceiling_uv = atlas_uv(590, 2, 64, 64)
	enemy_uv : Uv
	enemy_uv = atlas_uv(656, 2, 41, 57)
	ammo_uv : Uv
	ammo_uv = atlas_uv(532, 132, 17, 16)

	atlas_uv : F32, F32, F32, F32 -> Uv
	atlas_uv = |x, y, width, height| {
		left: x / 1024,
		top: y / 512,
		right: (x + width) / 1024,
		bottom: (y + height) / 512,
	}
}
