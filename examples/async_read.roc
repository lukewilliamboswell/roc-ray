app [Model, program] { rr: platform "../platform/main.roc" }

import rr.App
import rr.Color
import rr.Draw
import rr.Program
import rr.Text

## Read a file without stalling the frame.
##
## The read is a `Cmd`, so `update!` hands it to the host and returns
## immediately; the host does the blocking work on another thread and the answer
## arrives later as an `EffectResult` carrying the id the app chose. Nothing here
## waits, and the animation below keeps running while the read is outstanding --
## which is the whole point.
##
## The same code path runs when the host has no worker: the result simply
## arrives on the frame the command was issued instead of a later one.
Model : {
	state : LoadState,
	elapsed : F32,
	title : Text.Prepared,
}

LoadState : [
	Requested,
	Loaded(U64),
	Failed(U8),
]

## The id the host echoes back, so a result can be matched to its request. With
## one outstanding read a constant is enough; a real app would allocate these.
read_id : U64
read_id = 1

program = { init!, update!, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default.with_title("RocRay Async Read").with_frame_pacing(Capped(120)),
	|_host|
		Ok({
			state: Requested,
			elapsed: 0,
			title: Text.from("Reading while the frame keeps moving").size(22).prepare!()?,
		}),
)

update! : Model, Program.Input => Try({ model : Model, cmds : List(Program.Cmd) }, [Exit(I64), ..])
update! = |model, input|
	match input {
		# Frame 0 issues the read. Returning it as a command rather than calling
		# a blocking effect is what keeps this frame short.
		Frame(host) =>
			if host.key_pressed(KeyEscape) {
				host.exit!(0)
				Ok({ model: model, cmds: [] })
			} else if host.frame_count == 0 {
				Ok({ model: model, cmds: [ReadFile({ id: read_id, path: "README.md" })] })
			} else {
				Ok({ model: model, cmds: [] })
			}

		Tick(tick) => Ok({ model: { ..model, elapsed: model.elapsed + tick.frame_time }, cmds: [] })

		EffectResult(result) =>
			if result.id != read_id {
				Ok({ model: model, cmds: [] })
			} else {
				next = match result.value {
					StrValue(contents) => Loaded(Str.count_utf8_bytes(contents))
					Failed(code) => Failed(code)
					_ => Failed(0)
				}
				Ok({ model: { ..model, state: next }, cmds: [] })
			}
		}

render! : Model, Draw.Frame => Try(Model, [Exit(I64), ..])
render! = |model, frame| {
	status = match model.state {
		Requested => "reading..."
		Loaded(bytes) => Str.concat("read ", Str.concat(U64.to_str(bytes), " bytes"))
		Failed(_) => "read failed"
	}

	frame.clear!(Color.from_hex_rgb(0x121420))
	model.title.draw!(frame, { pos: { x: 40, y: 40 }, color: Color.white, align: Text.align_top_left })
	frame.text_at!({ pos: { x: 40, y: 90 }, text: status, size: 20, color: Color.from_hex_rgb(0xa3be8c) })

	# Keeps moving while the read is outstanding, so a stalled frame would show.
	frame.circle!({
		center: { x: 400 + 220 * F32.cos(model.elapsed * 2), y: 320 + 120 * F32.sin(model.elapsed * 2) },
		radius: 26,
		style: Draw.filled(Color.from_hex_rgb(0x5e81ac)),
	})

	Ok(model)
}
