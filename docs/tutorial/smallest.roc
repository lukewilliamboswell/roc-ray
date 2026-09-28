app [Model, program] { rr: platform "../../platform/main.roc" }

# tag::body[]
import rr.App
import rr.Color
import rr.Draw

Model : { pointer : { x : F32, y : F32 } }

Msg : []

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default.with_title("Hello"), |_io| Ok({ pointer: { x: 400, y: 300 } }))

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |_model, input, _io| Ok({ pointer: input.devices.mouse.position() })

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |model, frame| {
	frame.clear!(Color.black)
	frame.circle!({ center: model.pointer, radius: 40, style: Draw.filled(Color.red) })
	Ok({})
}
# end::body[]
