app [Model, program] { rr: platform "../platform/main.roc" }

import rr.App
import rr.Color
import rr.Draw
import rr.File
import rr.Program
import rr.Text

## Read files without stalling the frame, in the two ways that differ in cost.
##
## Both reads are `Task`s, so `update` hands them to the host and returns
## immediately; the host does the blocking work on another thread and the answer
## arrives later as a `Completion` carrying the id the app chose. Nothing here
## waits, and the animation below keeps running while the reads are outstanding
## -- which is the whole point.
##
## What the two answers cost is the interesting part, and this app issues all
## three cases at once so they can be compared on one screen:
##
## * `ReadSmallFile` on a small file answers with a `Str`. Building that string
##   is a copy on the frame thread, which is fine for a few kilobytes.
## * `ReadSmallFile` on a large file is *refused* with `TooLarge`. The host will
##   not spend a frame copying an unbounded payload just because the read itself
##   happened elsewhere.
## * `ReadFile` on the same large file succeeds, because it copies nothing. The
##   worker's allocation is installed into a host slot and the app is handed a
##   `File.Blob` -- a handle. `Blob.len` is free, a `ReadBlobSlice` task copies
##   exactly the range asked for, and dropping the handle gives the memory
##   back.
##
## The same code path runs when the host has no worker: the results simply
## arrive on the frame the tasks were issued instead of a later one.
Model : {
	small : LoadState,
	refused : LoadState,
	blob : BlobState,

	## The bytes that crossed into Roc, and only these twenty. Filled by a
	## `ReadBlobSlice` completion rather than copied while drawing: a pure
	## `update` cannot reach into a blob, and doing it from `render!` means
	## paying for a copy and a UTF-8 scan every frame for a value that changed
	## once.
	preview : PreviewState,

	## Tasks this app wants started but the cycle would not carry.
	##
	## A cycle takes at most `Program.max_tasks_per_step`, so a work list the
	## app does not control the size of has to live somewhere between frames.
	## This app never actually overflows -- it asks for four tasks at most --
	## but carrying the remainder is what the shape looks like when it does.
	queued : List(Program.Task),
	elapsed : F32,
	title : Text.Prepared,
}

## A read delivered as a string: waiting, so many bytes, or a named failure.
LoadState : [
	Waiting,
	Loaded(U64),
	Failed(Str),
]

## A bounded range asked for out of a held blob.
PreviewState : [
	NoPreview,
	Preview(Str),
	PreviewFailed(Str),
]

## A read delivered as a handle.
##
## `Held` is the only state that owns host memory, and it owns it the way a
## `Str` field owns its bytes: replacing it with `Dropped` is what frees the
## file. There is nothing to call and nothing to forget to call. It lasts
## exactly as long as it takes to answer one `ReadBlobSlice` -- one more cycle
## -- so the whole lifecycle fits inside a three-frame headless run. A real app
## would keep the handle for as long as it wanted the bytes.
BlobState : [
	Waiting,
	Held(File.Blob),
	Dropped(U64),
	Failed(Str),
]

## The ids the host echoes back, so each result can be matched to its request.
small_id : U64
small_id = 1

refused_id : U64
refused_id = 2

blob_id : U64
blob_id = 3

preview_id : U64
preview_id = 4

## A few kilobytes: small enough that copying it into a `Str` is reasonable.
small_path : Str
small_path = "README.md"

## A few hundred kilobytes of generated Zig -- the largest text file in this
## repository, and comfortably past the host's inline copy limit.
large_path : Str
large_path = "src/roc_platform_abi.zig"

## How much of the blob to copy out for display. Bounded on purpose: the point
## of a blob is that the app decides what crosses, and how much.
preview_bytes : U64
preview_bytes = 20

program = { init!, update, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default.with_title("RocRay Async Read").with_frame_pacing(Capped(120)),
	|_host|
		Ok({
			small: Waiting,
			refused: Waiting,
			blob: Waiting,
			preview: NoPreview,
			queued: [],
			elapsed: 0,
			title: Text.from("Reading while the frame keeps moving").size(22).prepare!()?,
		}),
)

