app [Model, program] { rr: platform "../../platform/main.roc" }

import rr.App
import rr.AppConfig
import rr.Draw
import rr.Program

Model : {}

program = { init!, update, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |_startup| Ok({}))

Msg : []

update : Model, Program.Step(Msg) -> Try(Program.Next(Model, Msg), [Exit(I64), ..])
update = |model, _step| Ok({ model, actions: [], tasks: [] })

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
