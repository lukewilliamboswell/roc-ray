## Navigable Freedoom E1M1 rendered from its real Doom map lumps. The app owns
## player simulation and map policy in Roc; the host retains textures and draws
## bounded borrowed triangle batches derived by E1M1Renderer.
app [Model, program] {
	rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst",
	roc: "nightly-2026-08-23-fb208ba",
}

import rr.App
import rr.Assets
import rr.Camera
import rr.Color
import rr.Draw
import DoomLevel
import DoomMap
import DoomRuntime
import DoomSim
import DoomSprites
import DoomWorld
import E1M1Renderer
import "sprite_cutout.fs" as sprite_fragment_shader : Str

RenderGeometry : {
	vertices : List({ position : { x : F32, y : F32, z : F32 }, uv : { x : F32, y : F32 }, tint : Color.Rgba }),
	indices : List(U32),
}

Model : {
	world : DoomWorld.World,
	level : DoomLevel.State,
	blockers : List(DoomSim.Segment),
	batches : List(RenderGeometry),
	world_atlas : Draw.Texture,
	sprite_atlas : Draw.Texture,
	sprite_shader : Draw.Shader,
}

Msg : []

program = { init!, update!, render! }

init! : App.Init(Model, _)
init! = App.init(
	App.default
		.with_title("RocRay: Freedoom E1M1")
		.with_size({ width: 1280, height: 720 })
		.with_frame_pacing(VSync)
		.with_cursor_mode(Locked),
	|startup| {
		# Reapply capture after native-window creation; see App.Config cursor-mode
		# transport notes in the original vertical-slice example.
		App.set_cursor_mode!(startup, Locked)
		store = Assets.Store.open!(Assets.working_directory("examples/doom/assets"))?
		world_atlas = Assets.load_texture!(store, "freedoom/generated/e1m1/world_atlas.png")?
		sprite_atlas = Assets.load_texture!(store, "freedoom/generated/e1m1/sprite_atlas.png")?
		Assets.set_texture_filter!(world_atlas, Point)
		Assets.set_texture_filter!(sprite_atlas, Point)
		sprite_shader = Draw.Shader.from_source!({ vertex_source: "", fragment_source: sprite_fragment_shader })?

		map = DoomMap.e1m1
		start = map.player_start() ?? crash "validated E1M1 must contain exactly one player start"
		mesh_batches = E1M1Renderer.build(map.surface_polygons(), map.wall_spans()) ?? crash "generated E1M1 atlas is incomplete"
		batches = List.map(mesh_batches, render_geometry)
		position = { x: I64.to_f32(start.position.x), y: I64.to_f32(start.position.y) }
		angle = DoomSim.Angle.from_turns(I64.to_f32(start.angle) / 360)
		spawned = DoomWorld.spawn(map.raw().things, Medium)
		world : DoomWorld.World
		world = { player: DoomWorld.player(position, angle), actors: spawned.actors, pickups: spawned.pickups, rng: DoomWorld.Rng.seed(0) }
		level = DoomLevel.initial(map)
		blockers = List.map(
			map.blocking_segments(),
			|segment| {
				start: { x: I64.to_f32(segment.start.x), y: I64.to_f32(segment.start.y) },
				end: { x: I64.to_f32(segment.end.x), y: I64.to_f32(segment.end.y) },
			},
		)
		Ok({ world, level, blockers, batches, world_atlas, sprite_atlas, sprite_shader })
	},
)

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	if input.devices.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		forward = signed_command(
			input.devices.key_down(KeyW) or input.devices.key_down(KeyUp),
			input.devices.key_down(KeyS) or input.devices.key_down(KeyDown),
			50,
		)
		side = signed_command(
			input.devices.key_down(KeyD) or input.devices.key_down(KeyRight),
			input.devices.key_down(KeyA) or input.devices.key_down(KeyLeft),
			40,
		)
		turn = input.devices.mouse.delta().x * mouse_turns_per_pixel
		fire = input.devices.mouse.button_pressed(Left) or input.devices.key_pressed(KeySpace)
		previous_pos = model.world.player.sim.state.pos
		blockers = DoomRuntime.blockers_for_player(DoomMap.e1m1, model.level, previous_pos)
		advanced = DoomRuntime.advance(model.world, input.time.elapsed_seconds, { forward, side, turn, fire }, blockers)
		crossed_level = DoomRuntime.cross_specials(DoomMap.e1m1, model.level, previous_pos, advanced.world.player.sim.state.pos)
		level0 = if input.devices.key_pressed(KeyE) {
			match DoomRuntime.use_nearest(DoomMap.e1m1, crossed_level, advanced.world.player.sim.state.pos, advanced.world.player.keys) {
				Activated(next) => next
				_ => crossed_level
			}
		} else crossed_level
		level = advance_level(level0, advanced.tics)
		Ok({ ..model, world: advanced.world, level, blockers })
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ScopeUnavailable, ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x101010))
	state = model.world.player.sim.state
	world_x = state.pos.x * E1M1Renderer.doom_scale
	world_z = state.pos.y * E1M1Renderer.doom_scale
	facing = state.angle.forward()
	sector = DoomLevel.sector_at(DoomMap.e1m1, { x: F32.to_f64(state.pos.x), y: F32.to_f64(state.pos.y) }) ?? crash "player left validated E1M1 geometry"
	heights = DoomLevel.heights_for(model.level, sector) ?? crash "player sector state missing"
	eye_y = I64.to_f32(heights.floor + 41) * E1M1Renderer.doom_scale
	camera = Camera.perspective({
		position: { x: world_x, y: eye_y, z: world_z },
		target: { x: world_x + facing.x, y: eye_y, z: world_z + facing.y },
		up: { x: 0, y: 1, z: 0 },
		fovy: 74,
	})
	frame.with_camera_3d!(
		camera,
		|scene| {
			for batch in model.batches {
				scene.textured_triangles_3d!({ texture: model.world_atlas, vertices: batch.vertices, indices: batch.indices })
			}
			sprites = sprite_geometry(model.world, model.level, state.pos)
			scene.with_shader!(
				model.sprite_shader,
				|cutout| {
					cutout.textured_triangles_3d!({ texture: model.sprite_atlas, vertices: sprites.vertices, indices: sprites.indices })
					Ok({})
				},
			)?
			Ok({})
		},
	)?
	draw_hud!(frame, model.world.player)
	Ok({})
}

