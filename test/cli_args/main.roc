app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App

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
init! = App.init_for_args(config_for_args, |startup| Ok({ args: App.args!(startup) }))

Msg : []

update : Model, App.Input(Msg) -> App.Transition(Model, Msg)
update = |model, program_input| {
	passed =
		List.len(model.args) == 3
			and List.contains(model.args, config_flag)
				and List.contains(model.args, passthrough_flag)
					and program_input.window.size == { width: 321, height: 123 }

	App.next(model).with_commands([App.exit(if passed 0 else 1)])
}

render! : Model, _ => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
