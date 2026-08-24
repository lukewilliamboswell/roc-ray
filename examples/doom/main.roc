## Navigable Freedoom E1M1 rendered from its real Doom map lumps. The app owns
## player simulation and map policy in Roc; the host retains textures and draws
## bounded borrowed triangle batches derived by E1M1Renderer.
app [Model, program] {
	rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst",
	roc: "nightly-2026-08-23-fb208ba",
}

import rr.App
import rr.Assets
import rr.Audio
import rr.Camera
import rr.Color
import rr.Draw
import DoomLevel
import DoomMap
import DoomPresentation
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
	world : DoomRuntime.World,
	level : DoomLevel.State,
	blockers : List(DoomSim.Segment),
	batches : List(RenderGeometry),
	world_atlas : Draw.Texture,
	sprite_atlas : Draw.Texture,
	sprite_shader : Draw.Shader,
	sounds : Sounds,
}

Sounds : { fire : Audio.Sound, pickup : Audio.Sound, pain : Audio.Sound, death : Audio.Sound, alert : Audio.Sound, door : Audio.Sound, switch_on : Audio.Sound, switch_off : Audio.Sound }

Cue : [FireCue, PickupCue, PainCue, DeathCue, AlertCue, DoorCue, SwitchOnCue, SwitchOffCue]

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
		sounds = load_sounds!()?

		map = DoomMap.e1m1
		start = map.player_start() ?? crash "validated E1M1 must contain exactly one player start"
		mesh_batches = E1M1Renderer.build_static(map) ?? crash "generated E1M1 atlas is incomplete"
		batches = List.map(mesh_batches, render_geometry)
		position = { x: I64.to_f32(start.position.x), y: I64.to_f32(start.position.y) }
		angle = DoomSim.Angle.from_turns(I64.to_f32(start.angle) / 360)
		world = initial_runtime(map, position, angle)
		level = DoomLevel.initial(map)
		blockers = List.map(
			map.blocking_segments(),
			|segment| {
				start: { x: I64.to_f32(segment.start.x), y: I64.to_f32(segment.start.y) },
				end: { x: I64.to_f32(segment.end.x), y: I64.to_f32(segment.end.y) },
			},
		)
		Ok({ world, level, blockers, batches, world_atlas, sprite_atlas, sprite_shader, sounds })
	},
)

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	if input.devices.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else if input.devices.key_pressed(KeyR) {
		start = DoomMap.e1m1.player_start() ?? crash "validated E1M1 player start missing"
		position = { x: I64.to_f32(start.position.x), y: I64.to_f32(start.position.y) }
		angle = DoomSim.Angle.from_turns(I64.to_f32(start.angle) / 360)
		world = initial_runtime(DoomMap.e1m1, position, angle)
		level = DoomLevel.initial(DoomMap.e1m1)
		blockers = DoomRuntime.blockers_for_player(DoomMap.e1m1, level, position)
		Ok({ ..model, world, level, blockers })
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
		fire = input.devices.mouse.button_down(Left) or input.devices.key_down(KeySpace)
		previous_pos = model.world.doom.player.sim.state.pos
		blockers = DoomRuntime.blockers_for_player(DoomMap.e1m1, model.level, previous_pos)
		advanced = DoomRuntime.advance(model.world, input.time.elapsed_seconds, { forward, side, turn, fire }, blockers)
		crossed = DoomRuntime.cross_specials(DoomMap.e1m1, model.level, previous_pos, advanced.world.doom.player.sim.state.pos)
		use_result = if input.devices.key_pressed(KeyE) {
			DoomRuntime.use_forward(DoomMap.e1m1, crossed.level, advanced.world.doom.player.sim.state.pos, advanced.world.doom.player.sim.state.angle, advanced.world.doom.player.keys)
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
		for cue in transition_cues(model.world, world, use_result, advanced.fired) {
			play_cue!(model.sounds, cue)
		}
		Ok({ ..model, world, level, blockers })
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ScopeUnavailable, ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x101010))
	state = model.world.doom.player.sim.state
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
			dynamic_batches = E1M1Renderer.build_dynamic(DoomMap.e1m1, model.level) ?? crash "generated dynamic E1M1 atlas is incomplete"
			for batch in dynamic_batches {
				dynamic = render_geometry(batch)
				scene.textured_triangles_3d!({ texture: model.world_atlas, vertices: dynamic.vertices, indices: dynamic.indices })
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
	draw_weapon!(frame, model.sprite_atlas, model.world)
	draw_hud!(frame, model.sprite_atlas, model.world)
	Ok({})
}

