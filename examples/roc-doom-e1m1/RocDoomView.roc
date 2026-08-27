## Pure tic-driven presentation state. Host-cycle duration never enters this
## module, so palette flashes remain identical for equivalent simulation-tic
## partitions. Movement bob itself is owned by RocDoomSim.View and is consumed by
## the app's camera and weapon placement.

RocDoomView := [].{
	Flashes : { damage : U64, pickup : U64 }
	Facts : { damaged : Bool, picked_up : Bool }

	initial : Flashes
	initial = { damage: 0, pickup: 0 }

	advance : Flashes, U64, Facts -> Flashes
	advance = |flashes, tics, facts| {
		damage0 = if flashes.damage > tics flashes.damage - tics else 0
		pickup0 = if flashes.pickup > tics flashes.pickup - tics else 0
		{
			damage: if facts.damaged damage_flash_tics else damage0,
			pickup: if facts.picked_up pickup_flash_tics else pickup0,
		}
	}

	damage_flash_tics = 12.U64
	pickup_flash_tics = 8.U64
}

expect {
	started = RocDoomView.advance(RocDoomView.initial, 1, { damaged: Bool.True, picked_up: Bool.True })
	whole = RocDoomView.advance(started, 7, { damaged: Bool.False, picked_up: Bool.False })
	part = RocDoomView.advance(RocDoomView.advance(started, 3, { damaged: Bool.False, picked_up: Bool.False }), 4, { damaged: Bool.False, picked_up: Bool.False })
	whole.damage == part.damage and whole.pickup == part.pickup and whole.damage == 5 and whole.pickup == 1
}

expect {
	flashes = RocDoomView.advance({ damage: 2, pickup: 3 }, 8, { damaged: Bool.False, picked_up: Bool.False })
	flashes.damage == 0 and flashes.pickup == 0
}
