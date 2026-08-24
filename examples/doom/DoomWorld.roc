## Pure Doom-world runtime foundations layered over `DoomSim` and the compact
## map vocabulary in `DoomMap`. Actor timing, random combat outcomes, spawning,
## inventory, and damage are deterministic application state; no host resource
## or callback crosses this module.
##
## Behavior is independently implemented using Linux Doom 1.10 and Chocolate
## Doom as oracles: `info.c` state durations/editor numbers, `p_enemy.c` actor
## state flow, `p_inter.c` pickup and armor rules, and `p_pspr.c` hitscan damage.
import DoomSim

DoomWorld := [].{
	Skill := [Baby, Easy, Medium, Hard, Nightmare].{
		is_eq : _
	}
	ArmorKind := [NoArmor, GreenArmor, BlueArmor].{
		is_eq : _
	}
	Weapon := [Pistol, Shotgun].{
		is_eq : _
	}

	ThingKind := [
		PlayerStart,
		DeathmatchStart,
		TeleportDestination,
		ZombieMan,
		ShotgunGuy,
		Imp,
		Barrel,
		ShotgunPickup,
		ClipPickup,
		ShellPickup,
		StimpackPickup,
		MedikitPickup,
		GreenArmorPickup,
		BlueArmorPickup,
		HealthBonusPickup,
		ArmorBonusPickup,
		BlueKeyPickup,
		YellowKeyPickup,
		RedKeyPickup,
	].{
		is_eq : _
	}

	ActorMode := [Look, Chase, Attack, Pain, Dead].{
		is_eq : _
	}
	ActorState : { mode : ActorMode, remaining : I64 }
	Actor : { id : U64, kind : ThingKind, pos : DoomSim.Vec2, angle : DoomSim.Angle, health : I64, state : ActorState, ambush : Bool }
	Pickup : { id : U64, kind : ThingKind, pos : DoomSim.Vec2, taken : Bool }

	## Structural match for `DoomMap.Thing`, so a validated map can hand its
	## things over directly without this runtime layer importing map payloads.
	Thing : { x : I64, y : I64, angle : I64, type : U64, flags : U64 }

	Ammo : { bullets : I64, shells : I64, rockets : I64, cells : I64 }
	Keys : { blue : Bool, yellow : Bool, red : Bool }
	Player : {
		sim : DoomSim.Clock,
		health : I64,
		armor : I64,
		armor_kind : ArmorKind,
		ammo : Ammo,
		keys : Keys,
		weapon : Weapon,
	}

	Rng :: U8.{
		seed : U8 -> Rng
		seed = |value| Rng.(value)

		index : Rng -> U8
		index = |Rng.(value)| value
	}
	Random : { rng : Rng, byte : U8 }
	Shot : { rng : Rng, damage : I64, spread_turns : F32, pellets : U64 }

	Spawned : { player_start : Try(Thing, [NoPlayerStart]), actors : List(Actor), pickups : List(Pickup) }
	World : { player : Player, actors : List(Actor), pickups : List(Pickup), rng : Rng }
	Advance : { world : World, tics : U64, dropped : Bool }

	player : DoomSim.Vec2, DoomSim.Angle -> Player
	player = |pos, angle| {
		sim: DoomSim.clock(DoomSim.initial(pos, angle)),
		health: 100,
		armor: 0,
		armor_kind: NoArmor,
		ammo: { bullets: 50, shells: 0, rockets: 0, cells: 0 },
		keys: { blue: Bool.False, yellow: Bool.False, red: Bool.False },
		weapon: Pistol,
	}

	## Classify the editor numbers used by E1M1 and its normal Doom pickups.
	thing_kind : U64 -> Try(ThingKind, [UnsupportedThing(U64)])
	thing_kind = |editor_type|
		match editor_type {
			1 => Ok(PlayerStart)
			11 => Ok(DeathmatchStart)
			14 => Ok(TeleportDestination)
			3004 => Ok(ZombieMan)
			9 => Ok(ShotgunGuy)
			3001 => Ok(Imp)
			2035 => Ok(Barrel)
			2001 => Ok(ShotgunPickup)
			2007 => Ok(ClipPickup)
			2008 => Ok(ShellPickup)
			2011 => Ok(StimpackPickup)
			2012 => Ok(MedikitPickup)
			2018 => Ok(GreenArmorPickup)
			2019 => Ok(BlueArmorPickup)
			2014 => Ok(HealthBonusPickup)
			2015 => Ok(ArmorBonusPickup)
			5 => Ok(BlueKeyPickup)
			6 => Ok(YellowKeyPickup)
			13 => Ok(RedKeyPickup)
			_ => Err(UnsupportedThing(editor_type))
		}

	## Doom thing flags select easy, medium, and hard/nightmare with bits 0-2.
	skill_allowed : U64, Skill -> Bool
	skill_allowed = |flags, skill| {
		mask = match skill {
			Baby => 1
			Easy => 1
			Medium => 2
			Hard => 4
			Nightmare => 4
		}
		U64.bitwise_and(flags, mask) != 0
	}

	spawn : List(Thing), Skill -> Spawned
	spawn = |things, skill| {
		var $player_start = Err(NoPlayerStart)
		var $actors = []
		var $pickups = []
		for thing in things {
			match thing_kind(thing.type) {
				Err(_) => {}
				Ok(kind) => {
					if kind == PlayerStart {
						$player_start = Ok(thing)
					} else if skill_allowed(thing.flags, skill) and U64.bitwise_and(thing.flags, multiplayer_flag) == 0 {
						pos = { x: I64.to_f32(thing.x), y: I64.to_f32(thing.y) }
						if is_actor(kind) {
							$actors = List.append($actors, actor(List.len($actors), kind, pos, angle_from_degrees(thing.angle), U64.bitwise_and(thing.flags, ambush_flag) != 0))
						} else if is_pickup(kind) {
							$pickups = List.append($pickups, { id: List.len($pickups), kind, pos, taken: Bool.False })
						}
					}
				}
			}
		}
		{ player_start: $player_start, actors: $actors, pickups: $pickups }
	}

	actor : U64, ThingKind, DoomSim.Vec2, DoomSim.Angle, Bool -> Actor
	actor = |id, kind, pos, angle, ambush| { id, kind, pos, angle, health: actor_health(kind), state: state(Look), ambush }

	state : ActorMode -> ActorState
	state = |mode| { mode, remaining: state_duration(mode) }

	## Advance exactly one actor tic. Sensing and attack selection remain caller
	## policy; this pins the explicit state timing and its deterministic cycle.
	tick_actor : Actor -> Actor
	tick_actor = |value| {
		if value.state.mode == Dead {
			value
		} else if value.state.remaining > 1 {
			{ ..value, state: { ..value.state, remaining: value.state.remaining - 1 } }
		} else {
			next = match value.state.mode {
				Look => Chase
				Chase => Attack
				Attack => Chase
				Pain => Chase
				Dead => Dead
			}
			{ ..value, state: state(next) }
		}
	}

	set_pain : Actor -> Actor
	set_pain = |value| if value.health <= 0 { ..value, state: state(Dead) } else { ..value, state: state(Pain) }

	damage_actor : Actor, I64 -> Actor
	damage_actor = |value, amount| {
		health = I64.max(0, value.health - I64.max(0, amount))
		if health <= 0 { ..value, health, state: state(Dead) } else { ..value, health, state: state(Pain) }
	}

	## Table-free deterministic byte stream. Doom routes gameplay randomness
	## through one explicit state; this preserves that reproducibility without
	## copying the original lookup table.
	random : Rng -> Random
	random = |Rng.(index)| {
		next = U8.to_u16(index) * 73 + 41
		byte = U16.to_u8_wrap(next)
		{ rng: Rng.(byte), byte }
	}

	## Pistol consumes one random damage roll and one independent spread roll;
	## shotgun repeats the same 5/10/15 pellet rule seven times.
	hitscan : Rng, Weapon -> Shot
	hitscan = |rng, weapon| {
		pellets = if weapon == Pistol 1 else 7
		var $rng = rng
		var $damage = 0.I64
		var $spread_total = 0.I64
		for _ in List.repeat({}, pellets) {
			damage_roll = random($rng)
			$damage = $damage + (U8.to_i64(damage_roll.byte % 3) + 1) * 5
			spread_roll = random(damage_roll.rng)
			$spread_total = $spread_total + U8.to_i64(spread_roll.byte) - 128
			$rng = spread_roll.rng
		}
		{ rng: $rng, damage: $damage, spread_turns: I64.to_f32($spread_total) / U64.to_f32(pellets) / 65536, pellets }
	}

	damage_player : Player, I64 -> Player
	damage_player = |value, raw_damage| {
		damage = I64.max(0, raw_damage)
		absorbed = match value.armor_kind {
			NoArmor => 0
			GreenArmor => damage / 3
			BlueArmor => damage / 2
		}
		actual_absorbed = I64.min(value.armor, absorbed)
		armor = value.armor - actual_absorbed
		{ ..value, health: I64.max(0, value.health - (damage - actual_absorbed)), armor, armor_kind: if armor == 0 NoArmor else value.armor_kind }
	}

	collect : Player, Pickup -> { player : Player, pickup : Pickup, collected : Bool }
	collect = |value, pickup| {
		if pickup.taken {
			{ player: value, pickup, collected: Bool.False }
		} else {
			applied = apply_pickup(value, pickup.kind)
			{ player: applied.player, pickup: if applied.collected { ..pickup, taken: Bool.True } else pickup, collected: applied.collected }
		}
	}

	## One host-cycle fold: player simulation determines the number of 35 Hz
	## tics, then actor state and optional firing advance exactly that many times.
	advance : World, F32, DoomSim.Command, List(DoomSim.Segment) -> Advance
	advance = |world, elapsed, command, blockers| {
		sim = DoomSim.advance(world.player.sim, elapsed, command, blockers)
		var $next = { ..world, player: { ..world.player, sim: sim.clock } }
		for _ in List.repeat({}, sim.tics) {
			$next = world_tic($next, command)
		}
		{ world: $next, tics: sim.tics, dropped: sim.dropped }
	}

	world_tic : World, DoomSim.Command -> World
	world_tic = |world, command| {
		actors0 = List.map(world.actors, tick_actor)
		if command.fire and ammo_for(world.player) > 0 {
			shot = hitscan(world.rng, world.player.weapon)
			actors = damage_first_live(actors0, shot.damage)
			{ ..world, player: spend_ammo(world.player), actors, rng: shot.rng }
		} else {
			{ ..world, actors: actors0 }
		}
	}

	state_duration : ActorMode -> I64
	state_duration = |mode|
		match mode {
			Look => 10
			Chase => 4
			Attack => 8
			Pain => 3
			Dead => -1
		}
	actor_health = |kind|
		match kind {
			ZombieMan => 20
			ShotgunGuy => 30
			Imp => 60
			Barrel => 20
			_ => 1
		}
	is_actor = |kind| kind == ZombieMan or kind == ShotgunGuy or kind == Imp or kind == Barrel
	is_pickup = |kind|
		match kind {
			ShotgunPickup => Bool.True
			ClipPickup => Bool.True
			ShellPickup => Bool.True
			StimpackPickup => Bool.True
			MedikitPickup => Bool.True
			GreenArmorPickup => Bool.True
			BlueArmorPickup => Bool.True
			HealthBonusPickup => Bool.True
			ArmorBonusPickup => Bool.True
			BlueKeyPickup => Bool.True
			YellowKeyPickup => Bool.True
			RedKeyPickup => Bool.True
			_ => Bool.False
		}
	angle_from_degrees = |degrees| DoomSim.Angle.from_turns(I64.to_f32(degrees) / 360)
	max_health = 100.I64
	max_bullets = 200.I64
	max_shells = 50.I64
	ambush_flag = 8.U64
	multiplayer_flag = 16.U64
}

