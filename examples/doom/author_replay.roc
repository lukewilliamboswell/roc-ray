## Bounded offline diagnostic author for a future fixed E1M1 replay fixture.
## This deliberately executes DoomRuntime and DoomLevel in ordinary Roc app
## code. It is not a completion fixture: until it reports Exited, its summary,
## visited sectors and RLE stream are navigation diagnostics only.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Draw
import rr.Color
import rr.Stdout
import DoomLevel
import DoomMap
import DoomRuntime
import DoomSim
import DoomWorld

Run : { world : DoomRuntime.World, level : DoomLevel.State, decorations : List(DoomWorld.Decoration), route_index : U64, tics : U64, runs : List(CommandRun), visited : List(U64) }
CommandRun : { count : U64, command : DoomSim.Command }
Model : { run : Run, printed : Bool }
Msg : []

program = { init!, update!, render! }

init! : App.Init(Model, _)
init! = App.init(App.default.with_title("E1M1 replay author").with_visible(Bool.False), |_host| Ok({ run: author(initial({}), 0), printed: Bool.False }))

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, _input| {
	if model.printed { Err(Exit(if model.run.world.phase == Exited 0 else 1)) } else {
		_ = Stdout.line!(summary(model.run))
		_ = Stdout.line!(encode_runs(model.run.runs, 0, ""))
		Ok({ ..model, printed: Bool.True })
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ScopeUnavailable, ..])
render! = |_model, frame| {
	frame.clear!(Color.black)
	Ok({})
}

initial = |_unit| {
	map = DoomMap.e1m1
	start = map.player_start() ?? crash "player start missing"
	# The first complete proof intentionally authors against the genuine Baby
	# thing population. Inventory, health and runtime rules remain untouched.
	spawned = DoomWorld.spawn(map.raw().things, Baby)
	player = DoomWorld.player({ x: I64.to_f32(start.position.x), y: I64.to_f32(start.position.y) }, DoomSim.Angle.from_turns(I64.to_f32(start.angle) / 360))
	doom : DoomWorld.World
	doom = { player, actors: spawned.actors, pickups: spawned.pickups, rng: DoomWorld.Rng.seed(0) }
	{ world: DoomRuntime.initial_for_skill(doom, Baby), level: DoomLevel.initial(map), decorations: spawned.decorations, route_index: 0, tics: 0, runs: [], visited: [140] }
}

author = |initial_run, _zero| {
	var $run = initial_run
	while $run.world.phase == Playing and $run.tics < max_tics {
		$run = author_tic($run)
	}
	$run
}

author_tic = |run| {
	map = DoomMap.e1m1
	pos = run.world.doom.player.sim.state.pos
	sector = DoomLevel.sector_at(map, { x: F32.to_f64(pos.x), y: F32.to_f64(pos.y) }) ?? crash "author left map"
	route_index = recover_route_index(sector, run.route_index)
	line_index = List.get(portal_lines, route_index) ?? exit_line
	target = author_target(route_index, pos, line_midpoint(line_index))
	route_line = List.get(map.raw().linedefs, line_index) ?? crash "route line missing"
	blockers = List.concat(DoomRuntime.blockers_for_player(map, run.level, pos), decoration_segments(run.decorations))
	supply = closest_supply(run.world.doom.pickups, run.world.doom.player, pos, sector, blockers)
	using_special = route_line.special != 0 and DoomSim.distance_squared(pos, target) < 64 * 64
	combat_target = if can_fire(run.world.doom.player) and !(using_special) closest_visible_actor(run.world.doom.actors, pos, blockers) else Err(NoActor)
	planned = match combat_target {
		Ok(actor) => combat_move(run.world.doom.player.sim.state, actor.pos, match supply { Ok(pickup) => pickup.pos, Err(_) => target })
		Err(_) => steer(run.world.doom.player.sim.state, match supply { Ok(pickup) => pickup.pos, Err(_) => target }, Bool.False)
	}
	command = match closest_projectile(run.world.projectiles, pos) {
		Ok(projectile) => evade_projectile(run.world.doom.player.sim.state, projectile.momentum, target)
		Err(_) => planned
	}
	advanced = DoomRuntime.advance_in_map(run.world, DoomSim.tic_seconds * 1.0001, command, blockers, map)
	new_pos = advanced.world.doom.player.sim.state.pos
	crossed = DoomRuntime.cross_specials(map, run.level, pos, new_pos)
	use_result = DoomRuntime.use_forward(map, crossed.level, new_pos, advanced.world.doom.player.sim.state.angle, advanced.world.doom.player.keys)
	level0 = match use_result { Activated(next) => next, _ => crossed.level }
	exited = crossed.exited or match use_result { Exit => Bool.True, _ => Bool.False }
	world = if exited { ..advanced.world, phase: Exited } else advanced.world
	new_sector = DoomLevel.sector_at(map, { x: F32.to_f64(new_pos.x), y: F32.to_f64(new_pos.y) }) ?? sector
	last_sector = List.last(run.visited) ?? sector
	visited = if new_sector == last_sector run.visited else List.append(run.visited, new_sector)
	{ ..run, world, level: advance_level(level0, advanced.tics), route_index, tics: run.tics + advanced.tics, runs: append_run(run.runs, command), visited }
}

