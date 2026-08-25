app [target] { fuzz: platform "../../../roc-fuzz/platform/main.roc" }

## Property fuzzing for the pure `DoomWorld` inventory/combat layer.
##
## Properties:
##  P1 pickup sequences keep ammo/health/armor inside their caps and
##     `collected` is True iff the player state changed
##  P2 a second backpack never re-doubles the caps
##  P3 firing through `world_tic` never makes ammo negative; the current
##     weapon is always owned
##  P4 actor tics over random facts: health never rises, Dead is absorbing,
##     remaining never negative, player_damage only on the terminal Attack tic,
##     Rng is a deterministic function of the seed
##  P5 damage_actor / damage_actor_random with degenerate damage values
import fuzz.Fuzz
import DoomSim
import DoomWorld

Input := {
	backpack_first : U8,
	pickups : List(U8),
	fire_seed : U8,
	fire_ticks : U8,
	weapon_choice : U8,
	ammo_bullets : U8,
	ammo_shells : U8,
	actor_kind : U8,
	actor_ambush : U8,
	seed : U8,
	player_x : U8,
	player_y : U8,
	sight_bits : U8,
	tics : U8,
	damages : List(U64),
	skill : U8,
}.{
	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		{
			backpack_first: Fuzz.u8_in(0, 1),
			pickups: Fuzz.list(Fuzz.u8_in(0, 24), 64),
			fire_seed: Fuzz.u8,
			fire_ticks: Fuzz.u8,
			weapon_choice: Fuzz.u8_in(0, 5),
			ammo_bullets: Fuzz.u8,
			ammo_shells: Fuzz.u8,
			actor_kind: Fuzz.u8_in(0, 5),
			actor_ambush: Fuzz.u8_in(0, 1),
			seed: Fuzz.u8,
			player_x: Fuzz.u8,
			player_y: Fuzz.u8,
			sight_bits: Fuzz.u8,
			tics: Fuzz.u8_in(0, 200),
			damages: Fuzz.list(Fuzz.u64, 8),
			skill: Fuzz.u8_in(0, 4),
		}.Fuzz
	}
}

pickup_kind : U8 -> DoomWorld.ThingKind
pickup_kind = |index|
	match index {
		0 => ShotgunPickup
		1 => ClipPickup
		2 => ShellPickup
		3 => StimpackPickup
		4 => MedikitPickup
		5 => GreenArmorPickup
		6 => BlueArmorPickup
		7 => HealthBonusPickup
		8 => ArmorBonusPickup
		9 => BlueKeyPickup
		10 => YellowKeyPickup
		11 => RedKeyPickup
		12 => BackpackPickup
		13 => ChaingunPickup
		14 => RocketLauncherPickup
		15 => PlasmaRiflePickup
		16 => ChainsawPickup
		17 => RocketPickup
		18 => SoulSpherePickup
		19 => BerserkPickup
		20 => ComputerMapPickup
		21 => LightAmpPickup
		22 => BulletBoxPickup
		23 => ShellBoxPickup
		_ => CellPackPickup
	}

actor_kind : U8 -> DoomWorld.ThingKind
actor_kind = |index|
	match index {
		0 => ZombieMan
		1 => ShotgunGuy
		2 => Imp
		3 => Demon
		4 => Spectre
		_ => Barrel
	}

weapon : U8 -> DoomWorld.Weapon
weapon = |index|
	match index {
		0 => Pistol
		1 => Shotgun
		2 => Chaingun
		3 => RocketLauncher
		4 => PlasmaRifle
		_ => Chainsaw
	}

skill : U8 -> DoomWorld.Skill
skill = |index|
	match index {
		0 => Baby
		1 => Easy
		2 => Medium
		3 => Hard
		_ => Nightmare
	}

