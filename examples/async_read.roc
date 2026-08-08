app [Model, program] { rr: platform "../platform/main.roc" }

import rr.App
import rr.Color
import rr.Draw
import rr.Program
import rr.Text

## Read a file without stalling the frame.
##
## The read is a `Task`, so `update` hands it to the host and returns
## immediately; the host does the blocking work on another thread and the answer
## arrives later as a `Completion` carrying the id the app chose. Nothing here
## waits, and the animation below keeps running while the read is outstanding --
## which is the whole point.
##
## The same code path runs when the host has no worker: the result simply
## arrives on the frame the task was issued instead of a later one.
Model : {
	state : LoadState,
	elapsed : F32,
	title : Text.Prepared,
}

LoadState : [
	Requested,
	Loaded(U64),
	Failed(Str),
]

## The id the host echoes back, so a result can be matched to its request. With
## one outstanding read a constant is enough; a real app would allocate these.
read_id : U64
read_id = 1

program = { init!, update, render! }

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

update : Model, Program.Step -> Try(Program.Next(Model), [Exit(I64), ..])
update = |model, step| {
	# Whatever finished since the last cycle arrives together. This app has one
	# request outstanding, so it picks its own out; an app juggling several
	# would fold over the list instead. On an ordinary frame it is empty.
	next_state =
		match List.first(List.keep_if(step.completed, is_our_read)) {
			Ok(completion) => apply_completion(completion)
			Err(_) => model.state
		}

	# Frame 0 issues the read. Returning it as a task rather than calling a
	# blocking effect is what keeps this frame short.
	tasks =
		if step.time.frame_count == 0 {
			[ReadSmallFile({ id: read_id, path: "README.md" })]
		} else {
			[]
		}

	Ok({
		model: { ..model, state: next_state, elapsed: model.elapsed + step.time.elapsed_seconds },
		actions: if step.input.key_pressed(KeyEscape) [Program.exit(0)] else [],
		tasks: tasks,
	})
}

## Whether a completion answers the read this app issued.
is_our_read : Program.Completion -> Bool
is_our_read = |completion|
	match completion {
		SmallFileRead(finished) => finished.id == read_id
		DelayElapsed(_) => Bool.False
		ScreenshotFinished(_) => Bool.False
		ClipboardRead(_) => Bool.False
	}

## Turn a finished read into the state to display.
##
## The result is typed to the operation that produced it, so a read cannot
## report something only a timer could have, and every way it can fail has a
## name. `Busy` and `Unavailable` are refusals: the host declined to start the
## work rather than running it on this thread.
apply_completion : Program.Completion -> LoadState
apply_completion = |completion|
	match completion {
		SmallFileRead(finished) =>
			match finished.result {
				Ok(contents) => Loaded(Str.count_utf8_bytes(contents))
				Err(NotFound) => Failed("not found")
				Err(ReadFailed) => Failed("read failed")
				Err(Busy) => Failed("too many reads in flight")
				Err(Unavailable) => Failed("reads unavailable")
				# The frame thread will not copy an unbounded payload, so a
				# large file is refused rather than stalling the frame.
				Err(TooLarge) => Failed("file too large to deliver inline")
			}

		# Only a read reaches here: `is_our_read` filters the rest out first.
		DelayElapsed(_) => Requested
		ScreenshotFinished(_) => Requested
		ClipboardRead(_) => Requested
	}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	status = match model.state {
		Requested => "reading..."
		Loaded(bytes) => Str.concat("read ", Str.concat(U64.to_str(bytes), " bytes"))
		Failed(reason) => reason
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

	Ok({})
}
