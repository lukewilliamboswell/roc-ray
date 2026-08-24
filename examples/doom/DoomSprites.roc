## Pure sprite-atlas adapter for DoomWorld actors and pickups. It selects Doom
## facing aliases before producing camera-facing structural triangle records;
## the app converts tint to RocRay Color and submits them under a cutout shader.
import DoomAssets
import DoomSim
import DoomWorld

DoomSprites := [].{
	Vertex : { position : { x : F32, y : F32, z : F32 }, uv : { x : F32, y : F32 }, tint : { r : U8, g : U8, b : U8, a : U8 } }
	Geometry : { vertices : List(Vertex), indices : List(U32) }

	actor_geometry : DoomWorld.Actor, DoomSim.Vec2 -> Try(Geometry, [MissingSprite({ sprite : Str, frame : Str, angle : U64 }), MissingSpriteMapping(DoomWorld.ThingKind)])
	actor_geometry = |actor, viewer| {
		mapping = match actor_mapping(actor) {
			Ok(value) => value
			Err(MissingSpriteMapping(kind)) => return Err(MissingSpriteMapping(kind))
		}
		angle = facing_alias(actor.angle, actor.pos, viewer)
		view = match DoomAssets.sprite(mapping.sprite, mapping.frame, angle) {
			Ok(value) => value
			Err(MissingSprite(details)) => return Err(MissingSprite(details))
		}
		Ok(billboard(actor.pos, viewer, view, mapping.low))
	}

	pickup_geometry : DoomWorld.Pickup, DoomSim.Vec2 -> Try(Geometry, [MissingSprite({ sprite : Str, frame : Str, angle : U64 }), MissingSpriteMapping(DoomWorld.ThingKind)])
	pickup_geometry = |pickup, viewer| {
		mapping = match pickup_mapping(pickup.kind) {
			Ok(value) => value
			Err(MissingSpriteMapping(kind)) => return Err(MissingSpriteMapping(kind))
		}
		view = match DoomAssets.sprite(mapping.sprite, mapping.frame, 1) {
			Ok(value) => value
			Err(MissingSprite(details)) => return Err(MissingSprite(details))
		}
		Ok(billboard(pickup.pos, viewer, view, Bool.False))
	}

	## Doom aliases: 1 front, 3 left, 5 back, 7 right, with even-numbered
	## diagonals. Mirroring is metadata, not inferred from the requested bucket.
	facing_alias : DoomSim.Angle, DoomSim.Vec2, DoomSim.Vec2 -> U64
	facing_alias = |angle, actor_pos, viewer| {
		forward = angle.forward()
		to_viewer = DoomSim.normalize(DoomSim.sub(viewer, actor_pos))
		dot = DoomSim.dot(forward, to_viewer)
		cross = forward.x * to_viewer.y - forward.y * to_viewer.x
		ax = F32.abs(dot)
		ay = F32.abs(cross)
		if dot >= 0 and ay <= ax * 0.41421357 {
			1
		} else if dot < 0 and ay <= ax * 0.41421357 {
			5
		} else if cross > 0 and ax <= ay * 0.41421357 {
			3
		} else if cross < 0 and ax <= ay * 0.41421357 {
			7
		} else if dot >= 0 and cross > 0 {
			2
		} else if dot < 0 and cross > 0 {
			4
		} else if dot < 0 {
			6
		} else {
			8
		}
	}

	doom_scale = 1 / 64
}

ActorMapping : { sprite : Str, frame : Str, low : Bool }

PickupMapping : { sprite : Str, frame : Str }

actor_mapping : DoomWorld.Actor -> Try(ActorMapping, [MissingSpriteMapping(DoomWorld.ThingKind)])
actor_mapping = |actor| {
	sprite = match actor.kind {
		ZombieMan => "POSS"
		ShotgunGuy => "SPOS"
		Imp => "TROO"
		Barrel => "BAR1"
		_ => return Err(MissingSpriteMapping(actor.kind))
	}
	frame = match actor.state.mode {
		Look => "A"
		Chase => if actor.state.remaining % 2 == 0 "A" else "B"
		Attack => "E"
		Pain => "G"
		Dead => if actor.kind == Barrel "B" else "T"
	}
	Ok({ sprite, frame, low: actor.state.mode == Dead })
}

