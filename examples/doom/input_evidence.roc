## Native evidence that Doom controls travel through RocRay's sampled virtual
## keyboard and mouse sources with the same edge/down semantics as hardware.
app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Keys
import rr.Mouse
import DoomControls
import DoomLevel
import DoomMap
import DoomSim
import DoomWorld

Model : { initial : DoomSim.State, initial_ok : Bool, right_ok : Bool }

Msg : []

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default.with_title("Doom input evidence").with_visible(Bool.False).with_frame_pacing(Uncapped),
	|_startup| {
		map = DoomMap.e1m1
		start = map.player_start() ?? crash "validated E1M1 player start missing"
		pos = { x: I64.to_f32(start.position.x), y: I64.to_f32(start.position.y) }
		angle = DoomSim.Angle.from_turns(I64.to_f32(start.angle) / 360)
		player = DoomWorld.player(pos, angle)
		sector = DoomLevel.sector_at(map, { x: I64.to_f64(start.position.x), y: I64.to_f64(start.position.y) }) ?? crash "E1M1 start outside map"
		heights = DoomLevel.heights_for(DoomLevel.initial(map), sector) ?? crash "E1M1 start sector missing"
		Ok({ initial: player.sim.state, initial_ok: player.health == 100 and sector == 140 and heights.floor == 0, right_ok: Bool.False })
	},
)

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	cycle = input.time.cycle_count
	devices = input.devices
	if cycle == 0 {
		Keys.set_source!(Keys.holding([KeyD]))
		Mouse.set_source!(Mouse.virtual_at({ x: 100, y: 80 }))
		Ok(model)
	} else if cycle == 1 {
		right_state = DoomSim.tic(model.initial, { ..DoomSim.neutral, side: DoomControls.side(Bool.False, devices.key_down(KeyD)) }, [])
		right_delta = DoomSim.sub(right_state.pos, model.initial.pos)
		right_ok = devices.key_pressed(KeyD)
			and devices.key_down(KeyD)
				and DoomSim.dot(right_delta, DoomControls.visual_right(model.initial.angle)) > 0
		Keys.set_source!(Keys.holding([KeyA]))
		Mouse.set_source!(Mouse.virtual_at({ x: 120, y: 80 }))
		Ok({ ..model, right_ok })
	} else if cycle == 2 {
		left_state = DoomSim.tic(model.initial, { ..DoomSim.neutral, side: DoomControls.side(devices.key_down(KeyA), Bool.False) }, [])
		left_delta = DoomSim.sub(left_state.pos, model.initial.pos)
		mouse_delta = devices.mouse.delta().x
		turned = model.initial.angle.add(DoomControls.turn(mouse_delta)).forward()
		left_ok = devices.key_released(KeyD)
			and devices.key_pressed(KeyA)
				and devices.key_down(KeyA)
					and DoomSim.dot(left_delta, DoomControls.visual_right(model.initial.angle)) < 0
		turn_ok = mouse_delta > 0 and DoomSim.dot(turned, DoomControls.visual_right(model.initial.angle)) > 0
		if model.initial_ok and model.right_ok and left_ok and turn_ok Err(Exit(0)) else Err(Exit(3))
	} else {
		Err(Exit(4))
	}
}

render! : Model, _ => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
