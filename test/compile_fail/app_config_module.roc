app [Model, program] { rr: platform "../../platform/main.roc" }

import rr.App
import rr.AppConfig
import rr.Draw
import rr.Program

Model : {}

program = { init!, update, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |_startup| Ok({}))

update : Model, Program.Step -> Try(Program.Next(Model), [Exit(I64), ..])
update = |model, _step| Ok({ model, actions: [], tasks: Program.no_tasks })

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
