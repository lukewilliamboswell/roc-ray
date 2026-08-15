app [Model, program] { rr: platform "../platform/main.roc", roc: "nightly-2026-08-14-549b94e" }

import rr.App
import rr.Assets
import rr.Draw
import rr.Program

Model : { store : Assets.Store, texture : Assets.Texture, font : Draw.Font, shader : Draw.Shader }

program = { init!, update, render! }

init! : App.Init(Model, _)
init! = App.init(
	App.static_config(App.default),
	|_startup| {
		store = Assets.Store.open!(
			Assets.with_manifest(
				Assets.beside_executable("assets"),
				{
					asset_set: "test-assets",
					schema: 1,
					content_version: 1,
					content: Sha256("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
				},
			),
		)?
		texture = store.texture!("textures/example.png")?
		font = Draw.load_store_font!(store, { path: "fonts/example.ttf", size: 20 })?
		shader = Draw.Shader.from_store!(store, { vertex_path: "", fragment_path: "shaders/example.fs" })?
		Ok({ store, texture, font, shader })
	},
)

Msg : []

update : Model, Program.Step(Msg) -> Program.Update(Model, Msg)
update = |model, _step| Program.static(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