apply_pickup = |player, kind|
	match kind {
		ClipPickup => give_bullets(player, 10)
		ShellPickup => give_shells(player, 4)
		StimpackPickup => give_health(player, 10, DoomWorld.max_health)
		MedikitPickup => give_health(player, 25, DoomWorld.max_health)
		HealthBonusPickup => give_health(player, 1, 200)
		ArmorBonusPickup => { player: { ..player, armor: I64.min(200, player.armor + 1), armor_kind: if player.armor_kind == NoArmor GreenArmor else player.armor_kind }, collected: Bool.True }
		GreenArmorPickup => if player.armor >= 100 { player, collected: Bool.False } else { player: { ..player, armor: 100, armor_kind: GreenArmor }, collected: Bool.True }
		BlueArmorPickup => if player.armor >= 200 { player, collected: Bool.False } else { player: { ..player, armor: 200, armor_kind: BlueArmor }, collected: Bool.True }
		BlueKeyPickup => { player: { ..player, keys: { ..player.keys, blue: Bool.True } }, collected: !(player.keys.blue) }
		YellowKeyPickup => { player: { ..player, keys: { ..player.keys, yellow: Bool.True } }, collected: !(player.keys.yellow) }
		RedKeyPickup => { player: { ..player, keys: { ..player.keys, red: Bool.True } }, collected: !(player.keys.red) }
		ShotgunPickup => { player: { ..give_shells(player, 8).player, weapon: Shotgun }, collected: Bool.True }
		_ => { player, collected: Bool.False }
	}

