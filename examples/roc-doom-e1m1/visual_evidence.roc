## Native visual-evidence harness for the navigable Freedoom E1M1.
## Renders from its real Doom map lumps. The app owns
## player simulation and map policy in Roc; the host retains textures and draws
## bounded borrowed triangle batches derived by E1M1Renderer.
app [Model, program] {
	rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst",
	roc: "nightly-2026-08-26-b29bef3",
}

import rr.App
import rr.Assets
import rr.Audio
import rr.Camera
import rr.Capture
import rr.Color
import rr.Draw
import rr.Keys
import rr.Mouse
import rr.Stdout
import rr.Task
import RocDoomControls
import RocDoomLevel
import RocDoomMap
import RocDoomPresentation
import RocDoomRuntime
import RocDoomSim
import RocDoomSprites
import RocDoomView
import RocDoomWorld
import E1M1Renderer
import "sprite_cutout.fs" as sprite_fragment_shader : Str

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
	sounds : Sounds,
	evidence : Evidence,
}

Evidence : { active : Bool, long : Bool, stage : U64, tic : U64, mouse_x : F32, requested : List(Str), saved : U64, hold_until : U64, start_pos : RocDoomSim.Vec2, start_angle : RocDoomSim.Angle }

Sounds : { fire : Audio.Sound, pickup : Audio.Sound, pain : Audio.Sound, death : Audio.Sound, alert : Audio.Sound, door : Audio.Sound, switch_on : Audio.Sound, switch_off : Audio.Sound, monster_attack : Audio.Sound, projectile : Audio.Sound, explosion : Audio.Sound, oof : Audio.Sound, no_way : Audio.Sound, platform_move : Audio.Sound, music : Audio.Music }

Cue : [FireCue, PickupCue, PainCue, DeathCue, AlertCue, DoorCue, SwitchOnCue, SwitchOffCue, MonsterAttackCue, ProjectileCue, ExplosionCue, OofCue, NoWayCue, PlatformCue]

Msg : [EvidenceSaved]

program = { init!, update!, render! }

