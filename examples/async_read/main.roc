## Reads text, bytes, and file details while continuing to animate the window.
## Press Escape to quit. This example introduces tasks for work that may take
## time, messages that return task results to `update!`, and typed file errors.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/3vVeddfDE6rraq5j8v1cGHtFNaQhC6dij1zGRN63NGP1.tar.zst", roc: "nightly-2026-08-26-b29bef3" }

import rr.App
import rr.Files
import rr.Task
import rr.Time
import rr.Color
import rr.Draw
import rr.Text

## The Model is the app state kept between calls to `update!`. It stores each
## operation's progress or result, animation time, and prepared labels needed
## to draw the next frame.
Model : {
	small : ReadState,
	large : BytesState,
	meta : MetaState,
	elapsed : F32,
	title : Text.Prepared,
	subtitle : Text.Prepared,
	hint : Text.Prepared,
}

ReadState : [Waiting, Loaded(U64), Failed(Str)]

## The bytes are an ordinary Roc list. Keeping or discarding the list also
## keeps or releases its storage; no manual cleanup is needed.
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
	App.default.with_title("RocRay Async Read").with_size({ width: 880, height: 480 }).with_frame_pacing(Capped(120)),
	|_host| {
		font = Draw.default_font!()
		Ok({
			small: Waiting,
			large: Waiting,
			meta: Waiting,
			elapsed: 0,
			title: Text.from("Reading while the frame keeps moving", font).size(26).prepare!()?,
			subtitle: Text.from("three tasks in flight, three Msg variants, one frame loop that never stalls", font).size(15).prepare!()?,
			hint: Text.from("ESC  quit", font).size(14).spacing(2.0).prepare!()?,
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

## Formats file details as the line shown in the app. `modified` is a
## `Time.Timestamp`, so it can be displayed as a UTC date and time.
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

## File details do not return retained data, so this operation has no `Busy`
## result to handle.
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
	size = draw_backdrop!(frame)
	model.title.draw!(frame, { pos: { x: 44, y: 40 }, color: ink })
	model.subtitle.draw!(frame, { pos: { x: 44, y: 76 }, color: muted })

	card_width = size.width - 88
	draw_row!(frame, { y: 128, width: card_width, accent: accent_read, label: "Files.read_text!", path: small_path, phase: string_phase(model.small), value: describe_string(model.small), elapsed: model.elapsed })
	draw_row!(frame, { y: 216, width: card_width, accent: accent_bytes, label: "Files.read_bytes!", path: large_path, phase: bytes_phase(model.large), value: describe_bytes(model.large), elapsed: model.elapsed })
	draw_row!(frame, { y: 304, width: card_width, accent: accent_meta, label: "Files.metadata!", path: small_path, phase: meta_phase(model.meta), value: describe_meta(model.meta), elapsed: model.elapsed })

	model.hint.draw!(frame, { pos: { x: 44, y: size.height - 40 }, color: faint })
	Ok({})
}

## Background: one vertical gradient and one soft glow, so the cards sit on
## something with depth rather than on flat grey.
draw_backdrop! : Draw.Frame => Draw.FrameSize
draw_backdrop! = |frame| {
	size = frame.size!()
	frame.rectangle_gradient_v!({ x: 0, y: 0, width: size.width, height: size.height, color_top: bg_top, color_bottom: bg_bottom })
	frame.circle_gradient!({ center: { x: size.width * 0.5, y: -40 }, radius: size.height, color_inner: Color.from_hex_rgba(0x3a5f9c33), color_outer: Color.from_hex_rgba(0x00000000) })
	size
}

## One status card: accent bar, indicator, effect name, path, and answer.
draw_row! : Draw.Frame, { y : F32, width : F32, accent : Color.Rgba, label : Str, path : Str, phase : Phase, value : Str, elapsed : F32 } => {}
draw_row! = |frame, row| {
	frame.rounded_rectangle!({ x: 44, y: row.y, width: row.width, height: 72, radius: 0.18, segments: 8, style: Draw.filled_and_outlined(card, card_edge, 1) })
	frame.rounded_rectangle!({ x: 44, y: row.y + 12, width: 4, height: 48, radius: 1, segments: 4, style: Draw.filled(row.accent) })
	draw_indicator!(frame, { x: 86, y: row.y + 36 }, row.phase, row.accent, row.elapsed)
	frame.text_at!({ pos: { x: 116, y: row.y + 14 }, text: row.label, size: 17, color: ink })
	frame.text_at!({ pos: { x: 116 + 172, y: row.y + 16 }, text: row.path, size: 14, color: faint })
	frame.text_at!({ pos: { x: 116, y: row.y + 42 }, text: row.value, size: 15, color: phase_color(row.phase) })
}

## In flight: a comet of fading dots, driven by wall-clock elapsed time so a
## stalled frame loop would be obvious. Settled: a solid dot in a quiet ring.
draw_indicator! : Draw.Frame, { x : F32, y : F32 }, Phase, Color.Rgba, F32 => {}
draw_indicator! = |frame, center, phase, accent, elapsed|
	match phase {
		Pending =>
			List.for_each!(
				spinner_dots,
				|dot| {
					angle = elapsed * 3.6 - dot.lag
					frame.circle!({
						center: { x: center.x + 10 * F32.cos(angle), y: center.y + 10 * F32.sin(angle) },
						radius: dot.radius,
						style: Draw.filled(Color.with_alpha(accent, dot.alpha)),
					})
				},
			)

		Settled(color) => {
			frame.circle!({ center: center, radius: 11, style: Draw.outlined(Color.with_alpha(color, 70), 1.5) })
			frame.circle!({ center: center, radius: 5, style: Draw.filled(color) })
		}
	}

## Where a card has got to, as the renderer needs it: waiting, or finished
## well or badly. Derived from the state rather than stored beside it.
Phase : [Pending, Settled(Color.Rgba)]

string_phase : ReadState -> Phase
string_phase = |state|
	match state {
		Waiting => Pending
		Loaded(_) => Settled(accent_read)
		Failed(_) => Settled(accent_bad)
	}

bytes_phase : BytesState -> Phase
bytes_phase = |state|
	match state {
		Waiting => Pending
		Held(_) => Settled(accent_bytes)
		Failed(_) => Settled(accent_bad)
	}

meta_phase : MetaState -> Phase
meta_phase = |state|
	match state {
		Waiting => Pending
		Described(_) => Settled(accent_meta)
		Failed(_) => Settled(accent_bad)
	}

expect string_phase(Waiting) == Pending
expect string_phase(Failed("nope")) == Settled(accent_bad)
expect bytes_phase(Held([1])) == Settled(accent_bytes)

## Grey while the task is in flight, then the colour the phase settled on.
phase_color : Phase -> Color.Rgba
phase_color = |phase|
	match phase {
		Pending => muted
		Settled(color) => color
	}

spinner_dots : List({ lag : F32, radius : F32, alpha : U8 })
spinner_dots = [
	{ lag: 0, radius: 3.4, alpha: 255 },
	{ lag: 0.34, radius: 2.9, alpha: 190 },
	{ lag: 0.68, radius: 2.4, alpha: 135 },
	{ lag: 1.02, radius: 1.9, alpha: 85 },
	{ lag: 1.36, radius: 1.5, alpha: 45 },
]

bg_top = Color.from_hex_rgb(0x0b0e17)

bg_bottom = Color.from_hex_rgb(0x151b2a)

card = Color.from_hex_rgb(0x171d2b)

card_edge = Color.from_hex_rgb(0x2a3348)

ink = Color.from_hex_rgb(0xe8ecf5)

muted = Color.from_hex_rgb(0x8a97b0)

faint = Color.from_hex_rgb(0x5c6880)

accent_read = Color.from_hex_rgb(0x7fd6a2)

accent_bytes = Color.from_hex_rgb(0x6fb3e0)

accent_meta = Color.from_hex_rgb(0xf2a97c)

accent_bad = Color.from_hex_rgb(0xef7d7d)

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