give_bullets = |player, amount| {
	next = I64.min(DoomWorld.max_bullets, player.ammo.bullets + amount)
	{ player: { ..player, ammo: { ..player.ammo, bullets: next } }, collected: next > player.ammo.bullets }
}

give_shells = |player, amount| {
	next = I64.min(DoomWorld.max_shells, player.ammo.shells + amount)
	{ player: { ..player, ammo: { ..player.ammo, shells: next } }, collected: next > player.ammo.shells }
}

give_health = |player, amount, cap| {
	next = I64.min(cap, player.health + amount)
	{ player: { ..player, health: next }, collected: next > player.health }
}

ammo_for = |player|
	match player.weapon {
		Pistol => player.ammo.bullets
		Shotgun => player.ammo.shells
	}

spend_ammo = |player|
	match player.weapon {
		Pistol => { ..player, ammo: { ..player.ammo, bullets: I64.max(0, player.ammo.bullets - 1) } }
		Shotgun => { ..player, ammo: { ..player.ammo, shells: I64.max(0, player.ammo.shells - 1) } }
	}

damage_first_live = |actors, damage| {
	var $hit = Bool.False
	var $next = []
	for actor in actors {
		if !($hit) and actor.state.mode != Dead {
			$hit = Bool.True
			$next = List.append($next, DoomWorld.damage_actor(actor, damage))
		} else {
			$next = List.append($next, actor)
		}
	}
	$next
}