init! : App.Init(Model, _)
init! = App.init_for_args(
	|args| {
		evidence = List.contains(args, "--capture-evidence")
		long_evidence = List.contains(args, "--long-evidence")
		cursor_mode : Mouse.CursorMode
		cursor_mode = if evidence Visible else Locked
		config = App.default
			.with_title("RocRay: Freedoom E1M1")
			.with_size(if evidence { width: 320, height: 200 } else { width: 1280, height: 720 })
			.with_frame_pacing(if evidence Uncapped else VSync)
			.with_visible(!(evidence))
			.with_output_dir("examples/roc-doom-e1m1/evidence")
			.with_cursor_mode(cursor_mode)
		if evidence {
			config.with_recording(
				Capture.default
					.with_path(if long_evidence "doom-scripted-long.webm" else "doom-scripted-fast.webm")
					.with_format(WebM)
					.with_fps(35)
					.with_max_frames(0)
					.with_scale(Full)
					.with_timing(FixedStep)
					.with_cursor(NoCursor),
			)
		} else {
			config
		}
	},
	|startup| {
		evidence_active = List.contains(App.args!(startup), "--capture-evidence")
		store = Assets.Store.open!(Assets.working_directory("examples/roc-doom-e1m1/assets"))?
		world_atlas = Assets.load_texture!(store, "freedoom/generated/e1m1/world_atlas.png")?
		sprite_atlas = Assets.load_texture!(store, "freedoom/generated/e1m1/sprite_atlas.png")?
		Assets.set_texture_filter!(world_atlas, Point)
		Assets.set_texture_filter!(sprite_atlas, Point)
		sprite_shader = Draw.Shader.from_source!({ vertex_source: "", fragment_source: sprite_fragment_shader })?
		logical_target = Draw.load_render_texture!({ width: 320.I32, height: 200.I32 })?
		sounds = load_sounds!()?

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
		Ok({ world, decorations, level, blockers, batches, masked_batches, dynamic_batches, masked_dynamic_batches, sprites, world_atlas, sprite_atlas, sprite_shader, logical_target, flashes: RocDoomView.initial, sounds, evidence: { active: evidence_active, long: List.contains(App.args!(startup), "--long-evidence"), stage: 0, tic: 0, mouse_x: 100, requested: [], saved: 0, hold_until: 0, start_pos: position, start_angle: angle } })
	},
)

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	saved = model.evidence.saved + List.len(input.messages)
	model0 = { ..model, evidence: { ..model.evidence, saved } }
	if model0.evidence.active {
		update_evidence!(model0, input)
	} else if input.devices.key_pressed(KeyEscape) {
		Err(Exit(0))
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
		Ok({ ..model, world, decorations, level, blockers, dynamic_batches, masked_dynamic_batches, sprites, flashes: RocDoomView.initial })
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
		turn = RocDoomControls.turn(input.devices.mouse.delta().x)
		fire = input.devices.mouse.button_down(Left) or input.devices.key_down(KeySpace)
		weapon_slot = if input.devices.key_pressed(Key2) SelectSlot(2) else if input.devices.key_pressed(Key3) SelectSlot(3) else if input.devices.key_pressed(Key4) SelectSlot(4) else if input.devices.key_pressed(Key5) SelectSlot(5) else if input.devices.key_pressed(Key6) SelectSlot(6) else if input.devices.key_pressed(Key8) SelectSlot(8) else KeepWeapon
		previous_pos = model.world.doom.player.sim.state.pos
		extra_blockers = decoration_segments(model.decorations)
		advanced = RocDoomRuntime.advance_in_map(model.world, input.time.elapsed_seconds, { forward, side, turn, fire, weapon_slot }, extra_blockers, RocDoomMap.e1m1, model.level)
		crossed = RocDoomRuntime.cross_specials(RocDoomMap.e1m1, advanced.level, previous_pos, advanced.world.doom.player.sim.state.pos)
		use_result = if input.devices.key_pressed(KeyE) {
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
		for cue in transition_cues(model.world, world, use_result, advanced.fired, input.devices.key_pressed(KeyE)) {
			play_cue!(model.sounds, cue)
		}
		Ok({ ..model, world, level, blockers, dynamic_batches, masked_dynamic_batches, sprites, flashes })
	}
}

