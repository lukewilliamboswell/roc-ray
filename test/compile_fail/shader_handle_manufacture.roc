app [Model, program] {
	rr: platform "../../platform/main.roc",
	rrt: "../../types/main.roc",
	roc: "nightly-2026-08-23-fb208ba",
}

# A shader's resource identity is private to the host. Applications can retain
# the shared shader value, but cannot manufacture its handle from a raw integer.
import rr.App
import rr.Draw
import rrt.Handle as ResourceHandle
import rrt.Shader

Model : {
	shader : Shader,
}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default,
	|_startup| {
		handle = ResourceHandle.(Box.box(0))
		Ok({ shader: { handle } })
	},
)

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, _input| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
