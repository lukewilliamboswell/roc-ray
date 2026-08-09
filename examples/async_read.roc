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
## arrives later as an application `Msg`. Nothing here waits, and the animation
## below keeps running while the reads are outstanding -- which is the whole
## point. Each task's callback chooses the message variant, so no request IDs or
## completion filtering leak into the app.
##
## What the two answers cost is the interesting part, and this app issues all
## three cases at once so they can be compared on one screen:
##
## * `Program.read_small_file` on a small file answers with a `Str`. Building that string
##   is a copy on the frame thread, which is fine for a few kilobytes.
## * `Program.read_small_file` on a large file is *refused* with `TooLarge`. The host will
##   not spend a frame copying an unbounded payload just because the read itself
##   happened elsewhere.
## * `Program.read_file` on the same large file succeeds, because it copies nothing. The
##   worker's allocation is installed into a host slot and the app is handed a
##   `File.Blob` -- a handle. `Blob.len` is free, a `Program.read_blob_slice` task copies
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
	## `Program.read_blob_slice` message rather than copied while drawing: a pure
	## `update` cannot reach into a blob, and doing it from `render!` means
	## paying for a copy and a UTF-8 scan every frame for a value that changed
	## once.
	preview : PreviewState,

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
## exactly as long as it takes to answer one `Program.read_blob_slice` -- one more cycle
## -- so the whole lifecycle fits inside a three-frame headless run. A real app
## would keep the handle for as long as it wanted the bytes.
BlobState : [
	Waiting,
	Held(File.Blob),
	Dropped(U64),
	Failed(Str),
]

## Results that can arrive on a later step. The tag is the correlation: it is
## selected by the typed callback at submission time, rather than recovered by
## scanning opaque completions later.
Msg : [
	SmallReadFinished({ path : Str, result : Try(Str, Program.SmallFileError) }),
	LargeTextReadFinished({ path : Str, result : Try(Str, Program.SmallFileError) }),
	BlobReadFinished(Try(File.Blob, Program.FileReadError)),
	PreviewReadFinished(Try(Str, [NotUtf8, TooLarge, OutOfBounds, Busy])),
]

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
			elapsed: 0,
			title: Text.from("Reading while the frame keeps moving").size(22).prepare!()?,
		}),
)

update : Model, Program.Step(Msg) -> Try(Program.Next(Model, Msg), [Exit(I64), ..])
update = |model, step| {
	# All completed task callbacks arrive together. Folding the already-typed
	# messages preserves host observation order without allocating a filtered
	# completion list or comparing request IDs.
	resolved = apply_messages({ small: model.small, refused: model.refused, blob: model.blob, preview: model.preview }, step.messages)

	# The preview has landed, so the app is done with the bytes. Being done is
	# the whole of it: the next model does not hold the handle, so the last
	# reference goes when this cycle's model does and the host frees the file.
	# No action, no effect, nothing for a later cycle to get wrong.
	#
	# `blob.len()` is read here, from the pure `update`, because a length costs
	# nothing -- it arrived with the handle. Only the bytes are host-side, which
	# is exactly why getting at them took a task.
	answered = resolved.preview != NoPreview and model.preview == NoPreview

	settled =
		match resolved.blob {
			Held(blob) => if answered Dropped(blob.len()) else Held(blob)
			other => other
		}

	next = { ..resolved, blob: settled }

	# The cycle the handle arrives is the cycle to ask for the range. Twenty
	# bytes cross once, here, instead of on every frame that draws them.
	preview_tasks =
		match (model.blob, next.blob) {
			(Waiting, Held(blob)) => [Program.read_blob_slice(blob, 0, preview_bytes, |result| PreviewReadFinished(result))]
			_ => []
		}

	# Frame 0 issues all three reads. Returning them as tasks rather than
	# calling blocking effects is what keeps this frame short.
	reads =
		if step.time.frame_count == 0 {
			[
				Program.read_small_file(small_path, |result| small_read_message(small_path, result)),
				Program.read_small_file(large_path, |result| large_text_read_message(large_path, result)),
				Program.read_file(large_path, |result| BlobReadFinished(result)),
			]
		} else {
			[]
		}

	Ok({
		model: {
			..model,
			small: next.small,
			refused: next.refused,
			blob: next.blob,
			preview: next.preview,
			elapsed: model.elapsed + step.time.elapsed_seconds,
		},
		actions: if step.input.key_pressed(KeyEscape) [Program.exit(0)] else [],
		tasks: List.concat(reads, preview_tasks),
	})
}

