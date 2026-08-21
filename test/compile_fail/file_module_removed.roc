app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

# Large reads now return `List(U8)` from `Files`; the old module must stay absent.
import rr.App
import rr.Draw
import rr.File

Model : {}

program = { init!, update, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |_startup| Ok({}))

Msg : []

update : Model, App.Input(Msg) -> App.Transition(Model, Msg)
update = |model, _input| App.next(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