sprite_geometry : DoomRuntime.World, DoomLevel.State, DoomSim.Vec2 -> RenderGeometry
sprite_geometry = |world, level, viewer| {
	var $geometry = { vertices: [], indices: [] }
	for actor in world.doom.actors {
		primitive = DoomSprites.actor_geometry(actor, viewer) ?? crash "generated E1M1 actor has no sprite mapping"
		$geometry = append_sprite($geometry, place_on_floor(render_sprite_geometry(primitive), level, actor.pos))
	}
	for pickup in world.doom.pickups {
		match DoomSprites.pickup_geometry(pickup, viewer, world.doom.player.sim.state.tic) ?? crash "generated E1M1 pickup has no sprite mapping" {
			Visible(primitive) => {
				$geometry = append_sprite($geometry, place_on_floor(render_sprite_geometry(primitive), level, pickup.pos))
			}
			Hidden => {}
		}
	}
	for projectile in world.projectiles {
		primitive = DoomSprites.effect_geometry(ImpProjectile, projectile.pos, viewer, world.doom.player.sim.state.tic) ?? crash "Imp projectile sprite missing"
		$geometry = append_sprite($geometry, place_above_floor(render_sprite_geometry(primitive), level, projectile.pos, 24))
	}
	for explosion in world.explosions {
		phase = (DoomRuntime.explosion_lifetime - explosion.remaining) / 3
		primitive = DoomSprites.effect_geometry(ImpExplosion, explosion.pos, viewer, phase) ?? crash "Imp explosion sprite missing"
		$geometry = append_sprite($geometry, place_above_floor(render_sprite_geometry(primitive), level, explosion.pos, 20))
	}
	$geometry
}

place_on_floor = |geometry, level, pos| {
	place_above_floor(geometry, level, pos, 0)
}

