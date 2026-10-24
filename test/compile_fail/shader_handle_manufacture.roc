app [Model, program] {
	rr: platform "../../platform/main.roc",
}

# A shader's resource identity is private to the host. Applications can retain
# the shared shader value, but cannot manufacture its handle from a raw integer.
import rr.App
import rr.Draw
import rr.Shader

Model : {
	shader : Shader({}),
}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default,
	|_io| {
		handle = Box.box(0)
		Ok({ shader: Shader.({ resource: handle, uniforms: {} }) })
	},
)

Msg : []

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, _input, _io| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |_model, _frame| Ok({})
