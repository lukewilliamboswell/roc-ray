app [Model, program] {
	roc: "nightly-2026-10-09-258ab27",
	rr: platform "../../platform/main.roc",
}

# A uniform record is derived structurally. Str has no shader-uniform encoder,
# so an unsupported field is rejected before the host can see it.
import rr.App
import rr.Draw
import rr.Shader

Model : {}

program = { init!, update!, render! }

init! : App.Init(Model, _)
init! = App.init(
	App.default,
	|_io| {
		_shader = Shader.from_source!(
			{ vertex_source: "", fragment_source: "void main() {}" },
			{ label: "unsupported" },
		)?
		Ok({})
	},
)

Msg : []

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, _input, _io| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |_model, _frame| Ok({})
