app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-09-27-a3ce7f1" }

import rr.App
import rr.Draw
import rr.Files

Model : {
	item : Files.Designated,
}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default, |_io| Ok({ item: Files.Designated.({ path: "/etc/passwd", parent: "/etc", name: "passwd" }) }))

Msg : []

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, _input, _io| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |_model, _frame| Ok({})