## Vanilla `P_TouchSpecialThing` rule: is this pickup accepted (removed from
## the map) given the player state?
vanilla_accepts : DoomWorld.Player, DoomWorld.ThingKind -> Bool
vanilla_accepts = |p, kind| {
	bcap = if p.backpack 400 else 200
	scap = if p.backpack 100 else 50
	rcap = if p.backpack 100 else 50
	ccap = if p.backpack 600 else 300
	match kind {
		ClipPickup | BulletBoxPickup => p.ammo.bullets < bcap
		ShellPickup | ShellBoxPickup => p.ammo.shells < scap
		RocketPickup => p.ammo.rockets < rcap
		CellPackPickup => p.ammo.cells < ccap
		StimpackPickup | MedikitPickup => p.health < 100
		HealthBonusPickup => Bool.True
		ArmorBonusPickup => Bool.True
		GreenArmorPickup => p.armor < 100
		BlueArmorPickup => p.armor < 200
		BlueKeyPickup => !(p.keys.blue)
		YellowKeyPickup => !(p.keys.yellow)
		RedKeyPickup => !(p.keys.red)
		BackpackPickup => Bool.True
		SoulSpherePickup => Bool.True
		BerserkPickup => Bool.True
		ComputerMapPickup => !(p.computer_map)
		LightAmpPickup => Bool.True
		ShotgunPickup => !(p.weapons.shotgun) or p.ammo.shells < scap
		ChaingunPickup => !(p.weapons.chaingun) or p.ammo.bullets < bcap
		RocketLauncherPickup => !(p.weapons.rocket_launcher) or p.ammo.rockets < rcap
		PlasmaRiflePickup => !(p.weapons.plasma_rifle) or p.ammo.cells < ccap
		ChainsawPickup => !(p.weapons.chainsaw)
		_ => Bool.False
	}
}

check_player : DoomWorld.Player, Str -> {}
check_player = |p, ctx| {
	mult = if p.backpack 2 else 1
	if p.ammo.bullets < 0 or p.ammo.bullets > 200 * mult {
		crash "PROPERTY: bullets out of range ${Str.inspect(p.ammo)} ${ctx}"
	}
	if p.ammo.shells < 0 or p.ammo.shells > 50 * mult {
		crash "PROPERTY: shells out of range ${Str.inspect(p.ammo)} ${ctx}"
	}
	if p.ammo.rockets < 0 or p.ammo.rockets > 50 * mult {
		crash "PROPERTY: rockets out of range ${Str.inspect(p.ammo)} ${ctx}"
	}
	if p.ammo.cells < 0 or p.ammo.cells > 300 * mult {
		crash "PROPERTY: cells out of range ${Str.inspect(p.ammo)} ${ctx}"
	}
	if p.health < 0 or p.health > 200 {
		crash "PROPERTY: health out of range ${Str.inspect(p.health)} ${ctx}"
	}
	if p.armor < 0 or p.armor > 200 {
		crash "PROPERTY: armor out of range ${Str.inspect(p.armor)} ${ctx}"
	}
	if (p.armor > 0) != (p.armor_kind != NoArmor) {
		crash "PROPERTY: armor_kind inconsistent armor=${Str.inspect(p.armor)} kind=${Str.inspect(p.armor_kind)} ${ctx}"
	}
	if !(DoomWorld.owns(p, p.weapon)) {
		crash "PROPERTY: current weapon not owned ${Str.inspect(p.weapon)} ${ctx}"
	}
	if !(p.weapons.pistol) {
		crash "PROPERTY: pistol lost ${ctx}"
	}
	{}
}

## Player equality ignoring the F32 sim clock (which pickups never touch).
same_player : DoomWorld.Player, DoomWorld.Player -> Bool
same_player = |a, b|
	a.health == b.health
		and a.armor == b.armor
			and a.armor_kind == b.armor_kind
				and a.ammo == b.ammo
					and a.keys == b.keys
						and a.weapon == b.weapon
							and a.weapons == b.weapons
								and a.backpack == b.backpack
									and a.berserk == b.berserk
										and a.computer_map == b.computer_map
											and a.light_amp_tics == b.light_amp_tics

