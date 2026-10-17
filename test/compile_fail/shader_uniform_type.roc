app [Model, program] {
	roc: "nightly-2026-10-09-258ab27",
	rr: platform "../../platform/main.roc",
}

# Replacing uniforms must preserve every field's value type.
import rr.App
import rr.Draw

Model : { shader : Draw.Shader({ amount : F32 }) }

program = { init!, update!, render! }

init! : App.Init(Model, _)
init! = App.init(
	App.default,
	|_io| {
		shader = Draw.Shader.stub({ amount: 1.F32 })
		changed = shader.with_uniforms({ amount: 2.I32 })
		Ok({ shader: changed })
	},
)

Msg : []

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, _input, _io| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |_model, _frame| Ok({})