closest_projectile = |projectiles, pos| {
	var $best = Err(NoProjectile)
	var $distance = 160 * 160
	for projectile in projectiles {
		distance = DoomSim.distance_squared(pos, projectile.pos)
		if distance < $distance {
			$best = Ok(projectile)
			$distance = distance
		}
	}
	$best
}

evade_projectile = |state, momentum, target| {
	left = { x: 0 - momentum.y, y: momentum.x }
	rightward = { x: momentum.y, y: 0 - momentum.x }
	route = DoomSim.normalize(DoomSim.sub(target, state.pos))
	direction = if DoomSim.dot(left, route) > DoomSim.dot(rightward, route) left else rightward
	move = DoomSim.normalize(direction)
	facing = state.angle.forward()
	right = { x: facing.y, y: 0 - facing.x }
	forward = DoomSim.dot(facing, move)
	side = DoomSim.dot(right, move)
	{ forward: if forward > 0.2 50 else if forward < -0.2 -50 else 0, side: if side > 0.2 40 else if side < -0.2 -40 else 0, turn: 0, fire: Bool.False }
}

recover_route_index = |sector, current| {
	var $found = current
	for pair in List.map_with_index(route_sectors, |value, index| { value, index }) {
		if pair.value == sector { $found = pair.index }
	}
	$found
}

line_midpoint = |index| {
	raw = DoomMap.e1m1.raw()
	line = List.get(raw.linedefs, index) ?? crash "route line missing"
	a = List.get(raw.vertices, line.start_vertex) ?? crash "route vertex missing"
	b = List.get(raw.vertices, line.end_vertex) ?? crash "route vertex missing"
	{ x: I64.to_f32(a.x + b.x) * 0.5, y: I64.to_f32(a.y + b.y) * 0.5 }
}

author_target = |route_index, pos, portal| {
	if route_index == 6 and pos.x < 660 { x: 670, y: 303 }
	else if route_index == 6 and pos.y < 350 { x: 700, y: 370 }
	else if route_index == 6 and pos.y < 420 { x: 800, y: 430 }
	else if route_index == 10 { x: 680, y: 1024 }
	else if route_index == 14 and pos.y < 1280 and pos.x > 240 { x: 224, y: 1240 }
	else if route_index == 14 { x: 224, y: 1490 }
	else if route_index == 15 and pos.x > 0 and pos.y < 1560 { x: 200, y: 1580 }
	else if route_index == 15 and pos.x > -350 and pos.y > 1500 { x: -360, y: 1580 }
	else if route_index == 15 and pos.y > 1440 { x: -360, y: 1440 }
	else if route_index == 15 { x: -224, y: 1390 }
	else portal
}

steer = |state, target, combat| {
	direction = DoomSim.normalize(DoomSim.sub(target, state.pos))
	facing = state.angle.forward()
	dot = DoomSim.dot(facing, direction)
	cross = facing.x * direction.y - facing.y * direction.x
	turn = if cross > 0.08 0.015625 else if cross < -0.08 -0.015625 else 0
	{ forward: if dot > 0.35 50 else 0, side: if combat 40 else if (state.tic / 16) % 2 == 0 20 else -20, turn, fire: combat and dot > 0.92 }
}

combat_steer = |state, aim, _movement| {
	aim_direction = DoomSim.normalize(DoomSim.sub(aim, state.pos))
	facing = state.angle.forward()
	aim_dot = DoomSim.dot(facing, aim_direction)
	cross = facing.x * aim_direction.y - facing.y * aim_direction.x
	{
		forward: 0,
		side: if (state.tic / 16) % 2 == 0 40 else -40,
		turn: if cross > 0.08 0.015625 else if cross < -0.08 -0.015625 else 0,
		fire: aim_dot > 0.92,
	}
}

combat_move = |state, aim, movement| {
	aim_direction = DoomSim.normalize(DoomSim.sub(aim, state.pos))
	move_direction = DoomSim.normalize(DoomSim.sub(movement, state.pos))
	facing = state.angle.forward()
	right = { x: facing.y, y: 0 - facing.x }
	forward_dot = DoomSim.dot(facing, move_direction)
	side_dot = DoomSim.dot(right, move_direction)
	cross = facing.x * aim_direction.y - facing.y * aim_direction.x
	{ forward: if forward_dot > 0.2 50 else if forward_dot < -0.2 -50 else 0, side: if side_dot > 0.2 40 else if side_dot < -0.2 -40 else 0, turn: if cross > 0.08 0.015625 else if cross < -0.08 -0.015625 else 0, fire: DoomSim.dot(facing, aim_direction) > 0.92 }
}