pickup_mapping : DoomWorld.ThingKind -> Try(PickupMapping, [MissingSpriteMapping(DoomWorld.ThingKind)])
pickup_mapping = |kind|
	match kind {
		ShotgunPickup => Ok({ sprite: "SHOT", frame: "A" })
		ClipPickup => Ok({ sprite: "CLIP", frame: "A" })
		ShellPickup => Ok({ sprite: "SHEL", frame: "A" })
		StimpackPickup => Ok({ sprite: "STIM", frame: "A" })
		MedikitPickup => Ok({ sprite: "MEDI", frame: "A" })
		GreenArmorPickup => Ok({ sprite: "ARM1", frame: "A" })
		BlueArmorPickup => Ok({ sprite: "ARM2", frame: "A" })
		HealthBonusPickup => Ok({ sprite: "BON1", frame: "A" })
		ArmorBonusPickup => Ok({ sprite: "BON2", frame: "A" })
		BlueKeyPickup => Ok({ sprite: "BKEY", frame: "A" })
		_ => Err(MissingSpriteMapping(kind))
	}

billboard = |pos, viewer, view, low| {
	to_viewer = DoomSim.normalize(DoomSim.sub(viewer, pos))
	right = { x: 0 - to_viewer.y, y: to_viewer.x }
	width = U64.to_f32(view.rect.width)
	height = U64.to_f32(view.rect.height) * DoomSprites.doom_scale
	half = DoomSim.scale(right, width * 0.5)
	bottom = if low 0 else 0
	left = { x: (pos.x - half.x) * DoomSprites.doom_scale, y: bottom, z: (pos.y - half.y) * DoomSprites.doom_scale }
	right_bottom = { x: (pos.x + half.x) * DoomSprites.doom_scale, y: bottom, z: (pos.y + half.y) * DoomSprites.doom_scale }
	left_u = (U64.to_f32(view.rect.x) + 0.5) / U64.to_f32(DoomAssets.sprites.width)
	right_u = (U64.to_f32(view.rect.x + view.rect.width) - 0.5) / U64.to_f32(DoomAssets.sprites.width)
	u0 = if view.mirrored right_u else left_u
	u1 = if view.mirrored left_u else right_u
	v0 = (U64.to_f32(view.rect.y) + 0.5) / U64.to_f32(DoomAssets.sprites.height)
	v1 = (U64.to_f32(view.rect.y + view.rect.height) - 0.5) / U64.to_f32(DoomAssets.sprites.height)
	tint = { r: 255, g: 255, b: 255, a: 255 }
	{
		vertices: [
			{ position: left, uv: { x: u0, y: v1 }, tint },
			{ position: right_bottom, uv: { x: u1, y: v1 }, tint },
			{ position: { ..right_bottom, y: bottom + height }, uv: { x: u1, y: v0 }, tint },
			{ position: { ..left, y: bottom + height }, uv: { x: u0, y: v0 }, tint },
		],
		indices: [0, 1, 2, 0, 2, 3],
	}
}

expect {
	angle = DoomSim.Angle.from_turns(0)
	DoomSprites.facing_alias(angle, { x: 0, y: 0 }, { x: 10, y: 0 }) == 1
		and DoomSprites.facing_alias(angle, { x: 0, y: 0 }, { x: 0, y: 10 }) == 3
			and DoomSprites.facing_alias(angle, { x: 0, y: 0 }, { x: -10, y: 0 }) == 5
				and DoomSprites.facing_alias(angle, { x: 0, y: 0 }, { x: 0, y: -10 }) == 7
}

expect {
	actor = DoomWorld.actor(1, ZombieMan, { x: 64, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	geometry = DoomSprites.actor_geometry(actor, { x: 0, y: 0 }) ?? crash "POSS sprite missing"
	List.len(geometry.vertices) == 4 and geometry.indices == [0, 1, 2, 0, 2, 3]
}

expect {
	pickup : DoomWorld.Pickup
	pickup = { id: 1, kind: BlueKeyPickup, pos: { x: 0, y: 0 }, taken: Bool.False }
	geometry = DoomSprites.pickup_geometry(pickup, { x: 64, y: 0 }) ?? crash "BKEY sprite missing"
	missing = DoomSprites.pickup_geometry({ ..pickup, kind: YellowKeyPickup }, { x: 64, y: 0 })
	List.len(geometry.vertices) == 4 and match missing {
		Err(MissingSpriteMapping(YellowKeyPickup)) => Bool.True
		_ => Bool.False
	}
}