update_evidence! = |model, input| {
	required = if model.evidence.long 13 else 12
	# A capture task completes only after the returned model has had a
	# presentation frame. Never place the next scenario while that task is
	# outstanding: the PNG and the JSON record must describe the same model.
	if model.evidence.stage == 26 {
		match input.capture {
			Finished(_) => Err(Exit(0))
			Failed(_) => Err(Exit(4))
			_ => Ok(model)
		}
	} else if model.evidence.saved < List.len(model.evidence.requested) {
		Ok(model)
	} else if input.time.cycle_count < model.evidence.hold_until {
		# Give each diagnostic viewpoint enough screen time to be legible when
		# this same run is shared as a video, without changing its simulation.
		Ok(model)
	} else if model.evidence.saved >= required {
		# Finalize explicitly and wait for the following sampled status. This
		# makes a successful exit proof that the shareable WebM was closed.
		Capture.stop!()
		Ok({ ..model, evidence: { ..model.evidence, stage: 26 } })
	} else if input.time.cycle_count > 1400 {
		Err(Exit(2))
	} else if model.evidence.stage == 0 {
		if !(valid_spawn(model)) return Err(Exit(3))
		next = capture_state!(model, input, "spawn")
		Ok({ ..next, evidence: { ..next.evidence, stage: 1 } })
	} else if model.evidence.stage == 1 {
		Keys.set_source!(Keys.holding([KeyA]))
		Mouse.set_source!(Mouse.virtual_at({ x: 100, y: 80 }))
		Ok({ ..model, evidence: { ..model.evidence, stage: 2 } })
	} else if model.evidence.stage == 2 {
		next = advance_from_input(model, input)
		delta = RocDoomSim.sub(next.world.doom.player.sim.state.pos, model.evidence.start_pos)
		if !(input.devices.key_pressed(KeyA) and input.devices.key_down(KeyA) and RocDoomSim.dot(delta, RocDoomControls.visual_right(model.evidence.start_angle)) < 0) return Err(Exit(3))
		captured = capture_state!(next, input, "strafe-left")
		Ok({ ..captured, evidence: { ..captured.evidence, stage: 3 } })
	} else if model.evidence.stage == 3 {
		Keys.set_source!(Keys.holding([KeyD]))
		reset = at_scenario(model, model.evidence.start_pos, model.evidence.start_angle)
		Ok({ ..reset, evidence: { ..reset.evidence, stage: 4 } })
	} else if model.evidence.stage == 4 {
		next = advance_from_input(model, input)
		delta = RocDoomSim.sub(next.world.doom.player.sim.state.pos, model.evidence.start_pos)
		if !(input.devices.key_released(KeyA) and input.devices.key_pressed(KeyD) and RocDoomSim.dot(delta, RocDoomControls.visual_right(model.evidence.start_angle)) > 0) return Err(Exit(3))
		captured = capture_state!(next, input, "strafe-right")
		Ok({ ..captured, evidence: { ..captured.evidence, stage: 5 } })
	} else if model.evidence.stage == 5 {
		Keys.set_source!(Keys.holding([]))
		Mouse.set_source!(Mouse.virtual_at({ x: 120, y: 80 }))
		reset = at_scenario(model, model.evidence.start_pos, model.evidence.start_angle)
		Ok({ ..reset, evidence: { ..reset.evidence, stage: 6, mouse_x: 120 } })
	} else if model.evidence.stage == 6 {
		next = advance_from_input(model, input)
		if !(input.devices.mouse.delta().x > 0 and RocDoomSim.dot(next.world.doom.player.sim.state.angle.forward(), RocDoomControls.visual_right(model.evidence.start_angle)) > 0) return Err(Exit(3))
		captured = capture_state!(next, input, "mouse-turn")
		Ok({ ..captured, evidence: { ..captured.evidence, stage: 7 } })
	} else if model.evidence.stage == 7 {
		# Face the intentional null-texture gap at linedef 1049. Both adjoining
		# ceilings are F_SKY1, so this view must reveal the sky enclosure rather
		# than the host's black clear colour.
		west_sky = at_scenario(model, { x: -600, y: 256 }, RocDoomSim.Angle.from_turns(0.5))
		Keys.set_source!(Keys.holding([]))
		Ok({ ..west_sky, evidence: { ..west_sky.evidence, stage: 8 } })
	} else if model.evidence.stage == 8 {
		captured = capture_state!(model, input, "west-sky-portal")
		Ok({ ..captured, evidence: { ..captured.evidence, stage: 9 } })
	} else if model.evidence.stage == 9 {
		corridor = at_scenario(model, { x: -288, y: 256 }, RocDoomSim.Angle.from_turns(0))
		Keys.set_source!(Keys.holding([]))
		Ok({ ..corridor, evidence: { ..corridor.evidence, stage: 10 } })
	} else if model.evidence.stage == 10 {
		captured = capture_state!(model, input, "first-corridor-wall-hole")
		Ok({ ..captured, evidence: { ..captured.evidence, stage: 11 } })
	} else if model.evidence.stage == 11 {
		Keys.set_source!(Keys.holding([KeyW]))
		Ok({ ..model, evidence: { ..model.evidence, stage: 12 } })
	} else if model.evidence.stage == 12 {
		next = advance_from_input(model, input)
		if current_sector(next) == 141 {
			captured = capture_state!(next, input, "open-portal-collision")
			Ok({ ..captured, evidence: { ..captured.evidence, stage: 13 } })
		} else {
			Keys.set_source!(Keys.holding([KeyW]))
			Ok(next)
		}
	} else if model.evidence.stage == 13 {
		# Stand inside sector 141 and look squarely through the eight-unit portal
		# throat formed by linedefs 836 and 846 into sector 91. This is the close
		# view implicated by the manually reported black wall void.
		aperture = at_scenario(model, { x: -208, y: 256 }, RocDoomSim.Angle.from_turns(0))
		Keys.set_source!(Keys.holding([]))
		Ok({ ..aperture, evidence: { ..aperture.evidence, stage: 14 } })
	} else if model.evidence.stage == 14 {
		captured = capture_state!(model, input, "sector141-aperture")
		Ok({ ..captured, evidence: { ..captured.evidence, stage: 15 } })
	} else if model.evidence.stage == 15 {
		colu = at_scenario(model, { x: 752, y: 608 }, RocDoomSim.Angle.from_turns(0.5))
		Keys.set_source!(Keys.holding([KeyW]))
		Ok({ ..colu, evidence: { ..colu.evidence, stage: 16 } })
	} else if model.evidence.stage == 16 {
		next = advance_from_input(model, input)
		if next.world.doom.player.sim.state.tic >= 7 {
			captured = capture_state!(next, input, "colu-portal-navigation")
			Ok({ ..captured, evidence: { ..captured.evidence, stage: 17 } })
		} else {
			Keys.set_source!(Keys.holding([KeyW]))
			Ok(next)
		}
	} else if model.evidence.stage == 17 {
		door = at_scenario(model, { x: 832, y: 496 }, RocDoomSim.Angle.from_turns(0.25))
		Keys.set_source!(Keys.holding([]))
		Ok({ ..door, evidence: { ..door.evidence, stage: 18 } })
	} else if model.evidence.stage == 18 {
		captured = capture_state!(model, input, "door-closed")
		Ok({ ..captured, evidence: { ..captured.evidence, stage: 19 } })
	} else if model.evidence.stage == 19 {
		Keys.set_source!(Keys.holding([KeyE]))
		Ok({ ..model, evidence: { ..model.evidence, stage: 20 } })
	} else if model.evidence.stage == 20 {
		next = advance_from_input(model, input)
		if List.is_empty(next.level.doors) return Err(Exit(3))
		if next.world.doom.player.sim.state.tic >= 20 {
			captured = capture_state!(next, input, "door-open")
			Ok({ ..captured, evidence: { ..captured.evidence, stage: 21 } })
		} else {
			Keys.set_source!(Keys.holding([]))
			Ok(next)
		}
	} else if model.evidence.stage == 21 {
		Keys.set_source!(Keys.holding([KeySpace]))
		Ok({ ..model, evidence: { ..model.evidence, stage: 22 } })
	} else if model.evidence.stage == 22 {
		next = advance_from_input(model, input)
		if next.world.weapon.phase == 0 return Err(Exit(3))
		captured = capture_state!(next, input, "combat")
		Ok({ ..captured, evidence: { ..captured.evidence, stage: 23 } })
	} else if model.evidence.stage == 23 {
		if model.evidence.long {
			damage = at_scenario(model, { x: 1258, y: 949 }, RocDoomSim.Angle.from_turns(0.044))
			Keys.set_source!(Keys.holding([KeyW]))
			Ok({ ..damage, evidence: { ..damage.evidence, stage: 24 } })
		} else {
			Keys.set_source!(Keys.holding([]))
			Ok({ ..model, evidence: { ..model.evidence, stage: 25 } })
		}
	} else if model.evidence.stage == 24 {
		next = advance_from_input(model, input)
		sector = current_sector(next)
		special = (List.get(RocDoomMap.e1m1.raw().sectors, sector) ?? crash "validated sector missing").special
		if special == 7 {
			captured = capture_state!(next, input, "damaging-floor")
			Keys.set_source!(Keys.holding([]))
			Ok({ ..captured, evidence: { ..captured.evidence, stage: 25 } })
		} else {
			Keys.set_source!(Keys.holding([KeyW]))
			Ok(next)
		}
	} else {
		Ok(model)
	}
}

