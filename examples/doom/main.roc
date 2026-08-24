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
import DoomMap
import DoomSim
import E1M1Renderer

RenderGeometry : {
	vertices : List({ position : { x : F32, y : F32, z : F32 }, uv : { x : F32, y : F32 }, tint : Color.Rgba }),
	indices : List(U32),
}

Model : {
	player : DoomSim.Clock,
	blockers : List(DoomSim.Segment),
	batches : List(RenderGeometry),
	world_atlas : Draw.Texture,
	sprite_atlas : Draw.Texture,
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

		map = DoomMap.e1m1
		start = map.player_start() ?? crash "validated E1M1 must contain exactly one player start"
		mesh_batches = E1M1Renderer.build(map.surface_polygons(), map.wall_spans()) ?? crash "generated E1M1 atlas is incomplete"
		batches = List.map(mesh_batches, render_geometry)
		position = { x: I64.to_f32(start.position.x), y: I64.to_f32(start.position.y) }
		angle = DoomSim.Angle.from_turns(I64.to_f32(start.angle) / 360)
		blockers = List.map(
			map.blocking_segments(),
			|segment| {
				start: { x: I64.to_f32(segment.start.x), y: I64.to_f32(segment.start.y) },
				end: { x: I64.to_f32(segment.end.x), y: I64.to_f32(segment.end.y) },
			},
		)
		Ok({ player: DoomSim.clock(DoomSim.initial(position, angle)), blockers, batches, world_atlas, sprite_atlas })
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
		advanced = DoomSim.advance(model.player, input.time.elapsed_seconds, { forward, side, turn, fire: Bool.False }, model.blockers)
		Ok({ ..model, player: advanced.clock })
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ScopeUnavailable, ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x101010))
	state = model.player.state
	world_x = state.pos.x * E1M1Renderer.doom_scale
	world_z = state.pos.y * E1M1Renderer.doom_scale
	facing = state.angle.forward()
	camera = Camera.perspective({
		position: { x: world_x, y: eye_height, z: world_z },
		target: { x: world_x + facing.x, y: eye_height, z: world_z + facing.y },
		up: { x: 0, y: 1, z: 0 },
		fovy: 74,
	})
	frame.with_camera_3d!(
		camera,
		|scene| {
			for batch in model.batches {
				scene.textured_triangles_3d!({ texture: model.world_atlas, vertices: batch.vertices, indices: batch.indices })
			}
			Ok({})
		},
	)?
	Ok({})
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

eye_height = 41 / 64

mouse_turns_per_pixel = 0.0004

expect signed_command(Bool.True, Bool.False, 50) == 50
	and signed_command(Bool.False, Bool.True, 50) == -50
		and signed_command(Bool.True, Bool.True, 50) == 0
