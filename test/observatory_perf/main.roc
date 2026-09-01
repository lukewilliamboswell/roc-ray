app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-31-86e69b4" }

import rr.App
import rr.Color
import rr.Draw
import rr.Trace

## Deterministic Observatory overhead workload.
##
## The benchmark harness controls the number of host cycles. This app performs
## the same bounded update, annotation, allocation, and draw work on each one;
## it deliberately does no I/O and reads no wall clock.
Model : { cycle : U64, values : List(U64) }

Msg : []

program = { init!, update!, render! }

init! : App.Init(Model, Msg)
init! = App.init(
	App.default.with_title("Observatory performance probe"),
	|_startup|
		Ok({ cycle: 0, values: List.repeat(0, 64) }),
)

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, _input| {
	zone = Trace.begin!("benchmark update")
	index = model.cycle % List.len(model.values)
	values = match List.set(model.values, index, model.cycle) {
		Ok(updated) => updated
		Err(_) => model.values
	}
	Trace.sample_i64!("benchmark sample", 7, Count)
	Trace.mark!("benchmark mark")
	Trace.end!(zone)
	Ok({ cycle: model.cycle + 1, values })
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, frame| {
	draw = App.effects().render(frame)
	frame.clear!(Color.from_hex_rgb(0x080c14))
	draw.rectangle!({
		x: 24,
		y: 24,
		width: 120,
		height: 48,
		style: Draw.filled(Color.from_hex_rgb(0x4c5ab4)),
	})
	draw.circle!({
		center: { x: 180, y: 48 },
		radius: 18,
		style: Draw.outlined(Color.white, 2),
	})
	Ok({})
}
