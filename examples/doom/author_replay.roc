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
	spawned = DoomWorld.spawn(map.raw().things, Medium)
	player = DoomWorld.player({ x: I64.to_f32(start.position.x), y: I64.to_f32(start.position.y) }, DoomSim.Angle.from_turns(I64.to_f32(start.angle) / 360))
	doom : DoomWorld.World
	doom = { player, actors: spawned.actors, pickups: spawned.pickups, rng: DoomWorld.Rng.seed(0) }
	{ world: DoomRuntime.initial(doom), level: DoomLevel.initial(map), decorations: spawned.decorations, route_index: 0, tics: 0, runs: [], visited: [140] }
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
	line_index = if sector == 142 566 else List.get(portal_lines, route_index) ?? exit_line
	target = author_target(route_index, pos, line_midpoint(line_index))
	blockers = List.concat(DoomRuntime.blockers_for_player(map, run.level, pos), decoration_segments(run.decorations))
	combat_target = closest_visible_actor(run.world.doom.actors, pos, blockers)
	command = if sector == 150 and pos.x < 70 and run.world.doom.player.sim.state.momentum.x > 1 {
		world_move(run.world.doom.player.sim.state, { x: -1, y: 0 })
	} else match combat_target {
		Ok(actor) => combat_steer(run.world.doom.player.sim.state, actor.pos, target)
		Err(_) => steer(run.world.doom.player.sim.state, target, Bool.False)
	}
	advanced = DoomRuntime.advance(run.world, DoomSim.tic_seconds * 1.0001, command, blockers)
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
	if route_index == 3 and pos.x < 70 and pos.y < 325 { x: 48, y: 328 }
	else if route_index == 3 and pos.x < 380 { x: 400, y: 328 }
	else if route_index == 4 and pos.x < 620 { x: 630, y: 328 }
	else if route_index == 4 and pos.y < 420 { x: 730, y: 430 }
	else if route_index == 5 and pos.x < 700 { x: 700, y: 380 }
	else if route_index == 5 and pos.y < 410 { x: 800, y: 420 }
	else portal
}

steer = |state, target, combat| {
	direction = DoomSim.normalize(DoomSim.sub(target, state.pos))
	facing = state.angle.forward()
	dot = DoomSim.dot(facing, direction)
	cross = facing.x * direction.y - facing.y * direction.x
	turn = if cross > 0.08 0.015625 else if cross < -0.08 -0.015625 else 0
	{ forward: if combat { if dot > 0.35 50 else 0 } else if dot > 0.35 50 else 0, side: if combat 40 else 0, turn, fire: combat and dot > 0.92 }
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

world_move = |state, direction| {
	facing = state.angle.forward()
	right = { x: facing.y, y: 0 - facing.x }
	forward = DoomSim.dot(facing, direction)
	side = DoomSim.dot(right, direction)
	{ forward: if forward > 0 50 else -50, side: if side > 0 40 else -40, turn: 0, fire: Bool.False }
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
	"phase=${phase} tics=${U64.to_str(run.tics)} sector=${U64.to_str(s)} route=${U64.to_str(run.route_index)} pos=${F32.to_str(p.x)},${F32.to_str(p.y)} health=${I64.to_str(run.world.doom.player.health)} runs=${U64.to_str(List.len(run.runs))} visited=${join_u64(run.visited, 0, "")}"
}

join_u64 = |values, index, text|
	match List.get(values, index) { Err(_) => text, Ok(value) => join_u64(values, index + 1, "${text}${if index == 0 "" else ","}${U64.to_str(value)}") }

encode_runs = |runs, index, text|
	match List.get(runs,index) {
		Err(_) => text
		Ok(r) => encode_runs(runs,index+1,"${text}${U64.to_str(r.count)}:${I16.to_str(r.command.forward)},${I16.to_str(r.command.side)},${F32.to_str(r.command.turn)},${if r.command.fire "1" else "0"};")
	}

route_sectors = [140,141,91,150,151,17,93,10,9,13,12,37,34,8,135,63,64,68,66,67]
portal_lines = [834,837,564,873,1166,573,577,55,62,76,248,203,201,1006,386,391,389,396,405]
exit_line = 407
max_tics = 1000.U64
