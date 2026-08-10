app [Model, program] { rr: platform "../../platform/main.roc" }

# Large reads now return `List(U8)` from `Program`; the old module must stay absent.
import rr.App
import rr.Draw
import rr.File
import rr.Program

Model : {}

program = { init!, update, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |_startup| Ok({}))

Msg : []

update : Model, Program.Step(Msg) -> Program.Update(Model, Msg)
update = |model, _step| Program.static(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