## Apply each completed callback in order. This walks the host-owned message
## buffer directly; unlike the old completion filters it creates no temporary
## lists and needs no app-visible transport metadata.
apply_messages : { small : LoadState, refused : LoadState, blob : BlobState, preview : PreviewState }, List(Msg) -> { small : LoadState, refused : LoadState, blob : BlobState, preview : PreviewState }
apply_messages = |state, messages|
	match List.first(messages) {
		Ok(message) => apply_messages(apply_message(state, message), List.drop_first(messages, 1))
		Err(_) => state
	}

## These are deliberately tiny callback bodies. They capture only the stable
## request path for diagnostics; they never retain the model.
small_read_message : Str, Try(Str, Program.SmallFileError) -> Msg
small_read_message = |path, result| SmallReadFinished({ path, result })

large_text_read_message : Str, Try(Str, Program.SmallFileError) -> Msg
large_text_read_message = |path, result| LargeTextReadFinished({ path, result })

apply_message : { small : LoadState, refused : LoadState, blob : BlobState, preview : PreviewState }, Msg -> { small : LoadState, refused : LoadState, blob : BlobState, preview : PreviewState }
apply_message = |state, message|
	match message {
		SmallReadFinished(finished) => { ..state, small: string_read_state(finished.result) }
		LargeTextReadFinished(finished) => { ..state, refused: string_read_state(finished.result) }
		BlobReadFinished(result) => { ..state, blob: blob_read_state(result) }
		PreviewReadFinished(result) =>
			{
				..state,
				preview: match result {
					Ok(contents) => Preview(contents)
					Err(NotUtf8) => PreviewFailed("(not text)")
					Err(TooLarge) => PreviewFailed("(preview too large)")
					Err(OutOfBounds) => PreviewFailed("(shorter than the preview)")
					Err(Busy) => PreviewFailed("(host busy, try again)")
				},
			}
		}

string_read_state : Try(Str, Program.SmallFileError) -> LoadState
string_read_state = |result|
	match result {
		Ok(contents) => Loaded(Str.count_utf8_bytes(contents))
		Err(NotFound) => Failed("not found")
		Err(ReadFailed) => Failed("read failed")
		Err(Busy) => Failed("too many reads in flight")
		Err(Unavailable) => Failed("reads unavailable")
		# The frame thread will not copy an unbounded payload into a
		# string, so a large file is refused rather than stalling the
		# frame. `Program.read_file` is the operation that does not refuse.
		Err(TooLarge) => Failed("too large to deliver as a string")
		# A `Str` is UTF-8 and a file is bytes, so this read can refuse
		# for a reason `Program.read_file` never can. Read it as a blob instead.
		Err(NotUtf8) => Failed("not text")
	}

## Nothing here touches the file's bytes: a callback carries a handle, and a
## handle is a couple of words whatever the file's size.
blob_read_state : Try(File.Blob, Program.FileReadError) -> BlobState
blob_read_state = |result|
	match result {
		Ok(blob) => Held(blob)
		Err(NotFound) => Failed("not found")
		Err(ReadFailed) => Failed("read failed")
		Err(Busy) => Failed("no blob slot free")
		Err(Unavailable) => Failed("reads unavailable")
		Err(TooLarge) => Failed("larger than the host will read")
	}

expect match apply_messages(
	{ small: Waiting, refused: Waiting, blob: Waiting, preview: NoPreview },
	[small_read_message("small.txt", Ok("ok")), large_text_read_message("large.txt", Err(TooLarge))],
).small {
	Loaded(bytes) => bytes == 2
	_ => Bool.False
}

expect match small_read_message("saved-context.txt", Ok("ok")) {
	SmallReadFinished(finished) => finished.path == "saved-context.txt"
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
## model, where a callback message put it, instead of asking the host for it again on
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