same_vec : DoomSim.Vec2, DoomSim.Vec2 -> Bool
same_vec = |a, b| F32.to_bits(a.x) == F32.to_bits(b.x) and F32.to_bits(a.y) == F32.to_bits(b.y)

same_turn : DoomWorld.ActorTic, DoomWorld.ActorTic -> Bool
same_turn = |a, b|
	a.actor.health == b.actor.health
		and a.actor.state == b.actor.state
			and same_vec(a.actor.pos, b.actor.pos)
				and F32.to_bits(a.actor.angle.turns()) == F32.to_bits(b.actor.angle.turns())
					and a.rng.index() == b.rng.index()
						and a.player_damage == b.player_damage
							and a.attack_kind == b.attack_kind

pickup_at : DoomWorld.ThingKind, U64 -> DoomWorld.Pickup
pickup_at = |kind, id| { id, kind, pos: { x: 0, y: 0 }, taken: Bool.False }

test_pickups : Input -> {}
test_pickups = |input| {
	base = DoomWorld.player({ x: 0, y: 0 }, DoomSim.Angle.from_turns(0))
	start = if input.backpack_first == 1 DoomWorld.collect(base, pickup_at(BackpackPickup, 999)).player else base
	var $player = start
	var $index = 0
	var $backpacks = if input.backpack_first == 1 1 else 0
	for byte in input.pickups {
		kind = pickup_kind(byte)
		before = $player
		result = DoomWorld.collect(before, pickup_at(kind, $index))
		after = result.player
		ctx = "after pickup #${Str.inspect($index)} ${Str.inspect(kind)}"
		check_player(after, ctx)
		changed = !(same_player(after, before))
		# W2 fixed: weapon pickups now follow P_GiveWeapon, so they are checked against vanilla.
		# GUARD (contract-only, vanilla-consistent): Berserk/LightAmp always collect.
		is_weapon = kind == ShotgunPickup or kind == ChaingunPickup or kind == RocketLauncherPickup or kind == PlasmaRiflePickup or kind == ChainsawPickup
		# GUARD B2: Stimpack/Medikit/Berserk clamp health above 100 DOWN to 100.
		guard_b2 = Bool.False # W1 fixed: give_health refuses at or above cap
		# GUARD B3 (fidelity): SoulSphere/HealthBonus at health 200 are refused; vanilla always takes them.
		guard_b3 = Bool.False # W3 fixed: SoulSphere/HealthBonus are always taken
		# GUARD (contract-only, vanilla-consistent): ArmorBonus at 200 armor collects without change.
		guard_armor = before.armor >= 200 and kind == ArmorBonusPickup
		# Contract-only (vanilla-consistent): these collect without necessarily changing state.
		guard_b1 = is_weapon or kind == BerserkPickup or kind == LightAmpPickup or kind == SoulSpherePickup or kind == HealthBonusPickup or guard_b2 or guard_armor
		if after.health < before.health and !(guard_b2) {
			crash "PROPERTY: pickup lowered health ${ctx} ${Str.inspect(before.health)} -> ${Str.inspect(after.health)}"
		}
		# P1b: collected iff state changed (module's own contract, both directions)
		if result.collected != changed and !(guard_b1) {
			crash "PROPERTY: collected=${Str.inspect(result.collected)} but changed=${Str.inspect(changed)} ${ctx} before=${Str.inspect(before)}"
		}
		if result.collected != result.pickup.taken {
			crash "PROPERTY: pickup.taken disagrees with collected ${ctx}"
		}
		# P1c: vanilla fidelity of the accept decision
		if result.collected != vanilla_accepts(before, kind) and !(guard_b2) and !(guard_b3) {
			crash "FIDELITY: collected=${Str.inspect(result.collected)} vanilla=${Str.inspect(vanilla_accepts(before, kind))} ${ctx} before=${Str.inspect(before)}"
		}
		# monotonic: keys/weapons/backpack never lost
		if (before.keys.blue and !(after.keys.blue)) or (before.keys.yellow and !(after.keys.yellow)) or (before.keys.red and !(after.keys.red)) {
			crash "PROPERTY: key lost ${ctx}"
		}
		if before.backpack and !(after.backpack) {
			crash "PROPERTY: backpack lost ${ctx}"
		}
		# P2: backpack doubles caps exactly once
		if kind == BackpackPickup {
			$backpacks = $backpacks + 1
			if $backpacks >= 2 {
				if after.ammo.bullets != I64.min(400, before.ammo.bullets + 10) or after.ammo.shells != I64.min(100, before.ammo.shells + 4) or after.ammo.rockets != I64.min(100, before.ammo.rockets + 1) or after.ammo.cells != I64.min(600, before.ammo.cells + 20) {
					crash "PROPERTY: second backpack ammo wrong ${ctx} before=${Str.inspect(before.ammo)} after=${Str.inspect(after.ammo)}"
				}
			}
		}
		# taken pickups never collect again
		again = DoomWorld.collect(after, result.pickup)
		if result.collected and (again.collected or !(same_player(again.player, after))) {
			crash "PROPERTY: taken pickup collected again ${ctx}"
		}
		# collect_for_skill: same accept decision, bounded state
		sk = DoomWorld.collect_for_skill(before, pickup_at(kind, $index), skill(input.skill))
		if sk.collected != result.collected {
			crash "PROPERTY: collect_for_skill accept differs ${ctx} skill=${Str.inspect(skill(input.skill))}"
		}
		check_player(sk.player, "${ctx} via collect_for_skill")
		$player = after
		$index = $index + 1
	}
	# damage_player never underflows and keeps armor consistent
	for raw in input.damages {
		amount = U64.to_i64_wrap(raw)
		damaged = DoomWorld.damage_player($player, amount)
		check_player(damaged, "after damage_player ${Str.inspect(amount)}")
		if damaged.health > $player.health or damaged.armor > $player.armor {
			crash "PROPERTY: damage_player increased health/armor ${Str.inspect(amount)}"
		}
		if amount <= 0 and !(same_player(damaged, $player)) {
			crash "PROPERTY: non-positive damage changed player ${Str.inspect(amount)}"
		}
	}
	{}
}