sprite_geometry : DoomWorld.World, DoomLevel.State, DoomSim.Vec2 -> RenderGeometry
sprite_geometry = |world, level, viewer| {
	var $geometry = { vertices: [], indices: [] }
	for actor in world.actors {
		primitive = DoomSprites.actor_geometry(actor, viewer) ?? crash "generated E1M1 actor has no sprite mapping"
		$geometry = append_sprite($geometry, place_on_floor(render_sprite_geometry(primitive), level, actor.pos))
	}
	for pickup in world.pickups {
		if !(pickup.taken) {
			primitive = DoomSprites.pickup_geometry(pickup, viewer) ?? crash "generated E1M1 pickup has no sprite mapping"
			$geometry = append_sprite($geometry, place_on_floor(render_sprite_geometry(primitive), level, pickup.pos))
		}
	}
	$geometry
}

place_on_floor = |geometry, level, pos| {
	sector = DoomLevel.sector_at(DoomMap.e1m1, { x: F32.to_f64(pos.x), y: F32.to_f64(pos.y) })
	floor = match sector {
		Ok(index) => (DoomLevel.heights_for(level, index) ?? crash "sprite sector state missing").floor
		Err(OutsideMap) => 0
	}
	offset = I64.to_f32(floor) * E1M1Renderer.doom_scale
	{ ..geometry, vertices: List.map(geometry.vertices, |vertex| { ..vertex, position: { ..vertex.position, y: vertex.position.y + offset } }) }
}

render_sprite_geometry = |batch| {
	vertices = List.map(
		batch.vertices,
		|vertex| {
			..vertex,
			tint: Color.rgba(vertex.tint.r, vertex.tint.g, vertex.tint.b, vertex.tint.a),
		},
	)
	{ vertices, indices: batch.indices }
}

append_sprite = |geometry, primitive| {
	offset = U64.to_u32_wrap(List.len(geometry.vertices))
	indices = List.map(primitive.indices, |index| index + offset)
	{ vertices: List.concat(geometry.vertices, primitive.vertices), indices: List.concat(geometry.indices, indices) }
}

draw_hud! = |frame, player| {
	size = frame.size!()
	frame.text_at!({ pos: { x: 24, y: size.height - 42 }, text: "HEALTH ${I64.to_str(player.health)}", size: 24, color: if player.health <= 25 Color.red else Color.ray_white })
	ammo = if player.weapon == Pistol player.ammo.bullets else player.ammo.shells
	frame.text_at!({ pos: { x: size.width - 160, y: size.height - 42 }, text: "AMMO ${I64.to_str(ammo)}", size: 24, color: Color.from_hex_rgb(0xe8c56a) })
	frame.line!({ start: { x: size.width * 0.5 - 6, y: size.height * 0.5 }, end: { x: size.width * 0.5 + 6, y: size.height * 0.5 }, stroke: Draw.stroke(Color.white, 1) })
	frame.line!({ start: { x: size.width * 0.5, y: size.height * 0.5 - 6 }, end: { x: size.width * 0.5, y: size.height * 0.5 + 6 }, stroke: Draw.stroke(Color.white, 1) })
}

## Resolve the independently testable mesh module's structural tint into the
## platform's opaque Color once at startup; presentation reuses retained lists.
render_geometry : E1M1Renderer.Geometry -> RenderGeometry
render_geometry = |batch| {
	vertices = List.map(
		batch.vertices,
		|vertex| {
			..vertex,
			tint: Color.rgba(vertex.tint.r, vertex.tint.g, vertex.tint.b, vertex.tint.a),
		},
	)
	{ vertices, indices: batch.indices }
}

signed_command : Bool, Bool, I16 -> I16
signed_command = |positive, negative, magnitude|
	if positive and !(negative) magnitude else if negative and !(positive) 0 - magnitude else 0

advance_level = |level, tics| if tics == 0 level else advance_level(DoomLevel.tick(level), tics - 1)

mouse_turns_per_pixel = 0.0004

expect signed_command(Bool.True, Bool.False, 50) == 50
	and signed_command(Bool.False, Bool.True, 50) == -50
		and signed_command(Bool.True, Bool.True, 50) == 0
