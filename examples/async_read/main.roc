app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Files
import rr.Color
import rr.Draw
import rr.Text

## Read files without stalling the frame.
##
## Both reads are `Request`s: `update` submits them and returns immediately, while
## the host does blocking I/O away from the drawing thread and later delivers a
## typed `Msg`. No request IDs or completion filtering leak into the app.
##
## `Files.read_text` copies valid UTF-8 into a `Str`, so it has a small
## inline limit. `Files.read_bytes` instead delivers an ordinary `List(U8)`:
## the host moves the worker allocation into List ARC without copying file
## bytes. Keep the list in the model for as long as its bytes are useful; when
## the final List or seamless sublist goes away, its typed host resource is
## released automatically. To retain only a small portion, use
## `List.release_excess_capacity` to deliberately copy that portion instead of
## pinning the source file. List updates use normal copy-on-write semantics.
Model : {
	small : ReadState,
	large : BytesState,
	elapsed : F32,
	title : Text.Prepared,
}

ReadState : [Waiting, Loaded(U64), Failed(Str)]

## Holding this ordinary Roc list is the whole ownership API. There is no host
## handle and no release effect to remember.
BytesState : [Waiting, Held(List(U8)), Failed(Str)]

Msg : [
	SmallReadFinished(Try(Str, Files.ReadTextError)),
	BytesReadFinished(Try(List(U8), Files.ReadBytesError)),
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
			elapsed: 0,
			title: Text.from("Reading while the frame keeps moving", font).size(22).prepare!()?,
		})
	},
)

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	resolved = List.fold(program_input.messages, { small: model.small, large: model.large }, apply_message)
	if program_input.time.cycle_count == 0 {
		App.request!(Files.read_text(small_path, |result| SmallReadFinished(result)))
		App.request!(Files.read_bytes(large_path, |result| BytesReadFinished(result)))
	}

	if program_input.devices.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		Ok({ ..model, small: resolved.small, large: resolved.large, elapsed: model.elapsed + program_input.time.elapsed_seconds })
	}
}

apply_message : { small : ReadState, large : BytesState }, Msg -> { small : ReadState, large : BytesState }
apply_message = |state, message|
	match message {
		SmallReadFinished(result) => { ..state, small: string_state(result) }
		BytesReadFinished(result) => { ..state, large: bytes_state(result) }
	}

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

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x121420))
	model.title.draw!(frame, { pos: { x: 40, y: 40 }, color: Color.white, align: Text.align_top_left })
	frame.text_at!({ pos: { x: 40, y: 92 }, text: Str.concat("ReadSmallFile README.md: ", describe_string(model.small)), size: 20, color: Color.from_hex_rgb(0xa3be8c) })
	frame.text_at!({ pos: { x: 40, y: 120 }, text: Str.concat("ReadFile generated ABI: ", describe_bytes(model.large)), size: 20, color: Color.from_hex_rgb(0x88c0d0) })
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
