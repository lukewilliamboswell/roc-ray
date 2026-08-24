app [Model, program] {
	rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst",
	roc: "nightly-2026-08-23-fb208ba",
}

import rr.App
import rr.Assets
import rr.Color
import rr.Draw
import rr.Math
import rr.Text

## A sprite fountain that draws every particle in a single hosted call.
##
## `frame.texture!` crosses the Roc/host boundary once per sprite, and at a few
## thousand sprites that crossing, not the GPU, is what a frame is spent on.
## `frame.texture_instances!` hands the host one list and lets it loop, so the
## whole fountain costs one crossing however many particles are in it.
##
## The simulation is pure and runs in `update!`: it advances the particles and
## projects them onto the flat `Draw.TextureInstance` records the batch
## transports. `render!` only hands that retained list to the host, so the
## particle record can stay whatever the application wants it to be.
##
## Move the pointer to steer the emitter, hold Space for a wider spray, ESC quits.
Model : {
	sprite : Draw.Texture,
	particles : List(Particle),
	instances : List(Draw.TextureInstance),
	hud : Text.Prepared,
}

## One particle. `seed` and `phase` are fixed per particle, so respawns are
## deterministic and the fountain looks the same on every run without needing a
## random source. Two independent values keep the launch angle uncorrelated from
## speed and lifetime, which is what stops the spray looking like a flower.
Particle : {
	pos : Math.Vec2,
	vel : Math.Vec2,
	life : F32,
	seed : F32,
	phase : F32,
	tint : Color.Rgba,
}

Msg : []

program = { init!, update!, render! }

particle_count : U64
particle_count = 4000

sprite_source : Math.Rect
sprite_source = Math.rect(0, 0, 8, 8)

palette : U64 -> Color.Rgba
palette = |index|
	match index {
		0 => Color.from_hex_rgb(0xffd166)
		1 => Color.from_hex_rgb(0xef476f)
		2 => Color.from_hex_rgb(0x06d6a0)
		_ => Color.from_hex_rgb(0x118ab2)
	}

## Spread an index over 0..1 without a random source. The modulus is prime and
## the multiplier is coprime to it, so the map is injective for a particle count
## far below it: every particle gets its own value, and a different `salt` gives
## an independent one. `index % small` would instead collapse thousands of
## particles onto a handful of identical trajectories.
unit_hash : U64, U64 -> F32
unit_hash = |index, salt| U64.to_f32((index * (2_654_435_761 + salt * 40_503) + salt * 7919 + 1) % 65_521) / 65_521

initial_particles : List(Particle)
initial_particles = List.map_with_index(
	List.repeat({}, particle_count),
	|_unit, index| {
		seed = unit_hash(index, 0)
		{
			pos: Math.zero,
			vel: Math.zero,
			# Stagger the first respawn so the fountain fills instead of pulsing.
			life: seed * 2.8,
			seed: seed,
			phase: unit_hash(index, 1),
			tint: palette(index % 4),
		}
	},
)

## Advance one particle, respawning it at the emitter once its life runs out.
step_particle : Particle, Math.Vec2, F32, F32 -> Particle
step_particle = |particle, emitter, spread, dt| {
	life = particle.life - dt
	if life > 0 {
		{
			..particle,
			pos: { x: particle.pos.x + particle.vel.x * dt, y: particle.pos.y + particle.vel.y * dt },
			vel: { x: particle.vel.x, y: particle.vel.y + 420 * dt },
			life: life,
		}
	} else {
		angle = particle.phase * 6.2831855
		speed = 90 + 150 * particle.seed
		{
			..particle,
			pos: emitter,
			vel: { x: F32.cos(angle) * speed * spread, y: F32.sin(angle) * speed - 210 },
			life: 1.1 + particle.seed * 1.7,
		}
	}
}

## Project a particle onto the flat instance record the batch transports.
to_instance : Particle -> Draw.TextureInstance
to_instance = |particle| {
	size = 3 + 6 * particle.seed
	{
		source: sprite_source,
		dest: Math.rect(particle.pos.x, particle.pos.y, size, size),
		origin: { x: size / 2, y: size / 2 },
		rotation: particle.life * 120,
		tint: particle.tint,
	}
}

init! : App.Init(Model, [ResourceLimit, TextureGenerationFailed])
init! = App.init(
	App.default
		.with_title("RocRay Particles")
		.with_size({ width: 800, height: 600 })
		.with_frame_pacing(Capped(120)),
	|_startup| {
		sprite = Assets.generate_color_texture!({ width: 8, height: 8, color: Color.white })?
		font = Draw.default_font!()
		Ok({
			sprite: sprite,
			particles: initial_particles,
			instances: List.map(initial_particles, to_instance),
			hud: Text.from("4000 sprites, one hosted call - Space widens the spray, ESC quits", font).size(18).prepare!()?,
		})
	},
)

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	input = program_input.devices
	# A long first frame or a resize stall must not teleport the fountain.
	dt = F32.min(program_input.time.elapsed_seconds, 0.05)
	spread = if input.key_down(KeySpace) 1.9 else 0.7
	pointer = input.mouse.position()
	emitter =
		if pointer.x == 0 and pointer.y == 0 {
			{ x: I32.to_f32(program_input.window.size.width) / 2, y: I32.to_f32(program_input.window.size.height) / 3 }
		} else {
			pointer
		}

	particles = List.map(model.particles, |particle| step_particle(particle, emitter, spread, dt))

	if input.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		Ok({ ..model, particles: particles, instances: List.map(particles, to_instance) })
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x0d1425))
	frame.texture_instances!(model.sprite, model.instances)
	model.hud.draw!(frame, { pos: { x: 24, y: 24 }, color: Color.from_hex_rgb(0xa8b4cc), align: Text.align_top_left })

	Ok({})
}

expect {
	respawned = step_particle({ pos: Math.zero, vel: Math.zero, life: 0.01, seed: 0.5, phase: 0.25, tint: Color.white }, { x: 40, y: 60 }, 1, 0.02)
	respawned.pos == { x: 40, y: 60 } and respawned.life > 1
}

expect {
	moved = step_particle({ pos: { x: 10, y: 10 }, vel: { x: 100, y: 0 }, life: 1, seed: 0.5, phase: 0.25, tint: Color.white }, Math.zero, 1, 0.1)
	moved.pos == { x: 20, y: 10 } and moved.vel.y == 42
}

expect {
	instance = to_instance({ pos: { x: 12, y: 34 }, vel: Math.zero, life: 0.5, seed: 0, phase: 0, tint: Color.white })
	instance.dest == Math.rect(12, 34, 3, 3) and instance.origin == { x: 1.5, y: 1.5 }
}

## Neighbouring particles, the far end of the list, and the two salts all land
## on different values. That is what keeps 4000 sprites from collapsing onto a
## handful of shared trajectories.
expect {
	distinct_indices = unit_hash(0, 0) != unit_hash(1, 0) and unit_hash(1, 0) != unit_hash(2, 0) and unit_hash(0, 0) != unit_hash(particle_count - 1, 0)
	distinct_salts = unit_hash(7, 0) != unit_hash(7, 1) and unit_hash(2000, 0) != unit_hash(2000, 1)
	distinct_indices and distinct_salts
}

## Every derived value stays inside the unit interval the trajectories assume.
expect List.all(
	List.map_with_index(List.repeat({}, particle_count), |_unit, index| unit_hash(index, 1)),
	|value| value >= 0 and value < 1,
)
