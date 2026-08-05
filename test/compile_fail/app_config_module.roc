app [Model, program] { rr: platform "../../platform/main.roc" }

import rr.App
import rr.AppConfig
import rr.Draw
import rr.Host

Model : {}

program = { init!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |_host| Ok({}))

render! : Model, Host, Draw.Frame => Try(Model, [Exit(I64), ..])
render! = |model, _host, _frame| Ok(model)
