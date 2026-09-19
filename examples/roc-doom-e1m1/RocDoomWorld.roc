## Pure Doom-world runtime foundations layered over `RocDoomSim` and the compact
## map vocabulary in `RocDoomMap`. Actor timing, random combat outcomes, spawning,
## inventory, and damage are deterministic application state; no host resource
## or callback crosses this module.
##
## Behavior is independently implemented using Linux Doom 1.10 and Chocolate
## Doom as oracles: `info.c` state durations/editor numbers, `p_enemy.c` actor
## state flow, `p_inter.c` pickup and armor rules, and `p_pspr.c` hitscan damage.
import RocDoomSim
import RocDoomMap

RocDoomWorld := [].{
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
		DroppedShotgun,
		DroppedClip,
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
	ActorState : { mode : ActorMode, remaining : I64, attacked : Bool }
	Actor : { id : U64, kind : ThingKind, pos : RocDoomSim.Vec2, angle : RocDoomSim.Angle, spawn_pos : RocDoomSim.Vec2, spawn_angle : RocDoomSim.Angle, health : I64, state : ActorState, ambush : Bool, reaction_time : I64, target_threshold : I64, move_count : I64, move_dir : I64, chase_frame : U64, just_attacked : Bool, dead_tics : U64 }
	OccupiedActor : { pos : RocDoomSim.Vec2, radius : F32 }
	ActorFacts : { player_pos : RocDoomSim.Vec2, has_sight : Bool, heard_sound : Bool, blockers : List(RocDoomSim.Segment), occupied : List(OccupiedActor), nightmare : Bool, used_door : Bool }
	ActorTic : { actor : Actor, rng : Rng, player_damage : I64, attack_kind : AttackKind }
	ActorDamage : { actor : Actor, rng : Rng, entered_pain : Bool }
	Pickup : { id : U64, kind : ThingKind, pos : RocDoomSim.Vec2, taken : Bool }
	Decoration : { id : U64, kind : ThingKind, pos : RocDoomSim.Vec2, blocking : Bool }

	## Structural match for `RocDoomMap.Thing`, so a validated map can hand its
	## things over directly without this runtime layer importing map payloads.
	Thing : { x : I64, y : I64, angle : I64, type : U64, flags : U64 }

	Ammo : { bullets : I64, shells : I64, rockets : I64, cells : I64 }
	Weapons : { pistol : Bool, shotgun : Bool, chaingun : Bool, rocket_launcher : Bool, plasma_rifle : Bool, chainsaw : Bool }
	Keys : { blue : Bool, yellow : Bool, red : Bool }
	Player : {
		sim : RocDoomSim.Clock,
		health : I64,
		armor : I64,
		armor_kind : ArmorKind,
		ammo : Ammo,
		keys : Keys,
		weapon : Weapon,
		weapons : Weapons,
		backpack : Bool,
		berserk : Bool,
		computer_map : Bool,
		light_amp_tics : U64,
	}

	Rng :: U8.{
		seed : U8 -> Rng
		seed = |value| Rng.(value)

		index : Rng -> U8
		index = |Rng.(value)| value
	}
	Random : { rng : Rng, byte : U8 }
	Shot : { rng : Rng, damage : I64, spread_turns : F32, pellets : U64 }

	Spawned : { player_start : Try(Thing, [NoPlayerStart]), actors : List(Actor), pickups : List(Pickup), decorations : List(Decoration), unsupported : List(U64), rng : Rng }
	World : { player : Player, actors : List(Actor), pickups : List(Pickup), rng : Rng }
	Advance : { world : World, tics : U64, dropped : Bool }

	player : RocDoomSim.Vec2, RocDoomSim.Angle -> Player
	player = |pos, angle| {
		sim: RocDoomSim.clock(RocDoomSim.initial(pos, angle)),
		health: 100,
		armor: 0,
		armor_kind: NoArmor,
		ammo: { bullets: 50, shells: 0, rockets: 0, cells: 0 },
		keys: { blue: Bool.False, yellow: Bool.False, red: Bool.False },
		weapon: Pistol,
		weapons: { pistol: Bool.True, shotgun: Bool.False, chaingun: Bool.False, rocket_launcher: Bool.False, plasma_rifle: Bool.False, chainsaw: Bool.False },
		backpack: Bool.False,
		berserk: Bool.False,
		computer_map: Bool.False,
		light_amp_tics: 0,
	}

	owns : Player, Weapon -> Bool
	owns = |value, weapon| owns_weapon(value, weapon)

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
		var $rng = Rng.seed(0)
		for thing in things {
			match thing_kind(thing.type) {
				Err(UnsupportedThing(editor_type)) => {
					$unsupported = List.append($unsupported, editor_type)
				}
				Ok(kind) => {
					if kind == PlayerStart {
						$player_start = Ok(thing)
						roll = RocDoomWorld.random($rng)
						$rng = roll.rng
					} else if kind == CooperativeStart or kind == DeathmatchStart {
						# These starts are retained by the map loader but do not spawn an
						# object in a single-player run.
					} else if skill_allowed(thing.flags, skill) and U64.bitwise_and(thing.flags, multiplayer_flag) == 0 {
						roll = RocDoomWorld.random($rng)
						$rng = roll.rng
						pos = { x: I64.to_f32(thing.x), y: I64.to_f32(thing.y) }
						if is_actor(kind) {
							spawned_actor = actor(List.len($actors), kind, pos, angle_from_degrees(thing.angle), U64.bitwise_and(thing.flags, ambush_flag) != 0)
							remaining = I64.max(1, spawned_actor.state.remaining - U8.to_i64(roll.byte % 4))
							$actors = List.append($actors, { ..spawned_actor, state: { ..spawned_actor.state, remaining } })
						} else if is_pickup(kind) {
							$pickups = List.append($pickups, { id: List.len($pickups), kind, pos, taken: Bool.False })
						} else if is_decoration(kind) {
							$decorations = List.append($decorations, { id: List.len($decorations), kind, pos, blocking: decoration_blocking(kind) })
						}
					}
				}
			}
		}
		{ player_start: $player_start, actors: $actors, pickups: $pickups, decorations: $decorations, unsupported: $unsupported, rng: $rng }
	}

	actor : U64, ThingKind, RocDoomSim.Vec2, RocDoomSim.Angle, Bool -> Actor
	actor = |id, kind, pos, angle, ambush| { id, kind, pos, angle, spawn_pos: pos, spawn_angle: angle, health: actor_health(kind), state: state_for(kind, Look), ambush, reaction_time: 8, target_threshold: 0, move_count: 0, move_dir: -1, chase_frame: 0, just_attacked: Bool.False, dead_tics: 0 }

	state : ActorMode -> ActorState
	state = |mode| state_for(ZombieMan, mode)

	state_for : ThingKind, ActorMode -> ActorState
	state_for = |kind, mode| { mode, remaining: state_duration_for(kind, mode), attacked: Bool.False }

	## Advance exactly one actor tic. Sensing and attack selection remain caller
	## policy; this pins the explicit state timing and its deterministic cycle.
	tick_actor : Actor -> Actor
	tick_actor = |value| {
		if value.state.mode == Dead {
			advance_dead(value)
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
			{ ..value, state: state_for(value.kind, next) }
		}
	}

	## Advance one actor from explicit perception facts. Sound wakes ordinary
	## actors, while ambush actors require sight. Chase direction is quantized to
	## Doom's eight compass directions and collision uses the shared bounded
	## radius/segment slide. Attack damage is emitted for the caller to apply.
	tick_actor_with : Actor, ActorFacts, Rng -> ActorTic
	tick_actor_with = |value, facts, rng| {
		if value.state.mode == Dead {
			{ actor: advance_dead(value), rng, player_damage: 0, attack_kind: NoAttack }
		} else if value.kind == Barrel {
			{ actor: value, rng, player_damage: 0, attack_kind: NoAttack }
		} else {
			match value.state.mode {
				Look => {
					awake = look_sees_player(value, facts) or (facts.heard_sound and !(value.ambush))
					wake = if awake wake_random(value.kind, rng) else { rng, byte: 0 }
					actor1 = if awake {
						{ ..value, state: state_for(value.kind, Chase) }
					} else if value.state.remaining > 1 {
						{ ..value, state: { ..value.state, remaining: value.state.remaining - 1 } }
					} else {
						{ ..value, state: state_for(value.kind, Look) }
					}
					{ actor: actor1, rng: wake.rng, player_damage: 0, attack_kind: NoAttack }
				}
				Chase => {
					if value.state.remaining > 1 {
						{ actor: { ..value, state: { ..value.state, remaining: value.state.remaining - 1 } }, rng, player_damage: 0, attack_kind: NoAttack }
					} else {
						reaction_time = if value.reaction_time > 0 value.reaction_time - 1 else 0
						target_threshold = if value.target_threshold > 0 value.target_threshold - 1 else 0
						chase_frame = (value.chase_frame + 1) % 8
						if facts.used_door {
							count = RocDoomWorld.random(rng)
							active = RocDoomWorld.random(count.rng)
							actor1 = { ..value, reaction_time, target_threshold, chase_frame, move_count: U8.to_i64(count.byte % 16), move_dir: -1, just_attacked: Bool.False, state: state_for(value.kind, Chase) }
							{ actor: actor1, rng: active.rng, player_damage: 0, attack_kind: NoAttack }
						} else if value.just_attacked and !(facts.nightmare) {
							walk = select_chase_move({ ..value, reaction_time, target_threshold, chase_frame, just_attacked: Bool.False }, facts, rng)
							{ actor: { ..walk.actor, state: state_for(value.kind, Chase) }, rng: walk.rng, player_damage: 0, attack_kind: NoAttack }
						} else {
							ready = { ..value, reaction_time, target_threshold, just_attacked: Bool.False }
							decision = attack_decision(ready, facts.player_pos, facts.has_sight, facts.nightmare, rng)
							if decision.attack {
								{ actor: { ..ready, angle: face_toward(value.pos, facts.player_pos), state: state_for(value.kind, Attack) }, rng: decision.rng, player_damage: 0, attack_kind: NoAttack }
							} else {
								walk = chase_walk({ ..ready, chase_frame }, facts, decision.rng)
								active = RocDoomWorld.random(walk.rng)
								{ actor: { ..walk.actor, state: state_for(value.kind, Chase) }, rng: active.rng, player_damage: 0, attack_kind: NoAttack }
							}
						}
					}
				}
				Attack => {
					action_now = !(value.state.attacked) and value.state.remaining == attack_action_remaining(value.kind)
					if action_now {
						attack = actor_attack(value, facts.player_pos, facts.has_sight, rng)
						next_state = if value.state.remaining > 1 { ..value.state, remaining: value.state.remaining - 1, attacked: Bool.True } else state_for(value.kind, Chase)
						{ actor: { ..value, state: next_state, just_attacked: Bool.True }, rng: attack.rng, player_damage: attack.damage, attack_kind: attack.kind }
					} else if value.state.remaining > 1 {
						{ actor: { ..value, state: { ..value.state, remaining: value.state.remaining - 1, attacked: value.state.attacked or action_now } }, rng, player_damage: 0, attack_kind: NoAttack }
					} else {
						{ actor: { ..value, state: state_for(value.kind, Chase) }, rng, player_damage: 0, attack_kind: NoAttack }
					}
				}
				Pain => {
					actor1 = if value.state.remaining > 1 { ..value, state: { ..value.state, remaining: value.state.remaining - 1 } } else { ..value, state: state_for(value.kind, Chase) }
					{ actor: actor1, rng, player_damage: 0, attack_kind: NoAttack }
				}
				Dead => { actor: value, rng, player_damage: 0, attack_kind: NoAttack }
			}
		}
	}

	advance_dead = |value| {
		state1 = if value.state.remaining > 1 { ..value.state, remaining: value.state.remaining - 1 } else value.state
		{ ..value, state: state1, dead_tics: value.dead_tics + 1 }
	}

	set_pain : Actor -> Actor
	set_pain = |value| if value.health <= 0 { ..value, state: state_for(value.kind, Dead), dead_tics: 0 } else { ..value, state: state_for(value.kind, Pain) }

	damage_actor : Actor, I64 -> Actor
	damage_actor = |value, amount| {
		if amount <= 0 {
			value
		} else {
			health = I64.max(0, value.health - amount)
			if health <= 0 { ..value, health, state: state_for(value.kind, Dead), dead_tics: 0 } else { ..value, health, state: state_for(value.kind, Pain) }
		}
	}

	## Apply damage and consume one gameplay random byte for Doom-style pain
	## chance. Death always wins; surviving actors may continue their current
	## state when the pain roll misses.
	damage_actor_random : Actor, I64, Rng -> ActorDamage
	damage_actor_random = |value, amount, rng| {
		if amount <= 0 or value.state.mode == Dead {
			{ actor: value, rng, entered_pain: Bool.False }
		} else {
			health = I64.max(0, value.health - amount)
			if health <= 0 {
				roll = random(rng)
				death = state_for(value.kind, Dead)
				remaining = I64.max(1, death.remaining - U8.to_i64(roll.byte % 4))
				{ actor: { ..value, health, state: { ..death, remaining }, dead_tics: 0 }, rng: roll.rng, entered_pain: Bool.False }
			} else {
				roll = random(rng)
				entered_pain = U8.to_u64(roll.byte) < pain_chance(value.kind)
				actor1 = if entered_pain { ..value, health, reaction_time: 0, state: state_for(value.kind, Pain) } else { ..value, health, reaction_time: 0 }
				{ actor: actor1, rng: roll.rng, entered_pain }
			}
		}
	}

	## Advance the single explicit gameplay-random index and read its canonical
	## byte. Presentation randomness must remain on a separate stream.
	random : Rng -> Random
	random = |Rng.(index)| {
		next = U16.to_u8_wrap(U8.to_u16(index) + 1)
		byte = List.get(gameplay_random_table, U8.to_u64(next)) ?? crash "complete gameplay random table"
		{ rng: Rng.(next), byte }
	}

	gameplay_random_table = [
		0, 8, 109, 220, 222, 241, 149, 107, 75, 248, 254, 140, 16, 66, 74, 21,
		211, 47, 80, 242, 154, 27, 205, 128, 161, 89, 77, 36, 95, 110, 85, 48,
		212, 140, 211, 249, 22, 79, 200, 50, 28, 188, 52, 140, 202, 120, 68, 145,
		62, 70, 184, 190, 91, 197, 152, 224, 149, 104, 25, 178, 252, 182, 202, 182,
		141, 197, 4, 81, 181, 242, 145, 42, 39, 227, 156, 198, 225, 193, 219, 93,
		122, 175, 249, 0, 175, 143, 70, 239, 46, 246, 163, 53, 163, 109, 168, 135,
		2, 235, 25, 92, 20, 145, 138, 77, 69, 166, 78, 176, 173, 212, 166, 113,
		94, 161, 41, 50, 239, 49, 111, 164, 70, 60, 2, 37, 171, 75, 136, 156,
		11, 56, 42, 146, 138, 229, 73, 146, 77, 61, 98, 196, 135, 106, 63, 197,
		195, 86, 96, 203, 113, 101, 170, 247, 181, 113, 80, 250, 108, 7, 255, 237,
		129, 226, 79, 107, 112, 166, 103, 241, 24, 223, 239, 120, 198, 58, 60, 82,
		128, 3, 184, 66, 143, 224, 145, 224, 81, 206, 163, 45, 63, 90, 168, 114,
		59, 33, 159, 95, 28, 139, 123, 98, 125, 196, 15, 70, 194, 253, 54, 14,
		109, 226, 71, 17, 161, 93, 186, 87, 244, 138, 20, 52, 123, 251, 26, 36,
		17, 46, 52, 231, 232, 76, 31, 221, 84, 37, 216, 165, 212, 106, 197, 242,
		98, 43, 39, 175, 254, 145, 190, 84, 118, 222, 187, 136, 120, 163, 236, 249,
	]

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

	collect_for_skill : Player, Pickup, Skill -> { player : Player, pickup : Pickup, collected : Bool }
	collect_for_skill = |value, pickup, skill| {
		first = collect(value, pickup)
		if !(first.collected) or !(skill == Baby or skill == Nightmare) or !(grants_ammo(pickup.kind)) {
			first
		} else {
			second = apply_pickup(first.player, pickup.kind)
			{ player: second.player, pickup: first.pickup, collected: Bool.True }
		}
	}

	## One host-cycle fold: player simulation determines the number of 35 Hz
	## tics, then actor state and optional firing advance exactly that many times.
	advance : World, F32, RocDoomSim.Command, List(RocDoomSim.Segment) -> Advance
	advance = |world, elapsed, command, blockers| {
		sim = RocDoomSim.advance(world.player.sim, elapsed, command, blockers)
		var $next = { ..world, player: { ..world.player, sim: sim.clock } }
		for _ in List.repeat({}, sim.tics) {
			$next = world_tic($next, command)
		}
		{ world: $next, tics: sim.tics, dropped: sim.dropped }
	}

	world_tic : World, RocDoomSim.Command -> World
	world_tic = |world, command| {
		actors0 = List.map(world.actors, tick_actor)
		player0 = tick_player_powers(world.player)
		if command.fire and ammo_for(player0) > 0 {
			shot = hitscan(world.rng, world.player.weapon)
			actors = damage_first_live(actors0, shot.damage)
			{ ..world, player: spend_ammo(player0), actors, rng: shot.rng }
		} else {
			{ ..world, player: player0, actors: actors0 }
		}
	}

	tick_player_powers : Player -> Player
	tick_player_powers = |value| { ..value, light_amp_tics: if value.light_amp_tics > 0 value.light_amp_tics - 1 else 0 }

	state_duration : ActorMode -> I64
	state_duration = |mode| state_duration_for(ZombieMan, mode)

	state_duration_for : ThingKind, ActorMode -> I64
	state_duration_for = |kind, mode|
		match mode {
			Look => 10
			Chase => match kind {
				ZombieMan => 4
				ShotgunGuy => 3
				Imp => 3
				Demon => 2
				Spectre => 2
				_ => 4
			}
			Attack => match kind {
				ZombieMan => 26
				ShotgunGuy => 30
				Imp => 22
				Demon => 24
				Spectre => 24
				_ => 8
			}
			Pain => match kind {
				ZombieMan => 6
				ShotgunGuy => 6
				Imp => 4
				Demon => 4
				Spectre => 4
				_ => 3
			}
			Dead => match kind {
				ZombieMan => 21
				ShotgunGuy => 21
				Imp => 29
				Demon => 29
				Spectre => 29
				Barrel => 26
				_ => 1
			}
		}

	attack_action_remaining : ThingKind -> I64
	attack_action_remaining = |kind|
		match kind {
			ZombieMan => 16
			ShotgunGuy => 20
			Imp => 6
			Demon => 8
			Spectre => 8
			_ => 1
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
			DroppedShotgun => Bool.True
			DroppedClip => Bool.True
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
	angle_from_degrees = |degrees| RocDoomSim.Angle.from_turns(I64.to_f32(degrees) / 360)
	max_health = 100.I64
	max_bullets = 200.I64
	max_shells = 50.I64
	max_rockets = 50.I64
	max_cells = 300.I64
	actor_radius = 20
	actor_radius_for = |kind|
		match kind {
			Demon | Spectre => 30
			Barrel => 10
			_ => 20
		}
	player_collision_radius = 16
	chase_candidate : Actor, RocDoomSim.Vec2 -> RocDoomSim.Vec2
	chase_candidate = |value, target| {
		direction = direction_vector(chase_direction_index(value.pos, target))
		RocDoomSim.add(value.pos, RocDoomSim.scale(direction, actor_speed(value.kind)))
	}
	ambush_flag = 8.U64
	multiplayer_flag = 16.U64
}

	grants_ammo = |kind|
	match kind {
		ClipPickup | DroppedClip => Bool.True
		ShellPickup => Bool.True
		ShotgunPickup | DroppedShotgun => Bool.True
		BackpackPickup => Bool.True
		ChaingunPickup => Bool.True
		RocketLauncherPickup => Bool.True
		PlasmaRiflePickup => Bool.True
		RocketPickup => Bool.True
		BulletBoxPickup => Bool.True
		ShellBoxPickup => Bool.True
		CellPackPickup => Bool.True
		_ => Bool.False
	}

