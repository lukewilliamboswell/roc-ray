app [Model, program] { rr: platform "../platform/main.roc" }

import rr.App
import rr.Color
import rr.Draw
import rr.Program
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

	## The screenshot each outstanding task will answer for, by the id it
	## echoes back. An outcome arrives a step after the request, so the id has
	## to outlive the frame that asked -- and a refusal and a save mean
	## different things, so they cannot share one slot.
	pending_escape : Pending,
	pending_save : Pending,

	## Where task ids come from. They only have to be unique, not dense, so
	## this advances by two every cycle whether or not either was requested.
	next_id : U64,

	## Whether any screenshot has reported back yet. The file is encoded and
	## written off the frame thread, so how many frames that takes is not
	## something this app gets to assume.
	settled : Bool,
}

## A screenshot task in flight, by the id its completion will echo back.
Pending : [Idle, Waiting(U64)]

## What a step said about an outstanding screenshot.
Outcome : [NotYet, Finished(Try({}, Program.ScreenshotError))]

program = { init!, update, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default
		.with_title("RocRay Capture: Screenshot")
		.with_size({ width: 640, height: 360 })
		.with_output_dir("shots"),
	|_startup|
		{
			idle = Text.from("no capture yet").size(16).prepare!()?
			Ok({
				title: Text.from("Screenshot demo").size(28).prepare!()?,
				help: Text.from("S = save, E = try to escape the sandbox, ESC = quit").size(16).prepare!()?,
				idle: idle,
				saved: Text.from("saved shots/scene.png").size(16).prepare!()?,
				save_failed: Text.from("could not write shots/scene.png").size(16).prepare!()?,
				refused: Text.from("refused ../escaped.png (PathEscapesOutputDir)").size(16).prepare!()?,
				result: idle,
				pending_escape: Idle,
				pending_save: Idle,
				next_id: 0,
				settled: Bool.False,
			})
		},
)

## A screenshot can fail, and this app branches on that, so it is a task rather
## than an action: the request goes out here and the outcome comes back on a
## later step instead of being read off the call.
##
## The pixels are still this frame's -- the host reads the framebuffer at the
## end of the frame that asked, exactly where `Capture.screenshot!` read it --
## so only the report waits.
update : Model, Program.Step -> Try(Program.Next(Model), [Exit(I64), ..])
update = |model, step| {
	input = step.input

	escape_id = model.next_id
	save_id = model.next_id + 1

	# `..` cannot reach outside the output directory, so this comes back as
	# PathEscapesOutputDir rather than writing beside the example source.
	escape_requested = input.key_pressed(KeyE)
	save_requested = input.key_pressed(KeyS) or step.time.frame_count == 3

	escape_outcome = screenshot_outcome(step.completed, model.pending_escape)
	saved_outcome = screenshot_outcome(step.completed, model.pending_save)

	escaped =
		match escape_outcome {
			Finished(Err(PathEscapesOutputDir)) => Ok(model.refused)
			# Any other outcome means the sandbox let something through.
			Finished(_) => Ok(model.save_failed)
			NotYet => Err(NotRequested)
		}

	saved =
		match saved_outcome {
			Finished(Ok(_)) => Ok(model.saved)
			Finished(Err(_)) => Ok(model.save_failed)
			NotYet => Err(NotRequested)
		}

	# Frame 3 asks and the host reads the framebuffer at the end of it, but the
	# file is encoded and written off the frame thread, so the outcome arrives
	# on whichever later step the write finished by. Wait for it rather than for
	# a frame number: that is the whole difference between a task and an action.
	# The frame cap is only so an unattended run cannot hang.
	settled = model.settled or escape_outcome != NotYet or saved_outcome != NotYet
	actions =
		if input.key_pressed(KeyEscape) or (settled and step.time.frame_count > 4) or step.time.frame_count > 240 {
			[Program.exit(0)]
		} else {
			[]
		}

	tasks =
		List.concat(
			if escape_requested [Screenshot({ id: escape_id, path: "../escaped.png" })] else [],
			if save_requested [Screenshot({ id: save_id, path: "scene.png" })] else [],
		)

	next = match (escaped, saved) {
		(Ok(text), _) => { ..model, result: text }
		(_, Ok(text)) => { ..model, result: text }
		_ => model
	}

	Ok({
		model: {
			..next,
			pending_escape: still_pending(model.pending_escape, escape_requested, escape_id, escape_outcome),
			pending_save: still_pending(model.pending_save, save_requested, save_id, saved_outcome),
			next_id: model.next_id + 2,
			settled: settled,
		},
		actions: actions,
		tasks: tasks,
	})
}

## The outcome of an outstanding screenshot, if this step is the one carrying it.
##
## Completions are matched by the id the request was made with, so another
## screenshot finishing on the same step is not mistaken for this one.
screenshot_outcome : List(Program.Completion), Pending -> Outcome
screenshot_outcome = |completed, pending|
	match pending {
		Idle => NotYet
		Waiting(id) =>
			match List.first(List.keep_if(completed, |completion| answers(completion, id))) {
				Ok(ScreenshotFinished(finished)) => Finished(finished.result)
				# Unreachable: `answers` kept only this task's screenshot.
				Ok(_) => NotYet
				Err(_) => NotYet
			}
		}

## Whether a completion answers the screenshot task with this id.
answers : Program.Completion, U64 -> Bool
answers = |completion, id|
	match completion {
		ScreenshotFinished(finished) => finished.id == id
		SmallFileRead(_) => Bool.False
		FileRead(_) => Bool.False
		DelayElapsed(_) => Bool.False
		ClipboardRead(_) => Bool.False
	}

## Carry an outstanding request into the next cycle: a fresh request replaces
## it, an answered one clears it, and anything else is still waiting.
still_pending : Pending, Bool, U64, Outcome -> Pending
still_pending = |pending, requested, id, outcome|
	if requested {
		Waiting(id)
	} else {
		match outcome {
			Finished(_) => Idle
			NotYet => pending
		}
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
