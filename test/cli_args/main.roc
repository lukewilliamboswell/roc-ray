app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-14-549b94e" }

import rr.App
import rr.Program

Model : { args : List(Str) }

program = { init!, update, render! }

config_flag : Str
config_flag = "--cli-args-config"

passthrough_flag : Str
passthrough_flag = "--headless"

config_for_args : List(Str) -> App.Config
config_for_args = |args|
	if List.contains(args, config_flag) {
		App.default.with_size({ width: 321, height: 123 })
	} else {
		App.default
	}

init! : App.Init(Model, [])
init! = App.init(config_for_args, |startup| Ok({ args: startup.args!() }))

Msg : []

update : Model, Program.Step(Msg) -> Program.Update(Model, Msg)
update = |model, step| {
	passed =
		List.len(model.args) == 3
			and List.contains(model.args, config_flag)
				and List.contains(model.args, passthrough_flag)
					and step.window.size == { width: 321, height: 123 }

	Program.static(model).with_actions([Program.exit(if passed 0 else 1)])
}

render! : Model, _ => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
