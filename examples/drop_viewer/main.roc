## Displays an image dropped onto the window; press Escape to quit. This
## example shows one-time dropped-file input, tasks that read without pausing
## drawing, messages that return the bytes to `update!`, and texture creation.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/3vVeddfDE6rraq5j8v1cGHtFNaQhC6dij1zGRN63NGP1.tar.zst", roc: "nightly-2026-08-31-86e69b4" }

import rr.App
import rr.Assets
import rr.Color
import rr.Draw
import rr.Files
import rr.Math
import rr.Task
import rr.Text

## The Model keeps the current status, decoded texture, overflow warning, and
## font and prepared title between updates. The dropped path itself is handled
## when it arrives; only information needed for later progress and drawing is
## retained.
Model : {
	font : Text.Font,
	title : Text.Prepared,
	subtitle : Text.Prepared,
	empty_hint : Text.Prepared,
	overflow_hint : Text.Prepared,
	footer : Text.Prepared,
	status : Status,
	image : [NoImage, Shown(Assets.Texture)],
	partial_drop : Bool,
}

## What the viewer is doing with the most recent drop.
Status : [WaitingForDrop, Reading(Str), Showing(Str, { x : F32, y : F32 }), Refused(Str)]

Msg : [Opened(Str, { x : F32, y : F32 }, Try(List(U8), Files.ReadBytesError))]

program = { init!, update!, render! }

window_width = 900.F32

window_height = 620.F32

## Where the image goes. Everything else is a line of text above or below it.
canvas : Math.Rect
canvas = Math.rect(40, 120, window_width - 80, window_height - 200)

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default
		.with_title("RocRay Drop Viewer")
		.with_size({ width: 900, height: 620 })
		.with_frame_pacing(Capped(120)),
	|_startup| {
		font = Draw.default_font!()
		Ok({
			font,
			title: Text.from("Drop Viewer", font).size(28).prepare!()?,
			subtitle: Text.from("A dropped path, read off the frame thread and decoded into a texture", font).size(15).prepare!()?,
			empty_hint: Text.from("Drop a PNG, JPEG, GIF, QOI or BMP file here", font).size(18).prepare!()?,
			overflow_hint: Text.from("That drop carried more than 64 files; only the first 64 were delivered", font).size(16).prepare!()?,
			footer: Text.from("Drag a file onto the window  |  ESC quits", font).size(14).prepare!()?,
			status: WaitingForDrop,
			image: NoImage,
			partial_drop: Bool.False,
		})
	},
)

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	# One dropped path starts one read. If several files are dropped, the app
	# displays the result whose message arrives last.
	List.for_each!(
		input.dropped,
		|drop| Task.spawn!(input, || Opened(drop.path, drop.position, Files.read_bytes!(drop.path))),
	)

	requested = match List.last(input.dropped) {
		Ok(drop) => Reading(drop.path)
		Err(_) => model.status
	}

	# Decoding is a host-state change, so it belongs here rather than in the
	# task. `plan` decides what each message means without performing anything,
	# which is the part the expects below exercise.
	opened = List.fold(input.messages, { status: requested, decode: NoDecode }, apply_message)
	next = match opened.decode {
		NoDecode => { status: opened.status, image: model.image }
		Decode(path, position, kind, bytes) =>
			match Assets.texture_from_bytes!({ format: asset_format(kind), bytes }) {
				Ok(texture) => { status: Showing(path, position), image: Shown(texture) }
				Err(_) => { status: Refused("${path}: the decoder refused these bytes"), image: model.image }
			}
		}

	if input.devices.key_pressed(KeyEscape) {
		Err(Exit(0))
	} else {
		Ok({
			..model,
			status: next.status,
			image: next.image,
			partial_drop: if List.is_empty(input.dropped) model.partial_drop else input.dropped_overflow,
		})
	}
}

## Converts one delivered read into the next status and an optional decode.
Pending : { status : Status, decode : [NoDecode, Decode(Str, { x : F32, y : F32 }, Recognized, List(U8))] }