advance_from_input = |model, input| {
	forward = signed_command(Keys.key_down(input.devices, KeyW) or Keys.key_down(input.devices, KeyUp), Keys.key_down(input.devices, KeyS) or Keys.key_down(input.devices, KeyDown), 50)
	side = RocDoomControls.side(Keys.key_down(input.devices, KeyA) or Keys.key_down(input.devices, KeyLeft), Keys.key_down(input.devices, KeyD) or Keys.key_down(input.devices, KeyRight))
	command = { ..RocDoomSim.neutral, forward, side, turn: RocDoomControls.turn(input.devices.mouse.delta().x), fire: input.devices.mouse.button_down(Left) or Keys.key_down(input.devices, KeySpace), weapon_slot: evidence_weapon_slot(input.devices) }
	previous_pos = model.world.doom.player.sim.state.pos
	extra_blockers = decoration_segments(model.decorations)
	advanced = RocDoomRuntime.advance_in_map(model.world, RocDoomSim.tic_seconds * 1.0001, command, extra_blockers, RocDoomMap.e1m1, model.level)
	crossed = RocDoomRuntime.cross_specials(RocDoomMap.e1m1, advanced.level, previous_pos, advanced.world.doom.player.sim.state.pos)
	use_result = if Keys.key_pressed(input.devices, KeyE) RocDoomRuntime.use_forward(RocDoomMap.e1m1, crossed.level, advanced.world.doom.player.sim.state.pos, advanced.world.doom.player.sim.state.angle, advanced.world.doom.player.keys) else NotUsable
	level0 = match use_result {
		Activated(value) => value
		_ => crossed.level
	}
	world = if crossed.exited { ..advanced.world, phase: Exited } else advanced.world
	level = advance_level(level0, advanced.tics)
	dynamic_changed = RocDoomLevel.render_changed(RocDoomMap.e1m1, model.level, level)
	dynamic_batches = if dynamic_changed List.map(E1M1Renderer.build_dynamic(RocDoomMap.e1m1, level) ?? crash "generated dynamic E1M1 atlas is incomplete", render_geometry) else model.dynamic_batches
	masked_dynamic_batches = if dynamic_changed List.map(E1M1Renderer.build_masked_dynamic(RocDoomMap.e1m1, level) ?? crash "generated dynamic masked E1M1 atlas is incomplete", render_geometry) else model.masked_dynamic_batches
	sprites = sprite_geometry(world, model.decorations, level, world.doom.player.sim.state.pos)
	blockers = List.concat(RocDoomRuntime.blockers_for_player(RocDoomMap.e1m1, level, world.doom.player.sim.state.pos), extra_blockers)
	{ ..model, world, level, blockers, dynamic_batches, masked_dynamic_batches, sprites }
}

