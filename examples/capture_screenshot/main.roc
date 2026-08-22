app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Capture
import rr.Task
import rr.Time
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
## The filename carries the wall-clock instant the app started, so a second run
## does not overwrite the first one's picture. `Time.now!` is the only clock
## that knows what day it is; `input.time` is the simulation timeline and would
## give every run the same name. Reading it once in `init!` and keeping the
## name in the model is what makes the name stable for the whole run, which is
## the shape to copy: the calendar is nondeterministic, so an app reads it
## deliberately at the moments it means to.
##
## Press S to write the shot, E to watch an escaping path be refused, ESC to
## exit. With no keypress it screenshots itself on frame 3 and exits, so the
## headless CI sweep still runs it.
Model : {
	title : Text.Prepared,
	help : Text.Prepared,

	## Every outcome is prepared once at startup rather than re-laid-out each
	## frame, which keeps `render!` free of the allocation and its error.
	idle : Text.Prepared,
	saved : Text.Prepared,
	save_failed : Text.Prepared,
	refused : Text.Prepared,

	## Which of those four to draw. A tag rather than the prepared text itself,
	## so folding a finished screenshot in stays pure and can be tested.
	outcome : Outcome,

	## The name this run writes, fixed at startup from the wall clock.
	shot_path : Str,
}

## How far the app has got. `NoCapture` until a task answers: the file is
## encoded and written off the frame thread, so how many frames that takes is
## not something this app gets to assume.
Outcome := [NoCapture, Saved, SaveFailed, Refused].{
	is_eq : _
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
			shot_path = "scene-${Time.now!().to_file_stamp()}.png"
			Ok({
				title: Text.from("Screenshot demo", font).size(28).prepare!()?,
				help: Text.from("S = save, E = try to escape the sandbox, ESC = quit", font).size(16).prepare!()?,
				idle: Text.from("no capture yet", font).size(16).prepare!()?,
				saved: Text.from("saved shots/${shot_path}", font).size(16).prepare!()?,
				save_failed: Text.from("could not write shots/${shot_path}", font).size(16).prepare!()?,
				refused: Text.from("refused ../escaped.png (PathEscapesOutputDir)", font).size(16).prepare!()?,
				outcome: NoCapture,
				shot_path: shot_path,
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
	outcome = apply_messages(model.outcome, program_input.messages)

	# `..` cannot reach outside the output directory, so this comes back as
	# PathEscapesOutputDir rather than writing beside the example source.
	escape_requested = input.key_pressed(KeyE)
	save_requested = input.key_pressed(KeyS) or program_input.time.cycle_count == 3

	# Frame 3 asks and the host reads the framebuffer at the end of it, but the
	# file is encoded and written off the frame thread, so the outcome arrives
	# on whichever later input the task finished by. Wait for it rather than for
	# a frame number: that is the whole difference between a task and a direct
	# effect. The frame cap is only so an unattended run cannot hang.
	settled = outcome != NoCapture

	if escape_requested {
		Task.spawn!(program_input, || EscapingScreenshotFinished(Capture.screenshot!("../escaped.png")))
	}
	if save_requested {
		# Read out of the model before spawning: the closure captures the name,
		# and a task cannot reach into the model for it.
		shot_path = model.shot_path
		Task.spawn!(program_input, || SavedScreenshotFinished(Capture.screenshot!(shot_path)))
	}

	if input.key_pressed(KeyEscape) or (settled and program_input.time.cycle_count > 4) or program_input.time.cycle_count > 240 {
		Err(Exit(0))
	} else {
		Ok({ ..model, outcome })
	}
}

## Fold every message this cycle delivered, in the order the tasks finished.
apply_messages : Outcome, List(Msg) -> Outcome
apply_messages = |outcome, messages| List.fold(messages, outcome, apply_message)

## The latest answer wins: two screenshots can finish on one cycle, and the app
## has one line to report them on.
apply_message : Outcome, Msg -> Outcome
apply_message = |_outcome, message|
	match message {
		EscapingScreenshotFinished(Err(PathEscapesOutputDir)) => Refused
		EscapingScreenshotFinished(_) => SaveFailed
		SavedScreenshotFinished(Ok(_)) => Saved
		SavedScreenshotFinished(Err(_)) => SaveFailed
	}

## The sandbox refusal is its own outcome: the path was rejected before
## anything was written, which is not the same as a write that failed.
expect apply_message(NoCapture, EscapingScreenshotFinished(Err(PathEscapesOutputDir))) == Refused
expect apply_message(NoCapture, EscapingScreenshotFinished(Err(WriteFailed))) == SaveFailed
expect apply_message(NoCapture, SavedScreenshotFinished(Ok({}))) == Saved
expect apply_message(NoCapture, SavedScreenshotFinished(Err(WriteFailed))) == SaveFailed

## Nothing delivered leaves the outcome alone, which is what keeps the app
## waiting rather than exiting on a frame number.
expect apply_messages(NoCapture, []) == NoCapture

## Both tasks can finish on one cycle; they are folded in the order they did.
expect apply_messages(NoCapture, [SavedScreenshotFinished(Ok({})), EscapingScreenshotFinished(Err(PathEscapesOutputDir))]) == Refused

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x121420))
	model.title.draw!(frame, { pos: { x: 32, y: 28 }, color: Color.white, align: Text.align_top_left })
	model.help.draw!(frame, { pos: { x: 32, y: 64 }, color: Color.from_hex_rgb(0x81a1c1), align: Text.align_top_left })
	result = match model.outcome {
		NoCapture => model.idle
		Saved => model.saved
		SaveFailed => model.save_failed
		Refused => model.refused
	}
	result.draw!(frame, { pos: { x: 32, y: 300 }, color: Color.from_hex_rgb(0xa3be8c), align: Text.align_top_left })

	frame.circle!({
		center: { x: 320, y: 190 },
		radius: 70,
		style: Draw.filled(Color.from_hex_rgb(0x5e81ac)),
	})

	Ok({})
}