update : Model, Program.Step -> Try(Program.Next(Model), [Exit(I64), ..])
update = |model, step| {
	# Whatever finished since the last cycle arrives together. This app has
	# three requests outstanding, so it picks each one out by id; on an ordinary
	# frame the list is empty and none of this finds anything.
	next_small = advance_string_read(model.small, step.completed, small_id)
	next_refused = advance_string_read(model.refused, step.completed, refused_id)

	preview = advance_preview(model.preview, step.completed)

	# The preview has landed, so the app is done with the bytes. Being done is
	# the whole of it: the next model does not hold the handle, so the last
	# reference goes when this cycle's model does and the host frees the file.
	# No action, no effect, nothing for a later cycle to get wrong.
	#
	# `blob.len()` is read here, from the pure `update`, because a length costs
	# nothing -- it arrived with the handle. Only the bytes are host-side, which
	# is exactly why getting at them took a task.
	answered = preview != NoPreview and model.preview == NoPreview

	settled =
		match model.blob {
			Held(blob) => if answered Dropped(blob.len()) else Held(blob)
			other => other
		}

	next_blob = advance_blob_read(settled, step.completed)

	# The cycle the handle arrives is the cycle to ask for the range. Twenty
	# bytes cross once, here, instead of on every frame that draws them.
	preview_tasks : List(Program.Task)
	preview_tasks =
		match (model.blob, next_blob) {
			(Waiting, Held(blob)) => [ReadBlobSlice({ id: preview_id, blob, offset: 0, count: preview_bytes })]
			_ => []
		}

	# Frame 0 issues all three reads. Returning them as tasks rather than
	# calling blocking effects is what keeps this frame short.
	reads =
		if step.time.frame_count == 0 {
			[
				ReadSmallFile({ id: small_id, path: small_path }),
				ReadSmallFile({ id: refused_id, path: large_path }),
				ReadFile({ id: blob_id, path: large_path }),
			]
		} else {
			[]
		}

	# Anything a previous cycle could not carry goes first, so a deferred task
	# is delayed rather than starved.
	filled = Program.fill(List.join([model.queued, reads, preview_tasks]))

	Ok({
		model: {
			..model,
			small: next_small,
			refused: next_refused,
			blob: next_blob,
			preview: preview,
			queued: filled.deferred,
			elapsed: model.elapsed + step.time.elapsed_seconds,
		},
		actions: if step.input.key_pressed(KeyEscape) [Program.exit(0)] else [],
		tasks: filled.batch,
	})
}

## Fold one cycle's completions into the preview asked for out of the blob.
advance_preview : PreviewState, List(Program.Completion) -> PreviewState
advance_preview = |current, completed|
	match List.first(List.keep_if(completed, answers_preview)) {
		Ok(BlobSliceRead(finished)) =>
			match finished.result {
				Ok(contents) => Preview(contents)
				Err(NotUtf8) => PreviewFailed("(not text)")
				Err(TooLarge) => PreviewFailed("(preview too large)")
				Err(OutOfBounds) => PreviewFailed("(shorter than the preview)")
				# The host was at its limit, not the blob's end: a real app
				# would ask again next cycle rather than give up.
				Err(Busy) => PreviewFailed("(host busy, try again)")
			}

		# Unreachable: `answers_preview` kept only this app's slice.
		Ok(_) => current
		Err(_) => current
	}

## Whether a completion answers this app's blob-slice request.
answers_preview : Program.Completion -> Bool
answers_preview = |completion|
	match completion {
		BlobSliceRead(finished) => finished.id == preview_id
		_ => Bool.False
	}

## Fold one cycle's completions into the state of a string-delivered read.
advance_string_read : LoadState, List(Program.Completion), U64 -> LoadState
advance_string_read = |current, completed, id|
	match List.first(List.keep_if(completed, |completion| answers_small(completion, id))) {
		Ok(SmallFileRead(finished)) =>
			match finished.result {
				Ok(contents) => Loaded(Str.count_utf8_bytes(contents))
				Err(NotFound) => Failed("not found")
				Err(ReadFailed) => Failed("read failed")
				Err(Busy) => Failed("too many reads in flight")
				Err(Unavailable) => Failed("reads unavailable")
				# The frame thread will not copy an unbounded payload into a
				# string, so a large file is refused rather than stalling the
				# frame. `ReadFile` is the operation that does not refuse.
				Err(TooLarge) => Failed("too large to deliver as a string")
				# A `Str` is UTF-8 and a file is bytes, so this read can refuse
				# for a reason `ReadFile` never can. Read it as a blob instead.
				Err(NotUtf8) => Failed("not text")
			}

		# Unreachable: `answers_small` kept only this read's completion.
		Ok(_) => current
		Err(_) => current
	}

