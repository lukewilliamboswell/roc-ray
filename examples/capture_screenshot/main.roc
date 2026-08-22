app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Capture
import rr.Task
import rr.Color
import rr.Draw
import rr.Text

## Take a single screenshot, and show what the output sandbox refuses.
##
## Every capture path is relative to the directory set with `with_output_dir`.
## A path that would escape it -- absolute, or containing `..` -- is refused
## rather than quietly rewritten, because writing files is the only filesystem
## capability the platform grants an app.
##
## Press S to write `shots/scene.png`, E to watch an escaping path be refused,
## ESC to exit. With no keypress it screenshots itself on frame 3 and exits, so
## the headless CI sweep still runs it.
Model : {
	title : Text.Prepared,
	help : Text.Prepared,

	## Every outcome is prepared once at startup rather than re-laid-out each
	## frame, which keeps `render!` free of the allocation and its error.
	idle : Text.Prepared,
	saved : Text.Prepared,
	save_failed : Text.Prepared,
	refused : Text.Prepared,
	result : Text.Prepared,

	## Whether any screenshot has reported back yet. The file is encoded and
	## written off the frame thread, so how many frames that takes is not
	## something this app gets to assume.
	settled : Bool,
}

## Each task returns its own message variant, so two screenshots completing on
## one input need neither IDs nor completion filtering.
Msg : [EscapingScreenshotFinished(Try({}, Capture.ScreenshotError)), SavedScreenshotFinished(Try({}, Capture.ScreenshotError))]

program = { init!, update!, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default
		.with_title("RocRay Capture: Screenshot")
		.with_size({ width: 640, height: 360 })
		.with_output_dir("shots"),
	|_startup|
		{
			font = Draw.default_font!()
			idle = Text.from("no capture yet", font).size(16).prepare!()?
			Ok({
				title: Text.from("Screenshot demo", font).size(28).prepare!()?,
				help: Text.from("S = save, E = try to escape the sandbox, ESC = quit", font).size(16).prepare!()?,
				idle: idle,
				saved: Text.from("saved shots/scene.png", font).size(16).prepare!()?,
				save_failed: Text.from("could not write shots/scene.png", font).size(16).prepare!()?,
				refused: Text.from("refused ../escaped.png (PathEscapesOutputDir)", font).size(16).prepare!()?,
				result: idle,
				settled: Bool.False,
			})
		},
)

## A screenshot waits: the host reads the framebuffer at the end of the frame
## that asked, then encodes and writes the file off the frame thread. So the
## call belongs inside a task, where it parks the coroutine and the frame loop
## keeps drawing; its outcome arrives on a later input.
##
## The pixels are still the asking frame's. Only the report waits.
update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	input = program_input.devices
	next = apply_messages(model, program_input.messages)

	# `..` cannot reach outside the output directory, so this comes back as
	# PathEscapesOutputDir rather than writing beside the example source.
	escape_requested = input.key_pressed(KeyE)
	save_requested = input.key_pressed(KeyS) or program_input.time.cycle_count == 3

	# Frame 3 asks and the host reads the framebuffer at the end of it, but the
	# file is encoded and written off the frame thread, so the outcome arrives
	# on whichever later input the task finished by. Wait for it rather than for
	# a frame number: that is the whole difference between a task and a direct
	# effect. The frame cap is only so an unattended run cannot hang.
	settled = next.settled

	if escape_requested {
		Task.spawn!(program_input, || EscapingScreenshotFinished(Capture.screenshot!("../escaped.png")))
	}
	if save_requested {
		Task.spawn!(program_input, || SavedScreenshotFinished(Capture.screenshot!("scene.png")))
	}

	if input.key_pressed(KeyEscape) or (settled and program_input.time.cycle_count > 4) or program_input.time.cycle_count > 240 {
		Err(Exit(0))
	} else {
		Ok(next)
	}
}

## Apply every callback in host-observed order with one `List.fold` over the
## received message buffer.
apply_messages : Model, List(Msg) -> Model
apply_messages = |model, messages| List.fold(messages, model, apply_message)

apply_message : Model, Msg -> Model
apply_message = |model, message|
	match message {
		EscapingScreenshotFinished(Err(PathEscapesOutputDir)) => { ..model, result: model.refused, settled: Bool.True }
		EscapingScreenshotFinished(_) => { ..model, result: model.save_failed, settled: Bool.True }
		SavedScreenshotFinished(Ok(_)) => { ..model, result: model.saved, settled: Bool.True }
		SavedScreenshotFinished(Err(_)) => { ..model, result: model.save_failed, settled: Bool.True }
	}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x121420))
	model.title.draw!(frame, { pos: { x: 32, y: 28 }, color: Color.white, align: Text.align_top_left })
	model.help.draw!(frame, { pos: { x: 32, y: 64 }, color: Color.from_hex_rgb(0x81a1c1), align: Text.align_top_left })
	model.result.draw!(frame, { pos: { x: 32, y: 300 }, color: Color.from_hex_rgb(0xa3be8c), align: Text.align_top_left })

	frame.circle!({
		center: { x: 320, y: 190 },
		radius: 70,
		style: Draw.filled(Color.from_hex_rgb(0x5e81ac)),
	})

	Ok({})
}
