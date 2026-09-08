app [Model, program] {
	rr: platform "../../platform/main.roc",
	roc: "nightly-2026-09-07-14d9829",
}

# A shader's resource identity is private to the host. Applications can retain
# the shared shader value, but cannot manufacture its handle from a raw integer.
import rr.App
import rr.Draw

Model : {
	shader : Draw.Shader,
}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default,
	|_startup| {
		handle = Box.box(0)
		Ok({ shader: Draw.Shader.(handle) })
	},
)

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, _input| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