## Fold one cycle's completions into the state of the blob-delivered read.
##
## Nothing here touches the file's bytes: a completion carries a handle, and a
## handle is a couple of words whatever the file's size.
advance_blob_read : BlobState, List(Program.Completion) -> BlobState
advance_blob_read = |current, completed|
	match List.first(List.keep_if(completed, answers_blob)) {
		Ok(FileRead(finished)) =>
			match finished.result {
				Ok(blob) => Held(blob)
				Err(NotFound) => Failed("not found")
				Err(ReadFailed) => Failed("read failed")
				Err(Busy) => Failed("no blob slot free")
				Err(Unavailable) => Failed("reads unavailable")
				Err(TooLarge) => Failed("larger than the host will read")
			}

		# Unreachable: `answers_blob` kept only this read's completion.
		Ok(_) => current
		Err(_) => current
	}

## Whether a completion answers the string-delivered read with this id.
answers_small : Program.Completion, U64 -> Bool
answers_small = |completion, id|
	match completion {
		SmallFileRead(finished) => finished.id == id

		# Every other completion belongs to some other request. A wildcard
		# rather than a branch each: this asks one question, and enumerating
		# the platform's whole task list here would break the app every time
		# a new kind of task existed.
		_ => Bool.False
	}

## Whether a completion answers this app's blob-delivered read.
answers_blob : Program.Completion -> Bool
answers_blob = |completion|
	match completion {
		FileRead(finished) => finished.id == blob_id

		# Every other completion belongs to some other request. A wildcard
		# rather than a branch each: this asks one question, and enumerating
		# the platform's whole task list here would break the app every time
		# a new kind of task existed.
		_ => Bool.False
	}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x121420))
	model.title.draw!(frame, { pos: { x: 40, y: 40 }, color: Color.white, align: Text.align_top_left })

	frame.text_at!({
		pos: { x: 40, y: 92 },
		text: Str.concat("ReadSmallFile README.md: ", describe(model.small)),
		size: 20,
		color: Color.from_hex_rgb(0xa3be8c),
	})
	frame.text_at!({
		pos: { x: 40, y: 120 },
		text: Str.concat("ReadSmallFile generated ABI: ", describe(model.refused)),
		size: 20,
		color: Color.from_hex_rgb(0xbf616a),
	})
	frame.text_at!({
		pos: { x: 40, y: 148 },
		text: Str.concat("ReadFile generated ABI: ", describe_blob(model.blob)),
		size: 20,
		color: Color.from_hex_rgb(0x88c0d0),
	})

	# The one copy this app makes, and it is bounded and deliberate: twenty
	# bytes out of a few hundred thousand, only while the blob is held.
	draw_preview!(model.preview, frame)?

	# Keeps moving while the reads are outstanding, so a stalled frame would
	# show as a stutter in this circle rather than as a number nobody reads.
	frame.circle!({
		center: { x: 400 + 220 * F32.cos(model.elapsed * 2), y: 340 + 120 * F32.sin(model.elapsed * 2) },
		radius: 26,
		style: Draw.filled(Color.from_hex_rgb(0x5e81ac)),
	})

	Ok({})
}

## Draw the range that already crossed. No bytes move here.
##
## This is the difference the task makes: `render!` reads a `Str` out of the
## model, where a completion put it, instead of asking the host for it again on
## every frame.
draw_preview! : PreviewState, Draw.Frame => Try({}, [Exit(I64), ..])
draw_preview! = |state, frame|
	match state {
		NoPreview => Ok({})
		Preview(text) => draw_preview_text!(frame, text)
		PreviewFailed(reason) => draw_preview_text!(frame, reason)
	}

draw_preview_text! : Draw.Frame, Str => Try({}, [Exit(I64), ..])
draw_preview_text! = |frame, text| {
	frame.text_at!({
		pos: { x: 40, y: 176 },
		text: Str.concat("first 20 bytes: ", text),
		size: 20,
		color: Color.from_hex_rgb(0xd8dee9),
	})
	Ok({})
}

## One line of status for a string-delivered read.
describe : LoadState -> Str
describe = |state|
	match state {
		Waiting => "reading..."
		Loaded(bytes) => Str.concat(U64.to_str(bytes), " bytes copied into a Str")
		Failed(reason) => reason
	}

## One line of status for the blob-delivered read. `Blob.len` costs nothing, so
## the size is available without any of the bytes being.
describe_blob : BlobState -> Str
describe_blob = |state|
	match state {
		Waiting => "reading..."
		Held(blob) => Str.concat(U64.to_str(blob.len()), " bytes held by the host")
		Dropped(bytes) => Str.concat(U64.to_str(bytes), " bytes read, then dropped")
		Failed(reason) => reason
	}
