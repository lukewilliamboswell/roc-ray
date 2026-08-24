app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

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
## rather than quietly rewritten. `Capture` is the one path-sandboxed writer the
## platform grants; `Files.write_text!` and `Files.write_bytes!` write wherever
## the process may write, so this confinement is `Capture`'s own promise rather
## than the platform's only way of putting bytes on disk.
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
	subtitle : Text.Prepared,
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
		.with_size({ width: 720, height: 420 })
		.with_output_dir("shots"),
	|_startup|
		{
			font = Draw.default_font!()
			shot_path = "scene-${Time.now!().to_file_stamp()}.png"
			Ok({
				title: Text.from("A picture of this frame", font).size(26).prepare!()?,
				subtitle: Text.from("encoded and written off the frame thread, reported back as a message", font).size(14).prepare!()?,
				help: Text.from("S  save        E  try to escape the sandbox        ESC  quit", font).size(13).spacing(2.0).prepare!()?,
				idle: Text.from("no capture yet", font).size(16).prepare!()?,
				saved: Text.from("saved shots/${shot_path}", font).size(16).prepare!()?,
				save_failed: Text.from("could not write shots/${shot_path}", font).size(16).prepare!()?,
				refused: Text.from("refused ../escaped.png -- PathEscapesOutputDir", font).size(16).prepare!()?,
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
	size = frame.size!()
	frame.rectangle_gradient_v!({ x: 0, y: 0, width: size.width, height: size.height, color_top: bg_top, color_bottom: bg_bottom })

	# Something worth photographing: a still motif, so two runs of the example
	# differ only in the filename rather than in the picture.
	center = { x: size.width - 140, y: 190 }
	frame.circle_gradient!({ center: center, radius: 120, color_inner: Color.from_hex_rgba(0x5e81ac55), color_outer: Color.from_hex_rgba(0x5e81ac00) })
	frame.circle!({ center: center, radius: 62, style: Draw.filled(Color.from_hex_rgb(0x4f7cc0)) })
	frame.circle!({ center: center, radius: 79, style: Draw.outlined(Color.with_alpha(accent, 110), 2) })
	frame.circle!({ center: center, radius: 94, style: Draw.outlined(Color.with_alpha(accent, 45), 1) })
	frame.circle!({ center: { x: center.x + 56, y: center.y - 56 }, radius: 7, style: Draw.filled(accent) })

	model.title.draw!(frame, { pos: { x: 36, y: 34 }, color: ink, align: Text.align_top_left })
	model.subtitle.draw!(frame, { pos: { x: 36, y: 68 }, color: muted, align: Text.align_top_left })

	# The outcome card. Its accent is the whole report: green for a file on
	# disk, amber for the sandbox refusing a path, red for a write that failed.
	color = outcome_color(model.outcome)
	frame.rounded_rectangle!({ x: 36, y: 236, width: 404, height: 72, radius: 0.16, segments: 8, style: Draw.filled_and_outlined(card, card_edge, 1) })
	frame.rounded_rectangle!({ x: 36, y: 248, width: 4, height: 48, radius: 1, segments: 4, style: Draw.filled(color) })
	frame.circle!({ center: { x: 78, y: 272 }, radius: 11, style: Draw.outlined(Color.with_alpha(color, 70), 1.5) })
	frame.circle!({ center: { x: 78, y: 272 }, radius: 5, style: Draw.filled(color) })
	frame.text_at!({ pos: { x: 108, y: 250 }, text: outcome_label(model.outcome), size: 13, color: faint })
	outcome_text(model).draw!(frame, { pos: { x: 108, y: 270 }, color: color, align: Text.align_top_left })

	model.help.draw!(frame, { pos: { x: 36, y: size.height - 38 }, color: faint, align: Text.align_top_left })
	Ok({})
}

## The prepared line for the outcome, all four laid out once at startup.
outcome_text : Model -> Text.Prepared
outcome_text = |model|
	match model.outcome {
		NoCapture => model.idle
		Saved => model.saved
		SaveFailed => model.save_failed
		Refused => model.refused
	}

outcome_label : Outcome -> Str
outcome_label = |outcome|
	match outcome {
		NoCapture => "WAITING FOR A TASK"
		Saved => "Capture.screenshot!"
		SaveFailed => "Capture.screenshot!"
		Refused => "OUTPUT SANDBOX"
	}

outcome_color : Outcome -> Color.Rgba
outcome_color = |outcome|
	match outcome {
		NoCapture => muted
		Saved => Color.from_hex_rgb(0x7fd6a2)
		SaveFailed => Color.from_hex_rgb(0xef7d7d)
		Refused => Color.from_hex_rgb(0xf2c777)
	}

expect outcome_color(Saved) != outcome_color(Refused)

bg_top = Color.from_hex_rgb(0x0b0e17)

bg_bottom = Color.from_hex_rgb(0x151b2a)

card = Color.from_hex_rgb(0x171d2b)

card_edge = Color.from_hex_rgb(0x2a3348)

ink = Color.from_hex_rgb(0xe8ecf5)

muted = Color.from_hex_rgb(0x8a97b0)

faint = Color.from_hex_rgb(0x5c6880)

accent = Color.from_hex_rgb(0x9ec7f5)
