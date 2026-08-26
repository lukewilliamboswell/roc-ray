app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-26-b29bef3" }

import rr.App
import rr.Draw
import rr.FilesHost

Model : {}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |_startup| Ok({}))

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, _input| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