evidence_weapon_slot = |devices|
	if Keys.key_pressed(devices, Key2) SelectSlot(2) else if Keys.key_pressed(devices, Key3) SelectSlot(3) else if Keys.key_pressed(devices, Key4) SelectSlot(4) else if Keys.key_pressed(devices, Key5) SelectSlot(5) else if Keys.key_pressed(devices, Key6) SelectSlot(6) else if Keys.key_pressed(devices, Key8) SelectSlot(8) else KeepWeapon

reset_world = |_model| {
	start = RocDoomMap.e1m1.player_start() ?? crash "validated E1M1 player start missing"
	position = { x: I64.to_f32(start.position.x), y: I64.to_f32(start.position.y) }
	angle = RocDoomSim.Angle.from_turns(I64.to_f32(start.angle) / 360)
	(initial_runtime(RocDoomMap.e1m1, position, angle)).world
}

at_scenario = |model, pos, angle| {
	# Evidence-only scenario placement is the remaining adapter duplication. It
	# selects a stable E1M1 viewpoint; every movement, use, turn, collision and
	# attack after placement still enters through sampled virtual devices and the
	# same advance_from_input/runtime path as the playable app.
	player = model.world.doom.player
	world = { ..model.world, doom: { ..model.world.doom, player: { ..player, sim: RocDoomSim.clock(RocDoomSim.initial(pos, angle)) } } }
	level = RocDoomLevel.initial(RocDoomMap.e1m1)
	blockers = List.concat(RocDoomRuntime.blockers_for_player(RocDoomMap.e1m1, level, pos), decoration_segments(model.decorations))
	dynamic_batches = List.map(E1M1Renderer.build_dynamic(RocDoomMap.e1m1, level) ?? crash "generated dynamic E1M1 atlas is incomplete", render_geometry)
	masked_dynamic_batches = List.map(E1M1Renderer.build_masked_dynamic(RocDoomMap.e1m1, level) ?? crash "generated dynamic masked E1M1 atlas is incomplete", render_geometry)
	{ ..model, world, level, blockers, dynamic_batches, masked_dynamic_batches, sprites: sprite_geometry(world, model.decorations, level, pos), flashes: RocDoomView.initial }
}

