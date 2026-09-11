## Pure sprite-atlas adapter for RocDoomWorld actors and pickups. It selects Doom
## facing aliases before producing camera-facing structural triangle records;
## the app converts tint to RocRay Color and submits them under a cutout shader.
import RocDoomAssets
import RocDoomPresentation
import RocDoomSim
import RocDoomWorld

RocDoomSprites := [].{
	Vertex : { position : { x : F32, y : F32, z : F32 }, uv : { x : F32, y : F32 }, tint : { r : U8, g : U8, b : U8, a : U8 } }
	Geometry : { vertices : List(Vertex), indices : List(U32) }

	actor_geometry : RocDoomWorld.Actor, RocDoomSim.Vec2 -> Try(Geometry, [MissingActorSpriteMapping(RocDoomWorld.ThingKind), MissingSprite({ sprite : Str, frame : Str, angle : U64 })])
	actor_geometry = |actor, viewer| {
		view = match RocDoomPresentation.actor(actor, viewer) {
			Ok(value) => value
			Err(MissingActorSpriteMapping(kind)) => return Err(MissingActorSpriteMapping(kind))
			Err(MissingSprite(details)) => return Err(MissingSprite(details))
		}
		Ok(billboard(actor.pos, viewer, view, actor.state.mode == Dead))
	}

	pickup_geometry : RocDoomWorld.Pickup, RocDoomSim.Vec2, U64 -> Try([Hidden, Visible(Geometry)], [MissingPickupSpriteMapping(RocDoomWorld.ThingKind), MissingSprite({ sprite : Str, frame : Str, angle : U64 })])
	pickup_geometry = |pickup, viewer, tic| {
		match RocDoomPresentation.pickup(pickup, tic) {
			Ok(Hidden) => Ok(Hidden)
			Ok(Visible(view)) => Ok(Visible(billboard(pickup.pos, viewer, view, Bool.False)))
			Err(MissingPickupSpriteMapping(kind)) => Err(MissingPickupSpriteMapping(kind))
			Err(MissingSprite(details)) => Err(MissingSprite(details))
		}
	}

	effect_geometry : RocDoomPresentation.Effect, RocDoomSim.Vec2, RocDoomSim.Vec2, U64 -> Try(Geometry, [MissingSprite({ sprite : Str, frame : Str, angle : U64 })])
	effect_geometry = |effect, pos, viewer, phase| {
		view = RocDoomPresentation.effect(effect, phase)?
		Ok(billboard(pos, viewer, view, Bool.False))
	}

	decoration_geometry : RocDoomWorld.Decoration, RocDoomSim.Vec2 -> Try(Geometry, [MissingDecorationSpriteMapping(RocDoomWorld.ThingKind), MissingSprite({ sprite : Str, frame : Str, angle : U64 })])
	decoration_geometry = |decoration, viewer| {
		view = match RocDoomPresentation.decoration(decoration) {
			Ok(value) => value
			Err(MissingDecorationSpriteMapping(kind)) => return Err(MissingDecorationSpriteMapping(kind))
			Err(MissingSprite(details)) => return Err(MissingSprite(details))
		}
		Ok(billboard(decoration.pos, viewer, view, Bool.False))
	}

	## Doom aliases: 1 front, 3 left, 5 back, 7 right, with even-numbered
	## diagonals. Mirroring is metadata, not inferred from the requested bucket.
	facing_alias : RocDoomSim.Angle, RocDoomSim.Vec2, RocDoomSim.Vec2 -> U64
	facing_alias = |angle, actor_pos, viewer| {
		forward = angle.forward()
		to_viewer = RocDoomSim.normalize(RocDoomSim.sub(viewer, actor_pos))
		dot = RocDoomSim.dot(forward, to_viewer)
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
	to_viewer = RocDoomSim.normalize(RocDoomSim.sub(viewer, pos))
	right = { x: 0 - to_viewer.y, y: to_viewer.x }
	width = U64.to_f32(view.rect.width)
	height = U64.to_f32(view.rect.height) * RocDoomSprites.doom_scale
	half = RocDoomSim.scale(right, width * 0.5)
	bottom = if low 0 else 0
	left = { x: (pos.x - half.x) * RocDoomSprites.doom_scale, y: bottom, z: (pos.y - half.y) * RocDoomSprites.doom_scale }
	right_bottom = { x: (pos.x + half.x) * RocDoomSprites.doom_scale, y: bottom, z: (pos.y + half.y) * RocDoomSprites.doom_scale }
	left_u = (U64.to_f32(view.rect.x) + 0.5) / U64.to_f32(RocDoomAssets.sprites.width)
	right_u = (U64.to_f32(view.rect.x + view.rect.width) - 0.5) / U64.to_f32(RocDoomAssets.sprites.width)
	u0 = if view.mirrored right_u else left_u
	u1 = if view.mirrored left_u else right_u
	v0 = (U64.to_f32(view.rect.y) + 0.5) / U64.to_f32(RocDoomAssets.sprites.height)
	v1 = (U64.to_f32(view.rect.y + view.rect.height) - 0.5) / U64.to_f32(RocDoomAssets.sprites.height)
	tint = { r: 255, g: 255, b: 255, a: 255 }
	{
		vertices: [
			{ position: left, uv: { x: u0, y: v1 }, tint },
			{ position: right_bottom, uv: { x: u1, y: v1 }, tint },
			{ position: { ..right_bottom, y: bottom + height }, uv: { x: u1, y: v0 }, tint },
			{ position: { ..left, y: bottom + height }, uv: { x: u0, y: v0 }, tint },
		],
		# Front faces point toward `viewer`; the 3D draw path culls the opposite
		# winding before the cutout shader can sample the sprite.
		indices: [0, 2, 1, 0, 3, 2],
	}
}

faces_viewer = |geometry, viewer| {
	a = List.get(geometry.vertices, U32.to_u64(List.get(geometry.indices, 0) ?? return Bool.False)) ?? return Bool.False
	b = List.get(geometry.vertices, U32.to_u64(List.get(geometry.indices, 1) ?? return Bool.False)) ?? return Bool.False
	c = List.get(geometry.vertices, U32.to_u64(List.get(geometry.indices, 2) ?? return Bool.False)) ?? return Bool.False
	ab = { x: b.position.x - a.position.x, y: b.position.y - a.position.y, z: b.position.z - a.position.z }
	ac = { x: c.position.x - a.position.x, y: c.position.y - a.position.y, z: c.position.z - a.position.z }
	normal = {
		x: ab.y * ac.z - ab.z * ac.y,
		y: ab.z * ac.x - ab.x * ac.z,
		z: ab.x * ac.y - ab.y * ac.x,
	}
	to_viewer = { x: viewer.x * RocDoomSprites.doom_scale - a.position.x, y: 0 - a.position.y, z: viewer.y * RocDoomSprites.doom_scale - a.position.z }
	normal.x * to_viewer.x + normal.y * to_viewer.y + normal.z * to_viewer.z > 0
}

expect {
	angle = RocDoomSim.Angle.from_turns(0)
	RocDoomSprites.facing_alias(angle, { x: 0, y: 0 }, { x: 10, y: 0 }) == 1
		and RocDoomSprites.facing_alias(angle, { x: 0, y: 0 }, { x: 0, y: 10 }) == 3
			and RocDoomSprites.facing_alias(angle, { x: 0, y: 0 }, { x: -10, y: 0 }) == 5
				and RocDoomSprites.facing_alias(angle, { x: 0, y: 0 }, { x: 0, y: -10 }) == 7
}

expect {
	actor = RocDoomWorld.actor(1, ZombieMan, { x: 64, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	viewers = [{ x: 0, y: 0 }, { x: 128, y: 0 }, { x: 64, y: 64 }, { x: 64, y: -64 }]
	List.all(
		viewers,
		|viewer| {
			geometry = RocDoomSprites.actor_geometry(actor, viewer) ?? crash "POSS sprite missing"
			List.len(geometry.vertices) == 4 and faces_viewer(geometry, viewer)
		},
	)
}

expect {
	pickup : RocDoomWorld.Pickup
	pickup = { id: 1, kind: BlueKeyPickup, pos: { x: 0, y: 0 }, taken: Bool.False }
	visible = RocDoomSprites.pickup_geometry(pickup, { x: 64, y: 0 }, 0) ?? crash "BKEY sprite missing"
	hidden = RocDoomSprites.pickup_geometry({ ..pickup, taken: Bool.True }, { x: 64, y: 0 }, 0) ?? crash "taken pickup lookup failed"
	match visible {
		Visible(geometry) => List.len(geometry.vertices) == 4 and faces_viewer(geometry, { x: 64, y: 0 }) and hidden == Hidden
		Hidden => Bool.False
	}
}
