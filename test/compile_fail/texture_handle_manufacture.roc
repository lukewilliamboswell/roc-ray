app [Model, program] {
	rr: platform "../../platform/main.roc",
	roc: "nightly-2026-09-06-d85e877",
}

# A texture's resource identity is private to the host. Applications can copy a
# shared texture and alter its descriptive dimensions, but cannot manufacture a
# handle from a raw integer.
import rr.App
import rr.Draw
import rr.Texture

Model : {
	texture : Texture,
}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default,
	|_startup| {
		handle : Box(U64)
		handle = Box.box(0)
		Ok({ texture: { ..Texture.stub, handle } })
	},
)

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, _input| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