place_above_floor = |geometry, level, pos, above| {
	sector = DoomLevel.sector_at(DoomMap.e1m1, { x: F32.to_f64(pos.x), y: F32.to_f64(pos.y) })
	floor = match sector {
		Ok(index) => (DoomLevel.heights_for(level, index) ?? crash "sprite sector state missing").floor
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
	if world.phase == Playing {
		match DoomPresentation.weapon(world.doom.player.weapon, world.weapon.phase) {
			Ok(view) => {
				size = frame.size!()
				width = U64.to_f32(view.rect.width) * 3
				height = U64.to_f32(view.rect.height) * 3
				frame.texture!({ texture: atlas, source: atlas_rect(view.rect), dest: { x: size.width * 0.5 - width * 0.5, y: size.height - height - hud_height, width, height }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
			}
			Err(_) => {}
		}
	}
}

draw_hud! = |frame, atlas, world| {
	player = world.doom.player
	size = frame.size!()
	ammo = if player.weapon == Pistol player.ammo.bullets else player.ammo.shells
	bar = DoomPresentation.hud(StatusBar) ?? crash "generated status bar sprite missing"
	frame.texture!({ texture: atlas, source: atlas_rect(bar), dest: { x: size.width * 0.5 - 480, y: size.height - hud_height, width: 960, height: hud_height }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
	draw_number!(frame, atlas, I64.max(0, ammo), size.width * 0.5 - 430, size.height - 82)
	draw_number!(frame, atlas, I64.max(0, player.health), size.width * 0.5 - 270, size.height - 82)
	face = DoomPresentation.hud(Face("ST00")) ?? crash "generated status face sprite missing"
	frame.texture!({ texture: atlas, source: atlas_rect(face), dest: { x: size.width * 0.5 - 54, y: size.height - 96, width: 108, height: 90 }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
	draw_keys!(frame, atlas, player.keys, size)
	frame.line!({ start: { x: size.width * 0.5 - 6, y: size.height * 0.5 }, end: { x: size.width * 0.5 + 6, y: size.height * 0.5 }, stroke: Draw.stroke(Color.white, 1) })
	frame.line!({ start: { x: size.width * 0.5, y: size.height * 0.5 - 6 }, end: { x: size.width * 0.5, y: size.height * 0.5 + 6 }, stroke: Draw.stroke(Color.white, 1) })
	match world.phase {
		Playing => {}
		Dead => overlay!(frame, size, "YOU DIED", "Press R to restart")
		Exited => overlay!(frame, size, "LEVEL COMPLETE", "Press R to restart")
	}
}

draw_number! = |frame, atlas, value, x, y| {
	n = I64.min(999, value)
	digits = [I64.to_u8_wrap(n / 100), I64.to_u8_wrap((n / 10) % 10), I64.to_u8_wrap(n % 10)]
	for entry in List.map_with_index(digits, |digit, index| { digit, index }) {
		match DoomPresentation.hud(LargeDigit(entry.digit)) {
			Ok(rect) => frame.texture!({ texture: atlas, source: atlas_rect(rect), dest: { x: x + U64.to_f32(entry.index) * 42, y, width: 42, height: 54 }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
			Err(_) => {}
		}
	}
}

draw_keys! = |frame, atlas, keys, size| {
	flags = [{ present: keys.blue, index: 0.U8 }, { present: keys.yellow, index: 1.U8 }, { present: keys.red, index: 2.U8 }]
	for item in List.map_with_index(flags, |entry, slot| { entry, slot }) {
		if item.entry.present {
			match DoomPresentation.hud(Key(item.entry.index)) {
				Ok(rect) => frame.texture!({ texture: atlas, source: atlas_rect(rect), dest: { x: size.width * 0.5 + 300 + U64.to_f32(item.slot) * 42, y: size.height - 70, width: 36, height: 30 }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
				Err(_) => {}
			}
		}
	}
}

atlas_rect = |rect| { x: U64.to_f32(rect.x), y: U64.to_f32(rect.y), width: U64.to_f32(rect.width), height: U64.to_f32(rect.height) }

overlay! = |frame, size, title, subtitle| {
	frame.rectangle!({ x: 0, y: 0, width: size.width, height: size.height, style: Draw.filled(Color.with_alpha(Color.black, 165)) })
	frame.text_at!({ pos: { x: size.width * 0.5 - 150, y: size.height * 0.42 }, text: title, size: 36, color: Color.from_hex_rgb(0xd7433f) })
	frame.text_at!({ pos: { x: size.width * 0.5 - 100, y: size.height * 0.42 + 48 }, text: subtitle, size: 18, color: Color.ray_white })
}

initial_runtime = |map, position, angle| {
	spawned = DoomWorld.spawn(map.raw().things, Medium)
	doom : DoomWorld.World
	doom = { player: DoomWorld.player(position, angle), actors: spawned.actors, pickups: spawned.pickups, rng: DoomWorld.Rng.seed(0) }
	DoomRuntime.initial(doom)
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

hud_height = 96

transition_cues = |before, after, use_result, fired| {
	var $cues = if fired [FireCue] else []
	if taken_count(after.doom.pickups) > taken_count(before.doom.pickups) {
		$cues = List.append($cues, PickupCue)
	}
	if dead_count(after.doom.actors) > dead_count(before.doom.actors) {
		$cues = List.append($cues, DeathCue)
	} else if actor_health(after.doom.actors) < actor_health(before.doom.actors) {
		$cues = List.append($cues, PainCue)
	}
	if awake_count(after.doom.actors) > awake_count(before.doom.actors) {
		$cues = List.append($cues, AlertCue)
	}
	match use_result {
		Activated(_) => {
			$cues = List.append($cues, DoorCue)
			$cues = List.append($cues, SwitchOnCue)
		}
		_ => {}
	}
	$cues
}

taken_count = |pickups| List.len(List.keep_if(pickups, |pickup| pickup.taken))

dead_count = |actors| List.len(List.keep_if(actors, |actor| actor.state.mode == Dead))

awake_count = |actors| List.len(List.keep_if(actors, |actor| actor.state.mode != Look and actor.state.mode != Dead))

actor_health = |actors| List.fold(actors, 0.I64, |total, actor| total + actor.health)

play_cue! = |sounds, cue|
	match cue {
		FireCue => sounds.fire.play!()
		PickupCue => sounds.pickup.play!()
		PainCue => sounds.pain.play!()
		DeathCue => sounds.death.play!()
		AlertCue => sounds.alert.play!()
		DoorCue => sounds.door.play!()
		SwitchOnCue => sounds.switch_on.play!()
		SwitchOffCue => sounds.switch_off.play!()
	}

load_sounds! = || {
	base = "examples/doom/assets/freedoom/generated/audio"
	fire = Audio.load_sound!("${base}/pistol.wav")?
	pickup = Audio.load_sound!("${base}/pickup.wav")?
	pain = Audio.load_sound!("${base}/enemy_pain.wav")?
	death = Audio.load_sound!("${base}/enemy_die.wav")?
	alert = Audio.load_sound!("${base}/enemy_alert.wav")?
	door = Audio.load_sound!("${base}/door_move.wav")?
	switch_on = Audio.load_sound!("${base}/switch_on.wav")?
	switch_off = Audio.load_sound!("${base}/switch_off.wav")?
	Ok({ fire, pickup, pain, death, alert, door, switch_on, switch_off })
}

expect signed_command(Bool.True, Bool.False, 50) == 50
	and signed_command(Bool.False, Bool.True, 50) == -50
		and signed_command(Bool.True, Bool.True, 50) == 0

expect {
	player = DoomWorld.player({ x: 0, y: 0 }, DoomSim.Angle.from_turns(0))
	doom : DoomWorld.World
	doom = { player, actors: [], pickups: [], rng: DoomWorld.Rng.seed(0) }
	world = DoomRuntime.initial(doom)
	transition_cues(world, world, NotUsable, Bool.True) == [FireCue]
}