closest_visible_actor = |actors, pos, blockers| {
	var $best = Err(NoActor)
	var $distance = 1000000000
	for actor in actors {
		d = DoomSim.distance_squared(pos, actor.pos)
		if actor.state.mode != Dead and d < $distance and DoomRuntime.line_of_sight(pos, actor.pos, blockers) {
			$best = Ok(actor)
			$distance = d
		}
	}
	$best
}

can_fire = |player|
	match player.weapon {
		Pistol | Chaingun => player.ammo.bullets > 0
		Shotgun => player.ammo.shells > 0
		RocketLauncher => player.ammo.rockets > 0
		PlasmaRifle => player.ammo.cells > 0
		Chainsaw => Bool.True
	}

closest_supply = |pickups, player, pos, sector, blockers| {
	var $best = Err(NoPickup)
	var $distance = 700 * 700
	for pickup in pickups {
		useful = match pickup.kind {
			StimpackPickup | MedikitPickup | HealthBonusPickup | SoulSpherePickup | BerserkPickup => player.health < 75 and DoomSim.distance_squared(pos, pickup.pos) < 280 * 280
			GreenArmorPickup | BlueArmorPickup | ArmorBonusPickup => player.armor < 75 and DoomSim.distance_squared(pos, pickup.pos) < 400 * 400
			ClipPickup | BulletBoxPickup | ChaingunPickup | BackpackPickup => !(can_fire(player))
			ShellPickup | ShellBoxPickup | ShotgunPickup => !(can_fire(player))
			ChainsawPickup => Bool.True
			_ => Bool.False
		}
		pickup_sector = DoomLevel.sector_at(DoomMap.e1m1, { x: F32.to_f64(pickup.pos.x), y: F32.to_f64(pickup.pos.y) })
		distance = DoomSim.distance_squared(pos, pickup.pos)
		if useful and !(pickup.taken) and pickup_sector == Ok(sector) and distance < $distance and DoomRuntime.line_of_sight(pos, pickup.pos, blockers) {
			$best = Ok(pickup)
			$distance = distance
		}
	}
	$best
}

append_run = |runs, command|
	match List.last(runs) {
		Ok(last) => if last.command == command { (List.replace(runs, List.len(runs) - 1, { ..last, count: last.count + 1 }) ?? { list: runs, prev: last }).list } else List.append(runs, { count: 1, command })
		Err(_) => [{ count: 1, command }]
	}

decoration_segments = |decorations| {
	var $segments = []
	for decoration in decorations {
		if decoration.blocking {
			r = 16
			a = { x: decoration.pos.x - r, y: decoration.pos.y - r }
			b = { x: decoration.pos.x + r, y: decoration.pos.y - r }
			c = { x: decoration.pos.x + r, y: decoration.pos.y + r }
			d = { x: decoration.pos.x - r, y: decoration.pos.y + r }
			$segments = List.concat($segments, [{ start: a, end: b }, { start: b, end: c }, { start: c, end: d }, { start: d, end: a }])
		}
	}
	$segments
}

advance_level = |level, count| if count == 0 level else advance_level(DoomLevel.tick(level), count - 1)

summary = |run| {
	p = run.world.doom.player.sim.state.pos
	s = DoomLevel.sector_at(DoomMap.e1m1, { x:F32.to_f64(p.x), y:F32.to_f64(p.y) }) ?? 9999
	phase = match run.world.phase { Playing => "Playing", Dead => "Dead", Exited => "Exited" }
	"phase=${phase} tics=${U64.to_str(run.tics)} sector=${U64.to_str(s)} route=${U64.to_str(run.route_index)} pos=${F32.to_str(p.x)},${F32.to_str(p.y)} health=${I64.to_str(run.world.doom.player.health)} armor=${I64.to_str(run.world.doom.player.armor)} bullets=${I64.to_str(run.world.doom.player.ammo.bullets)} shells=${I64.to_str(run.world.doom.player.ammo.shells)} runs=${U64.to_str(List.len(run.runs))} visited=${join_u64(run.visited, 0, "")}"
}

join_u64 = |values, index, text|
	match List.get(values, index) { Err(_) => text, Ok(value) => join_u64(values, index + 1, "${text}${if index == 0 "" else ","}${U64.to_str(value)}") }

encode_runs = |runs, index, text|
	match List.get(runs,index) {
		Err(_) => text
		Ok(r) => encode_runs(runs,index+1,"${text}${U64.to_str(r.count)}:${I16.to_str(r.command.forward)},${I16.to_str(r.command.side)},${F32.to_str(r.command.turn)},${if r.command.fire "1" else "0"};")
	}

route_sectors = [140,141,91,150,98,142,17,93,10,9,13,12,37,34,8,135,63,64,68,66,67]
portal_lines = [834,837,564,593,594,1084,573,577,55,62,76,248,203,201,1006,386,391,389,396,405]
exit_line = 407
max_tics = 3000.U64