valid_spawn = |model| {
	sector = current_sector(model)
	heights = RocDoomLevel.heights_for(model.level, sector) ?? crash "start sector missing"
	model.world.doom.player.health == 100 and sector == 140 and heights.floor == 0 and heights.ceiling == 128
}

current_sector = |model|
	RocDoomLevel.sector_at(RocDoomMap.e1m1, { x: F32.to_f64(model.world.doom.player.sim.state.pos.x), y: F32.to_f64(model.world.doom.player.sim.state.pos.y) }) ?? crash "evidence player outside BSP"

capture_state! = |model, input, checkpoint| {
	sector = current_sector(model)
	heights = RocDoomLevel.heights_for(model.level, sector) ?? crash "evidence sector missing"
	special = (List.get(RocDoomMap.e1m1.raw().sectors, sector) ?? crash "validated sector missing").special
	line = nearest_blocking_line(model, sector)
	state = model.world.doom.player.sim.state
	_ = Stdout.line!("{\"checkpoint\":\"${checkpoint}\",\"cycle\":${U64.to_str(input.time.cycle_count)},\"tic\":${U64.to_str(state.tic)},\"x\":${F32.to_str(state.pos.x)},\"y\":${F32.to_str(state.pos.y)},\"angle\":${F32.to_str(state.angle.turns())},\"sector\":${U64.to_str(sector)},\"floor\":${I64.to_str(heights.floor)},\"ceiling\":${I64.to_str(heights.ceiling)},\"special\":${U64.to_str(special)},\"health\":${I64.to_str(model.world.doom.player.health)},\"blocking_linedef\":${U64.to_str(line)}}")
	Task.spawn!(
		input,
		|| {
			_ = Capture.screenshot!("${checkpoint}.png")
			EvidenceSaved
		},
	)
	{ ..model, evidence: { ..model.evidence, requested: List.append(model.evidence.requested, checkpoint), hold_until: input.time.cycle_count + 18 } }
}

nearest_blocking_line = |model, sector| {
	segments = RocDoomLevel.collision_segments(RocDoomMap.e1m1, model.level, sector)
	pos = model.world.doom.player.sim.state.pos
	var $best = 1000000000000000000000000000000
	var $line = 18446744073709551615.U64
	for segment in segments {
		converted = { start: { x: F64.to_f32_wrap(segment.start.x), y: F64.to_f32_wrap(segment.start.y) }, end: { x: F64.to_f32_wrap(segment.end.x), y: F64.to_f32_wrap(segment.end.y) } }
		distance = RocDoomSim.distance_to_segment_squared(pos, converted)
		if distance < $best {
			$best = distance
			$line = segment.linedef
		}
	}
	$line
}

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

