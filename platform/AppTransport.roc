## Private decoding of the flat records the host reports each cycle.
## This module is intentionally absent from the package exposes list.
import Capture
import Devices
import Keys
import Mouse

AppTransport := [].{

	## The flat record one event crosses the host boundary as. Not for
	## applications: the platform decodes it into `Event` before `update!`
	## sees an input, and `events_from_raw` is the decoder.
	##
	## `kind` numbers the `Event` variants in declaration order from 0;
	## `code` is the key code, mouse button code or codepoint that kind
	## implies; `x` and `y` are a click's position or a wheel notch's offsets.
	RawEvent : { kind : U8, code : U32, x : F32, y : F32 }

	## Decode a cycle's flat events into `Event`s, keeping their order.
	##
	## A record the decoder cannot read -- a `kind` this module does not
	## know, or a code past the key or button tables -- is dropped rather
	## than crashing the app. Such a record can only come from a host newer
	## than this module, and a kind of event the app could not have matched
	## on anyway is not one it can act on.
	events_from_raw : List(RawEvent) -> List(Devices.Event)
	events_from_raw = |raw|
		List.fold(
			raw,
			[],
			|acc, record|
				match event_from_raw(record) {
					Ok(event) => List.append(acc, event)
					Err(_) => acc
				},
		)

	## Flat capture status sampled for one `App.Input`.
	AppRawCaptureStatus : {
		status : U8,
		err : U8,
		frames : U64,
		dropped : U64,
		bytes : U64,
	}

	## Turn the host's flat recording record into the public union.
	capture_status : AppRawCaptureStatus -> Capture.Status
	capture_status = |raw|
		if raw.status == capture_status_active {
			Active({ frames: raw.frames, dropped: raw.dropped })
		}
			else if raw.status == capture_status_failed {
				Failed({ frames: raw.frames, reason: capture_failure(raw.err) })
			}
				else if raw.status == capture_status_finished {
					Finished({ frames: raw.frames, bytes: raw.bytes })
				}
					else {
						Idle
					}
}

## `status` code for a running recording. Mirrored in `src/capture.zig`.
capture_status_active : U8
capture_status_active = 1

## `status` code for a recording that stopped early. Mirrored in `src/capture.zig`.
capture_status_failed : U8
capture_status_failed = 2

## `status` code for a recording that ran to its end and wrote its file.
## Mirrored in `src/capture.zig`.
capture_status_finished : U8
capture_status_finished = 3

## Name every failure code a recording can latch -- a start the host refused as
## well as a running recording that stopped early.
capture_failure : U8 -> Capture.FailureReason
capture_failure = |code|
	match code {
		1 => PathInvalid
		2 => PathEscapesOutputDir
		3 => AlreadyRecording
		5 => UnsupportedFormat
		6 => BudgetExceeded
		7 => OutOfMemory
		8 => WriteFailed
		9 => EncodeFailed
		_ => Unknown
	}

expect capture_failure(2) == PathEscapesOutputDir
expect capture_failure(9) == EncodeFailed
expect capture_failure(99) == Unknown

expect AppTransport.capture_status({ status: 0, err: 0, frames: 0, dropped: 0, bytes: 0 }) == Idle
expect AppTransport.capture_status({ status: 1, err: 0, frames: 12, dropped: 3, bytes: 0 })
	== Active({ frames: 12, dropped: 3 })
expect AppTransport.capture_status({ status: 2, err: 8, frames: 4, dropped: 0, bytes: 0 })
	== Failed({ frames: 4, reason: WriteFailed })
expect AppTransport.capture_status({ status: 3, err: 0, frames: 90, dropped: 1, bytes: 4096 })
	== Finished({ frames: 90, bytes: 4096 })

## Decode one flat event. The numbering mirrors `InputEventKind` in
## `src/backend_raylib.zig`; both sides state it so neither can drift alone.
event_from_raw : AppTransport.RawEvent -> Try(Devices.Event, [UnknownEvent])
event_from_raw = |record|
	match record.kind {
		0 => Keys.from_code(U32.to_u64(record.code)) |> Try.map_ok(|key| KeyPressed(key)) |> Try.map_err(|_| UnknownEvent)
		1 => Keys.from_code(U32.to_u64(record.code)) |> Try.map_ok(|key| KeyReleased(key)) |> Try.map_err(|_| UnknownEvent)
		2 => mouse_button_from_code(U32.to_u64(record.code)) |> Try.map_ok(|button| ButtonPressed(button, { x: record.x, y: record.y })) |> Try.map_err(|_| UnknownEvent)
		3 => mouse_button_from_code(U32.to_u64(record.code)) |> Try.map_ok(|button| ButtonReleased(button, { x: record.x, y: record.y })) |> Try.map_err(|_| UnknownEvent)
		4 => Ok(Wheel({ x: record.x, y: record.y }))
		5 => Ok(Text(record.code))
		_ => Err(UnknownEvent)
	}

## Decode a click's raylib button code.
mouse_button_from_code : U64 -> Try(Mouse.Button, [InvalidMouseButtonCode])
mouse_button_from_code = |code|
	match code {
		0 => Ok(Left)
		1 => Ok(Right)
		2 => Ok(Middle)
		3 => Ok(Side)
		4 => Ok(Extra)
		5 => Ok(Forward)
		6 => Ok(Back)
		_ => Err(InvalidMouseButtonCode)
	}

## A flat event for the decode expects below.
raw : U8, U32, F32, F32 -> AppTransport.RawEvent
raw = |kind, code, x, y| { kind, code, x, y }

## Every variant decodes, with its payload intact.
expect event_from_raw(raw(0, 65, 0, 0)) == Ok(KeyPressed(KeyA))
expect event_from_raw(raw(1, 256, 0, 0)) == Ok(KeyReleased(KeyEscape))
expect event_from_raw(raw(2, 0, 12.5, 34)) == Ok(ButtonPressed(Left, { x: 12.5, y: 34 }))
expect event_from_raw(raw(3, 6, 1, 2)) == Ok(ButtonReleased(Back, { x: 1, y: 2 }))
expect event_from_raw(raw(4, 0, -0.5, 2)) == Ok(Wheel({ x: -0.5, y: 2 }))
expect event_from_raw(raw(5, 0x20ac, 0, 0)) == Ok(Text(0x20ac))

## A kind or code this module cannot read is dropped, not a crash.
expect event_from_raw(raw(6, 0, 0, 0)) == Err(UnknownEvent)
expect event_from_raw(raw(255, 65, 0, 0)) == Err(UnknownEvent)
expect event_from_raw(raw(0, 100000, 0, 0)) == Err(UnknownEvent)
expect event_from_raw(raw(2, 7, 0, 0)) == Err(UnknownEvent)
expect AppTransport.events_from_raw([raw(0, 65, 0, 0), raw(9, 0, 0, 0), raw(5, 104, 0, 0)]) == [KeyPressed(KeyA), Text(104)]

## Decoding keeps delivery order.
expect AppTransport.events_from_raw([raw(5, 104, 0, 0), raw(2, 1, 3, 4), raw(1, 65, 0, 0)]) == [Text(104), ButtonPressed(Right, { x: 3, y: 4 }), KeyReleased(KeyA)]
expect AppTransport.events_from_raw([]) == []

## Decoder codes and test snapshot encoding agree for every mouse button.
expect List.all(
	[0, 1, 2, 3, 4, 5, 6],
	|code|
		match mouse_button_from_code(code) {
			Ok(button) => List.get(Devices.none.with_mouse_button_pressed(button).mouse.buttons, code) == Ok(3)
			Err(_) => Bool.False
		},
)
