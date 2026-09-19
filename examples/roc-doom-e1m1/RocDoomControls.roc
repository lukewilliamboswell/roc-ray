## Host-input mapping for the Doom world/camera coordinate convention.
##
## RocDoomSim follows the original `side` convention: positive side thrust is
## facing-minus-90 degrees. RocRay's camera embeds Doom y as world z, making
## that direction screen-left. Therefore a screen-right key is a negative
## simulation-side command. Positive mouse x still rotates toward screen-right.
import RocDoomSim

RocDoomControls := [].{
	side : Bool, Bool -> I16
	side = |left, right|
		if left and !(right) 40 else if right and !(left) -40 else 0

	turn : F32 -> F32
	turn = |mouse_delta_x| mouse_delta_x * mouse_turns_per_pixel

	visual_right : RocDoomSim.Angle -> RocDoomSim.Vec2
	visual_right = |angle| {
		facing = angle.forward()
		{ x: 0 - facing.y, y: facing.x }
	}

	## Input a host cycle sampled that has not yet reached a simulation tic.
	##
	## The host samples once per frame but the simulation runs at a fixed 35 Hz,
	## so a frame delivers zero, one or several tics. Mouse motion is a single
	## per-frame magnitude and presses are edges consumed by exactly one
	## `update!`, so neither may be handed to `RocDoomSim.Command` directly: a
	## zero-tic frame would discard it and a catch-up frame would apply it once
	## per tic. Latch both here until a tic consumes them.
	Pending : { turn : F32, fire : Bool, use : Bool, weapon_slot : [KeepWeapon, SelectSlot(U8)] }

	pending_none : Pending
	pending_none = { turn: 0, fire: Bool.False, use: Bool.False, weapon_slot: KeepWeapon }

	## Fold one host cycle of sampled input into the latch. Turn deltas sum,
	## edges latch on, and the most recent explicit weapon request wins.
	accumulate : Pending, { turn : F32, fire : Bool, use : Bool, weapon_slot : [KeepWeapon, SelectSlot(U8)] } -> Pending
	accumulate = |pending, frame| {
		turn: pending.turn + frame.turn,
		fire: pending.fire or frame.fire,
		use: pending.use or frame.use,
		weapon_slot: match frame.weapon_slot {
			KeepWeapon => pending.weapon_slot
			SelectSlot(slot) => SelectSlot(slot)
		},
	}

	## Split the latch into the pair `RocDoomRuntime.advance_in_map_first` expects.
	## The whole accumulated delta belongs to the opening tic; catch-up tics see
	## only the level-held axes, which are sampled fresh each cycle and are
	## meant to repeat. `first.fire` also honours a latched click shorter than
	## one tic, which a level-only read would drop.
	ticcmds : Pending, { forward : I16, side : I16, fire : Bool } -> { first : RocDoomSim.Command, repeat : RocDoomSim.Command }
	ticcmds = |pending, held| {
		first: { forward: held.forward, side: held.side, turn: pending.turn, fire: held.fire or pending.fire, weapon_slot: pending.weapon_slot },
		repeat: { forward: held.forward, side: held.side, turn: 0, fire: held.fire, weapon_slot: KeepWeapon },
	}

	## Latched input survives a cycle that produced no tic and is cleared only
	## once a tic has consumed it. Saturated catch-up still reports `tics > 0`,
	## so a dropped-tic frame clears the latch exactly once.
	drain : Pending, U64 -> Pending
	drain = |pending, tics| if tics == 0 pending else pending_none
}

mouse_turns_per_pixel = 0.0004

expect RocDoomControls.side(Bool.False, Bool.True) == -40
expect RocDoomControls.side(Bool.True, Bool.False) == 40
expect RocDoomControls.side(Bool.True, Bool.True) == 0

expect {
	angle = RocDoomSim.Angle.from_turns(0)
	right = RocDoomControls.visual_right(angle)
	turned = angle.add(RocDoomControls.turn(20)).forward()
	RocDoomSim.dot(turned, right) > 0
}

expect {
	# The whole frame delta lands on the opening tic; catch-up tics add nothing,
	# so total rotation is independent of how many tics the frame spends.
	pending = RocDoomControls.accumulate(RocDoomControls.pending_none, { turn: 0.01, fire: Bool.False, use: Bool.False, weapon_slot: KeepWeapon })
	cmds = RocDoomControls.ticcmds(pending, { forward: 0, side: 0, fire: Bool.False })
	cmds.first.turn == 0.01 and cmds.repeat.turn == 0
}

expect {
	# A press latched on a zero-tic cycle survives; a tic consumes it.
	first = RocDoomControls.accumulate(RocDoomControls.pending_none, { turn: 0.01, fire: Bool.False, use: Bool.True, weapon_slot: SelectSlot(3) })
	held = RocDoomControls.drain(first, 0)
	second = RocDoomControls.accumulate(held, { turn: 0.01, fire: Bool.False, use: Bool.False, weapon_slot: KeepWeapon })
	second.turn == 0.02
		and second.use
			and second.weapon_slot == SelectSlot(3)
				and RocDoomControls.drain(second, 1) == RocDoomControls.pending_none
}

expect {
	# Two sampled deltas accumulate to one combined delta.
	split = RocDoomControls.accumulate(RocDoomControls.accumulate(RocDoomControls.pending_none, { turn: RocDoomControls.turn(12), fire: Bool.False, use: Bool.False, weapon_slot: KeepWeapon }), { turn: RocDoomControls.turn(8), fire: Bool.False, use: Bool.False, weapon_slot: KeepWeapon })
	whole = RocDoomControls.accumulate(RocDoomControls.pending_none, { turn: RocDoomControls.turn(20), fire: Bool.False, use: Bool.False, weapon_slot: KeepWeapon })
	split.turn == whole.turn
}

expect {
	# KeepWeapon never erases a latched slot; the latest explicit request wins.
	a = RocDoomControls.accumulate(RocDoomControls.pending_none, { turn: 0, fire: Bool.False, use: Bool.False, weapon_slot: SelectSlot(2) })
	b = RocDoomControls.accumulate(a, { turn: 0, fire: Bool.False, use: Bool.False, weapon_slot: KeepWeapon })
	c = RocDoomControls.accumulate(b, { turn: 0, fire: Bool.False, use: Bool.False, weapon_slot: SelectSlot(6) })
	b.weapon_slot == SelectSlot(2) and c.weapon_slot == SelectSlot(6)
}

expect {
	# A click shorter than one tic still fires exactly once.
	clicked = RocDoomControls.accumulate(RocDoomControls.pending_none, { turn: 0, fire: Bool.True, use: Bool.False, weapon_slot: KeepWeapon })
	cmds = RocDoomControls.ticcmds(clicked, { forward: 0, side: 0, fire: Bool.False })
	cmds.first.fire and !(cmds.repeat.fire)
}