fixture_thing = |editor_type, flags| { x: 64, y: -32, angle: 90, type: editor_type, flags }

expect {
	actor = DoomWorld.actor(1, ZombieMan, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	var $next = actor
	for _ in List.repeat({}, 9) {
		$next = DoomWorld.tick_actor($next)
	}
	before = $next.state.mode == Look and $next.state.remaining == 1
	$next = DoomWorld.tick_actor($next)
	before and $next.state.mode == Chase and $next.state.remaining == 4
}

expect {
	first = DoomWorld.hitscan(DoomWorld.Rng.seed(0), Pistol)
	second = DoomWorld.hitscan(first.rng, Pistol)
	first.damage == 15 and second.damage == 15 and F32.abs(first.spread_turns - (90 / 65536)) < 0.000001
}

expect {
	base = { ..DoomWorld.player({ x: 0, y: 0 }, DoomSim.Angle.from_turns(0)), health: 70, armor: 50, armor_kind: GreenArmor }
	medikit : DoomWorld.Pickup
	medikit = { id: 1, kind: MedikitPickup, pos: { x: 0, y: 0 }, taken: Bool.False }
	key : DoomWorld.Pickup
	key = { id: 2, kind: BlueKeyPickup, pos: { x: 0, y: 0 }, taken: Bool.False }
	healed = DoomWorld.collect(base, medikit)
	keyed = DoomWorld.collect(healed.player, key)
	damaged = DoomWorld.damage_player(keyed.player, 30)
	healed.player.health == 95 and keyed.player.keys.blue and damaged.health == 75 and damaged.armor == 40
}

expect {
	things : List(DoomWorld.Thing)
	things = [fixture_thing(1, 7), fixture_thing(3004, 1), fixture_thing(3001, 2), fixture_thing(9, 4), fixture_thing(2007, 7), fixture_thing(3004, 16 + 7)]
	easy = DoomWorld.spawn(things, Easy)
	hard = DoomWorld.spawn(things, Hard)
	List.len(easy.actors) == 1 and List.len(hard.actors) == 1 and List.len(easy.pickups) == 1 and easy.player_start == Ok(fixture_thing(1, 7))
}

expect {
	# The world fold advances actor state by exactly the tics admitted by the
	# shared 35 Hz player clock.
	actor = DoomWorld.actor(1, Imp, { x: 128, y: 0 }, DoomSim.Angle.from_turns(0.5), Bool.False)
	world : DoomWorld.World
	world = { player: DoomWorld.player({ x: 0, y: 0 }, DoomSim.Angle.from_turns(0)), actors: [actor], pickups: [], rng: DoomWorld.Rng.seed(0) }
	advanced = DoomWorld.advance(world, DoomSim.tic_seconds * 2.1, DoomSim.neutral, [])
	next_actor = List.get(advanced.world.actors, 0) ?? actor
	advanced.tics == 2 and next_actor.state.mode == Look and next_actor.state.remaining == 8
}