apply_message : Pending, Msg -> Pending
apply_message = |pending, message|
	match message {
		Opened(path, position, Ok(bytes)) =>
			match format_of(bytes) {
				Ok(format) => { status: pending.status, decode: Decode(path, position, format, bytes) }
				Err(Unrecognized) => { status: Refused("${path}: not an image this viewer knows"), decode: pending.decode }
			}
		Opened(path, _position, Err(reason)) => { status: Refused("${path}: ${describe_read(reason)}"), decode: pending.decode }
	}

describe_read : Files.ReadBytesError -> Str
describe_read = |reason|
	match reason {
		NotFound => "not found"
		ReadFailed => "could not be read"
		Busy => "the host was busy"
		Unavailable => "reads are unavailable"
		TooLarge => "larger than the host will read"
	}

## The image kinds this viewer recognizes.
##
## `Assets.ImageFormat` is the host's vocabulary and is opaque, so the app
## names its own alongside it and converts at the call.
Recognized : [Png, Jpeg, Gif, Qoi, Bmp]

## Which decoder the bytes ask for.
##
## A dropped file is whatever was dragged in, so the name it happens to have is
## a hint rather than a fact. The first few bytes decide instead.
format_of : List(U8) -> Try(Recognized, [Unrecognized])
format_of = |bytes|
	if begins_with(bytes, [0x89, 0x50, 0x4e, 0x47]) {
		Ok(Png)
	} else if begins_with(bytes, [0xff, 0xd8, 0xff]) {
		Ok(Jpeg)
	} else if begins_with(bytes, [0x47, 0x49, 0x46]) {
		Ok(Gif)
	} else if begins_with(bytes, [0x71, 0x6f, 0x69, 0x66]) {
		Ok(Qoi)
	} else if begins_with(bytes, [0x42, 0x4d]) {
		Ok(Bmp)
	} else {
		Err(Unrecognized)
	}

begins_with : List(U8), List(U8) -> Bool
begins_with = |bytes, prefix| List.take_first(bytes, List.len(prefix)) == prefix

asset_format : Recognized -> Assets.ImageFormat
asset_format = |kind|
	match kind {
		Png => Png
		Jpeg => Jpeg
		Gif => Gif
		Qoi => Qoi
		Bmp => Bmp
	}

expect format_of([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a]) == Ok(Png)
expect format_of([0xff, 0xd8, 0xff, 0xe0]) == Ok(Jpeg)
expect format_of([0x71, 0x6f, 0x69, 0x66]) == Ok(Qoi)
expect format_of([1, 2, 3, 4]) == Err(Unrecognized)

## A short file cannot be mistaken for a long signature.
expect format_of([0x89, 0x50]) == Err(Unrecognized)

## A successful read asks for a decode and leaves the status alone until the
## decode has happened, so the viewer never claims to be showing a file it has
## not decoded yet.
expect
	apply_message(
		{ status: Reading("/home/example/holiday.png"), decode: NoDecode },
		Opened("/home/example/holiday.png", { x: 10, y: 20 }, Ok([0x89, 0x50, 0x4e, 0x47])),
	)
		.status
		== Reading("/home/example/holiday.png")

## A failed read names the path so the user can identify the selected file.
expect
	apply_message(
		{ status: Reading("/home/example/gone.png"), decode: NoDecode },
		Opened("/home/example/gone.png", { x: 0, y: 0 }, Err(NotFound)),
	)
		.status
		== Refused("/home/example/gone.png: not found")

## Reject unrecognized bytes before asking `Assets` to decode them.
expect
	apply_message(
		{ status: Reading("/home/example/notes.txt"), decode: NoDecode },
		Opened("/home/example/notes.txt", { x: 0, y: 0 }, Ok([104, 101, 108, 108, 111])),
	)
		.status
		== Refused("/home/example/notes.txt: not an image this viewer knows")

