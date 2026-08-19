app [Model, program] {
	rr: platform "../../platform/main.roc",
	rrt: "../../types/main.roc",
	roc: "nightly-2026-08-14-549b94e",
}

# A texture's resource identity is private to the host. Applications can copy a
# shared texture and alter its descriptive dimensions, but cannot manufacture a
# handle from a raw integer.
import rr.App
import rr.Draw
import rr.Program
import rrt.Texture

Model : {
	texture : Texture,
}

program = { init!, update, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.static_config(App.default),
	|_startup| {
		handle = Texture.Handle.(Box.box(0))
		Ok({ texture: { handle, width: 8, height: 8 } })
	},
)

Msg : []

update : Model, Program.Step(Msg) -> Program.Update(Model, Msg)
update = |model, _step| Program.static(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
