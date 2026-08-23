app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Files
import rr.Task
import rr.Time
import rr.Color
import rr.Draw
import rr.Text

## Read files without stalling the frame.
##
## Both reads happen inside tasks. `update!` spawns them and returns
## immediately; each task parks on the host's event loop while the frame loop
## keeps drawing, and its return value arrives as a typed `Msg` on a later
## `input.messages`. Neither read needs an id or a completion filter: each has
## its own `Msg` variant, so two answers landing on one cycle stay apart.
##
## Inside a task the read is an ordinary call that returns its answer, so a
## multi-step load is straight-line code with `?` rather than a state machine
## spread over `Msg` and `update!`.
##
## The third task neither reads nor copies: `Files.metadata!` asks what the
## path is, how large it is, and when it last changed. Its `modified` is
## wall-clock time, comparable with `Time.now!` and with a `modified` the app
## saved earlier, which is what makes polling it a hot reload.
##
## `Files.read_text!` copies valid UTF-8 into a `Str`, so it has a small
## inline limit. `Files.read_bytes!` instead returns an ordinary `List(U8)`:
## the host moves the worker allocation into List ARC without copying file
## bytes. Keep the list in the model for as long as its bytes are useful; when
## the final List or seamless sublist goes away, its typed host resource is
## released automatically. To retain only a small portion, use
## `List.release_excess_capacity` to deliberately copy that portion instead of
## pinning the source file. List updates use normal copy-on-write semantics.
Model : {
	small : ReadState,
	large : BytesState,
	meta : MetaState,
	elapsed : F32,
	title : Text.Prepared,
}

ReadState : [Waiting, Loaded(U64), Failed(Str)]

## Holding this ordinary Roc list is the whole ownership API. There is no host
## handle and no release effect to remember.
BytesState : [Waiting, Held(List(U8)), Failed(Str)]

## A stat holds nothing: it answers with numbers, so the model keeps the answer
## rather than a handle to it.
MetaState : [Waiting, Described(Str), Failed(Str)]

Msg : [
	SmallReadFinished(Try(Str, Files.ReadTextError)),
	BytesReadFinished(Try(List(U8), Files.ReadBytesError)),
	MetadataFinished(Try(Files.Metadata, Files.MetadataError)),
]

small_path : Str
small_path = "README.md"

large_path : Str
large_path = "src/roc_platform_abi.zig"

program = { init!, update!, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default.with_title("RocRay Async Read").with_frame_pacing(Capped(120)),
	|_host| {
		font = Draw.default_font!()
		Ok({
			small: Waiting,
			large: Waiting,
			meta: Waiting,
			elapsed: 0,
			title: Text.from("Reading while the frame keeps moving", font).size(22).prepare!()?,
		})
	},
)

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	resolved = List.fold(program_input.messages, { small: model.small, large: model.large, meta: model.meta }, apply_message)
	if program_input.time.cycle_count == 0 {
		Task.spawn!(program_input, || SmallReadFinished(Files.read_text!(small_path)))
		Task.spawn!(program_input, || BytesReadFinished(Files.read_bytes!(large_path)))
		Task.spawn!(program_input, || MetadataFinished(Files.metadata!(small_path)))
	}

	if program_input.devices.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		Ok({ ..model, small: resolved.small, large: resolved.large, meta: resolved.meta, elapsed: model.elapsed + program_input.time.elapsed_seconds })
	}
}

apply_message : { small : ReadState, large : BytesState, meta : MetaState }, Msg -> { small : ReadState, large : BytesState, meta : MetaState }
apply_message = |state, message|
	match message {
		SmallReadFinished(result) => { ..state, small: string_state(result) }
		BytesReadFinished(result) => { ..state, large: bytes_state(result) }
		MetadataFinished(result) => { ..state, meta: meta_state(result) }
	}

## What a stat found, as the line the app draws.
##
## `modified` is formatted as UTC rather than shown as a number, because an
## instant an app can read is the point of it being a `Time.Timestamp`.
meta_state : Try(Files.Metadata, Files.MetadataError) -> MetaState
meta_state = |result|
	match result {
		Ok(meta) => Described("${describe_kind(meta.kind)}, ${U64.to_str(meta.size_bytes)} bytes, modified ${meta.modified.to_iso_8601()}")
		Err(NotFound) => Failed("not found")
		Err(PermissionDenied) => Failed("not allowed to look")
		Err(ReadFailed) => Failed("stat failed")
		Err(Unavailable) => Failed("stats unavailable")
	}