## P3: firing through the world tic.
test_firing : Input -> {}
test_firing = |input| {
	base = DoomWorld.player({ x: 0, y: 0 }, DoomSim.Angle.from_turns(0))
	w = weapon(input.weapon_choice)
	player0 = {
		..base,
		weapon: w,
		weapons: { pistol: Bool.True, shotgun: Bool.True, chaingun: Bool.True, rocket_launcher: Bool.True, plasma_rifle: Bool.True, chainsaw: Bool.True },
		ammo: { bullets: U8.to_i64(input.ammo_bullets) % 201, shells: U8.to_i64(input.ammo_shells) % 51, rockets: U8.to_i64(input.ammo_shells) % 51, cells: U8.to_i64(input.ammo_bullets) },
	}
	actor = DoomWorld.actor(0, actor_kind(input.actor_kind), { x: 64, y: 0 }, DoomSim.Angle.from_turns(0.5), Bool.False)
	world : DoomWorld.World
	world = { player: player0, actors: [actor, { ..actor, id: 1 }], pickups: [], rng: DoomWorld.Rng.seed(input.fire_seed) }
	command = { ..DoomSim.neutral, fire: Bool.True }
	var $world = world
	var $count = 0
	while $count < U8.to_u64(input.fire_ticks) {
		before = $world
		$world = DoomWorld.world_tic(before, command)
		p = $world.player
		check_player(p, "after fire tic ${Str.inspect($count)} weapon=${Str.inspect(w)}")
		total_before = before.player.ammo.bullets + before.player.ammo.shells + before.player.ammo.rockets + before.player.ammo.cells
		total_after = p.ammo.bullets + p.ammo.shells + p.ammo.rockets + p.ammo.cells
		if total_after > total_before or total_before - total_after > 1 {
			crash "PROPERTY: fire tic changed ammo by more than one ${Str.inspect(before.player.ammo)} -> ${Str.inspect(p.ammo)}"
		}
		# actors: health never rises; a shot must hit the first live actor only
		var $slot = 0
		while $slot < List.len(before.actors) {
			old_actor = List.get(before.actors, $slot) ?? actor
			new_actor = List.get($world.actors, $slot) ?? actor
			if new_actor.health > old_actor.health {
				crash "PROPERTY: actor health rose in world_tic"
			}
			if old_actor.state.mode == Dead and new_actor.state.mode != Dead {
				crash "PROPERTY: dead actor revived in world_tic"
			}
			$slot = $slot + 1
		}
		$count = $count + 1
	}
	{}
}

