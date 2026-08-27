## Navigable Freedoom E1M1 rendered from its real Doom map lumps. The app owns
## player simulation and map policy in Roc; the host retains textures and draws
## bounded borrowed triangle batches derived by E1M1Renderer.
app [Model, program] {
	rr: platform "../../platform/main.roc",
	roc: "nightly-2026-08-23-fb208ba",
}

import rr.App
import rr.Assets
import rr.Audio
import rr.Camera
import rr.Color
import rr.Draw
import rr.Stdout
import rr.Text
import RocDoomLevel
import RocDoomControls
import RocDoomDebug
import RocDoomMap
import RocDoomPresentation
import RocDoomRuntime
import RocDoomSim
import RocDoomSprites
import RocDoomView
import RocDoomWorld
import E1M1Renderer
import "sprite_cutout.fs" as sprite_fragment_shader : Str

# Compile-time geometry diagnostics. Set to Bool.True locally, rebuild, and
# place the crosshair over a missing wall. Keep false for normal play/captures.
debug_geometry = Bool.False

RenderGeometry : {
	vertices : List({ position : { x : F32, y : F32, z : F32 }, uv : { x : F32, y : F32 }, tint : Color.Rgba }),
	indices : List(U32),
}

Model : {
	world : RocDoomRuntime.World,
	decorations : List(RocDoomWorld.Decoration),
	level : RocDoomLevel.State,
	blockers : List(RocDoomSim.Segment),
	batches : List(RenderGeometry),
	masked_batches : List(RenderGeometry),
	dynamic_batches : List(RenderGeometry),
	masked_dynamic_batches : List(RenderGeometry),
	sprites : RenderGeometry,
	world_atlas : Draw.Texture,
	sprite_atlas : Draw.Texture,
	sprite_shader : Draw.Shader,
	logical_target : Draw.RenderTexture,
	flashes : RocDoomView.Flashes,
	pending : RocDoomControls.Pending,
	sounds : Sounds,
	title : Bool,
	title_font : Text.Font,
}

Sounds : { fire : Audio.Sound, pickup : Audio.Sound, pain : Audio.Sound, death : Audio.Sound, alert : Audio.Sound, door : Audio.Sound, switch_on : Audio.Sound, switch_off : Audio.Sound, monster_attack : Audio.Sound, projectile : Audio.Sound, explosion : Audio.Sound, oof : Audio.Sound, no_way : Audio.Sound, platform_move : Audio.Sound, music : Audio.Music }

LocalCueKind : [FireSound, PickupSound, OofSound, NoWaySound]

SpatialCueKind : [PainSound, DeathSound, AlertSound, DoorSound, SwitchOnSound, SwitchOffSound, MonsterAttackSound, ProjectileSound, ExplosionSound, PlatformSound]

Cue : [LocalCue(LocalCueKind), SpatialCue(SpatialCueKind, RocDoomSim.Vec2)]

Listener : { pos : RocDoomSim.Vec2, angle : RocDoomSim.Angle }

Msg : []

program = { init!, update!, render! }

