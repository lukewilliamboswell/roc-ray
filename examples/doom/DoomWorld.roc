## Pure Doom-world runtime foundations layered over `DoomSim` and the compact
## map vocabulary in `DoomMap`. Actor timing, random combat outcomes, spawning,
## inventory, and damage are deterministic application state; no host resource
## or callback crosses this module.
##
## Behavior is independently implemented using Linux Doom 1.10 and Chocolate
## Doom as oracles: `info.c` state durations/editor numbers, `p_enemy.c` actor
## state flow, `p_inter.c` pickup and armor rules, and `p_pspr.c` hitscan damage.
import DoomSim
import DoomMap

DoomWorld := [].{
	Skill := [Baby, Easy, Medium, Hard, Nightmare].{
		is_eq : _
	}
	ArmorKind := [NoArmor, GreenArmor, BlueArmor].{
		is_eq : _
	}
	Weapon := [Pistol, Shotgun, Chaingun, RocketLauncher, PlasmaRifle, Chainsaw].{
		is_eq : _
	}

	ThingKind := [
		PlayerStart,
		CooperativeStart,
		DeathmatchStart,
		TeleportDestination,
		ZombieMan,
		ShotgunGuy,
		Imp,
		Demon,
		Spectre,
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
		BackpackPickup,
		ChaingunPickup,
		RocketLauncherPickup,
		PlasmaRiflePickup,
		ChainsawPickup,
		RocketPickup,
		SoulSpherePickup,
		BerserkPickup,
		ComputerMapPickup,
		LightAmpPickup,
		BulletBoxPickup,
		ShellBoxPickup,
		CellPackPickup,
		BloodyMess,
		DeadPlayer,
		DeadFormerHuman,
		DeadDemon,
		DeadImp,
		DeadShotgunGuy,
		GorePool,
		Candle,
		BurntTree,
		Stalagmite,
		TechPillar,
		LargeTree,
		HangingBody,
		FloorLamp,
	].{
		is_eq : _
	}

	ActorMode := [Look, Chase, Attack, Pain, Dead].{
		is_eq : _
	}
	AttackKind := [NoAttack, MeleeAttack, HitscanAttack, ProjectileAttack].{
		is_eq : _
	}
	ActorState : { mode : ActorMode, remaining : I64 }
	Actor : { id : U64, kind : ThingKind, pos : DoomSim.Vec2, angle : DoomSim.Angle, health : I64, state : ActorState, ambush : Bool }
	ActorFacts : { player_pos : DoomSim.Vec2, has_sight : Bool, heard_sound : Bool, blockers : List(DoomSim.Segment) }
	ActorTic : { actor : Actor, rng : Rng, player_damage : I64, attack_kind : AttackKind }
	ActorDamage : { actor : Actor, rng : Rng, entered_pain : Bool }
	Pickup : { id : U64, kind : ThingKind, pos : DoomSim.Vec2, taken : Bool }
	Decoration : { id : U64, kind : ThingKind, pos : DoomSim.Vec2, blocking : Bool }

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
		backpack : Bool,
		berserk : Bool,
	}

	Rng :: U8.{
		seed : U8 -> Rng
		seed = |value| Rng.(value)

		index : Rng -> U8
		index = |Rng.(value)| value
	}
	Random : { rng : Rng, byte : U8 }
	Shot : { rng : Rng, damage : I64, spread_turns : F32, pellets : U64 }

	Spawned : { player_start : Try(Thing, [NoPlayerStart]), actors : List(Actor), pickups : List(Pickup), decorations : List(Decoration), unsupported : List(U64) }
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
		backpack: Bool.False,
		berserk: Bool.False,
	}

	## Classify the editor numbers used by E1M1 and its normal Doom pickups.
	thing_kind : U64 -> Try(ThingKind, [UnsupportedThing(U64)])
	thing_kind = |editor_type|
		match editor_type {
			1 => Ok(PlayerStart)
			2 => Ok(CooperativeStart)
			3 => Ok(CooperativeStart)
			4 => Ok(CooperativeStart)
			11 => Ok(DeathmatchStart)
			14 => Ok(TeleportDestination)
			3004 => Ok(ZombieMan)
			9 => Ok(ShotgunGuy)
			3001 => Ok(Imp)
			3002 => Ok(Demon)
			58 => Ok(Spectre)
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
			8 => Ok(BackpackPickup)
			2002 => Ok(ChaingunPickup)
			2003 => Ok(RocketLauncherPickup)
			2004 => Ok(PlasmaRiflePickup)
			2005 => Ok(ChainsawPickup)
			2010 => Ok(RocketPickup)
			2013 => Ok(SoulSpherePickup)
			2023 => Ok(BerserkPickup)
			2046 => Ok(ComputerMapPickup)
			2047 => Ok(LightAmpPickup)
			2048 => Ok(BulletBoxPickup)
			2049 => Ok(ShellBoxPickup)
			10 => Ok(BloodyMess)
			12 => Ok(BloodyMess)
			15 => Ok(DeadPlayer)
			17 => Ok(CellPackPickup)
			18 => Ok(DeadFormerHuman)
			19 => Ok(DeadShotgunGuy)
			20 => Ok(DeadImp)
			21 => Ok(DeadDemon)
			24 => Ok(GorePool)
			26 => Ok(Candle)
			43 => Ok(BurntTree)
			47 => Ok(Stalagmite)
			48 => Ok(TechPillar)
			54 => Ok(LargeTree)
			60 => Ok(HangingBody)
			2028 => Ok(FloorLamp)
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
		var $decorations = []
		var $unsupported = []
		for thing in things {
			match thing_kind(thing.type) {
				Err(UnsupportedThing(editor_type)) => {
					$unsupported = List.append($unsupported, editor_type)
				}
				Ok(kind) => {
					if kind == PlayerStart {
						$player_start = Ok(thing)
					} else if skill_allowed(thing.flags, skill) and U64.bitwise_and(thing.flags, multiplayer_flag) == 0 {
						pos = { x: I64.to_f32(thing.x), y: I64.to_f32(thing.y) }
						if is_actor(kind) {
							$actors = List.append($actors, actor(List.len($actors), kind, pos, angle_from_degrees(thing.angle), U64.bitwise_and(thing.flags, ambush_flag) != 0))
						} else if is_pickup(kind) {
							$pickups = List.append($pickups, { id: List.len($pickups), kind, pos, taken: Bool.False })
						} else if is_decoration(kind) {
							$decorations = List.append($decorations, { id: List.len($decorations), kind, pos, blocking: decoration_blocking(kind) })
						}
					}
				}
			}
		}
		{ player_start: $player_start, actors: $actors, pickups: $pickups, decorations: $decorations, unsupported: $unsupported }
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

	## Advance one actor from explicit perception facts. Sound wakes ordinary
	## actors, while ambush actors require sight. Chase direction is quantized to
	## Doom's eight compass directions and collision uses the shared bounded
	## radius/segment slide. Attack damage is emitted for the caller to apply.
	tick_actor_with : Actor, ActorFacts, Rng -> ActorTic
	tick_actor_with = |value, facts, rng| {
		if value.state.mode == Dead {
			{ actor: value, rng, player_damage: 0, attack_kind: NoAttack }
		} else {
			match value.state.mode {
				Look => {
					awake = facts.has_sight or (facts.heard_sound and !(value.ambush))
					actor1 = if awake {
						{ ..value, state: state(Chase) }
					} else if value.state.remaining > 1 {
						{ ..value, state: { ..value.state, remaining: value.state.remaining - 1 } }
					} else {
						{ ..value, state: state(Look) }
					}
					{ actor: actor1, rng, player_damage: 0, attack_kind: NoAttack }
				}
				Chase => {
					if value.state.remaining > 1 {
						{ actor: { ..value, state: { ..value.state, remaining: value.state.remaining - 1 } }, rng, player_damage: 0, attack_kind: NoAttack }
					} else if facts.has_sight and can_attack(value, facts.player_pos) {
						{ actor: { ..value, angle: face_toward(value.pos, facts.player_pos), state: state(Attack) }, rng, player_damage: 0, attack_kind: NoAttack }
					} else {
						moved = chase_move(value, facts)
						{ actor: { ..moved, state: state(Chase) }, rng, player_damage: 0, attack_kind: NoAttack }
					}
				}
				Attack => {
					if value.state.remaining > 1 {
						{ actor: { ..value, state: { ..value.state, remaining: value.state.remaining - 1 } }, rng, player_damage: 0, attack_kind: NoAttack }
					} else if facts.has_sight and can_attack(value, facts.player_pos) {
						attack = actor_attack(value, facts.player_pos, rng)
						{ actor: { ..value, state: state(Chase) }, rng: attack.rng, player_damage: attack.damage, attack_kind: attack.kind }
					} else {
						{ actor: { ..value, state: state(Chase) }, rng, player_damage: 0, attack_kind: NoAttack }
					}
				}
				Pain => {
					actor1 = if value.state.remaining > 1 { ..value, state: { ..value.state, remaining: value.state.remaining - 1 } } else { ..value, state: state(Chase) }
					{ actor: actor1, rng, player_damage: 0, attack_kind: NoAttack }
				}
				Dead => { actor: value, rng, player_damage: 0, attack_kind: NoAttack }
			}
		}
	}

	set_pain : Actor -> Actor
	set_pain = |value| if value.health <= 0 { ..value, state: state(Dead) } else { ..value, state: state(Pain) }

	damage_actor : Actor, I64 -> Actor
	damage_actor = |value, amount| {
		health = I64.max(0, value.health - I64.max(0, amount))
		if health <= 0 { ..value, health, state: state(Dead) } else { ..value, health, state: state(Pain) }
	}

	## Apply damage and consume one gameplay random byte for Doom-style pain
	## chance. Death always wins; surviving actors may continue their current
	## state when the pain roll misses.
	damage_actor_random : Actor, I64, Rng -> ActorDamage
	damage_actor_random = |value, amount, rng| {
		roll = random(rng)
		health = I64.max(0, value.health - I64.max(0, amount))
		if health <= 0 {
			{ actor: { ..value, health, state: state(Dead) }, rng: roll.rng, entered_pain: Bool.False }
		} else {
			entered_pain = U8.to_u64(roll.byte) < pain_chance(value.kind)
			actor1 = if entered_pain { ..value, health, state: state(Pain) } else { ..value, health }
			{ actor: actor1, rng: roll.rng, entered_pain }
		}
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
		pellets = match weapon {
			Shotgun => 7
			_ => 1
		}
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
			Demon => 150
			Spectre => 150
			Barrel => 20
			_ => 1
		}
	is_actor = |kind| kind == ZombieMan or kind == ShotgunGuy or kind == Imp or kind == Demon or kind == Spectre or kind == Barrel
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
			BackpackPickup => Bool.True
			ChaingunPickup => Bool.True
			RocketLauncherPickup => Bool.True
			PlasmaRiflePickup => Bool.True
			ChainsawPickup => Bool.True
			RocketPickup => Bool.True
			SoulSpherePickup => Bool.True
			BerserkPickup => Bool.True
			ComputerMapPickup => Bool.True
			LightAmpPickup => Bool.True
			BulletBoxPickup => Bool.True
			ShellBoxPickup => Bool.True
			CellPackPickup => Bool.True
			_ => Bool.False
		}
	is_decoration = |kind|
		match kind {
			BloodyMess | DeadPlayer | DeadFormerHuman | DeadDemon | DeadImp | DeadShotgunGuy | GorePool | Candle | BurntTree | Stalagmite | TechPillar | LargeTree | HangingBody | FloorLamp => Bool.True
			_ => Bool.False
		}
	decoration_blocking = |kind|
		match kind {
			BurntTree | Stalagmite | TechPillar | LargeTree | HangingBody | FloorLamp => Bool.True
			_ => Bool.False
		}
	angle_from_degrees = |degrees| DoomSim.Angle.from_turns(I64.to_f32(degrees) / 360)
	max_health = 100.I64
	max_bullets = 200.I64
	max_shells = 50.I64
	max_rockets = 50.I64
	max_cells = 300.I64
	actor_radius = 20
	player_collision_radius = 16
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
		BackpackPickup => {
			ammo = {
				bullets: I64.min(DoomWorld.max_bullets * 2, player.ammo.bullets + 10),
				shells: I64.min(DoomWorld.max_shells * 2, player.ammo.shells + 4),
				rockets: I64.min(DoomWorld.max_rockets * 2, player.ammo.rockets + 1),
				cells: I64.min(DoomWorld.max_cells * 2, player.ammo.cells + 20),
			}
			{ player: { ..player, backpack: Bool.True, ammo }, collected: Bool.True }
		}
		ChaingunPickup => { player: { ..give_bullets(player, 20).player, weapon: Chaingun }, collected: Bool.True }
		RocketLauncherPickup => { player: { ..give_rockets(player, 2).player, weapon: RocketLauncher }, collected: Bool.True }
		PlasmaRiflePickup => { player: { ..give_cells(player, 40).player, weapon: PlasmaRifle }, collected: Bool.True }
		ChainsawPickup => { player: { ..player, weapon: Chainsaw }, collected: Bool.True }
		RocketPickup => give_rockets(player, 1)
		SoulSpherePickup => give_health(player, 100, 200)
		BerserkPickup => { player: { ..give_health(player, 100, DoomWorld.max_health).player, berserk: Bool.True, weapon: Chainsaw }, collected: Bool.True }
		ComputerMapPickup => { player, collected: Bool.True }
		LightAmpPickup => { player, collected: Bool.True }
		BulletBoxPickup => give_bullets(player, 50)
		ShellBoxPickup => give_shells(player, 20)
		CellPackPickup => give_cells(player, 100)
		_ => { player, collected: Bool.False }
	}

