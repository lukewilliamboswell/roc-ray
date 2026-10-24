app [Model, program] {
	roc: "nightly-2026-10-09-258ab27",
	rr: platform "../../platform/main.roc",
}

# Replacing uniforms must preserve the exact closed record shape.
import rr.App
import rr.Draw
import rr.Shader

Model : { shader : Shader({ amount : F32 }) }

program = { init!, update!, render! }

init! : App.Init(Model, _)
init! = App.init(
	App.default,
	|_io| {
		shader = Shader.stub({ amount: 1.F32 })
		changed = shader.with_uniforms({ amount: 2, enabled: Bool.True })
		Ok({ shader: changed })
	},
)

Msg : []

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, _input, _io| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |_model, _frame| Ok({})
