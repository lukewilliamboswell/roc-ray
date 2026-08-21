app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-19-edec830" }

import rr.App
import rr.Capture
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

## The request callback selects a message variant, so two screenshots completing
## on one input need neither IDs nor completion filtering.
Msg : [EscapingScreenshotFinished(Try({}, Capture.ScreenshotError)), SavedScreenshotFinished(Try({}, Capture.ScreenshotError))]

program = { init!, update, render! }

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

## A screenshot can fail, and this app branches on that, so it is a request rather
## than an command: the request goes out here and the outcome comes back on a
## later input instead of being read off the call.
##
## The pixels are still this frame's -- the host reads the framebuffer at the
## end of the frame that asked, exactly where `Capture.screenshot!` read it --
## so only the report waits.
update : Model, App.Input(Msg) -> App.Transition(Model, Msg)
update = |model, program_input| {
	input = program_input.devices
	next = apply_messages(model, program_input.messages)

	# `..` cannot reach outside the output directory, so this comes back as
	# PathEscapesOutputDir rather than writing beside the example source.
	escape_requested = input.key_pressed(KeyE)
	save_requested = input.key_pressed(KeyS) or program_input.time.cycle_count == 3

	# Frame 3 asks and the host reads the framebuffer at the end of it, but the
	# file is encoded and written off the frame thread, so the outcome arrives
	# on whichever later input the write finished by. Wait for it rather than for
	# a frame number: that is the whole difference between a request and an command.
	# The frame cap is only so an unattended run cannot hang.
	settled = next.settled
	commands =
		if input.key_pressed(KeyEscape) or (settled and program_input.time.cycle_count > 4) or program_input.time.cycle_count > 240 {
			[App.exit(0)]
		} else {
			[]
		}

	requests =
		List.concat(
			if escape_requested [Capture.screenshot("../escaped.png", |result| EscapingScreenshotFinished(result))] else [],
			if save_requested [Capture.screenshot("scene.png", |result| SavedScreenshotFinished(result))] else [],
		)

	App.next(next).with_commands(commands).with_requests(requests)
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