## P4/P5: actor state machine and damage.
test_actor : Input -> {}
test_actor = |input| {
	kind = actor_kind(input.actor_kind)
	actor = DoomWorld.actor(7, kind, { x: 0, y: 0 }, DoomSim.Angle.from_turns(0), input.actor_ambush == 1)
	facts : DoomWorld.ActorFacts
	facts = {
		player_pos: { x: U8.to_f32(input.player_x) * 12 - 1500, y: U8.to_f32(input.player_y) * 12 - 1500 },
		has_sight: U8.bitwise_and(input.sight_bits, 1) != 0,
		heard_sound: U8.bitwise_and(input.sight_bits, 2) != 0,
		blockers: if U8.bitwise_and(input.sight_bits, 4) != 0 [{ start: { x: 24, y: -64 }, end: { x: 24, y: 64 } }] else [],
	}
	var $turn = { actor, rng: DoomWorld.Rng.seed(input.seed), player_damage: 0, attack_kind: NoAttack }
	var $turn2 = { actor, rng: DoomWorld.Rng.seed(input.seed), player_damage: 0, attack_kind: NoAttack }
	var $count = 0
	var $damage_index = 0
	while $count < U8.to_u64(input.tics) {
		prev = $turn
		$turn = DoomWorld.tick_actor_with(prev.actor, facts, prev.rng)
		$turn2 = DoomWorld.tick_actor_with($turn2.actor, facts, $turn2.rng)
		ctx = "tic ${Str.inspect($count)} kind=${Str.inspect(kind)} prev=${Str.inspect(prev.actor.state)} facts=${Str.inspect(facts)}"
		if !(same_turn($turn, $turn2)) {
			crash "PROPERTY: tick_actor_with nondeterministic ${ctx}"
		}
		a = $turn.actor
		if a.health > prev.actor.health {
			crash "PROPERTY: actor health rose ${ctx}"
		}
		if prev.actor.state.mode == Dead and (a.state.mode != Dead or $turn.player_damage != 0 or $turn.attack_kind != NoAttack) {
			crash "PROPERTY: Dead not absorbing ${ctx}"
		}
		if a.state.mode != Dead and a.state.remaining < 1 {
			crash "PROPERTY: remaining < 1 while alive ${Str.inspect(a.state)} ${ctx}"
		}
		if $turn.player_damage < 0 {
			crash "PROPERTY: negative player_damage ${ctx}"
		}
		if $turn.player_damage != 0 and (prev.actor.state.mode != Attack or prev.actor.state.remaining != 1) {
			crash "PROPERTY: damage outside terminal Attack tic ${Str.inspect($turn.player_damage)} ${ctx}"
		}
		if ($turn.player_damage > 0) != ($turn.attack_kind != NoAttack) {
			crash "PROPERTY: attack_kind/damage disagree ${Str.inspect($turn)} ${ctx}"
		}
		if $turn.attack_kind == NoAttack and $turn.rng.index() != prev.rng.index() {
			crash "PROPERTY: rng consumed without attack ${ctx}"
		}
		if $turn.attack_kind != NoAttack and $turn.rng.index() == prev.rng.index() and !(kind == Barrel) {
			crash "PROPERTY: attack did not consume rng ${ctx}"
		}
		# tick_actor (facts-free) must agree on the timing skeleton when nothing wakes the actor
		if !(facts.has_sight) and !(facts.heard_sound) and prev.actor.state.mode != Look {
			plain = DoomWorld.tick_actor(prev.actor)
			if plain.state.remaining != a.state.remaining and prev.actor.state.mode != Chase and prev.actor.state.mode != Attack {
				crash "PROPERTY: tick_actor/tick_actor_with timing disagree ${Str.inspect(plain.state)} vs ${Str.inspect(a.state)} ${ctx}"
			}
		}
		# every 7th tic apply one damage from the list
		if $count % 7 == 6 {
			match List.get(input.damages, $damage_index) {
				Err(_) => {}
				Ok(raw) => {
					amount = U64.to_i64_wrap(raw)
					plain = DoomWorld.damage_actor(a, amount)
					rolled = DoomWorld.damage_actor_random(a, amount, $turn.rng)
					if plain.health > a.health or rolled.actor.health > a.health {
						crash "PROPERTY: damage raised health ${Str.inspect(amount)} ${ctx}"
					}
					if plain.health < 0 or rolled.actor.health < 0 {
						crash "PROPERTY: negative actor health ${Str.inspect(amount)} ${ctx}"
					}
					if (plain.health == 0) != (plain.state.mode == Dead) or (rolled.actor.health == 0) != (rolled.actor.state.mode == Dead) {
						crash "PROPERTY: health/Dead mismatch ${Str.inspect(amount)} ${ctx}"
					}
					if plain.health != rolled.actor.health {
						crash "PROPERTY: damage_actor and damage_actor_random disagree on health ${Str.inspect(amount)} ${ctx}"
					}
					if amount <= 0 and plain.health != a.health {
						crash "PROPERTY: non-positive damage changed health ${Str.inspect(amount)} ${ctx}"
					}
					if amount <= 0 and a.state.mode != Dead and plain.state.mode == Dead {
						crash "PROPERTY: non-positive damage killed actor ${ctx}"
					}
					if amount <= 0 and a.state.mode != Dead and plain.state.mode != a.state.mode {
						# W4 fixed: damage_actor(_, <= 0) is a no-op.
						crash "PROPERTY: non-positive damage changed state ${Str.inspect(amount)} ${ctx}"
					}
					if rolled.entered_pain and rolled.actor.state.mode != Pain {
						crash "PROPERTY: entered_pain without Pain state ${ctx}"
					}
					if a.state.mode == Dead and rolled.entered_pain {
						crash "PROPERTY: dead actor entered pain ${ctx}"
					}
					if rolled.rng.index() == $turn.rng.index() and !(kind == Barrel) {
						crash "PROPERTY: damage_actor_random consumed no random ${ctx}"
					}
					if Bool.False and kind == Barrel and rolled.actor.health > 0 and !(rolled.entered_pain) {
						# (property was wrong: pain_chance 255 still misses on byte 255, as in vanilla `P_Random() < painchance`)
						crash "PROPERTY: barrel pain_chance 255 missed ${Str.inspect(rolled)} ${ctx}"
					}
					$turn = { ..$turn, actor: rolled.actor, rng: rolled.rng }
					$turn2 = { ..$turn2, actor: rolled.actor, rng: rolled.rng }
					$damage_index = $damage_index + 1
				}
			}
		}
		$count = $count + 1
	}
	{}
}

test : Input -> Fuzz.Outcome
test = |input| {
	test_pickups(input)
	test_firing(input)
	test_actor(input)
	Fuzz.keep
}

target = Fuzz.target({
	name: "doom-world",
	test,
	show: |input| Str.inspect(input),
})
