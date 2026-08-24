## Pure sprite-atlas adapter for DoomWorld actors and pickups. It selects Doom
## facing aliases before producing camera-facing structural triangle records;
## the app converts tint to RocRay Color and submits them under a cutout shader.
import DoomAssets
import DoomPresentation
import DoomSim
import DoomWorld

DoomSprites := [].{
	Vertex : { position : { x : F32, y : F32, z : F32 }, uv : { x : F32, y : F32 }, tint : { r : U8, g : U8, b : U8, a : U8 } }
	Geometry : { vertices : List(Vertex), indices : List(U32) }

	actor_geometry : DoomWorld.Actor, DoomSim.Vec2 -> Try(Geometry, [MissingActorSpriteMapping(DoomWorld.ThingKind), MissingSprite({ sprite : Str, frame : Str, angle : U64 })])
	actor_geometry = |actor, viewer| {
		view = match DoomPresentation.actor(actor, viewer) {
			Ok(value) => value
			Err(MissingActorSpriteMapping(kind)) => return Err(MissingActorSpriteMapping(kind))
			Err(MissingSprite(details)) => return Err(MissingSprite(details))
		}
		Ok(billboard(actor.pos, viewer, view, actor.state.mode == Dead))
	}

	pickup_geometry : DoomWorld.Pickup, DoomSim.Vec2, U64 -> Try([Hidden, Visible(Geometry)], [MissingPickupSpriteMapping(DoomWorld.ThingKind), MissingSprite({ sprite : Str, frame : Str, angle : U64 })])
	pickup_geometry = |pickup, viewer, tic| {
		match DoomPresentation.pickup(pickup, tic) {
			Ok(Hidden) => Ok(Hidden)
			Ok(Visible(view)) => Ok(Visible(billboard(pickup.pos, viewer, view, Bool.False)))
			Err(MissingPickupSpriteMapping(kind)) => Err(MissingPickupSpriteMapping(kind))
			Err(MissingSprite(details)) => Err(MissingSprite(details))
		}
	}

	effect_geometry : DoomPresentation.Effect, DoomSim.Vec2, DoomSim.Vec2, U64 -> Try(Geometry, [MissingSprite({ sprite : Str, frame : Str, angle : U64 })])
	effect_geometry = |effect, pos, viewer, phase| {
		view = DoomPresentation.effect(effect, phase)?
		Ok(billboard(pos, viewer, view, Bool.False))
	}

	decoration_geometry : DoomWorld.Decoration, DoomSim.Vec2 -> Try(Geometry, [MissingDecorationSpriteMapping(DoomWorld.ThingKind), MissingSprite({ sprite : Str, frame : Str, angle : U64 })])
	decoration_geometry = |decoration, viewer| {
		view = match DoomPresentation.decoration(decoration) {
			Ok(value) => value
			Err(MissingDecorationSpriteMapping(kind)) => return Err(MissingDecorationSpriteMapping(kind))
			Err(MissingSprite(details)) => return Err(MissingSprite(details))
		}
		Ok(billboard(decoration.pos, viewer, view, Bool.False))
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
	visible = DoomSprites.pickup_geometry(pickup, { x: 64, y: 0 }, 0) ?? crash "BKEY sprite missing"
	hidden = DoomSprites.pickup_geometry({ ..pickup, taken: Bool.True }, { x: 64, y: 0 }, 0) ?? crash "taken pickup lookup failed"
	match visible {
		Visible(geometry) => List.len(geometry.vertices) == 4 and hidden == Hidden
		Hidden => Bool.False
	}
}