apply_pickup = |player, kind|
	match kind {
		ClipPickup => give_bullets(player, 10)
		DroppedClip => give_bullets(player, 5)
		ShellPickup => give_shells(player, 4)
		StimpackPickup => give_health(player, 10, RocDoomWorld.max_health)
		MedikitPickup => give_health(player, 25, RocDoomWorld.max_health)
		HealthBonusPickup => { player: give_health(player, 1, 200).player, collected: Bool.True }
		ArmorBonusPickup => { player: { ..player, armor: I64.min(200, player.armor + 1), armor_kind: if player.armor_kind == NoArmor GreenArmor else player.armor_kind }, collected: Bool.True }
		GreenArmorPickup => if player.armor >= 100 { player, collected: Bool.False } else { player: { ..player, armor: 100, armor_kind: GreenArmor }, collected: Bool.True }
		BlueArmorPickup => if player.armor >= 200 { player, collected: Bool.False } else { player: { ..player, armor: 200, armor_kind: BlueArmor }, collected: Bool.True }
		BlueKeyPickup => { player: { ..player, keys: { ..player.keys, blue: Bool.True } }, collected: !(player.keys.blue) }
		YellowKeyPickup => { player: { ..player, keys: { ..player.keys, yellow: Bool.True } }, collected: !(player.keys.yellow) }
		RedKeyPickup => { player: { ..player, keys: { ..player.keys, red: Bool.True } }, collected: !(player.keys.red) }
		ShotgunPickup => acquire_weapon(give_shells(player, 8), Shotgun)
		DroppedShotgun => acquire_weapon(give_shells(player, 4), Shotgun)
		BackpackPickup => {
			ammo = {
				bullets: I64.min(RocDoomWorld.max_bullets * 2, player.ammo.bullets + 10),
				shells: I64.min(RocDoomWorld.max_shells * 2, player.ammo.shells + 4),
				rockets: I64.min(RocDoomWorld.max_rockets * 2, player.ammo.rockets + 1),
				cells: I64.min(RocDoomWorld.max_cells * 2, player.ammo.cells + 20),
			}
			{ player: { ..player, backpack: Bool.True, ammo }, collected: Bool.True }
		}
		ChaingunPickup => acquire_weapon(give_bullets(player, 20), Chaingun)
		RocketLauncherPickup => acquire_weapon(give_rockets(player, 2), RocketLauncher)
		PlasmaRiflePickup => acquire_weapon(give_cells(player, 40), PlasmaRifle)
		ChainsawPickup => acquire_weapon({ player, collected: Bool.False }, Chainsaw)
		RocketPickup => give_rockets(player, 1)
		SoulSpherePickup => { player: give_health(player, 100, 200).player, collected: Bool.True }
		BerserkPickup => { player: { ..player, health: I64.max(player.health, RocDoomWorld.max_health), berserk: Bool.True }, collected: Bool.True }
		ComputerMapPickup => { player: { ..player, computer_map: Bool.True }, collected: !(player.computer_map) }
		LightAmpPickup => { player: { ..player, light_amp_tics: 4200 }, collected: Bool.True }
		BulletBoxPickup => give_bullets(player, 50)
		ShellBoxPickup => give_shells(player, 20)
		CellPackPickup => give_cells(player, 100)
		_ => { player, collected: Bool.False }
	}

