app [Model, program] { rr: platform "../../platform/main.roc" }

import rr.App
import rr.Draw
import rr.Program

Model : {}

program = { init!, update, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |_startup| Ok({}))

Msg : []

update : Model, Program.Step(Msg) -> Try(Program.Next(Model, Msg), [Exit(I64), ..])
update = |model, _step| {
	_transport = App.default.to_host()
	Ok({ model, actions: [], tasks: [] })
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