## The shared surface palette, so the frame, the status line and the hint all
## belong to one dark theme.
theme : { bg : Color.Rgba, panel : Color.Rgba, edge : Color.Rgba, ink : Color.Rgba, muted : Color.Rgba, faint : Color.Rgba, accent : Color.Rgba, ok : Color.Rgba, warn : Color.Rgba }
theme = {
	bg: Color.from_hex_rgb(0x0e1420),
	panel: Color.from_hex_rgb(0x141d2f),
	edge: Color.from_hex_rgb(0x25314b),
	ink: Color.from_hex_rgb(0xe6ecf5),
	muted: Color.from_hex_rgb(0x8fa0bd),
	faint: Color.from_hex_rgb(0x5c6b87),
	accent: Color.from_hex_rgb(0x4c8dff),
	ok: Color.from_hex_rgb(0x3ddc97),
	warn: Color.from_hex_rgb(0xf2a65a),
}

## The colour that says what the viewer is doing, without reading the words.
status_color : Status -> Color.Rgba
status_color = |status|
	match status {
		WaitingForDrop => theme.faint
		Reading(_) => theme.accent
		Showing(_, _) => theme.ok
		Refused(_) => theme.warn
	}

expect status_color(WaitingForDrop) == theme.faint
expect status_color(Refused("x")) == theme.warn

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	draw = App.effects().render(frame)
	frame.clear!(theme.bg)
	model.title.draw!(frame, { pos: { x: 40, y: 34 }, color: theme.ink })
	model.subtitle.draw!(frame, { pos: { x: 40, y: 70 }, color: theme.muted })

	# The drop target: a card first, an outline second, so an empty viewer still
	# looks like a place a file is meant to go.
	draw.rounded_rectangle!({ x: canvas.x, y: canvas.y, width: canvas.width, height: canvas.height, radius: 14, segments: 8, style: Draw.filled_and_outlined(theme.panel, theme.edge, 2) })

	match model.image {
		NoImage =>
			model.empty_hint.draw!(frame, { pos: { x: canvas.x + canvas.width / 2, y: canvas.y + canvas.height / 2 }, color: theme.faint, align: (Middle, Center) })

		Shown(texture) =>
			draw.texture!({
				texture,
				source: Math.rect(0, 0, texture.width, texture.height),
				dest: fit({ width: texture.width, height: texture.height }, canvas),
				origin: Math.zero,
				rotation: 0,
				tint: Color.white,
			})
		}

	# A lit dot carries the state; the words carry the detail.
	draw.circle!({ center: { x: 47, y: 105 }, radius: 5, style: Draw.filled(status_color(model.status)) })
	draw.text_at!({ pos: { x: 62, y: 96 }, text: describe(model.status), size: 17, color: theme.ink })
	if model.partial_drop {
		model.overflow_hint.draw!(frame, { pos: { x: 40, y: window_height - 74 }, color: theme.warn })
	} else {}
	model.footer.draw!(frame, { pos: { x: 40, y: window_height - 44 }, color: theme.faint })
	Ok({})
}

describe : Status -> Str
describe = |status|
	match status {
		WaitingForDrop => "Nothing dropped yet"
		Reading(path) => "Reading ${path} ..."
		Showing(path, position) => "${path}, dropped at ${F32.to_str(position.x)}, ${F32.to_str(position.y)}"
		Refused(reason) => reason
	}

expect describe(WaitingForDrop) == "Nothing dropped yet"

## Fit an image inside the canvas without distorting it: one scale for both
## axes, and whatever is left over becomes margin.
fit : { width : F32, height : F32 }, Math.Rect -> Math.Rect
fit = |image, area| {
	scale = F32.min(area.width / image.width, area.height / image.height)
	width = image.width * scale
	height = image.height * scale
	Math.rect(area.x + (area.width - width) / 2, area.y + (area.height - height) / 2, width, height)
}

## A square image in a wide canvas is centred horizontally and fills it
## vertically.
expect fit({ width: 100, height: 100 }, Math.rect(0, 0, 400, 200)) == Math.rect(100, 0, 200, 200)
