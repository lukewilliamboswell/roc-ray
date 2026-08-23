app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Assets
import rr.Color
import rr.Draw
import rr.Files
import rr.Math
import rr.Task
import rr.Text

## Drop an image on the window and look at it.
##
## `input.dropped` is where a drop arrives, and it behaves like a key press
## rather than like a position: it is empty on almost every cycle, and the one
## call to `update!` that sees a drop is the only one that will. So this app
## acts on it immediately rather than storing it.
##
## A dropped path is absolute and comes from outside anything the app chose,
## and `Files` is not sandboxed, so reading it is an ordinary read: the task
## spawned here parks on `Files.read_bytes!` while the frame loop keeps
## drawing, and the bytes arrive as a message on a later cycle. Decoding them
## into a texture is a host-state change, so it happens back in `update!`.
##
## The drop position rides along with each path. This viewer shows one image at
## a time and only reports where it landed, but an app with two panes would use
## it to decide which one the file was meant for.
##
## At most 64 paths cross in one cycle. A larger drop sets
## `input.dropped_overflow`, which is why this app can say that it was handed
## part of a drop instead of quietly showing the wrong file.
Model : {
	title : Text.Prepared,
	status : Status,
	image : [NoImage, Shown(Assets.Texture)],
	partial_drop : Bool,
}

## What the viewer is doing with the most recent drop.
Status : [WaitingForDrop, Reading(Str), Showing(Str, { x : F32, y : F32 }), Refused(Str)]

Msg : [Opened(Str, { x : F32, y : F32 }, Try(List(U8), Files.ReadBytesError))]

program = { init!, update!, render! }

window_width : F32
window_width = 900

window_height : F32
window_height = 620

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
			title: Text.from("Drop an image onto this window", font).size(26).prepare!()?,
			status: WaitingForDrop,
			image: NoImage,
			partial_drop: Bool.False,
		})
	},
)

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	# One dropped path is one read. Every file in the drop is read, so the
	# reads race; the app shows whichever answer lands last, which is the
	# honest thing for a viewer that shows one image.
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

## What one delivered read means, with nothing performed.
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

## A failed read names the path, because the whole point of a drop is that the
## user chose the file and the app did not.
expect
	apply_message(
		{ status: Reading("/home/example/gone.png"), decode: NoDecode },
		Opened("/home/example/gone.png", { x: 0, y: 0 }, Err(NotFound)),
	)
		.status
		== Refused("/home/example/gone.png: not found")

## Bytes that are not an image are refused before the host is asked to decode
## them.
expect
	apply_message(
		{ status: Reading("/home/example/notes.txt"), decode: NoDecode },
		Opened("/home/example/notes.txt", { x: 0, y: 0 }, Ok([104, 101, 108, 108, 111])),
	)
		.status
		== Refused("/home/example/notes.txt: not an image this viewer knows")

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x11161f))
	model.title.draw!(frame, { pos: { x: 40, y: 40 }, color: Color.white, align: Text.align_top_left })
	frame.rectangle!({ x: canvas.x, y: canvas.y, width: canvas.width, height: canvas.height, style: Draw.outlined(Color.from_hex_rgb(0x35415a), 2) })

	match model.image {
		NoImage => {}
		Shown(texture) =>
			frame.texture!({
				texture,
				source: Math.rect(0, 0, texture.width, texture.height),
				dest: fit({ width: texture.width, height: texture.height }, canvas),
				origin: Math.zero,
				rotation: 0,
				tint: Color.white,
			})
		}

	frame.text_at!({ pos: { x: 40, y: 84 }, text: describe(model.status), size: 18, color: Color.from_hex_rgb(0x88c0d0) })
	if model.partial_drop {
		frame.text_at!({ pos: { x: 40, y: window_height - 74 }, text: "That drop carried more than 64 files; only the first 64 were delivered", size: 16, color: Color.from_hex_rgb(0xd08770) })
	} else {}
	frame.text_at!({ pos: { x: 40, y: window_height - 48 }, text: "PNG, JPEG, GIF, QOI and BMP | ESC quits", size: 16, color: Color.from_hex_rgb(0x6f7a90) })
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