give_bullets = |player, amount| {
	cap = if player.backpack DoomWorld.max_bullets * 2 else DoomWorld.max_bullets
	next = I64.min(cap, player.ammo.bullets + amount)
	{ player: { ..player, ammo: { ..player.ammo, bullets: next } }, collected: next > player.ammo.bullets }
}

give_shells = |player, amount| {
	cap = if player.backpack DoomWorld.max_shells * 2 else DoomWorld.max_shells
	next = I64.min(cap, player.ammo.shells + amount)
	{ player: { ..player, ammo: { ..player.ammo, shells: next } }, collected: next > player.ammo.shells }
}

give_rockets = |player, amount| {
	cap = if player.backpack DoomWorld.max_rockets * 2 else DoomWorld.max_rockets
	next = I64.min(cap, player.ammo.rockets + amount)
	{ player: { ..player, ammo: { ..player.ammo, rockets: next } }, collected: next > player.ammo.rockets }
}

give_cells = |player, amount| {
	cap = if player.backpack DoomWorld.max_cells * 2 else DoomWorld.max_cells
	next = I64.min(cap, player.ammo.cells + amount)
	{ player: { ..player, ammo: { ..player.ammo, cells: next } }, collected: next > player.ammo.cells }
}

give_health = |player, amount, cap| {
	next = I64.min(cap, player.health + amount)
	{ player: { ..player, health: next }, collected: next > player.health }
}