draw_logical! = |model, frame| {
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
	Ok({})
}

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
				width = U64.to_f32(view.rect.width)
				height = U64.to_f32(view.rect.height)
				bob = world.doom.player.sim.state.view
				frame.texture!({ texture: atlas, source: atlas_rect(view.rect), dest: { x: size.width * 0.5 - width * 0.5 + bob.weapon_x, y: size.height - height - hud_height + bob.weapon_y + bob.weapon_kick, width, height }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
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
	draw_number!(frame, atlas, I64.max(0, ammo), 43, size.height - 29)
	draw_number!(frame, atlas, I64.max(0, player.health), 90, size.height - 29)
	draw_weapons!(frame, atlas, player, size)
	frame.text_at!({ pos: { x: 184, y: size.height - 12 }, text: "S:${U64.to_str(world.secrets_found)}", size: 8, color: Color.ray_white })
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
	frame.texture!({ texture: atlas, source: atlas_rect(face), dest: { x: 143, y: size.height - 30, width: 36, height: 30 }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
	draw_keys!(frame, atlas, player.keys, size)
	frame.line!({ start: { x: size.width * 0.5 - 6, y: size.height * 0.5 }, end: { x: size.width * 0.5 + 6, y: size.height * 0.5 }, stroke: Draw.stroke(Color.white, 1) })
	frame.line!({ start: { x: size.width * 0.5, y: size.height * 0.5 - 6 }, end: { x: size.width * 0.5, y: size.height * 0.5 + 6 }, stroke: Draw.stroke(Color.white, 1) })
	match world.phase {
		Playing => {}
		Dead => overlay!(frame, size, "YOU DIED", "Press R to restart")
		Exited => overlay!(frame, size, "LEVEL COMPLETE", "Press R to restart")
	}
}

draw_weapons! = |frame, atlas, player, size| {
	arms = RocDoomPresentation.hud(Arms) ?? crash "status arms sprite missing"
	frame.texture!({ texture: atlas, source: atlas_rect(arms), dest: { x: 104, y: size.height - 32, width: 32, height: 10 }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
	slots = [{ slot: 2.U8, owned: player.weapons.pistol }, { slot: 3.U8, owned: player.weapons.shotgun }, { slot: 4.U8, owned: player.weapons.chaingun }, { slot: 5.U8, owned: player.weapons.rocket_launcher }, { slot: 6.U8, owned: player.weapons.plasma_rifle }, { slot: 8.U8, owned: player.weapons.chainsaw }]
	for item in List.map_with_index(slots, |value, index| { value, index }) {
		element = if item.value.owned SmallDigit(item.value.slot) else GrayDigit(item.value.slot)
		match RocDoomPresentation.hud(element) {
			Ok(rect) => frame.texture!({ texture: atlas, source: atlas_rect(rect), dest: { x: 106 + U64.to_f32(item.index % 3) * 10, y: size.height - 20 + U64.to_f32(item.index / 3) * 9, width: 8, height: 7 }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
			Err(_) => {}
		}
	}
}

draw_number! = |frame, atlas, value, x, y| {
	n = I64.min(999, value)
	digits = [I64.to_u8_wrap(n / 100), I64.to_u8_wrap((n / 10) % 10), I64.to_u8_wrap(n % 10)]
	for entry in List.map_with_index(digits, |digit, index| { digit, index }) {
		match RocDoomPresentation.hud(LargeDigit(entry.digit)) {
			Ok(rect) => frame.texture!({ texture: atlas, source: atlas_rect(rect), dest: { x: x + U64.to_f32(entry.index) * 14, y, width: 14, height: 18 }, origin: { x: 0, y: 0 }, rotation: 0, tint: Color.white })
			Err(_) => {}
		}
	}
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

signed_command : Bool, Bool, I16 -> I16
signed_command = |positive, negative, magnitude|
	if positive and !(negative) magnitude else if negative and !(positive) 0 - magnitude else 0

advance_level = |level, tics| if tics == 0 level else advance_level(RocDoomLevel.tick(level), tics - 1)

logical_width = 320

logical_height = 200

hud_height = 32

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

transition_cues = |before, after, use_result, fired, used| {
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
	if attack_count(after.doom.actors) > attack_count(before.doom.actors) {
		$cues = List.append($cues, MonsterAttackCue)
	}
	if List.len(after.projectiles) > List.len(before.projectiles) {
		$cues = List.append($cues, ProjectileCue)
	}
	if List.len(after.explosions) > List.len(before.explosions) {
		$cues = List.append($cues, ExplosionCue)
	}
	if after.doom.player.health < before.doom.player.health {
		$cues = List.append($cues, OofCue)
	}
	match use_result {
		Activated(_) => {
			$cues = List.append($cues, DoorCue)
			$cues = List.append($cues, SwitchOnCue)
			$cues = List.append($cues, PlatformCue)
		}
		_ => if used {
			$cues = List.append($cues, NoWayCue)
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
		MonsterAttackCue => sounds.monster_attack.play!()
		ProjectileCue => sounds.projectile.play!()
		ExplosionCue => sounds.explosion.play!()
		OofCue => sounds.oof.play!()
		NoWayCue => sounds.no_way.play!()
		PlatformCue => sounds.platform_move.play!()
	}

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
		Ok(FireCue) => Bool.True
		_ => Bool.False
	}
}