## Vanilla `P_GiveWeapon`: a weapon is taken when it is new or when its
## bundled ammo was accepted; an owned weapon over full ammo stays on the map.
acquire_weapon = |given, weapon| {
	player = given.player
	already_owned = owns_weapon(player, weapon)
	weapons = match weapon {
		Pistol => { ..player.weapons, pistol: Bool.True }
		Shotgun => { ..player.weapons, shotgun: Bool.True }
		Chaingun => { ..player.weapons, chaingun: Bool.True }
		RocketLauncher => { ..player.weapons, rocket_launcher: Bool.True }
		PlasmaRifle => { ..player.weapons, plasma_rifle: Bool.True }
		Chainsaw => { ..player.weapons, chainsaw: Bool.True }
	}
	{ player: { ..player, weapons, weapon: if already_owned player.weapon else weapon }, collected: !(already_owned) or given.collected }
}

owns_weapon = |player, weapon|
	match weapon {
		Pistol => player.weapons.pistol
		Shotgun => player.weapons.shotgun
		Chaingun => player.weapons.chaingun
		RocketLauncher => player.weapons.rocket_launcher
		PlasmaRifle => player.weapons.plasma_rifle
		Chainsaw => player.weapons.chainsaw
	}

give_bullets = |player, amount| {
	cap = if player.backpack RocDoomWorld.max_bullets * 2 else RocDoomWorld.max_bullets
	next = I64.min(cap, player.ammo.bullets + amount)
	{ player: { ..player, ammo: { ..player.ammo, bullets: next } }, collected: next > player.ammo.bullets }
}

