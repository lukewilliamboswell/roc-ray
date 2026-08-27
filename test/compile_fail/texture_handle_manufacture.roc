app [Model, program] {
	rr: platform "../../platform/main.roc",
	rrt: "../../types/main.roc",
	roc: "nightly-2026-08-23-fb208ba",
}

# A texture's resource identity is private to the host. Applications can copy a
# shared texture and alter its descriptive dimensions, but cannot manufacture a
# handle from a raw integer.
import rr.App
import rr.Draw
import rrt.Texture

Model : {
	texture : Texture,
}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default,
	|_startup| {
		handle = Texture.Handle.(Box.box(0))
		Ok({ texture: { handle, width: 8, height: 8 } })
	},
)

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, _input| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