ammo_for = |player|
	match player.weapon {
		Pistol => player.ammo.bullets
		Shotgun => player.ammo.shells
		Chaingun => player.ammo.bullets
		RocketLauncher => player.ammo.rockets
		PlasmaRifle => player.ammo.cells
		Chainsaw => 1
	}

spend_ammo = |player|
	match player.weapon {
		Pistol => { ..player, ammo: { ..player.ammo, bullets: I64.max(0, player.ammo.bullets - 1) } }
		Shotgun => { ..player, ammo: { ..player.ammo, shells: I64.max(0, player.ammo.shells - 1) } }
		Chaingun => { ..player, ammo: { ..player.ammo, bullets: I64.max(0, player.ammo.bullets - 1) } }
		RocketLauncher => { ..player, ammo: { ..player.ammo, rockets: I64.max(0, player.ammo.rockets - 1) } }
		PlasmaRifle => { ..player, ammo: { ..player.ammo, cells: I64.max(0, player.ammo.cells - 1) } }
		Chainsaw => player
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

can_attack = |actor, player_pos| {
	distance2 = DoomSim.distance_squared(actor.pos, player_pos)
	if actor.kind == Demon or actor.kind == Spectre {
		distance2 <= 64 * 64
	} else if actor.kind == Imp {
		distance2 <= 1024 * 1024
	} else {
		(actor.kind == ZombieMan or actor.kind == ShotgunGuy) and distance2 <= 2048 * 2048
	}
}

## Doom chase movement selects one of eight directions rather than steering by
## an arbitrary floating angle. The diagonal components are unit length.
chase_direction = |from, to| {
	dx = to.x - from.x
	dy = to.y - from.y
	ax = F32.abs(dx)
	ay = F32.abs(dy)
	sx = if dx < 0 -1 else if dx > 0 1 else 0
	sy = if dy < 0 -1 else if dy > 0 1 else 0
	if ax == 0 and ay == 0 {
		DoomSim.zero
	} else if ax > ay * 2 {
		{ x: sx, y: 0 }
	} else if ay > ax * 2 {
		{ x: 0, y: sy }
	} else {
		{ x: sx * 0.70710677, y: sy * 0.70710677 }
	}
}

direction_angle = |direction|
	if direction.x > 0.9 {
		DoomSim.Angle.from_turns(0)
	} else if direction.x < -0.9 {
		DoomSim.Angle.from_turns(0.5)
	} else if direction.y > 0.9 {
		DoomSim.Angle.from_turns(0.25)
	} else if direction.y < -0.9 {
		DoomSim.Angle.from_turns(0.75)
	} else if direction.x > 0 and direction.y > 0 {
		DoomSim.Angle.from_turns(0.125)
	} else if direction.x < 0 and direction.y > 0 {
		DoomSim.Angle.from_turns(0.375)
	} else if direction.x < 0 and direction.y < 0 {
		DoomSim.Angle.from_turns(0.625)
	} else {
		DoomSim.Angle.from_turns(0.875)
	}

face_toward = |from, to| direction_angle(chase_direction(from, to))

chase_move = |actor, facts| {
	direction = chase_direction(actor.pos, facts.player_pos)
	displacement = DoomSim.scale(direction, actor_speed(actor.kind))
	candidate = DoomSim.move_with_slide(actor.pos, displacement, DoomWorld.actor_radius, facts.blockers)
	min_distance = DoomWorld.actor_radius + DoomWorld.player_collision_radius
	pos = if DoomSim.distance_squared(candidate, facts.player_pos) < min_distance * min_distance actor.pos else candidate
	{ ..actor, pos, angle: direction_angle(direction) }
}

actor_speed = |kind|
	match kind {
		ZombieMan => 8
		ShotgunGuy => 8
		Imp => 8
		Demon => 10
		Spectre => 10
		_ => 0
	}

actor_attack = |actor, player_pos, rng| {
	distance2 = DoomSim.distance_squared(actor.pos, player_pos)
	if actor.kind == Demon or actor.kind == Spectre {
		roll = DoomWorld.random(rng)
		{ rng: roll.rng, damage: (U8.to_i64(roll.byte % 10) + 1) * 4, kind: MeleeAttack }
	} else if actor.kind == ShotgunGuy {
		var $rng = rng
		var $damage = 0.I64
		for _ in List.repeat({}, 3) {
			roll = DoomWorld.random($rng)
			$damage = $damage + (U8.to_i64(roll.byte % 5) + 1) * 3
			$rng = roll.rng
		}
		{ rng: $rng, damage: $damage, kind: HitscanAttack }
	} else {
		roll = DoomWorld.random(rng)
		melee = actor.kind == Imp and distance2 <= 64 * 64
		damage = if melee {
			(U8.to_i64(roll.byte % 8) + 1) * 3
		} else if actor.kind == Imp {
			# Deterministic impact foundation for the later projectile layer.
			(U8.to_i64(roll.byte % 8) + 1) * 3
		} else {
			(U8.to_i64(roll.byte % 5) + 1) * 3
		}
		kind = if melee MeleeAttack else if actor.kind == Imp ProjectileAttack else HitscanAttack
		{ rng: roll.rng, damage, kind }
	}
}

pain_chance = |kind|
	match kind {
		ZombieMan => 200
		ShotgunGuy => 170
		Imp => 200
		Demon => 180
		Spectre => 180
		Barrel => 255
		_ => 0
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

expect {
	# Sound wakes ordinary monsters, but an ambush-flagged monster waits until
	# it has direct sight.
	base = DoomWorld.actor(1, ZombieMan, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	ambush = { ..base, id: 2, ambush: Bool.True }
	facts : DoomWorld.ActorFacts
	facts = { player_pos: { x: 128, y: 0 }, has_sight: Bool.False, heard_sound: Bool.True, blockers: [] }
	woken = DoomWorld.tick_actor_with(base, facts, DoomWorld.Rng.seed(0))
	sleeping = DoomWorld.tick_actor_with(ambush, facts, DoomWorld.Rng.seed(0))
	var $still_ambush = sleeping
	for _ in List.repeat({}, 12) {
		$still_ambush = DoomWorld.tick_actor_with($still_ambush.actor, facts, $still_ambush.rng)
	}
	seen = DoomWorld.tick_actor_with(sleeping.actor, { ..facts, has_sight: Bool.True }, sleeping.rng)
	woken.actor.state.mode == Chase and sleeping.actor.state.mode == Look and $still_ambush.actor.state.mode == Look and seen.actor.state.mode == Chase
}

expect {
	# A chase decision cannot cross a blocking line, and cannot overlap the
	# player's combined collision radii.
	base = DoomWorld.actor(1, Imp, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	ready = { ..base, state: { mode: Chase, remaining: 1 } }
	wall : DoomSim.Segment
	wall = { start: { x: 24, y: -64 }, end: { x: 24, y: 64 } }
	blocked = DoomWorld.tick_actor_with(ready, { player_pos: { x: 100, y: 0 }, has_sight: Bool.False, heard_sound: Bool.False, blockers: [wall] }, DoomWorld.Rng.seed(0))
	close = DoomWorld.tick_actor_with(ready, { player_pos: { x: 32, y: 0 }, has_sight: Bool.False, heard_sound: Bool.False, blockers: [] }, DoomWorld.Rng.seed(0))
	blocked.actor.pos == base.pos and close.actor.pos == base.pos
}

expect {
	# Hitscan damage occurs only on the terminal attack tic and then returns to
	# the chase cadence.
	base = DoomWorld.actor(1, ZombieMan, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	var $turn = { actor: { ..base, state: DoomWorld.state(Attack) }, rng: DoomWorld.Rng.seed(0), player_damage: 0, attack_kind: NoAttack }
	facts : DoomWorld.ActorFacts
	facts = { player_pos: { x: 128, y: 0 }, has_sight: Bool.True, heard_sound: Bool.False, blockers: [] }
	for _ in List.repeat({}, 7) {
		$turn = DoomWorld.tick_actor_with($turn.actor, facts, $turn.rng)
	}
	before = $turn.attack_kind == NoAttack and $turn.actor.state.remaining == 1
	$turn = DoomWorld.tick_actor_with($turn.actor, facts, $turn.rng)
	before and $turn.attack_kind == HitscanAttack and $turn.player_damage == 6 and $turn.actor.state.mode == Chase
}

expect {
	base = DoomWorld.actor(1, Imp, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	pained = DoomWorld.damage_actor_random(base, 5, DoomWorld.Rng.seed(0))
	killed = DoomWorld.damage_actor_random(base, 1000, DoomWorld.Rng.seed(0))
	pained.entered_pain and pained.actor.health == 55 and pained.actor.state.mode == Pain and killed.actor.health == 0 and killed.actor.state.mode == Dead and !(killed.entered_pain)
}

expect {
	base = DoomWorld.actor(1, Imp, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	ready = { ..base, state: { mode: Attack, remaining: 1 } }
	near : DoomWorld.ActorFacts
	near = { player_pos: { x: 48, y: 0 }, has_sight: Bool.True, heard_sound: Bool.False, blockers: [] }
	far = { ..near, player_pos: { x: 256, y: 0 } }
	melee = DoomWorld.tick_actor_with(ready, near, DoomWorld.Rng.seed(0))
	projectile = DoomWorld.tick_actor_with(ready, far, DoomWorld.Rng.seed(0))
	melee.attack_kind == MeleeAttack and projectile.attack_kind == ProjectileAttack
}

expect {
	spawned = DoomWorld.spawn(DoomMap.e1m1.raw().things, Medium)
	List.is_empty(spawned.unsupported)
		and List.len(spawned.actors) == 51
			and List.len(spawned.pickups) == 78
				and List.len(spawned.decorations) == 80
}

expect {
	demon0 = DoomWorld.actor(1, Demon, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), Bool.False)
	demon = { ..demon0, state: { mode: Attack, remaining: 1 } }
	facts : DoomWorld.ActorFacts
	facts = { player_pos: { x: 48, y: 0 }, has_sight: Bool.True, heard_sound: Bool.False, blockers: [] }
	turn = DoomWorld.tick_actor_with(demon, facts, DoomWorld.Rng.seed(0))
	turn.attack_kind == MeleeAttack and turn.player_damage > 0 and turn.actor.health == 150
}

expect {
	player = DoomWorld.player({ x: 0, y: 0 }, DoomSim.Angle.from_turns(0))
	backpack : DoomWorld.Pickup
	backpack = { id: 0, kind: BackpackPickup, pos: { x: 0, y: 0 }, taken: Bool.False }
	cell_pack : DoomWorld.Pickup
	cell_pack = { id: 1, kind: CellPackPickup, pos: { x: 0, y: 0 }, taken: Bool.False }
	packed = DoomWorld.collect(player, backpack)
	cells = DoomWorld.collect(packed.player, cell_pack)
	packed.player.backpack and packed.player.ammo.bullets == 60 and cells.player.ammo.cells == 120
}
