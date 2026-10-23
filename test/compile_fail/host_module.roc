app [Model, program] { roc: "nightly-2026-10-23-18478ff", rr: platform "../../platform/main.roc" }

import rr.App
import rr.Draw
import rr.Host

Model : {}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |io| Ok({}))

Msg : []

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, _input, _io| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |_model, _frame| Ok({})
