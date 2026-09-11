app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-09-10-a670e34" }

import rr.App
import rr.AppConfig
import rr.Draw

Model : {}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |io| Ok({}))

Msg : []

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64), ..])
update! = |model, _input, _io| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
