app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-09-07-14d9829" }

import rr.App
import rr.Draw

Model : {
	db : App.Io,
}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |io| Ok({ db: App.Io.(0) }))

Msg : []

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64), ..])
update! = |model, _input, _io| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