describe_kind : Files.EntryKind -> Str
describe_kind = |kind|
	match kind {
		File => "file"
		Dir => "directory"
		Other => "something else"
	}

expect meta_state(Ok({ kind: File, size_bytes: 12, modified: Time.Timestamp.epoch }))
	== Described("file, 12 bytes, modified 1970-01-01T00:00:00Z")

## A stat has no `Busy`: it holds no host payload, so there is no delivery slot
## for it to run out of, and the app has one refusal fewer to handle.
expect meta_state(Err(NotFound)) == Failed("not found")

string_state : Try(Str, Files.ReadTextError) -> ReadState
string_state = |result|
	match result {
		Ok(contents) => Loaded(Str.count_utf8_bytes(contents))
		Err(NotFound) => Failed("not found")
		Err(ReadFailed) => Failed("read failed")
		Err(Busy) => Failed("host busy")
		Err(Unavailable) => Failed("reads unavailable")
		Err(TooLarge) => Failed("too large to copy into a Str")
		Err(NotUtf8) => Failed("not text")
	}

bytes_state : Try(List(U8), Files.ReadBytesError) -> BytesState
bytes_state = |result|
	match result {
		Ok(bytes) => Held(bytes)
		Err(NotFound) => Failed("not found")
		Err(ReadFailed) => Failed("read failed")
		Err(Busy) => Failed("host busy")
		Err(Unavailable) => Failed("reads unavailable")
		Err(TooLarge) => Failed("larger than the host will read")
	}

expect match bytes_state(Ok([1, 2, 3])) {
	Held(bytes) => List.len(bytes) == 3
	_ => Bool.False
}

## `TooLarge` is the one error the two reads do not share a meaning for: a Str
## has an inline limit that a `List(U8)` does not, so the same file can be too
## large for one and fine for the other. Each says which limit it hit.
expect string_state(Err(TooLarge)) == Failed("too large to copy into a Str")
expect bytes_state(Err(TooLarge)) == Failed("larger than the host will read")

## Each read has its own `Msg` variant, so two answers on one cycle land in two
## fields rather than needing to be told apart.
expect
	apply_message(
		apply_message({ small: Waiting, large: Waiting, meta: Waiting }, SmallReadFinished(Ok("hello"))),
		BytesReadFinished(Ok([1, 2])),
	)
		== { small: Loaded(5), large: Held([1, 2]), meta: Waiting }

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x121420))
	model.title.draw!(frame, { pos: { x: 40, y: 40 }, color: Color.white, align: Text.align_top_left })
	frame.text_at!({ pos: { x: 40, y: 92 }, text: Str.concat("read_text README.md: ", describe_string(model.small)), size: 20, color: Color.from_hex_rgb(0xa3be8c) })
	frame.text_at!({ pos: { x: 40, y: 120 }, text: Str.concat("read_bytes generated ABI: ", describe_bytes(model.large)), size: 20, color: Color.from_hex_rgb(0x88c0d0) })
	frame.text_at!({ pos: { x: 40, y: 148 }, text: Str.concat("metadata README.md: ", describe_meta(model.meta)), size: 20, color: Color.from_hex_rgb(0xd08770) })
	frame.circle!({ center: { x: 400 + 220 * F32.cos(model.elapsed * 2), y: 300 + 120 * F32.sin(model.elapsed * 2) }, radius: 26, style: Draw.filled(Color.from_hex_rgb(0x5e81ac)) })
	Ok({})
}

describe_string : ReadState -> Str
describe_string = |state|
	match state {
		Waiting => "reading..."
		Loaded(bytes) => Str.concat(U64.to_str(bytes), " bytes copied into a Str")
		Failed(reason) => reason
	}

describe_bytes : BytesState -> Str
describe_bytes = |state|
	match state {
		Waiting => "reading..."
		Held(bytes) => Str.concat(U64.to_str(List.len(bytes)), " ordinary bytes held by Roc ARC")
		Failed(reason) => reason
	}

describe_meta : MetaState -> Str
describe_meta = |state|
	match state {
		Waiting => "asking..."
		Described(text) => text
		Failed(reason) => reason
	}