give_shells = |player, amount| {
	cap = if player.backpack RocDoomWorld.max_shells * 2 else RocDoomWorld.max_shells
	next = I64.min(cap, player.ammo.shells + amount)
	{ player: { ..player, ammo: { ..player.ammo, shells: next } }, collected: next > player.ammo.shells }
}

give_rockets = |player, amount| {
	cap = if player.backpack RocDoomWorld.max_rockets * 2 else RocDoomWorld.max_rockets
	next = I64.min(cap, player.ammo.rockets + amount)
	{ player: { ..player, ammo: { ..player.ammo, rockets: next } }, collected: next > player.ammo.rockets }
}

give_cells = |player, amount| {
	cap = if player.backpack RocDoomWorld.max_cells * 2 else RocDoomWorld.max_cells
	next = I64.min(cap, player.ammo.cells + amount)
	{ player: { ..player, ammo: { ..player.ammo, cells: next } }, collected: next > player.ammo.cells }
}

## Vanilla `P_TouchSpecialThing` refuses a health item once health has reached
## its cap, so a cap below the current health never lowers it.
give_health = |player, amount, cap| {
	if player.health >= cap {
		{ player, collected: Bool.False }
	} else {
		next = I64.min(cap, player.health + amount)
		{ player: { ..player, health: next }, collected: next > player.health }
	}
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
			$next = List.append($next, RocDoomWorld.damage_actor(actor, damage))
		} else {
			$next = List.append($next, actor)
		}
	}
	$next
}

can_attack = |actor, player_pos| {
	distance = approximate_distance(actor.pos, player_pos)
	if actor.kind == Demon or actor.kind == Spectre {
		distance < melee_attack_range
	} else {
		actor.kind == Imp or actor.kind == ZombieMan or actor.kind == ShotgunGuy
	}
}

melee_attack_range = 60

approximate_distance = |from, to| {
	delta = RocDoomSim.sub(to, from)
	dx = F32.abs(delta.x)
	dy = F32.abs(delta.y)
	if dx < dy dy + dx * 0.5 else dx + dy * 0.5
}

look_sees_player = |actor, facts| {
	if !(facts.has_sight) {
		Bool.False
	} else {
		to_player = RocDoomSim.sub(facts.player_pos, actor.pos)
		in_front = RocDoomSim.dot(actor.angle.forward(), to_player) >= 0
		in_front or approximate_distance(actor.pos, facts.player_pos) <= 64
	}
}

wake_random = |kind, rng|
	if kind == ZombieMan or kind == ShotgunGuy or kind == Imp RocDoomWorld.random(rng) else { rng, byte: 0 }

