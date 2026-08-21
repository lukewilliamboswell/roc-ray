app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-19-edec830" }

import rr.App
import rr.Draw
import rr.Input

Model : {}

program = { init!, update, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |_startup| Ok({}))

Msg : []

update : Model, App.Input(Msg) -> App.Transition(Model, Msg)
update = |model, _input| App.next(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
