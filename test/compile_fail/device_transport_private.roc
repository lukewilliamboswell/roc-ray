app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-09-06-d85e877" }

import rr.App
import rr.Draw
import rr.Devices

Model : { raw : List(Devices.RawEvent) }

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |_startup| Ok({ raw: [] }))

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, _input| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
