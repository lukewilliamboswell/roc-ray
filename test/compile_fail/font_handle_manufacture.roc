app [Model, program] {
	rr: platform "../../platform/main.roc",
	rrt: "../../types/main.roc",
	roc: "nightly-2026-08-23-fb208ba",
}

# A font's resource identity is private to the host. Applications can copy a
# font and alter its descriptive metrics -- which mismeasures text and nothing
# worse -- but cannot manufacture a resource from a raw integer.
import rr.App
import rr.Draw
import rrt.Font
import rrt.Handle as ResourceHandle

Model : {
	font : Font,
}

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(
	App.default,
	|_startup| {
		handle = ResourceHandle.(Box.box(0))
		Ok({
			font: { ..Font.stub, handle },
		})
	},
)

Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, _input| Ok(model)

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
