## Pure presentation policy for the DoomWorld state. This module chooses atlas
## families, animation frames, viewing rotations and mirrored aliases; it does
## not build geometry or retain a host resource. Missing art is typed data and
## is never repaired with an unrelated sprite.
import DoomAssets
import DoomMap
import DoomSim
import DoomWorld

DoomPresentation := [].{
	PickupView : [Hidden, Visible(DoomAssets.SpriteView)]
	HudElement : [StatusBar, LargeDigit(U8)]

	actor : DoomWorld.Actor, DoomSim.Vec2 -> Try(DoomAssets.SpriteView, [MissingActorSpriteMapping(DoomWorld.ThingKind), MissingSprite({ sprite : Str, frame : Str, angle : U64 })])
	actor = |actor_value, viewer| {
		match actor_mapping(actor_value) {
			Err(MissingActorSpriteMapping(kind)) => Err(MissingActorSpriteMapping(kind))
			Ok(mapping) => match DoomAssets.sprite(mapping.sprite, mapping.frame, viewing_angle(actor_value, viewer)) {
				Err(MissingSprite(details)) => Err(MissingSprite(details))
				Ok(view) => Ok(view)
			}
		}
	}

	pickup : DoomWorld.Pickup, U64 -> Try(PickupView, [MissingPickupSpriteMapping(DoomWorld.ThingKind), MissingSprite({ sprite : Str, frame : Str, angle : U64 })])
	pickup = |pickup_value, tic| {
		if pickup_value.taken {
			Ok(Hidden)
		} else {
			match pickup_mapping(pickup_value.kind, tic) {
				Err(MissingPickupSpriteMapping(kind)) => Err(MissingPickupSpriteMapping(kind))
				Ok(mapping) => match DoomAssets.sprite(mapping.sprite, mapping.frame, 1) {
					Err(MissingSprite(details)) => Err(MissingSprite(details))
					Ok(view) => Ok(Visible(view))
				}
			}
		}
	}

	## Resolve a first-person weapon frame when that family is present in the
	## complete sprite atlas. E1M1 currently has no PISG/SHTG entries, so callers
	## receive MissingSprite until extraction deliberately admits those lumps.
	weapon : DoomWorld.Weapon, U64 -> Try(DoomAssets.SpriteView, [MissingSprite({ sprite : Str, frame : Str, angle : U64 })])
	weapon = |weapon_kind, phase| {
		mapping = match weapon_kind {
			Pistol => { sprite: "PISG", frame: frame_at(["A", "B", "C", "D", "E"], phase) }
			Shotgun => { sprite: "SHTG", frame: frame_at(["A", "B", "C", "D"], phase) }
		}
		DoomAssets.sprite(mapping.sprite, mapping.frame, 1)
	}

	## HUD graphics are ordinary WAD graphics rather than rotating sprites. This
	## lookup succeeds only if the generated sprite atlas explicitly contains the
	## requested lump; the current E1M1 atlas does not silently substitute one.
	hud : HudElement -> Try(DoomAssets.Rect, [InvalidHudDigit(U8), MissingHudAsset(Str)])
	hud = |element| {
		name = match element {
			StatusBar => "STBAR"
			LargeDigit(digit) => if digit <= 9 "STTNUM${U8.to_str(digit)}" else return Err(InvalidHudDigit(digit))
		}
		match List.find_first(DoomAssets.sprites.entries, |entry| entry.doom_name == name) {
			Ok(entry) => Ok(entry.rect)
			Err(_) => Err(MissingHudAsset(name))
		}
	}

	## Doom rotations: 1 front, 3 actor-left, 5 back and 7 actor-right;
	## diagonals occupy the even buckets. DoomAssets owns whether a matched lump
	## alias is mirrored.
	viewing_angle : DoomWorld.Actor, DoomSim.Vec2 -> U64
	viewing_angle = |actor_value, viewer| {
		forward = actor_value.angle.forward()
		to_viewer = DoomSim.normalize(DoomSim.sub(viewer, actor_value.pos))
		dot = DoomSim.dot(forward, to_viewer)
		cross = forward.x * to_viewer.y - forward.y * to_viewer.x
		ax = F32.abs(dot)
		ay = F32.abs(cross)
		if dot >= 0 and ay <= ax * diagonal_threshold {
			1
		} else if dot < 0 and ay <= ax * diagonal_threshold {
			5
		} else if cross > 0 and ax <= ay * diagonal_threshold {
			3
		} else if cross < 0 and ax <= ay * diagonal_threshold {
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
}

actor_mapping : DoomWorld.Actor -> Try({ sprite : Str, frame : Str }, [MissingActorSpriteMapping(DoomWorld.ThingKind)])
actor_mapping = |actor_value| {
	sprite = match actor_value.kind {
		ZombieMan => Ok("POSS")
		ShotgunGuy => Ok("SPOS")
		Imp => Ok("TROO")
		Barrel => Ok("BAR1")
		_ => Err(MissingActorSpriteMapping(actor_value.kind))
	}?
	frame = match actor_value.kind {
		Barrel => match actor_value.state.mode {
			Dead => "C" # absent BEXP art is reported, never replaced with idle BAR1B
			_ => if actor_value.state.remaining % 2 == 0 "B" else "A"
		}
		Imp => match actor_value.state.mode {
			Look => "A"
			Chase => chase_frame(actor_value.state.remaining)
			Attack => if actor_value.state.remaining > 5 "E" else if actor_value.state.remaining > 2 "F" else "G"
			Pain => "H"
			Dead => "M"
		}
		_ => match actor_value.state.mode {
			Look => "A"
			Chase => chase_frame(actor_value.state.remaining)
			Attack => if actor_value.state.remaining > 4 "E" else "F"
			Pain => "G"
			Dead => "L"
		}
	}
	Ok({ sprite, frame })
}

pickup_mapping : DoomWorld.ThingKind, U64 -> Try({ sprite : Str, frame : Str }, [MissingPickupSpriteMapping(DoomWorld.ThingKind)])
pickup_mapping = |kind, tic|
	match kind {
		ShotgunPickup => Ok({ sprite: "SHOT", frame: "A" })
		ClipPickup => Ok({ sprite: "CLIP", frame: "A" })
		ShellPickup => Ok({ sprite: "SHEL", frame: "A" })
		StimpackPickup => Ok({ sprite: "STIM", frame: "A" })
		MedikitPickup => Ok({ sprite: "MEDI", frame: "A" })
		GreenArmorPickup => Ok({ sprite: "ARM1", frame: frame_at(["A", "B"], tic) })
		BlueArmorPickup => Ok({ sprite: "ARM2", frame: frame_at(["A", "B"], tic) })
		HealthBonusPickup => Ok({ sprite: "BON1", frame: frame_at(["A", "B", "C", "D"], tic) })
		ArmorBonusPickup => Ok({ sprite: "BON2", frame: frame_at(["A", "B", "C", "D"], tic) })
		BlueKeyPickup => Ok({ sprite: "BKEY", frame: frame_at(["A", "B"], tic) })
		YellowKeyPickup => Ok({ sprite: "YKEY", frame: frame_at(["A", "B"], tic) })
		RedKeyPickup => Ok({ sprite: "RKEY", frame: frame_at(["A", "B"], tic) })
		_ => Err(MissingPickupSpriteMapping(kind))
	}

chase_frame = |remaining|
	if remaining >= 4 "A" else if remaining == 3 "B" else if remaining == 2 "C" else "D"

frame_at = |frames, phase| List.get(frames, phase % List.len(frames)) ?? crash "nonempty presentation frame list"

diagonal_threshold = 0.41421357

expect {
	angle = DoomSim.Angle.from_turns(0)
	actor_value = DoomWorld.actor(0, ZombieMan, { x: 0, y: 0 }, angle, Bool.False)
	front : DoomAssets.SpriteView
	front = DoomPresentation.actor(actor_value, { x: 10, y: 0 }) ?? crash "POSS front missing"
	left : DoomAssets.SpriteView
	left = DoomPresentation.actor(actor_value, { x: 0, y: 10 }) ?? crash "POSS left missing"
	right : DoomAssets.SpriteView
	right = DoomPresentation.actor(actor_value, { x: 0, y: -10 }) ?? crash "POSS right missing"
	DoomPresentation.viewing_angle(actor_value, { x: 10, y: 0 }) == 1
		and DoomPresentation.viewing_angle(actor_value, { x: 0, y: 10 }) == 3
		and DoomPresentation.viewing_angle(actor_value, { x: 0, y: -10 }) == 7
		and front.doom_name != left.doom_name
		and left.doom_name != right.doom_name
}

expect {
	# Every actor and pickup kind that DoomWorld actually spawns from the pinned
	# E1M1 on medium skill resolves without a fallback.
	spawned = DoomWorld.spawn(DoomMap.e1m1.raw().things, Medium)
	actors_ok = List.all(spawned.actors, |value|
		match DoomPresentation.actor(value, { x: value.pos.x + 64, y: value.pos.y }) {
			Ok(_) => Bool.True
			Err(_) => Bool.False
		})
	pickups_ok = List.all(spawned.pickups, |value|
		match DoomPresentation.pickup(value, 0) {
			Ok(Visible(_)) => Bool.True
			_ => Bool.False
		})
	actors_ok and pickups_ok and List.len(spawned.actors) > 0 and List.len(spawned.pickups) > 0
}

expect {
	pickup : DoomWorld.Pickup
	pickup = { id: 0, kind: BlueKeyPickup, pos: { x: 0, y: 0 }, taken: Bool.False }
	missing_key = DoomPresentation.pickup({ ..pickup, kind: YellowKeyPickup }, 0)
	hidden = DoomPresentation.pickup({ ..pickup, taken: Bool.True }, 0)
	missing_weapon = DoomPresentation.weapon(Pistol, 0)
	missing_hud = DoomPresentation.hud(StatusBar)
	barrel = DoomWorld.actor(1, Barrel, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	missing_explosion = DoomPresentation.actor({ ..barrel, state: DoomWorld.state(Dead) }, { x: 64, y: 0 })
	match missing_key {
		Err(MissingSprite(_)) => Bool.True
		_ => Bool.False
	}
		and hidden == Ok(Hidden)
		and match missing_weapon {
			Err(MissingSprite(_)) => Bool.True
			_ => Bool.False
		}
		and match missing_hud {
			Err(MissingHudAsset("STBAR")) => Bool.True
			_ => Bool.False
		}
		and match missing_explosion {
			Err(MissingSprite({ sprite: "BAR1", frame: "C", angle: _ })) => Bool.True
			_ => Bool.False
		}
}
