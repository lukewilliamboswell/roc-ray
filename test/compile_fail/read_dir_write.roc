app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-09-27-a3ce7f1" }

import rr.App
import rr.Draw
import rr.Files

Model : {}

program = { init!, update!, render! }

## A read-only handle has no way to write: the write does not type-check.
init! : App.Init(Model, [])
init! = App.init(
	App.default,
	|_io| {
		_ = Files.ReadDir.stub.write_text!("notes.txt", "never written")
		Ok({})
	},
)

Msg : []

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, _input, _io| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |_model, _frame| Ok({})
