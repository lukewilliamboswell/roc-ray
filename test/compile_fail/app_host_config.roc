app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Draw

Model : {}

transport : App.HostConfig
transport = {
	title: "private",
	width: 800,
	height: 600,
	min_width: 0,
	min_height: 0,
	target_fps: 240,
	resizable: Bool.False,
	fullscreen: Bool.False,
	vsync: Bool.False,
	cursor_visible: Bool.True,
	exit_key_code: 256,
	visible: Bool.True,
	output_dir: ".",
	record_enabled: Bool.False,
	record_path: "",
	record_format: 0,
	record_fps: 0,
	record_max_frames: 0,
	record_scale_numerator: 1,
	record_scale_denominator: 1,
	record_every_nth: 1,
	record_timing: 0,
	record_cursor: 0,
	record_quality: 1,
}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |_startup| Ok({}))

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, _input| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
