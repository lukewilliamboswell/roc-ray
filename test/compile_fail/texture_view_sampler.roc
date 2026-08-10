app [Model, program] { rr: platform "../../platform/main.roc" }

# Sampler state lives on the shared GPU texture object, so setting a filter
# through a view would change how the owning texture -- and every other view of
# it -- is drawn. A value documented as a read-only view must not be able to do
# that, so the setters exist only on `Texture`.
import rr.Assets
import rr.App
import rr.Draw
import rr.Program

Model : {
	view : Assets.TextureView,
}

program = { init!, update, render! }

init! : App.Init(Model, [TextureGenerationFailed, ResourceLimit])
init! = App.init(
	App.default,
	|_startup| {
		texture = Assets.generate_color_texture!({ width: 8, height: 8, color: { r: 255, g: 0, b: 0, a: 255 } })?
		Ok({ view: texture.view() })
	},
)

Msg : []

update : Model, Program.Step(Msg) -> Program.Update(Model, Msg)
update = |model, _step| Program.static(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, _frame| {
	model.view.set_filter!(Point)
	Ok({})
}