init! : App.Init(Model, _)
init! = App.init(
	App.default
		.with_title("RocDOOM E1M1")
		.with_size({ width: 1280, height: 720 })
		.with_frame_pacing(VSync)
		.with_cursor_mode(Locked),
	|_startup| {
		store = Assets.Store.open!(Assets.working_directory("examples/roc-doom-e1m1/assets"))?
		world_atlas = Assets.load_texture!(store, "freedoom/generated/e1m1/world_atlas.png")?
		sprite_atlas = Assets.load_texture!(store, "freedoom/generated/e1m1/sprite_atlas.png")?
		Assets.set_texture_filter!(world_atlas, Point)
		Assets.set_texture_filter!(sprite_atlas, Point)
		sprite_shader = Draw.Shader.from_source!({ vertex_source: "", fragment_source: sprite_fragment_shader })?
		logical_target = Draw.load_render_texture!({ width: 320.I32, height: 200.I32 })?
		sounds = load_sounds!()?
		title_font = Draw.default_font!()

		map = RocDoomMap.e1m1
		start = map.player_start() ?? crash "validated E1M1 must contain exactly one player start"
		mesh_batches = E1M1Renderer.build_static(map) ?? crash "generated E1M1 atlas is incomplete"
		batches = List.map(mesh_batches, render_geometry)
		masked_batches = List.map(E1M1Renderer.build_masked_static(map) ?? crash "generated masked E1M1 atlas is incomplete", render_geometry)
		dynamic_batches = List.map(E1M1Renderer.build_dynamic(map, RocDoomLevel.initial(map)) ?? crash "generated dynamic E1M1 atlas is incomplete", render_geometry)
		masked_dynamic_batches = List.map(E1M1Renderer.build_masked_dynamic(map, RocDoomLevel.initial(map)) ?? crash "generated dynamic masked E1M1 atlas is incomplete", render_geometry)
		position = { x: I64.to_f32(start.position.x), y: I64.to_f32(start.position.y) }
		angle = RocDoomSim.Angle.from_turns(I64.to_f32(start.angle) / 360)
		runtime = initial_runtime(map, position, angle)
		world = runtime.world
		decorations = runtime.decorations
		level = RocDoomLevel.initial(map)
		sprites = sprite_geometry(world, decorations, level, position)
		blockers = List.map(
			map.blocking_segments(),
			|segment| {
				start: { x: I64.to_f32(segment.start.x), y: I64.to_f32(segment.start.y) },
				end: { x: I64.to_f32(segment.end.x), y: I64.to_f32(segment.end.y) },
			},
		)
		Ok({ world, decorations, level, blockers, batches, masked_batches, dynamic_batches, masked_dynamic_batches, sprites, world_atlas, sprite_atlas, sprite_shader, logical_target, flashes: RocDoomView.initial, pending: RocDoomControls.pending_none, sounds, title: Bool.True, title_font })
	},
)

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	write_geometry_debug!(model, input, debug_geometry)
	if input.devices.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else if model.title {
		# The title card never advances the simulation, and it dismisses itself
		# after `title_seconds` as well as on input. A scripted or headless run
		# therefore cannot be held on it indefinitely or desynchronised by it.
		dismissed =
			input.devices.key_pressed(KeySpace)
				or input.devices.key_pressed(KeyEnter)
					or input.devices.mouse.button_pressed(Left)
						or input.time.elapsed_seconds > title_seconds
		Ok({ ..model, title: !(dismissed) })
	} else if input.devices.key_pressed(KeyR) {
		start = RocDoomMap.e1m1.player_start() ?? crash "validated E1M1 player start missing"
		position = { x: I64.to_f32(start.position.x), y: I64.to_f32(start.position.y) }
		angle = RocDoomSim.Angle.from_turns(I64.to_f32(start.angle) / 360)
		runtime = initial_runtime(RocDoomMap.e1m1, position, angle)
		world = runtime.world
		decorations = runtime.decorations
		level = RocDoomLevel.initial(RocDoomMap.e1m1)
		blockers = List.concat(RocDoomRuntime.blockers_for_player(RocDoomMap.e1m1, level, position), decoration_segments(decorations))
		dynamic_batches = List.map(E1M1Renderer.build_dynamic(RocDoomMap.e1m1, level) ?? crash "generated dynamic E1M1 atlas is incomplete", render_geometry)
		masked_dynamic_batches = List.map(E1M1Renderer.build_masked_dynamic(RocDoomMap.e1m1, level) ?? crash "generated dynamic masked E1M1 atlas is incomplete", render_geometry)
		sprites = sprite_geometry(world, decorations, level, position)
		Ok({ ..model, world, decorations, level, blockers, dynamic_batches, masked_dynamic_batches, sprites, flashes: RocDoomView.initial, pending: RocDoomControls.pending_none })
	} else {
		forward = signed_command(
			input.devices.key_down(KeyW) or input.devices.key_down(KeyUp),
			input.devices.key_down(KeyS) or input.devices.key_down(KeyDown),
			50,
		)
		side = RocDoomControls.side(
			input.devices.key_down(KeyA) or input.devices.key_down(KeyLeft),
			input.devices.key_down(KeyD) or input.devices.key_down(KeyRight),
		)
		fire = input.devices.mouse.button_down(Left) or input.devices.key_down(KeySpace)
		# Mouse motion and key edges are per-cycle quantities, so they are
		# latched until a tic consumes them rather than handed to every
		# catch-up tic. See RocDoomControls.Pending.
		pending = RocDoomControls.accumulate(
			model.pending,
			{
				turn: RocDoomControls.turn(input.devices.mouse.delta().x),
				fire,
				use: input.devices.key_pressed(KeyE),
				weapon_slot: weapon_slot_from(input.devices),
			},
		)
		cmds = RocDoomControls.ticcmds(pending, { forward, side, fire })
		previous_pos = model.world.doom.player.sim.state.pos
		extra_blockers = decoration_segments(model.decorations)
		advanced = RocDoomRuntime.advance_in_map_first(model.world, input.time.elapsed_seconds, cmds.first, cmds.repeat, extra_blockers, RocDoomMap.e1m1, model.level)
		crossed = RocDoomRuntime.cross_specials(RocDoomMap.e1m1, advanced.level, previous_pos, advanced.world.doom.player.sim.state.pos)
		# A use latched on a cycle that produced no tic waits for one, so the
		# door opens on the same cycle the cue below reports it.
		used = pending.use and advanced.tics > 0
		use_result = if used {
			RocDoomRuntime.use_forward(RocDoomMap.e1m1, crossed.level, advanced.world.doom.player.sim.state.pos, advanced.world.doom.player.sim.state.angle, advanced.world.doom.player.keys)
		} else NotUsable
		level0 = match use_result {
			Activated(next) => next
			_ => crossed.level
		}
		exited = crossed.exited or match use_result {
			Exit => Bool.True
			_ => Bool.False
		}
		world = if exited { ..advanced.world, phase: Exited } else advanced.world
		level = advance_level(level0, advanced.tics)
		dynamic_changed = RocDoomLevel.render_changed(RocDoomMap.e1m1, model.level, level)
		dynamic_batches = if dynamic_changed List.map(E1M1Renderer.build_dynamic(RocDoomMap.e1m1, level) ?? crash "generated dynamic E1M1 atlas is incomplete", render_geometry) else model.dynamic_batches
		masked_dynamic_batches = if dynamic_changed List.map(E1M1Renderer.build_masked_dynamic(RocDoomMap.e1m1, level) ?? crash "generated dynamic masked E1M1 atlas is incomplete", render_geometry) else model.masked_dynamic_batches
		sprites = if advanced.tics > 0 sprite_geometry(world, model.decorations, level, world.doom.player.sim.state.pos) else model.sprites
		blockers = List.concat(RocDoomRuntime.blockers_for_player(RocDoomMap.e1m1, level, world.doom.player.sim.state.pos), extra_blockers)
		flashes = RocDoomView.advance(model.flashes, advanced.tics, { damaged: world.doom.player.health < model.world.doom.player.health, picked_up: taken_count(world.doom.pickups) > taken_count(model.world.doom.pickups) })
		listener = { pos: world.doom.player.sim.state.pos, angle: world.doom.player.sim.state.angle }
		for cue in List.take_first(transition_cues(model.world, world, use_result, advanced.fired, used), max_cues_per_cycle) {
			play_cue!(model.sounds, cue, listener)
		}
		next_pending = if advanced.tics > 0 or world.phase != Playing RocDoomControls.pending_none else pending
		Ok({ ..model, world, level, blockers, dynamic_batches, masked_dynamic_batches, sprites, flashes, pending: next_pending })
	}
}