# Melee is checked first. Missile attacks are suppressed during the spawn
# reaction delay and while the current chase direction still has moves; the
# remaining distance test is probabilistic rather than a fixed fire radius.
attack_decision = |actor, player_pos, has_sight, nightmare, rng| {
	if !(has_sight) or !(can_attack(actor, player_pos)) {
		{ attack: Bool.False, rng }
	} else {
		distance = approximate_distance(actor.pos, player_pos)
		melee = (actor.kind == Demon or actor.kind == Spectre or actor.kind == Imp) and distance < melee_attack_range
		if melee {
			{ attack: Bool.True, rng }
		} else if actor.reaction_time > 0 or actor.move_count > 0 {
			{ attack: Bool.False, rng }
		} else if nightmare {
			{ attack: Bool.True, rng }
		} else {
			# Distance is biased by the attacker's melee capability before the
			# bounded random refusal threshold is applied.
			distance_bias = if actor.kind == ZombieMan or actor.kind == ShotgunGuy 192 else 64
			threshold = I64.max(0, I64.min(200, F32.to_i64_wrap(distance - I64.to_f32(distance_bias))))
			roll = RocDoomWorld.random(rng)
			{ attack: U8.to_i64(roll.byte) >= threshold, rng: roll.rng }
		}
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
		RocDoomSim.zero
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
		RocDoomSim.Angle.from_turns(0)
	} else if direction.x < -0.9 {
		RocDoomSim.Angle.from_turns(0.5)
	} else if direction.y > 0.9 {
		RocDoomSim.Angle.from_turns(0.25)
	} else if direction.y < -0.9 {
		RocDoomSim.Angle.from_turns(0.75)
	} else if direction.x > 0 and direction.y > 0 {
		RocDoomSim.Angle.from_turns(0.125)
	} else if direction.x < 0 and direction.y > 0 {
		RocDoomSim.Angle.from_turns(0.375)
	} else if direction.x < 0 and direction.y < 0 {
		RocDoomSim.Angle.from_turns(0.625)
	} else {
		RocDoomSim.Angle.from_turns(0.875)
	}

face_toward = |from, to| direction_angle(chase_direction(from, to))

chase_walk = |actor, facts, rng| {
	remaining = actor.move_count - 1
	attempt = try_chase_direction({ ..actor, move_count: remaining }, actor.move_dir, facts)
	if remaining < 0 or !(attempt.moved) {
		select_chase_move(actor, facts, rng)
	} else {
		{ actor: attempt.actor, rng }
	}
}

# Choose a new retained compass direction when a run expires or an obstacle
# rejects the current step. Prefer the direct diagonal, order the target axes
# probabilistically, retry the old direction, scan all compass directions, and
# reserve the former direction's reverse as the last option.
select_chase_move = |actor, facts, rng| {
	dx = facts.player_pos.x - actor.pos.x
	dy = facts.player_pos.y - actor.pos.y
	horizontal = if dx > 10 0 else if dx < -10 4 else -1
	vertical = if dy > 10 2 else if dy < -10 6 else -1
	diagonal = if horizontal < 0 or vertical < 0 -1 else if dx > 0 and dy > 0 1 else if dx < 0 and dy > 0 3 else if dx < 0 and dy < 0 5 else 7
	old_reverse = if actor.move_dir < 0 -1 else normalize_direction(actor.move_dir + 4)
	diagonal_try = try_chase_directions(actor, if diagonal == old_reverse [] else [diagonal], facts, rng)
	if diagonal_try.moved {
		{ actor: diagonal_try.actor, rng: diagonal_try.rng }
	} else {
		axis_roll = RocDoomWorld.random(diagonal_try.rng)
		swap_axes = axis_roll.byte > 200 or F32.abs(dy) > F32.abs(dx)
		first_axis = if swap_axes vertical else horizontal
		second_axis = if swap_axes horizontal else vertical
		axes = [if first_axis == old_reverse -1 else first_axis, if second_axis == old_reverse -1 else second_axis]
		axis_try = try_chase_directions(actor, axes, facts, axis_roll.rng)
		if axis_try.moved {
			{ actor: axis_try.actor, rng: axis_try.rng }
		} else {
			old_try = try_chase_directions(actor, if actor.move_dir < 0 [] else [actor.move_dir], facts, axis_try.rng)
			if old_try.moved {
				{ actor: old_try.actor, rng: old_try.rng }
			} else {
				scan_roll = RocDoomWorld.random(old_try.rng)
				scan = if scan_roll.byte % 2 == 1 [0, 1, 2, 3, 4, 5, 6, 7] else [7, 6, 5, 4, 3, 2, 1, 0]
				scan_try = try_chase_directions(actor, List.map(scan, |direction| if direction == old_reverse -1 else direction), facts, scan_roll.rng)
				if scan_try.moved {
					{ actor: scan_try.actor, rng: scan_try.rng }
				} else {
					reverse_try = try_chase_directions(actor, [old_reverse], facts, scan_try.rng)
					{ actor: if reverse_try.moved reverse_try.actor else { ..actor, move_dir: -1, move_count: 0 }, rng: reverse_try.rng }
				}
			}
		}
	}
}

try_chase_directions = |actor, directions, facts, rng| {
	var $selected = actor
	var $moved = Bool.False
	var $rng = rng
	for direction in directions {
		if !($moved) and direction >= 0 {
			attempt = try_chase_direction(actor, direction, facts)
			if attempt.moved {
				count = RocDoomWorld.random($rng)
				$selected = { ..attempt.actor, move_count: U8.to_i64(count.byte % 16) }
				$rng = count.rng
				$moved = Bool.True
			}
		}
	}
	{ actor: $selected, rng: $rng, moved: $moved }
}

try_chase_direction = |actor, direction_index, facts| {
	if direction_index < 0 {
		{ actor, moved: Bool.False }
	} else {
		direction = direction_vector(direction_index)
		candidate = RocDoomSim.add(actor.pos, RocDoomSim.scale(direction, actor_speed(actor.kind)))
		radius = RocDoomWorld.actor_radius_for(actor.kind)
		min_distance = radius + RocDoomWorld.player_collision_radius
		wall_blocked = if RocDoomSim.any_penetration(actor.pos, radius, facts.blockers) {
			RocDoomSim.path_deepens_penetration(actor.pos, candidate, radius, facts.blockers)
		} else {
			RocDoomSim.any_collision(candidate, radius, facts.blockers)
		}
		blocked = wall_blocked
			or RocDoomSim.distance_squared(candidate, facts.player_pos) < min_distance * min_distance
			or List.any(facts.occupied, |other| RocDoomSim.distance_squared(candidate, other.pos) < (radius + other.radius) * (radius + other.radius))
		if blocked {
			{ actor, moved: Bool.False }
		} else {
			{ actor: { ..actor, pos: candidate, angle: direction_angle(direction), move_dir: direction_index }, moved: Bool.True }
		}
	}
}

chase_direction_index = |from, to| {
	direction = chase_direction(from, to)
	if direction.x > 0.9 0
	else if direction.x > 0 and direction.y > 0 1
	else if direction.y > 0.9 2
	else if direction.x < 0 and direction.y > 0 3
	else if direction.x < -0.9 4
	else if direction.x < 0 and direction.y < 0 5
	else if direction.y < -0.9 6
	else 7
}

normalize_direction = |direction| {
	value = direction % 8
	if value < 0 value + 8 else value
}

direction_vector = |direction|
	match normalize_direction(direction) {
		0 => { x: 1, y: 0 }
		1 => { x: 0.7171631, y: 0.7171631 }
		2 => { x: 0, y: 1 }
		3 => { x: -0.7171631, y: 0.7171631 }
		4 => { x: -1, y: 0 }
		5 => { x: -0.7171631, y: -0.7171631 }
		6 => { x: 0, y: -1 }
		_ => { x: 0.7171631, y: -0.7171631 }
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

actor_attack = |actor, player_pos, has_sight, rng| {
	distance = approximate_distance(actor.pos, player_pos)
	if actor.kind == Demon or actor.kind == Spectre {
		if has_sight and distance < melee_attack_range {
			roll = RocDoomWorld.random(rng)
			{ rng: roll.rng, damage: (U8.to_i64(roll.byte % 10) + 1) * 4, kind: MeleeAttack }
		} else {
			{ rng, damage: 0, kind: NoAttack }
		}
	} else if actor.kind == ShotgunGuy {
		var $rng = rng
		var $damage = 0.I64
		for _ in List.repeat({}, 3) {
			spread_a = RocDoomWorld.random($rng)
			spread_b = RocDoomWorld.random(spread_a.rng)
			roll = RocDoomWorld.random(spread_b.rng)
			if has_sight and enemy_hitscan_hits(actor.pos, player_pos, spread_a.byte, spread_b.byte) {
				$damage = $damage + (U8.to_i64(roll.byte % 5) + 1) * 3
			}
			$rng = roll.rng
		}
		{ rng: $rng, damage: $damage, kind: HitscanAttack }
	} else if actor.kind == ZombieMan {
		spread_a = RocDoomWorld.random(rng)
		spread_b = RocDoomWorld.random(spread_a.rng)
		roll = RocDoomWorld.random(spread_b.rng)
		damage = if has_sight and enemy_hitscan_hits(actor.pos, player_pos, spread_a.byte, spread_b.byte) (U8.to_i64(roll.byte % 5) + 1) * 3 else 0
		{ rng: roll.rng, damage, kind: HitscanAttack }
	} else if actor.kind == Imp {
		if has_sight and distance < melee_attack_range {
			roll = RocDoomWorld.random(rng)
			{ rng: roll.rng, damage: (U8.to_i64(roll.byte % 8) + 1) * 3, kind: MeleeAttack }
		} else {
			# The missile carries base damage; its random multiplier is consumed only
			# if impact resolution damages a player or actor.
			{ rng, damage: 3, kind: ProjectileAttack }
		}
	} else {
		roll = RocDoomWorld.random(rng)
		{ rng: roll.rng, damage: (U8.to_i64(roll.byte % 5) + 1) * 3, kind: HitscanAttack }
	}
}

enemy_hitscan_hits = |from, target, spread_a, spread_b| {
	direction = RocDoomSim.normalize(RocDoomSim.sub(target, from))
	perpendicular = { x: 0 - direction.y, y: direction.x }
	spread_turns = I64.to_f32(U8.to_i64(spread_a) - U8.to_i64(spread_b)) / 4096
	shot_direction = RocDoomSim.normalize(RocDoomSim.add(direction, RocDoomSim.scale(perpendicular, spread_turns * 6.2831855)))
	to_target = RocDoomSim.sub(target, from)
	along = RocDoomSim.dot(to_target, shot_direction)
	across = F32.abs(to_target.x * shot_direction.y - to_target.y * shot_direction.x)
	along > 0 and across <= RocDoomWorld.player_collision_radius
}

pain_chance = |kind|
	match kind {
		ZombieMan => 200
		ShotgunGuy => 170
		Imp => 200
		Demon => 180
		Spectre => 180
		Barrel => 0
		_ => 0
	}

fixture_thing = |editor_type, flags| { x: 64, y: -32, angle: 90, type: editor_type, flags }

expect {
	actor = RocDoomWorld.actor(1, ZombieMan, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	var $next = actor
	for _ in List.repeat({}, 9) {
		$next = RocDoomWorld.tick_actor($next)
	}
	before = $next.state.mode == Look and $next.state.remaining == 1
	$next = RocDoomWorld.tick_actor($next)
	before and $next.state.mode == Chase and $next.state.remaining == 4
}

expect {
	first = RocDoomWorld.hitscan(RocDoomWorld.Rng.seed(0), Pistol)
	second = RocDoomWorld.hitscan(first.rng, Pistol)
	first.damage == 15 and second.damage == 10 and F32.abs(first.spread_turns - (-19 / 65536)) < 0.000001
}

expect {
	first = RocDoomWorld.random(RocDoomWorld.Rng.seed(0))
	second = RocDoomWorld.random(first.rng)
	third = RocDoomWorld.random(second.rng)
	wrapped = RocDoomWorld.random(RocDoomWorld.Rng.seed(255))
	[first.byte, second.byte, third.byte, wrapped.byte] == [8, 109, 220, 0]
		and third.rng.index() == 3
		and wrapped.rng.index() == 0
}

expect {
	base = RocDoomWorld.player({ x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0))
	pickup : RocDoomWorld.Pickup
	pickup = { id: 0, kind: ShotgunPickup, pos: base.sim.state.pos, taken: Bool.False }
	result = RocDoomWorld.collect(base, pickup)
	result.collected and result.player.weapon == Shotgun and RocDoomWorld.owns(result.player, Shotgun) and !(RocDoomWorld.owns(base, Shotgun))
}

expect {
	# Items dropped by former humans use their reduced ammunition grants.
	base = RocDoomWorld.player({ x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0))
	clip = RocDoomWorld.collect(base, { id: 0, kind: DroppedClip, pos: base.sim.state.pos, taken: Bool.False })
	shotgun = RocDoomWorld.collect(base, { id: 1, kind: DroppedShotgun, pos: base.sim.state.pos, taken: Bool.False })
	clip.player.ammo.bullets == base.ammo.bullets + 5
		and shotgun.player.ammo.shells == 4
		and RocDoomWorld.owns(shotgun.player, Shotgun)
}

expect {
	base = RocDoomWorld.player({ x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0))
	clip : RocDoomWorld.Pickup
	clip = { id: 0, kind: ClipPickup, pos: base.sim.state.pos, taken: Bool.False }
	medium = RocDoomWorld.collect_for_skill(base, clip, Medium)
	baby = RocDoomWorld.collect_for_skill(base, clip, Baby)
	nightmare = RocDoomWorld.collect_for_skill(base, clip, Nightmare)
	medium.player.ammo.bullets == 60 and baby.player.ammo.bullets == 70 and nightmare.player.ammo.bullets == 70
}

expect {
	base = { ..RocDoomWorld.player({ x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0)), health: 70, armor: 50, armor_kind: GreenArmor }
	medikit : RocDoomWorld.Pickup
	medikit = { id: 1, kind: MedikitPickup, pos: { x: 0, y: 0 }, taken: Bool.False }
	key : RocDoomWorld.Pickup
	key = { id: 2, kind: BlueKeyPickup, pos: { x: 0, y: 0 }, taken: Bool.False }
	healed = RocDoomWorld.collect(base, medikit)
	keyed = RocDoomWorld.collect(healed.player, key)
	damaged = RocDoomWorld.damage_player(keyed.player, 30)
	healed.player.health == 95 and keyed.player.keys.blue and damaged.health == 75 and damaged.armor == 40
}

expect {
	things : List(RocDoomWorld.Thing)
	things = [fixture_thing(1, 7), fixture_thing(3004, 1), fixture_thing(3001, 2), fixture_thing(9, 4), fixture_thing(2007, 7), fixture_thing(3004, 16 + 7)]
	easy = RocDoomWorld.spawn(things, Easy)
	hard = RocDoomWorld.spawn(things, Hard)
	List.len(easy.actors) == 1 and List.len(hard.actors) == 1 and List.len(easy.pickups) == 1 and easy.player_start == Ok(fixture_thing(1, 7))
}

expect {
	# The world fold advances actor state by exactly the tics admitted by the
	# shared 35 Hz player clock.
	actor = RocDoomWorld.actor(1, Imp, { x: 128, y: 0 }, RocDoomSim.Angle.from_turns(0.5), Bool.False)
	world : RocDoomWorld.World
	world = { player: RocDoomWorld.player({ x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0)), actors: [actor], pickups: [], rng: RocDoomWorld.Rng.seed(0) }
	advanced = RocDoomWorld.advance(world, RocDoomSim.tic_seconds * 2.1, RocDoomSim.neutral, [])
	next_actor = List.get(advanced.world.actors, 0) ?? actor
	advanced.tics == 2 and next_actor.state.mode == Look and next_actor.state.remaining == 8
}

expect {
	# Sound wakes ordinary monsters, but an ambush-flagged monster waits until
	# it has direct sight.
	base = RocDoomWorld.actor(1, ZombieMan, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	ambush = { ..base, id: 2, ambush: Bool.True }
	facts : RocDoomWorld.ActorFacts
	facts = { player_pos: { x: 128, y: 0 }, has_sight: Bool.False, heard_sound: Bool.True, blockers: [], occupied: [], nightmare: Bool.False, used_door: Bool.False }
	woken = RocDoomWorld.tick_actor_with(base, facts, RocDoomWorld.Rng.seed(0))
	sleeping = RocDoomWorld.tick_actor_with(ambush, facts, RocDoomWorld.Rng.seed(0))
	var $still_ambush = sleeping
	for _ in List.repeat({}, 12) {
		$still_ambush = RocDoomWorld.tick_actor_with($still_ambush.actor, facts, $still_ambush.rng)
	}
	seen = RocDoomWorld.tick_actor_with(sleeping.actor, { ..facts, has_sight: Bool.True }, sleeping.rng)
	woken.actor.state.mode == Chase and sleeping.actor.state.mode == Look and $still_ambush.actor.state.mode == Look and seen.actor.state.mode == Chase
}

expect {
	# Sight wakes a sleeping monster only in its forward half-plane unless the
	# player is within the close-range exception.
	base = RocDoomWorld.actor(1, ZombieMan, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	far_behind : RocDoomWorld.ActorFacts
	far_behind = { player_pos: { x: -128, y: 0 }, has_sight: Bool.True, heard_sound: Bool.False, blockers: [], occupied: [], nightmare: Bool.False, used_door: Bool.False }
	close_behind = { ..far_behind, player_pos: { x: -64, y: 0 } }
	far = RocDoomWorld.tick_actor_with(base, far_behind, RocDoomWorld.Rng.seed(0))
	close = RocDoomWorld.tick_actor_with(base, close_behind, RocDoomWorld.Rng.seed(0))
	far.actor.state.mode == Look and close.actor.state.mode == Chase
}

expect {
	# Variable sight sounds consume the shared gameplay stream on wake, while a
	# monster with a single fixed sight sound does not.
	facts : RocDoomWorld.ActorFacts
	facts = { player_pos: { x: 128, y: 0 }, has_sight: Bool.True, heard_sound: Bool.False, blockers: [], occupied: [], nightmare: Bool.False, used_door: Bool.False }
	zombie = RocDoomWorld.tick_actor_with(RocDoomWorld.actor(1, ZombieMan, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False), facts, RocDoomWorld.Rng.seed(0))
	demon = RocDoomWorld.tick_actor_with(RocDoomWorld.actor(2, Demon, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False), facts, RocDoomWorld.Rng.seed(0))
	zombie.rng.index() == 1 and demon.rng.index() == 0
}

expect {
	# A blocked direct route selects another compass direction without crossing
	# the line, and no choice may overlap the player's combined collision radii.
	base = RocDoomWorld.actor(1, Imp, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	ready = { ..base, state: { mode: Chase, remaining: 1, attacked: Bool.False } }
	wall : RocDoomSim.Segment
	wall = { start: { x: 24, y: -64 }, end: { x: 24, y: 64 } }
	blocked = RocDoomWorld.tick_actor_with(ready, { player_pos: { x: 100, y: 0 }, has_sight: Bool.False, heard_sound: Bool.False, blockers: [wall], occupied: [], nightmare: Bool.False, used_door: Bool.False }, RocDoomWorld.Rng.seed(0))
	close = RocDoomWorld.tick_actor_with(ready, { player_pos: { x: 32, y: 0 }, has_sight: Bool.False, heard_sound: Bool.False, blockers: [], occupied: [], nightmare: Bool.False, used_door: Bool.False }, RocDoomWorld.Rng.seed(0))
	blocked.actor.pos.x <= base.pos.x
		and RocDoomSim.distance_squared(close.actor.pos, { x: 32, y: 0 }) >= (RocDoomWorld.actor_radius + RocDoomWorld.player_collision_radius) * (RocDoomWorld.actor_radius + RocDoomWorld.player_collision_radius)
}

expect {
	# An actor already intersecting a moving boundary may step out of it. Treating
	# every overlap as blocked would leave the actor permanently embedded.
	base = RocDoomWorld.actor(1, Imp, { x: 10, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	wall : RocDoomSim.Segment
	wall = { start: { x: 0, y: -64 }, end: { x: 0, y: 64 } }
	facts : RocDoomWorld.ActorFacts
	facts = { player_pos: { x: 256, y: 0 }, has_sight: Bool.False, heard_sound: Bool.False, blockers: [wall], occupied: [], nightmare: Bool.False, used_door: Bool.False }
	escape = try_chase_direction(base, 0, facts)
	deeper = try_chase_direction(base, 4, facts)
	escape.moved and escape.actor.pos.x > base.pos.x and !(deeper.moved)
}

expect {
	# A valid retained direction is reused until its bounded move count expires.
	base = RocDoomWorld.actor(1, Imp, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	ready = { ..base, target_threshold: 2, move_dir: 2, move_count: 3, state: { mode: Chase, remaining: 1, attacked: Bool.False } }
	facts : RocDoomWorld.ActorFacts
	facts = { player_pos: { x: 256, y: 0 }, has_sight: Bool.False, heard_sound: Bool.False, blockers: [], occupied: [], nightmare: Bool.False, used_door: Bool.False }
	turn = RocDoomWorld.tick_actor_with(ready, facts, RocDoomWorld.Rng.seed(0))
	turn.actor.move_dir == 2
		and turn.actor.move_count == 2
		and turn.actor.pos.y > 0
		and turn.actor.chase_frame == 1
		and turn.actor.target_threshold == 1
		and turn.rng.index() == 1
}

expect {
	# Direction reselection tries the direct diagonal before consuming an axis
	# ordering byte, but excludes an immediate turnaround and then tries an axis.
	base = RocDoomWorld.actor(1, Imp, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	facts : RocDoomWorld.ActorFacts
	facts = { player_pos: { x: 100, y: 100 }, has_sight: Bool.False, heard_sound: Bool.False, blockers: [], occupied: [], nightmare: Bool.False, used_door: Bool.False }
	direct = select_chase_move(base, facts, RocDoomWorld.Rng.seed(0))
	no_turnaround = select_chase_move({ ..base, move_dir: 5 }, facts, RocDoomWorld.Rng.seed(0))
	direct.actor.move_dir == 1
		and direct.actor.move_count == 8
		and direct.rng.index() == 1
		and no_turnaround.actor.move_dir == 0
		and no_turnaround.actor.move_count == 13
		and no_turnaround.rng.index() == 2
}

expect {
	# Occupied actor space participates in direction selection, so a rejected
	# direct step chooses another direction during the same chase action.
	base = RocDoomWorld.actor(1, ZombieMan, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	facts : RocDoomWorld.ActorFacts
	facts = { player_pos: { x: 128, y: 0 }, has_sight: Bool.False, heard_sound: Bool.False, blockers: [], occupied: [{ pos: { x: 40, y: 0 }, radius: 20 }], nightmare: Bool.False, used_door: Bool.False }
	selected = select_chase_move(base, facts, RocDoomWorld.Rng.seed(0))
	selected.actor.move_dir != 0 and selected.actor.pos != base.pos
}

expect {
	# The former-human attack action occurs after its 10-tic windup, once per
	# 26-tic frame chain; recovery remains in Attack afterwards.
	base = RocDoomWorld.actor(1, ZombieMan, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	var $turn = { actor: { ..base, state: RocDoomWorld.state(Attack) }, rng: RocDoomWorld.Rng.seed(2), player_damage: 0, attack_kind: NoAttack }
	facts : RocDoomWorld.ActorFacts
	facts = { player_pos: { x: 128, y: 0 }, has_sight: Bool.True, heard_sound: Bool.False, blockers: [], occupied: [], nightmare: Bool.False, used_door: Bool.False }
	for _ in List.repeat({}, 10) {
		$turn = RocDoomWorld.tick_actor_with($turn.actor, facts, $turn.rng)
	}
	before = $turn.attack_kind == NoAttack and $turn.actor.state.remaining == 16
	$turn = RocDoomWorld.tick_actor_with($turn.actor, facts, $turn.rng)
	before and $turn.attack_kind == HitscanAttack and $turn.player_damage == 6 and $turn.actor.state.mode == Attack and $turn.actor.state.attacked
}

expect {
	# Enemy bullets consume two spread bytes before damage. At this range the
	# first deterministic spread misses while the second fixture reaches the
	# player's collision radius.
	base = RocDoomWorld.actor(1, ZombieMan, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	ready = { ..base, state: { mode: Attack, remaining: 16, attacked: Bool.False } }
	facts : RocDoomWorld.ActorFacts
	facts = { player_pos: { x: 128, y: 0 }, has_sight: Bool.True, heard_sound: Bool.False, blockers: [], occupied: [], nightmare: Bool.False, used_door: Bool.False }
	miss = RocDoomWorld.tick_actor_with(ready, facts, RocDoomWorld.Rng.seed(0))
	hit = RocDoomWorld.tick_actor_with(ready, facts, RocDoomWorld.Rng.seed(2))
	miss.attack_kind == HitscanAttack and miss.player_damage == 0 and hit.player_damage == 6
}

expect {
	# Once a ranged attack chain reaches its action tic it still consumes the
	# shot's random values after sight is lost, but the intervening wall receives
	# the trace instead of the player.
	base = RocDoomWorld.actor(1, ZombieMan, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	ready = { ..base, state: { mode: Attack, remaining: 16, attacked: Bool.False } }
	facts : RocDoomWorld.ActorFacts
	facts = { player_pos: { x: 128, y: 0 }, has_sight: Bool.False, heard_sound: Bool.False, blockers: [], occupied: [], nightmare: Bool.False, used_door: Bool.False }
	shot = RocDoomWorld.tick_actor_with(ready, facts, RocDoomWorld.Rng.seed(2))
	shot.attack_kind == HitscanAttack and shot.player_damage == 0 and shot.rng.index() == 5 and shot.actor.state.attacked
}

expect {
	# A completed missile attack must yield a chase decision and choose a
	# bounded movement count before another ranged attack can begin.
	base = RocDoomWorld.actor(1, Imp, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	ready = { ..base, reaction_time: 0, just_attacked: Bool.True, state: { mode: Chase, remaining: 1, attacked: Bool.False } }
	facts : RocDoomWorld.ActorFacts
	facts = { player_pos: { x: 256, y: 0 }, has_sight: Bool.True, heard_sound: Bool.False, blockers: [], occupied: [], nightmare: Bool.False, used_door: Bool.False }
	turn = RocDoomWorld.tick_actor_with(ready, facts, RocDoomWorld.Rng.seed(0))
	turn.attack_kind == NoAttack and turn.actor.state.mode == Chase and !(turn.actor.just_attacked) and turn.actor.move_count >= 0 and turn.actor.move_count < 16
}

expect {
	# Nightmare clears the post-shot marker without forcing a movement action,
	# and skips the ordinary distance-based missile refusal.
	base = RocDoomWorld.actor(1, Imp, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	ready = { ..base, reaction_time: 0, just_attacked: Bool.True, state: { mode: Chase, remaining: 1, attacked: Bool.False } }
	ordinary : RocDoomWorld.ActorFacts
	ordinary = { player_pos: { x: 512, y: 0 }, has_sight: Bool.True, heard_sound: Bool.False, blockers: [], occupied: [], nightmare: Bool.False, used_door: Bool.False }
	fast = { ..ordinary, nightmare: Bool.True }
	normal_turn = RocDoomWorld.tick_actor_with(ready, ordinary, RocDoomWorld.Rng.seed(0))
	fast_turn = RocDoomWorld.tick_actor_with(ready, fast, RocDoomWorld.Rng.seed(0))
	normal_turn.actor.state.mode == Chase and fast_turn.actor.state.mode == Attack and !(fast_turn.actor.just_attacked)
}

expect {
	# Generic missile-capable monsters retain a bounded random chance to attack
	# at long range instead of using an artificial maximum fire radius.
	base = RocDoomWorld.actor(1, Imp, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	ready = { ..base, reaction_time: 0, move_count: 0 }
	decision = attack_decision(ready, { x: 4096, y: 0 }, Bool.True, Bool.False, RocDoomWorld.Rng.seed(3))
	decision.attack and decision.rng.index() == 4
}

expect {
	RocDoomWorld.state_for(ZombieMan, Attack).remaining == 26
		and RocDoomWorld.state_for(ShotgunGuy, Attack).remaining == 30
		and RocDoomWorld.state_for(Imp, Attack).remaining == 22
		and RocDoomWorld.state_for(Demon, Attack).remaining == 24
		and RocDoomWorld.state_for(Spectre, Attack).remaining == 24
}

expect {
	base = RocDoomWorld.actor(1, Imp, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	pained = RocDoomWorld.damage_actor_random(base, 5, RocDoomWorld.Rng.seed(0))
	killed = RocDoomWorld.damage_actor_random(base, 1000, RocDoomWorld.Rng.seed(0))
	pained.entered_pain
		and pained.actor.health == 55
		and pained.actor.state.mode == Pain
		and pained.rng.index() == 1
		and killed.actor.health == 0
		and killed.actor.state.mode == Dead
		and !(killed.entered_pain)
		and killed.rng.index() == 1
}

expect {
	# Lethal damage consumes the death-frame randomization byte, independently
	# of the pain roll used only by survivors.
	base = RocDoomWorld.actor(1, Imp, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	killed = RocDoomWorld.damage_actor_random(base, 1000, RocDoomWorld.Rng.seed(1))
	killed.actor.state.remaining == RocDoomWorld.state_for(Imp, Dead).remaining - 1 and killed.rng.index() == 2
}

expect {
	barrel = RocDoomWorld.actor(1, Barrel, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	damaged = RocDoomWorld.damage_actor_random(barrel, 1, RocDoomWorld.Rng.seed(0))
	damaged.actor.health == 19
		and damaged.actor.state.mode == Look
		and !(damaged.entered_pain)
		and damaged.rng.index() == 1
}

expect {
	base = RocDoomWorld.actor(1, Imp, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	ready = { ..base, state: { mode: Attack, remaining: 6, attacked: Bool.False } }
	near : RocDoomWorld.ActorFacts
	near = { player_pos: { x: 48, y: 0 }, has_sight: Bool.True, heard_sound: Bool.False, blockers: [], occupied: [], nightmare: Bool.False, used_door: Bool.False }
	far = { ..near, player_pos: { x: 256, y: 0 } }
	melee = RocDoomWorld.tick_actor_with(ready, near, RocDoomWorld.Rng.seed(0))
	projectile = RocDoomWorld.tick_actor_with(ready, far, RocDoomWorld.Rng.seed(0))
	melee.attack_kind == MeleeAttack
		and melee.rng.index() == 1
		and projectile.attack_kind == ProjectileAttack
		and projectile.player_damage == 3
		and projectile.rng.index() == 0
}

expect {
	# The close attack uses the engine's approximate distance and strict
	# effective player-melee range; the boundary position selects a missile.
	base = RocDoomWorld.actor(1, Imp, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	ready = { ..base, state: { mode: Attack, remaining: 6, attacked: Bool.False } }
	facts : RocDoomWorld.ActorFacts
	facts = { player_pos: { x: 59, y: 0 }, has_sight: Bool.True, heard_sound: Bool.False, blockers: [], occupied: [], nightmare: Bool.False, used_door: Bool.False }
	inside = RocDoomWorld.tick_actor_with(ready, facts, RocDoomWorld.Rng.seed(0))
	boundary = RocDoomWorld.tick_actor_with(ready, { ..facts, player_pos: { x: 60, y: 0 } }, RocDoomWorld.Rng.seed(0))
	inside.attack_kind == MeleeAttack and boundary.attack_kind == ProjectileAttack
}

expect {
	spawned = RocDoomWorld.spawn(RocDoomMap.e1m1.raw().things, Medium)
	List.is_empty(spawned.unsupported)
		and List.len(spawned.actors) == 51
			and List.len(spawned.pickups) == 78
				and List.len(spawned.decorations) == 80
}

expect {
	RocDoomWorld.actor_radius_for(ZombieMan) == 20
		and RocDoomWorld.actor_radius_for(ShotgunGuy) == 20
		and RocDoomWorld.actor_radius_for(Imp) == 20
		and RocDoomWorld.actor_radius_for(Demon) == 30
		and RocDoomWorld.actor_radius_for(Spectre) == 30
		and RocDoomWorld.actor_radius_for(Barrel) == 10
}

expect {
	spawned = RocDoomWorld.spawn(RocDoomMap.e1m1.raw().things, Medium)
	spawned.rng.index() == 210
}

expect {
	spawned = RocDoomWorld.spawn(RocDoomMap.e1m1.raw().things, Medium)
	List.any(spawned.actors, |value| value.state.remaining != RocDoomWorld.state_for(value.kind, Look).remaining)
}

expect {
	demon0 = RocDoomWorld.actor(1, Demon, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	demon = { ..demon0, state: { mode: Attack, remaining: 8, attacked: Bool.False } }
	facts : RocDoomWorld.ActorFacts
	facts = { player_pos: { x: 48, y: 0 }, has_sight: Bool.True, heard_sound: Bool.False, blockers: [], occupied: [], nightmare: Bool.False, used_door: Bool.False }
	turn = RocDoomWorld.tick_actor_with(demon, facts, RocDoomWorld.Rng.seed(0))
	turn.attack_kind == MeleeAttack and turn.player_damage > 0 and turn.actor.health == 150
}

expect {
	player = RocDoomWorld.player({ x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0))
	backpack : RocDoomWorld.Pickup
	backpack = { id: 0, kind: BackpackPickup, pos: { x: 0, y: 0 }, taken: Bool.False }
	cell_pack : RocDoomWorld.Pickup
	cell_pack = { id: 1, kind: CellPackPickup, pos: { x: 0, y: 0 }, taken: Bool.False }
	packed = RocDoomWorld.collect(player, backpack)
	cells = RocDoomWorld.collect(packed.player, cell_pack)
	packed.player.backpack and packed.player.ammo.bullets == 60 and cells.player.ammo.cells == 120
}

expect {
	player = RocDoomWorld.player({ x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0))
	map_pickup : RocDoomWorld.Pickup
	map_pickup = { id: 0, kind: ComputerMapPickup, pos: { x: 0, y: 0 }, taken: Bool.False }
	lamp_pickup : RocDoomWorld.Pickup
	lamp_pickup = { id: 1, kind: LightAmpPickup, pos: { x: 0, y: 0 }, taken: Bool.False }
	mapped = RocDoomWorld.collect(player, map_pickup)
	lit = RocDoomWorld.collect(mapped.player, lamp_pickup)
	ticked = RocDoomWorld.tick_player_powers(lit.player)
	mapped.player.computer_map and lit.player.light_amp_tics == 4200 and ticked.light_amp_tics == 4199
}

expect {
	# A health pickup never lowers health: a stimpack at 101 (after a health
	# bonus) is refused, a medikit after a soulsphere is refused, and berserk
	# keeps health above 100 rather than clamping it down.
	base = RocDoomWorld.player({ x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0))
	at = |player, kind| RocDoomWorld.collect(player, { id: 0, kind, pos: player.sim.state.pos, taken: Bool.False })
	bonus = at(base, HealthBonusPickup).player
	stim = at(bonus, StimpackPickup)
	sphere = at(base, SoulSpherePickup).player
	medikit = at(sphere, MedikitPickup)
	berserk = at(sphere, BerserkPickup)
	bonus.health == 101
		and stim.player.health == 101
			and !(stim.collected)
				and sphere.health == 200
					and medikit.player.health == 200
						and !(medikit.collected)
							and berserk.player.health == 200
								and berserk.player.berserk
}

expect {
	# W2: an owned weapon with full ammo is left on the map (vanilla
	# P_GiveWeapon returns false), while a weapon that only tops up ammo or a
	# newly acquired one is collected.
	base = RocDoomWorld.player({ x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0))
	at = |player, kind| RocDoomWorld.collect(player, { id: 0, kind, pos: player.sim.state.pos, taken: Bool.False })
	first = at(base, ShotgunPickup)
	var $player = first.player
	for _ in List.repeat({}, 8) {
		$player = at($player, ShotgunPickup).player
	}
	full = at($player, ShotgunPickup)
	saw = at(base, ChainsawPickup)
	saw_again = at(saw.player, ChainsawPickup)
	first.collected and $player.ammo.shells == 50 and !(full.collected) and saw.collected and !(saw_again.collected)
}

expect {
	# W3: soulspheres and health bonuses are always taken, even at 200 health.
	base = RocDoomWorld.player({ x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0))
	at = |player, kind| RocDoomWorld.collect(player, { id: 0, kind, pos: player.sim.state.pos, taken: Bool.False })
	full = at(base, SoulSpherePickup).player
	sphere = at(full, SoulSpherePickup)
	bonus = at(full, HealthBonusPickup)
	full.health == 200 and sphere.collected and sphere.player.health == 200 and bonus.collected and bonus.player.health == 200
}

expect {
	# W4: non-positive damage is a no-op and never restarts the pain state.
	actor = RocDoomWorld.actor(1, Imp, { x: 0, y: 0 }, RocDoomSim.Angle.from_turns(0), Bool.False)
	var $chasing = actor
	for _ in List.repeat({}, 12) {
		$chasing = RocDoomWorld.tick_actor($chasing)
	}
	zero = RocDoomWorld.damage_actor($chasing, 0)
	negative = RocDoomWorld.damage_actor($chasing, -5)
	$chasing.state.mode == Chase and zero.state.mode == Chase and zero.state.remaining == $chasing.state.remaining and negative.health == $chasing.health and negative.state.mode == Chase
}