write_geometry_debug! = |model, input, enabled| if enabled and input.devices.key_pressed(KeyF3) {
	state = model.world.doom.player.sim.state
	match RocDoomDebug.trace(RocDoomMap.e1m1, model.level, state.pos, state.angle) {
		Ok(hit) => for line in hit.lines {
			_ = Stdout.line!(line)
		}
		Err(_) => {
			_ = Stdout.line!("GEOMETRY DEBUG: crosshair ray hit no linedef")
		}
	}
} else {}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ScopeUnavailable, ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x101010))
	frame.with_render_texture!(model.logical_target, |logical| draw_logical!(model, logical))?
	size = frame.size!()
	scale = F32.min(size.width / logical_width, size.height / logical_height)
	width = logical_width * scale
	height = logical_height * scale
	frame.texture!({ texture: Draw.render_texture(model.logical_target), source: Draw.render_texture_source(model.logical_target), dest: { x: (size.width - width) * 0.5, y: (size.height - height) * 0.5, width, height }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
	Ok({})
}

draw_logical! = |model, frame| if model.title {
	draw_title!(frame, model.title_font)
	Ok({})
} else draw_world!(model, frame)

draw_world! = |model, frame| {
	frame.clear!(Color.black)
	state = model.world.doom.player.sim.state
	world_x = state.pos.x * E1M1Renderer.doom_scale
	world_z = state.pos.y * E1M1Renderer.doom_scale
	facing = state.angle.forward()
	sector = RocDoomLevel.sector_at(RocDoomMap.e1m1, { x: F32.to_f64(state.pos.x), y: F32.to_f64(state.pos.y) }) ?? crash "player left validated E1M1 geometry"
	heights = RocDoomLevel.heights_for(model.level, sector) ?? crash "player sector state missing"
	eye_y = (I64.to_f32(heights.floor + 41) + state.view.offset) * E1M1Renderer.doom_scale
	camera = Camera.perspective({
		position: { x: world_x, y: eye_y, z: world_z },
		target: { x: world_x + facing.x, y: eye_y, z: world_z + facing.y },
		up: { x: 0, y: 1, z: 0 },
		fovy: 74,
	})
	frame.with_camera_3d!(
		camera,
		|scene| {
			sky = render_geometry(E1M1Renderer.sky_geometry(world_x, world_z) ?? crash "generated E1M1 sky texture missing")
			scene.textured_triangles_3d!({ texture: model.world_atlas, vertices: sky.vertices, indices: sky.indices })
			for batch in model.batches {
				scene.textured_triangles_3d!({ texture: model.world_atlas, vertices: batch.vertices, indices: batch.indices })
			}
			for dynamic in model.dynamic_batches {
				scene.textured_triangles_3d!({ texture: model.world_atlas, vertices: dynamic.vertices, indices: dynamic.indices })
			}
			scene.with_shader!(
				model.sprite_shader,
				|cutout| {
					for batch in model.masked_batches {
						cutout.textured_triangles_3d!({ texture: model.world_atlas, vertices: batch.vertices, indices: batch.indices })
					}
					for dynamic in model.masked_dynamic_batches {
						cutout.textured_triangles_3d!({ texture: model.world_atlas, vertices: dynamic.vertices, indices: dynamic.indices })
					}
					cutout.textured_triangles_3d!({ texture: model.sprite_atlas, vertices: model.sprites.vertices, indices: model.sprites.indices })
					Ok({})
				},
			)?
			Ok({})
		},
	)?
	draw_weapon!(frame, model.sprite_atlas, model.world)
	draw_hud!(frame, model.sprite_atlas, model.world, model.flashes)
	draw_flashes!(frame, model.flashes)
	draw_geometry_debug!(frame, model, state, debug_geometry)
	Ok({})
}

draw_geometry_debug! = |frame, model, state, enabled| if enabled {
	report = RocDoomDebug.trace(RocDoomMap.e1m1, model.level, state.pos, state.angle)
	match report {
		Ok(hit) => {
			frame.rectangle!({ x: 2, y: 2, width: 316, height: 58, style: Draw.filled(Color.with_alpha(Color.black, 220)) })
			for entry in List.map_with_index(hit.lines, |line, index| { line, index }) {
				frame.text_at!({ pos: { x: 5, y: 4 + U64.to_f32(entry.index) * 8 }, text: entry.line, size: 7, color: if entry.index == 1 Color.from_hex_rgb(0xff00ff) else Color.ray_white })
			}
		}
		Err(_) => frame.text_at!({ pos: { x: 5, y: 5 }, text: "GEOMETRY DEBUG: crosshair ray hit no linedef", size: 7, color: Color.from_hex_rgb(0xff00ff) })
	}
} else {}

sprite_geometry : RocDoomRuntime.World, List(RocDoomWorld.Decoration), RocDoomLevel.State, RocDoomSim.Vec2 -> RenderGeometry
sprite_geometry = |world, decorations, level, viewer| {
	var $geometry = { vertices: [], indices: [] }
	for actor in world.doom.actors {
		primitive = RocDoomSprites.actor_geometry(actor, viewer) ?? crash "generated E1M1 actor has no sprite mapping"
		$geometry = append_sprite($geometry, place_on_floor(render_sprite_geometry(primitive), level, actor.pos))
	}
	for pickup in world.doom.pickups {
		match RocDoomSprites.pickup_geometry(pickup, viewer, world.doom.player.sim.state.tic) ?? crash "generated E1M1 pickup has no sprite mapping" {
			Visible(primitive) => {
				$geometry = append_sprite($geometry, place_on_floor(render_sprite_geometry(primitive), level, pickup.pos))
			}
			Hidden => {}
		}
	}
	for projectile in world.projectiles {
		primitive = RocDoomSprites.effect_geometry(ImpProjectile, projectile.pos, viewer, world.doom.player.sim.state.tic) ?? crash "Imp projectile sprite missing"
		$geometry = append_sprite($geometry, place_above_floor(render_sprite_geometry(primitive), level, projectile.pos, 24))
	}
	for explosion in world.explosions {
		phase = (RocDoomRuntime.explosion_lifetime - explosion.remaining) / 3
		primitive = RocDoomSprites.effect_geometry(ImpExplosion, explosion.pos, viewer, phase) ?? crash "Imp explosion sprite missing"
		$geometry = append_sprite($geometry, place_above_floor(render_sprite_geometry(primitive), level, explosion.pos, 20))
	}
	for decoration in decorations {
		primitive = RocDoomSprites.decoration_geometry(decoration, viewer) ?? crash "generated E1M1 decoration has no sprite mapping"
		$geometry = append_sprite($geometry, place_on_floor(render_sprite_geometry(primitive), level, decoration.pos))
	}
	$geometry
}

place_on_floor = |geometry, level, pos| {
	place_above_floor(geometry, level, pos, 0)
}

place_above_floor = |geometry, level, pos, above| {
	sector = RocDoomLevel.sector_at(RocDoomMap.e1m1, { x: F32.to_f64(pos.x), y: F32.to_f64(pos.y) })
	floor = match sector {
		Ok(index) => (RocDoomLevel.heights_for(level, index) ?? crash "sprite sector state missing").floor
		Err(OutsideMap) => 0
	}
	offset = I64.to_f32(floor + above) * E1M1Renderer.doom_scale
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

draw_weapon! = |frame, atlas, world| {
	playing = match world.phase {
		Playing => Bool.True
		_ => Bool.False
	}
	if playing {
		match RocDoomPresentation.weapon(world.doom.player.weapon, world.weapon.phase) {
			Ok(view) => {
				size = frame.size!()
				width = U64.to_f32(view.rect.width) * weapon_scale
				height = U64.to_f32(view.rect.height) * weapon_scale
				bob = world.doom.player.sim.state.view
				frame.texture!({ texture: atlas, source: atlas_rect(view.rect), dest: { x: size.width * 0.5 - width * 0.5 + weapon_offset_x + bob.weapon_x, y: size.height - height - hud_height + bob.weapon_y + bob.weapon_kick, width, height }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
			}
			Err(_) => {}
		}
	}
}

draw_hud! = |frame, atlas, world, flashes| {
	player = world.doom.player
	size = frame.size!()
	ammo = match player.weapon {
		Pistol => player.ammo.bullets
		Shotgun => player.ammo.shells
		Chaingun => player.ammo.bullets
		RocketLauncher => player.ammo.rockets
		PlasmaRifle => player.ammo.cells
		Chainsaw => 0
	}
	bar = RocDoomPresentation.hud(StatusBar) ?? crash "generated status bar sprite missing"
	frame.texture!({ texture: atlas, source: atlas_rect(bar), dest: { x: 0, y: size.height - hud_height, width: 320, height: hud_height }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
	draw_number!(frame, atlas, I64.max(0, ammo), 44, size.height - 29)
	draw_number!(frame, atlas, I64.max(0, player.health), 90, size.height - 29)
	draw_percent!(frame, atlas, 90, size.height - 29)
	draw_weapons!(frame, atlas, player, size)
	draw_number!(frame, atlas, I64.max(0, player.armor), 221, size.height - 29)
	draw_percent!(frame, atlas, 221, size.height - 29)
	draw_ammo_table!(frame, atlas, player, size)
	dead = match world.phase {
		Dead => Bool.True
		_ => Bool.False
	}
	face = if dead {
		RocDoomPresentation.hud(Face("DEAD0")) ?? crash "dead face missing"
	} else if flashes.damage > 0 {
		RocDoomPresentation.hud(Face("OUCH0")) ?? crash "ouch face missing"
	} else if world.doom.player.health <= 20 {
		RocDoomPresentation.hud(Face("ST40")) ?? crash "critical face missing"
	} else if world.doom.player.health <= 40 {
		RocDoomPresentation.hud(Face("ST30")) ?? crash "hurt face missing"
	} else if world.doom.player.health <= 60 {
		RocDoomPresentation.hud(Face("ST20")) ?? crash "hurt face missing"
	} else if world.doom.player.health <= 80 {
		RocDoomPresentation.hud(Face("ST10")) ?? crash "hurt face missing"
	} else {
		RocDoomPresentation.hud(Face("ST00")) ?? crash "healthy face missing"
	}
	frame.texture!({ texture: atlas, source: atlas_rect(face), dest: { x: 143, y: size.height - 32, width: U64.to_f32(face.width), height: U64.to_f32(face.height) }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
	draw_keys!(frame, atlas, player.keys, size)
	match world.phase {
		Playing => {}
		Dead => overlay!(frame, size, "YOU DIED", "Press R to restart")
		Exited => overlay!(frame, size, "LEVEL COMPLETE", "Press R to restart")
	}
}

draw_weapons! = |frame, atlas, player, size| {
	arms = RocDoomPresentation.hud(Arms) ?? crash "status arms sprite missing"
	frame.texture!({ texture: atlas, source: atlas_rect(arms), dest: { x: 104, y: size.height - 32, width: U64.to_f32(arms.width), height: U64.to_f32(arms.height) }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
	slots = [{ slot: 2.U8, owned: player.weapons.pistol }, { slot: 3.U8, owned: player.weapons.shotgun }, { slot: 4.U8, owned: player.weapons.chaingun }, { slot: 5.U8, owned: player.weapons.rocket_launcher }, { slot: 6.U8, owned: player.weapons.plasma_rifle }, { slot: 7.U8, owned: Bool.False }]
	for item in List.map_with_index(slots, |value, index| { value, index }) {
		element = if item.value.owned SmallDigit(item.value.slot) else GrayDigit(item.value.slot)
		match RocDoomPresentation.hud(element) {
			Ok(rect) => frame.texture!({ texture: atlas, source: atlas_rect(rect), dest: { x: 111 + U64.to_f32(item.index % 3) * 12, y: size.height - 28 + U64.to_f32(item.index / 3) * 10, width: U64.to_f32(rect.width), height: U64.to_f32(rect.height) }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
			Err(_) => {}
		}
	}
}

draw_number! = |frame, atlas, value, x, y| {
	n = I64.min(999, value)
	digits = number_digits(n)
	for entry in List.map_with_index(digits, |digit, index| { digit, index }) {
		match RocDoomPresentation.hud(LargeDigit(entry.digit)) {
			Ok(rect) => frame.texture!({ texture: atlas, source: atlas_rect(rect), dest: { x: x - U64.to_f32(List.len(digits) - entry.index) * U64.to_f32(rect.width), y, width: U64.to_f32(rect.width), height: U64.to_f32(rect.height) }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
			Err(_) => {}
		}
	}
}

draw_percent! = |frame, atlas, x, y| {
	rect = RocDoomPresentation.hud(Percent) ?? crash "status percent sprite missing"
	frame.texture!({ texture: atlas, source: atlas_rect(rect), dest: { x, y, width: U64.to_f32(rect.width), height: U64.to_f32(rect.height) }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
}

draw_ammo_table! = |frame, atlas, player, size| {
	maximums = if player.backpack [400.I64, 100.I64, 100.I64, 600.I64] else [200.I64, 50.I64, 50.I64, 300.I64]
	values = [player.ammo.bullets, player.ammo.shells, player.ammo.rockets, player.ammo.cells]
	for row in List.map_with_index(values, |value, index| { value, index }) {
		y = size.height - 27 + U64.to_f32(row.index) * 6
		draw_small_number!(frame, atlas, I64.max(0, row.value), 288, y)
		draw_small_number!(frame, atlas, List.get(maximums, row.index) ?? 0, 314, y)
	}
}

draw_small_number! = |frame, atlas, value, right, y| {
	digits = number_digits(I64.min(999, value))
	for entry in List.map_with_index(digits, |digit, index| { digit, index }) {
		match RocDoomPresentation.hud(SmallDigit(entry.digit)) {
			Ok(rect) => frame.texture!({ texture: atlas, source: atlas_rect(rect), dest: { x: right - U64.to_f32(List.len(digits) - entry.index) * U64.to_f32(rect.width), y, width: U64.to_f32(rect.width), height: U64.to_f32(rect.height) }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
			Err(_) => {}
		}
	}
}

number_digits = |value| if value >= 100 [I64.to_u8_wrap(value / 100), I64.to_u8_wrap((value / 10) % 10), I64.to_u8_wrap(value % 10)] else if value >= 10 [I64.to_u8_wrap(value / 10), I64.to_u8_wrap(value % 10)] else [I64.to_u8_wrap(value)]

expect number_digits(0) == [0] and number_digits(39) == [3, 9] and number_digits(100) == [1, 0, 0]

expect {
	# Canonical Doom status-bar coordinates at the 320x200 logical resolution.
	ammo_rows = List.map([0.U64, 1.U64, 2.U64, 3.U64], |row| logical_height - 27 + U64.to_f32(row) * 6)
	ammo_rows == [173, 179, 185, 191]
}

draw_keys! = |frame, atlas, keys, size| {
	flags = [{ present: keys.blue, index: 0.U8 }, { present: keys.yellow, index: 1.U8 }, { present: keys.red, index: 2.U8 }]
	for item in List.map_with_index(flags, |entry, slot| { entry, slot }) {
		if item.entry.present {
			match RocDoomPresentation.hud(Key(item.entry.index)) {
				Ok(rect) => frame.texture!({ texture: atlas, source: atlas_rect(rect), dest: { x: 239 + U64.to_f32(item.slot) * 14, y: size.height - 23, width: 12, height: 10 }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
				Err(_) => {}
			}
		}
	}
}

atlas_rect = |rect| { x: U64.to_f32(rect.x), y: U64.to_f32(rect.y), width: U64.to_f32(rect.width), height: U64.to_f32(rect.height) }

## The title card is deliberately plain: the default font, a flat rule, and no
## stylised wordmark. It names this project and separates it from both id
## Software's DOOM and the Freedoom project whose assets it renders, rather
## than imitating either one's presentation.
title_seconds = 8.0

draw_title! = |frame, font| {
	frame.clear!(Color.from_hex_rgb(0x0b0b0b))
	Text.from("RocDOOM", font).size(34).draw!(frame, { pos: { x: 160, y: 54 }, color: Color.from_hex_rgb(0xd7433f), align: (Middle, Center) })
	Text.from("E1M1", font).size(15).draw!(frame, { pos: { x: 160, y: 80 }, color: Color.ray_white, align: (Middle, Center) })
	frame.rectangle!({ x: 92, y: 95, width: 136, height: 1, style: Draw.filled(Color.with_alpha(Color.ray_white, 90)) })
	Text.from("A Doom-compatible engine written in Roc", font).size(8).draw!(frame, { pos: { x: 160, y: 112 }, color: Color.with_alpha(Color.ray_white, 200), align: (Middle, Center) })
	Text.from("Freedoom 0.13.0 assets, modified BSD licence", font).size(8).draw!(frame, { pos: { x: 160, y: 124 }, color: Color.with_alpha(Color.ray_white, 140), align: (Middle, Center) })
	Text.from("Not affiliated with or endorsed by id Software", font).size(8).draw!(frame, { pos: { x: 160, y: 136 }, color: Color.with_alpha(Color.ray_white, 140), align: (Middle, Center) })
	Text.from("or the Freedoom project", font).size(8).draw!(frame, { pos: { x: 160, y: 148 }, color: Color.with_alpha(Color.ray_white, 140), align: (Middle, Center) })
	Text.from("PRESS SPACE", font).size(11).draw!(frame, { pos: { x: 160, y: 176 }, color: Color.from_hex_rgb(0xd6b64c), align: (Middle, Center) })
}

overlay! = |frame, size, title, subtitle| {
	frame.rectangle!({ x: 0, y: 0, width: size.width, height: size.height, style: Draw.filled(Color.with_alpha(Color.black, 165)) })
	frame.text_at!({ pos: { x: size.width * 0.5 - 150, y: size.height * 0.42 }, text: title, size: 36, color: Color.from_hex_rgb(0xd7433f) })
	frame.text_at!({ pos: { x: size.width * 0.5 - 100, y: size.height * 0.42 + 48 }, text: subtitle, size: 18, color: Color.ray_white })
}

initial_runtime = |map, position, angle| {
	spawned = RocDoomWorld.spawn(map.raw().things, Medium)
	if !(List.is_empty(spawned.unsupported)) {
		crash "validated E1M1 contains unsupported thing types"
	}
	doom : RocDoomWorld.World
	doom = { player: RocDoomWorld.player(position, angle), actors: spawned.actors, pickups: spawned.pickups, rng: spawned.rng }
	{ world: RocDoomRuntime.initial_for_skill(doom, Medium), decorations: spawned.decorations }
}

decoration_segments = |decorations| {
	var $segments = []
	for decoration in decorations {
		if decoration.blocking {
			r = 16
			a = { x: decoration.pos.x - r, y: decoration.pos.y - r }
			b = { x: decoration.pos.x + r, y: decoration.pos.y - r }
			c = { x: decoration.pos.x + r, y: decoration.pos.y + r }
			d = { x: decoration.pos.x - r, y: decoration.pos.y + r }
			$segments = List.concat($segments, [{ start: a, end: b }, { start: b, end: c }, { start: c, end: d }, { start: d, end: a }])
		}
	}
	$segments
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

weapon_slot_from = |devices| if devices.key_pressed(Key2) SelectSlot(2) else if devices.key_pressed(Key3) SelectSlot(3) else if devices.key_pressed(Key4) SelectSlot(4) else if devices.key_pressed(Key5) SelectSlot(5) else if devices.key_pressed(Key6) SelectSlot(6) else if devices.key_pressed(Key8) SelectSlot(8) else KeepWeapon

signed_command : Bool, Bool, I16 -> I16
signed_command = |positive, negative, magnitude|
	if positive and !(negative) magnitude else if negative and !(positive) 0 - magnitude else 0

advance_level = |level, tics| if tics == 0 level else advance_level(RocDoomLevel.tick(level), tics - 1)

logical_width = 320

logical_height = 200

hud_height = 32

## The extracted PISG/SHTG frames are trimmed to their opaque bounds, so the
## original lumps' draw offsets are gone and the sprite can only be centred by
## its own width. These two dials restore the canonical framing: shrink the
## oversized Freedoom art slightly, then nudge the barrel back onto the screen
## centre that the trimmed arm pulls left of.
weapon_scale = 0.85

weapon_offset_x = 10

draw_flashes! = |frame, flashes| {
	size = frame.size!()
	if flashes.pickup > 0 {
		alpha = U64.to_u8_wrap(U64.min(80, flashes.pickup * 8))
		frame.rectangle!({ x: 0, y: 0, width: size.width, height: size.height, style: Draw.filled(Color.with_alpha(Color.from_hex_rgb(0xd6b64c), alpha)) })
	}
	if flashes.damage > 0 {
		alpha = U64.to_u8_wrap(U64.min(120, flashes.damage * 8))
		frame.rectangle!({ x: 0, y: 0, width: size.width, height: size.height, style: Draw.filled(Color.with_alpha(Color.red, alpha)) })
	}
}

transition_cues : RocDoomRuntime.World, RocDoomRuntime.World, RocDoomLevel.UseResult, Bool, Bool -> List(Cue)
transition_cues = |before, after, use_result, fired, used| {
	var $cues = if fired [LocalCue(FireSound)] else []
	if taken_count(after.doom.pickups) > taken_count(before.doom.pickups) {
		$cues = List.append($cues, LocalCue(PickupSound))
	}
	match changed_actor(before.doom.actors, after.doom.actors, |old, new| old.state.mode != Dead and new.state.mode == Dead) {
		Ok(actor) => {
			$cues = List.append($cues, SpatialCue(DeathSound, actor.pos))
		}
		Err(_) => match changed_actor(before.doom.actors, after.doom.actors, |old, new| new.health < old.health) {
			Ok(actor) => {
				$cues = List.append($cues, SpatialCue(PainSound, actor.pos))
			}
			Err(_) => {}
		}
	}
	match changed_actor(before.doom.actors, after.doom.actors, |old, new| old.state.mode == Look and new.state.mode != Look and new.state.mode != Dead) {
		Ok(actor) => {
			$cues = List.append($cues, SpatialCue(AlertSound, actor.pos))
		}
		Err(_) => {}
	}
	match changed_actor(before.doom.actors, after.doom.actors, |old, new| old.state.mode != Attack and new.state.mode == Attack) {
		Ok(actor) => {
			$cues = List.append($cues, SpatialCue(MonsterAttackSound, actor.pos))
		}
		Err(_) => {}
	}
	match newest_projectile(before.projectiles, after.projectiles) {
		Ok(projectile) => {
			$cues = List.append($cues, SpatialCue(ProjectileSound, projectile.pos))
		}
		Err(_) => {}
	}
	if List.len(after.explosions) > List.len(before.explosions) {
		match List.get(after.explosions, List.len(after.explosions) - 1) {
			Ok(explosion) => {
				$cues = List.append($cues, SpatialCue(ExplosionSound, explosion.pos))
			}
			Err(_) => {}
		}
	}
	match changed_actor(before.doom.actors, after.doom.actors, |old, new| new.kind == Barrel and old.state.mode == Dead and new.state.mode == Dead and old.state.remaining > 11 and new.state.remaining <= 11) {
		Ok(actor) => {
			$cues = List.append($cues, SpatialCue(ExplosionSound, actor.pos))
		}
		Err(_) => {}
	}
	if after.doom.player.health < before.doom.player.health {
		$cues = List.append($cues, LocalCue(OofSound))
	}
	match use_result {
		Activated(_) => {
			source = after.doom.player.sim.state.pos
			$cues = List.append($cues, SpatialCue(DoorSound, source))
			$cues = List.append($cues, SpatialCue(SwitchOnSound, source))
			$cues = List.append($cues, SpatialCue(PlatformSound, source))
		}
		_ => if used {
			$cues = List.append($cues, LocalCue(NoWaySound))
		}
	}
	$cues
}

taken_count = |pickups| List.len(List.keep_if(pickups, |pickup| pickup.taken))

dead_count = |actors|
	List.len(
		List.keep_if(
			actors,
			|actor| match actor.state.mode {
				Dead => Bool.True
				_ => Bool.False
			},
		),
	)

awake_count = |actors| List.len(List.keep_if(actors, |actor| actor.state.mode != Look and actor.state.mode != Dead))

attack_count = |actors|
	List.len(
		List.keep_if(
			actors,
			|actor| match actor.state.mode {
				Attack => Bool.True
				_ => Bool.False
			},
		),
	)

actor_health = |actors| List.fold(actors, 0.I64, |total, actor| total + actor.health)

changed_actor : List(RocDoomWorld.Actor), List(RocDoomWorld.Actor), (RocDoomWorld.Actor, RocDoomWorld.Actor -> Bool) -> Try(RocDoomWorld.Actor, [NoChangedActor])
changed_actor = |before, after, changed| {
	for actor in after {
		match List.find_first(before, |old| old.id == actor.id) {
			Ok(old) => if changed(old, actor) return Ok(actor)
			Err(_) => {}
		}
	}
	Err(NoChangedActor)
}

newest_projectile : List(RocDoomRuntime.Projectile), List(RocDoomRuntime.Projectile) -> Try(RocDoomRuntime.Projectile, [NotFound])
newest_projectile = |before, after|
	List.find_first(after, |projectile| !(List.any(before, |old| old.id == projectile.id)))

spatialize : Listener, RocDoomSim.Vec2 -> { pan : F32, volume : F32 }
spatialize = |listener, source| {
	offset = RocDoomSim.sub(source, listener.pos)
	distance = RocDoomSim.length(offset)
	direction = if distance <= 0 RocDoomSim.zero else RocDoomSim.scale(offset, 1 / distance)
	facing = listener.angle.forward()
	right = { x: facing.y, y: 0 - facing.x }
	pan = F32.max(-1, F32.min(1, RocDoomSim.dot(direction, right)))
	volume = F32.max(0, F32.min(1, 1 - distance / spatial_max_distance))
	{ pan, volume }
}

play_cue! : Sounds, Cue, Listener => {}
play_cue! = |sounds, cue, listener|
	match cue {
		LocalCue(kind) => match kind {
			FireSound => sounds.fire.play!()
			PickupSound => sounds.pickup.play!()
			OofSound => sounds.oof.play!()
			NoWaySound => sounds.no_way.play!()
		}
		SpatialCue(kind, source) => {
			settings = spatialize(listener, source)
			sound = match kind {
				PainSound => sounds.pain
				DeathSound => sounds.death
				AlertSound => sounds.alert
				DoorSound => sounds.door
				SwitchOnSound => sounds.switch_on
				SwitchOffSound => sounds.switch_off
				MonsterAttackSound => sounds.monster_attack
				ProjectileSound => sounds.projectile
				ExplosionSound => sounds.explosion
				PlatformSound => sounds.platform_move
			}
			sound.playback().with_pan(settings.pan).with_volume(settings.volume).play!()
		}
	}

max_cues_per_cycle = 16.U64

spatial_max_distance = 1200

load_sounds! = || {
	base = "examples/roc-doom-e1m1/assets/freedoom/generated/e1m1/sounds"
	fire = Audio.load_sound!("${base}/weapon_pistol.wav")?
	pickup = Audio.load_sound!("${base}/pickup_item.wav")?
	pain = Audio.load_sound!("${base}/monster_former_human_pain.wav")?
	death = Audio.load_sound!("${base}/monster_former_human_death_1.wav")?
	alert = Audio.load_sound!("${base}/monster_former_human_sight_1.wav")?
	door = Audio.load_sound!("${base}/world_door_open.wav")?
	switch_on = Audio.load_sound!("${base}/world_switch_on.wav")?
	switch_off = Audio.load_sound!("${base}/world_switch_off.wav")?
	monster_attack = Audio.load_sound!("${base}/monster_imp_ranged_attack.wav")?
	projectile = Audio.load_sound!("${base}/effect_imp_projectile.wav")?
	explosion = Audio.load_sound!("${base}/effect_imp_explosion.wav")?
	oof = Audio.load_sound!("${base}/player_oof.wav")?
	no_way = Audio.load_sound!("${base}/player_no_way.wav")?
	platform_move = Audio.load_sound!("${base}/world_platform_move.wav")?
	music = Audio.load_music!("examples/roc-doom-e1m1/assets/freedoom/generated/e1m1/music/e1m1.wav")?
	music.set_looping!(Bool.True)
	music.set_volume!(0.45)
	music.play!()
	Ok({ fire, pickup, pain, death, alert, door, switch_on, switch_off, monster_attack, projectile, explosion, oof, no_way, platform_move, music })
}

expect signed_command(Bool.True, Bool.False, 50) == 50
	and signed_command(Bool.False, Bool.True, 50) == -50
		and signed_command(Bool.True, Bool.True, 50) == 0

expect {
	player = RocDoomWorld.player({ x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0))
	doom : RocDoomWorld.World
	doom = { player, actors: [], pickups: [], rng: RocDoomWorld.Rng.seed(0) }
	world = RocDoomRuntime.initial(doom)
	cues = transition_cues(world, world, NotUsable, Bool.True, Bool.False)
	List.len(cues) == 1 and match List.get(cues, 0) {
		Ok(LocalCue(FireSound)) => Bool.True
		_ => Bool.False
	}
}

expect {
	listener = { pos: { x: 0, y: 0 }, angle: RocDoomSim.Angle.from_turns(0) }
	right = spatialize(listener, { x: 0, y: -64 })
	left = spatialize(listener, { x: 0, y: 64 })
	near = spatialize(listener, { x: 32, y: 0 })
	far = spatialize(listener, { x: spatial_max_distance, y: 0 })
	right.pan > 0.99 and left.pan < -0.99 and near.volume > 0.9 and far.volume == 0
}

expect {
	listener = { pos: { x: 10, y: 20 }, angle: RocDoomSim.Angle.from_turns(0.25) }
	centered = spatialize(listener, listener.pos)
	centered.pan == 0 and centered.volume == 1 and max_cues_per_cycle == 16
}
