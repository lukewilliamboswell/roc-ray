## Message-driven application updates and deferred host work.
##
## The host calls pure `update` once per cycle with a `Step`. The result contains
## the next model, immediate `Action` values, and asynchronous `Task` values.
## Actions run in order before rendering. Each submitted task invokes its typed
## callback exactly once on a later step while the app remains running,
## contributing one application message. App termination, whether requested or
## caused by an `update`/`render` failure, drops pending callbacks because there
## can be no later `Step` to deliver them on.
##
## `Delay` uses wall time. Animation and physics should use `step.time`.
import Input
import Window
import Time
import Keys
import Mouse
import Audio
import Assets
import Capture
import Color
import Draw
import AssetsHost

Program := [].{

	## Everything the host observed since the previous cycle.
	##
	## `messages` contains all task callbacks completed for this cycle, in the
	## order the host observed their completions. Independent asynchronous tasks
	## may complete in any order; their submission order does not constrain it.
	## `capture` contains the recording status sampled for this cycle.
	Step(msg) : {
		input : Input.Snapshot,
		window : Window.Snapshot,
		time : Time.Frame,
		messages : List(msg),
		capture : Capture.Status,
	}

	## What `update` returns: the next model, plus work for the platform.
	##
	## `actions` run this cycle, in order, before `render!`. `tasks` go to the
	## host in list order and answer on a later `Step`. While the app remains
	## running, every submitted task gets exactly one terminal callback, including
	## `Err(Busy)` when the host refuses admission; independent asynchronous
	## completions have no specified order. App termination drops pending
	## callbacks because no later step can observe them.
	##
	## An app with no messages should still declare `Msg : []`, use
	## `Program.Step(Msg)` and `Program.Next(Model, Msg)` in `update`, and return
	## `tasks: []`. This keeps the message type inferable if it adds a task later.
	Next(model, msg) : {
		model : model,
		actions : List(Action),
		tasks : List(Task(msg)),
	}

	## Something the platform does on the app's behalf during this cycle.
	##
	## Actions run in list order before rendering and produce no completion.
	##
	## Set shader uniforms during `Frame.with_shader!`, where their order relative
	## to draw calls is explicit.
	Action : [
		Exit(I64),
		SetCursor(Mouse.Cursor),
		SetCursorMode(Mouse.CursorMode),
		SetClipboardText(Str),
		SetExitKey(Keys.ExitKey),
		SetWindowMinSize({ width : I32, height : I32 }),
		PlaySound(Audio.Playback),
		SetMusicVolume({ music : Audio.Music, volume : F32 }),
		UpdateTexture({ texture : Assets.Texture, pixels : List(Color.Rgba) }),
		UpdateTextureRegion({ texture : Assets.Texture, region : Assets.Region }),
		SetVirtualMouse(Capture.Pointer),

		## Arm a recording, or finalize the one that is running.
		##
		## The outcome is reported through `step.capture`.
		StartRecording(Capture.Recording),
		StopRecording,
	]

	## Why a cycle's uploads would be refused, or `Ok` if all of them fit.
	##
	## The platform validates every cycle before applying its actions, so uploads
	## are all-or-nothing. Apps that generate pixels can call this during `update`
	## and defer work that exceeds `Assets.max_upload_bytes_per_step`.
	check_uploads : List(Action) -> Try({}, [PixelCountMismatch, RegionOutOfBounds, UploadBudgetExceeded])
	check_uploads = |actions| check_uploads_from(actions, 0, 0, Assets.max_upload_bytes_per_step)

	## Ask the host to shut down with an exit code.
	##
	## The exit happens once this cycle is finished, so the frame that asked for
	## it is still drawn -- and, if a recording is running, still captured.
	## Returning `Err(Exit(code))` from `update` instead stops immediately,
	## before anything is drawn.
	exit : I64 -> [Exit(I64), ..]
	exit = |code| Exit(code)

	## Work for the host to do, answered later. Returning one never blocks.
	##
	## A task owns the typed function that turns its one terminal result into the
	## application's message. The platform retains that function privately until
	## the matching host completion arrives. Task tickets are transport-only and
	## are not part of the supported application API.
	##
	## Platform wrappers capture only the callback supplied here, never the model
	## or request-only data. The callback itself retains every value it captures,
	## however, so prefer small stable context or generation values over capturing
	## an entire model for work that may remain pending.
	##
	## `ReadSmallFile` returns a UTF-8 `Str` and rejects files above its inline
	## copy limit. `ReadFile` returns ordinary Roc bytes for files up to the
	## host's 16 MiB per-file limit. The worker allocation becomes a seamless
	## `List(U8)` view, so delivery allocates and copies no payload bytes.
	## `Screenshot` captures the end of the frame that submitted it.
	Task(msg) :: [
		ReadSmallFile({ path : Str, callback : Try(Str, SmallFileError) -> msg }),
		ReadFile({ path : Str, callback : Try(List(U8), FileReadError) -> msg }),
		Delay({ millis : U64, callback : Try({}, [Busy]) -> msg }),
		Screenshot({ path : Str, callback : Try({}, ScreenshotError) -> msg }),
		ReadClipboard({ callback : Try(Str, [Unavailable, TooLarge, Busy]) -> msg }),
	]

	## Why a `ReadFile` produced no byte list.
	##
	## `Busy` and `Unavailable` mean the host did not start the read. `TooLarge`
	## means the file exceeds the host's per-file limit.
	FileReadError : [
		NotFound,
		ReadFailed,
		Busy,
		Unavailable,
		TooLarge,
	]

	## Why a `ReadSmallFile` produced no string.
	##
	## `NotUtf8` means the bytes are not a valid Roc string. `TooLarge` refers to
	## the inline string-copy limit, which is lower than the `ReadFile` limit.
	SmallFileError : [
		NotFound,
		ReadFailed,
		Busy,
		Unavailable,
		TooLarge,
		NotUtf8,
	]

	## Why a screenshot was not written, including the sandbox refusing a path
	## that escapes the output directory.
	##
	## `AlreadyPending` means this app already has a screenshot request queued.
	## `Busy` means the shared host worker is full and the request may be retried.
	ScreenshotError : [
		PathInvalid,
		PathEscapesOutputDir,
		AlreadyPending,
		OutOfMemory,
		WriteFailed,
		Busy,

		## The screenshot worker is unavailable; retrying will not help.
		Unavailable,
	]

	## Read a UTF-8 file into a `Str` and turn its terminal result into `msg`.
	read_small_file : Str, (Try(Str, SmallFileError) -> msg) -> Task(msg)
	read_small_file = |path, callback| Task.(ReadSmallFile({ path, callback }))

	## Read a file into an ordinary Roc byte list and turn its terminal result
	## into `msg`.
	##
	## The list owns its host-backed storage through Roc ARC. It supports normal
	## `List` operations; sublists are seamless views, so retaining a small
	## sublist can retain its whole source file. Compact a value deliberately
	## when it must outlive the full list but should not pin it.
	read_file : Str, (Try(List(U8), FileReadError) -> msg) -> Task(msg)
	read_file = |path, callback| Task.(ReadFile({ path, callback }))

	## Ask for one message after at least `millis` milliseconds have elapsed.
	delay : U64, (Try({}, [Busy]) -> msg) -> Task(msg)
	delay = |millis, callback| Task.(Delay({ millis, callback }))

	## Capture the end of this frame and write it to `path`.
	screenshot : Str, (Try({}, ScreenshotError) -> msg) -> Task(msg)
	screenshot = |path, callback| Task.(Screenshot({ path, callback }))

	## Read clipboard text on the frame thread and turn the result into `msg`.
	read_clipboard : (Try(Str, [Unavailable, TooLarge, Busy]) -> msg) -> Task(msg)
	read_clipboard = |callback| Task.(ReadClipboard({ callback: callback }))

	## The flat record a `Task` becomes on the way out to the host.
	##
	## Platform-internal transport, not supported application API. Apps construct
	## `Task` values only through the typed constructors above.
	##
	## Unions do not cross the host boundary in this platform; every effect
	## flattens to scalars behind a `U8` tag first. Actions never come here at
	## all -- they are applied in Roc, by the platform's own adapter. `deliver`
	## is an opaque Roc callable to the host: it moves with this request and is
	## invoked only when Roc receives the matching completion envelope.
	##
	## TODO(roc): make `TaskToHost`, `CompletionFromHost`, and
	## `CompletionEnvelope` opaque custom records once `roc glue` can traverse
	## them. With the pinned compiler, changing these declarations to `::` makes
	## `roc glue` crash even though `roc check` succeeds. Consequently these
	## structural records, including `CompletionFromHost.ticket`, are temporarily
	## nameable through `Program`; they are unsupported transport implementation
	## details. App code must use `Task` constructors and `Step.messages` and must
	## not construct, inspect, or depend on these records.
	TaskToHost(msg) : {
		kind : U8,

		path : Str,
		millis : U64,
		deliver : Box(CompletionFromHost -> Box(msg)),
	}

	## The flat record one completion arrives in.
	##
	## Platform-internal transport, not supported application API. The host owns
	## its ticket and pairs this raw result with the continuation it retained.
	##
	## A successful `ReadFile` places its one owning seamless `List(U8)` view in
	## `bytes` without copying the payload. The list is empty for other kinds and
	## failed reads.
	CompletionFromHost : {
		kind : U8,
		ticket : U64,
		err : U8,
		contents : Str,
		bytes : List(U8),
	}

	## A host-retained continuation returned to Roc with its terminal result.
	## Platform-internal transport, not supported application API.
	## The host treats `deliver` as an owned, opaque erased callable: it moves
	## and drops it, but never invokes it. This record is therefore the one
	## place a generic application message value crosses the ABI.
	##
	## The boxed function is necessary rather than an ordinary retained Roc
	## closure: the generated ABI gives `Box(function)` one fixed erased-callable
	## layout. Its body validates the expected kind, decodes the raw result, and
	## boxes the resulting application message for the ABI round trip.
	##
	## TODO(roc): make `TaskToHost`, `CompletionFromHost`, and
	## `CompletionEnvelope` opaque once `roc glue` handles opaque generic
	## transport records. That same generic opacity limitation rejects
	## `Box(Runtime(Model, Msg))`; the desired shape retains ordinary runtime
	## continuations inside an opaque `Runtime(Model, Msg)`, eliminating this
	## per-task box and per-message `Box(msg)` allocation.
	CompletionEnvelope(msg) : {
		raw : CompletionFromHost,
		deliver : Box(CompletionFromHost -> Box(msg)),
	}

	deliver_small_file : (Try(Str, SmallFileError) -> msg) -> Box(CompletionFromHost -> Box(msg))
	deliver_small_file = |callback|
		Box.box(
			|raw|
				if raw.kind != completion_small_file_read {
					crash "roc-ray: small-file callback received the wrong completion kind"
				} else {
					Box.box(callback(if raw.err == 0 Ok(raw.contents) else Err(small_file_error(raw.err))))
				},
		)

	deliver_file : (Try(List(U8), FileReadError) -> msg) -> Box(CompletionFromHost -> Box(msg))
	deliver_file = |callback|
		Box.box(
			|raw|
				if raw.kind != completion_file_read {
					crash "roc-ray: file callback received the wrong completion kind"
				} else {
					Box.box(callback(if raw.err == 0 Ok(raw.bytes) else Err(read_error(raw.err))))
				},
		)

	deliver_delay : (Try({}, [Busy]) -> msg) -> Box(CompletionFromHost -> Box(msg))
	deliver_delay = |callback|
		Box.box(
			|raw|
				if raw.kind != completion_delay {
					crash "roc-ray: delay callback received the wrong completion kind"
				} else {
					Box.box(callback(if raw.err == 0 Ok({}) else Err(Busy)))
				},
		)

	deliver_screenshot : (Try({}, ScreenshotError) -> msg) -> Box(CompletionFromHost -> Box(msg))
	deliver_screenshot = |callback|
		Box.box(
			|raw|
				if raw.kind != completion_screenshot_finished {
					crash "roc-ray: screenshot callback received the wrong completion kind"
				} else {
					Box.box(callback(if raw.err == 0 Ok({}) else Err(screenshot_error(raw.err))))
				},
		)

	deliver_clipboard : (Try(Str, [Unavailable, TooLarge, Busy]) -> msg) -> Box(CompletionFromHost -> Box(msg))
	deliver_clipboard = |callback|
		Box.box(
			|raw|
				if raw.kind != completion_clipboard_read {
					crash "roc-ray: clipboard callback received the wrong completion kind"
				} else {
					Box.box(callback(if raw.err == 0 Ok(raw.contents) else Err(clipboard_error(raw.err))))
				},
		)

	## The flat record a cycle's recording state arrives in.
	##
	## `bytes` is the size of a finished file and is zero while a recording is
	## active. Start and stop outcomes are reported through this record.
	CaptureFromHost : {
		status : U8,
		err : U8,
		frames : U64,
		dropped : U64,
		bytes : U64,
	}

	## Move a task's operation data and its one erased continuation into the
	## flat host request. The host takes ownership of the continuation and assigns
	## a private monotonic ticket while accepting it.
	## Platform-internal, unsupported application API.
	##
	normalize : Task(msg) -> TaskToHost(msg)
	normalize = |Task.(task)|
		match task {
			ReadSmallFile(request) => { kind: task_read_small_file, path: request.path, millis: 0, deliver: deliver_small_file(request.callback) }
			ReadFile(request) => { kind: task_read_file, path: request.path, millis: 0, deliver: deliver_file(request.callback) }
			Delay(request) => { kind: task_delay, path: "", millis: request.millis, deliver: deliver_delay(request.callback) }
			Screenshot(request) => { kind: task_screenshot, path: request.path, millis: 0, deliver: deliver_screenshot(request.callback) }
			ReadClipboard(request) => { kind: task_read_clipboard, path: "", millis: 0, deliver: deliver_clipboard(request.callback) }
		}

	## Invoke the continuation returned by the host with its terminal result.
	## Platform-internal, unsupported application API.
	##
	## Every typed closure validates `raw.kind` before decoding it. The box around
	## the produced message is solely the generic ABI return envelope and is
	## immediately unboxed in Roc.
	complete : CompletionEnvelope(msg) -> msg
	complete = |completion| {
		deliver = Box.unbox(completion.deliver)
		Box.unbox(deliver(completion.raw))
	}

	## Rebuild the sampled recording state from the host's flat record.
	capture_from_host : CaptureFromHost -> Capture.Status
	capture_from_host = |raw|
		if raw.status == capture_status_active {
			Active({ frames: raw.frames, dropped: raw.dropped })
		} else if raw.status == capture_status_failed {
			Failed({ frames: raw.frames, reason: capture_failure(raw.err) })
		} else if raw.status == capture_status_finished {
			Finished({ frames: raw.frames, bytes: raw.bytes })
		} else {
			Idle
		}
}

## Walk a cycle's actions, accumulating upload bytes and stopping at the first
## upload that would be refused.
##
## `budget` is a parameter so tests can verify cumulative charging without
## constructing a four-mebibyte pixel list.
check_uploads_from : List(Program.Action), U64, U64, U64 -> Try({}, [PixelCountMismatch, RegionOutOfBounds, UploadBudgetExceeded])
check_uploads_from = |actions, index, charged, budget|
	if index >= List.len(actions) {
		Ok({})
	} else {
		match List.get(actions, index) {
			Ok(action) => check_uploads_from(actions, index + 1, charge_upload(action, charged, budget)?, budget)

			# Unreachable: the index is bounded above.
			Err(_) => Ok({})
		}
	}

## Add one action's upload to the running total, or name why it cannot be made.
##
## Actions that are not uploads leave the running total unchanged.
charge_upload : Program.Action, U64, U64 -> Try(U64, [PixelCountMismatch, RegionOutOfBounds, UploadBudgetExceeded])
charge_upload = |action, charged, budget|
	match action {
		UpdateTexture(request) =>
			if U64.to_f32(List.len(request.pixels)) != request.texture.width() * request.texture.height() {
				Err(PixelCountMismatch)
			} else {
				add_upload(charged, request.pixels, budget)
			}

		UpdateTextureRegion(request) => {
			region = request.region
			# Sizes are compared as F32 because that is what a texture reports
			# its own size in, and adding in F32 also means a huge `x + width`
			# cannot wrap the way I32 addition would.
			width = I32.to_f32(region.width)
			height = I32.to_f32(region.height)
			if region.width <= 0 or region.height <= 0 or region.x < 0 or region.y < 0 {
				Err(RegionOutOfBounds)
			} else if I32.to_f32(region.x) + width > request.texture.width() or I32.to_f32(region.y) + height > request.texture.height() {
				Err(RegionOutOfBounds)
			} else if U64.to_f32(List.len(region.pixels)) != width * height {
				Err(PixelCountMismatch)
			} else {
				add_upload(charged, region.pixels, budget)
			}
		}

		_ => Ok(charged)
	}

## Charge one upload against the frame's budget.
add_upload : U64, List(Color.Rgba), U64 -> Try(U64, [PixelCountMismatch, RegionOutOfBounds, UploadBudgetExceeded])
add_upload = |charged, pixels, budget| {
	total = charged + Assets.upload_bytes(pixels)
	if total > budget Err(UploadBudgetExceeded) else Ok(total)
}

## `kind` code for a finished small-file read. Mirrored in `src/host_native.zig`.
completion_small_file_read : U8
completion_small_file_read = 0

## `kind` code for an elapsed delay. Mirrored in `src/host_native.zig`.
completion_delay : U8
completion_delay = 1

## `kind` code for a serviced screenshot. Mirrored in `src/host_native.zig`.
completion_screenshot_finished : U8
completion_screenshot_finished = 2

## `kind` code for a clipboard read. Mirrored in `src/host_native.zig`.
completion_clipboard_read : U8
completion_clipboard_read = 3

## `kind` code for an ordinary byte-list read. Mirrored in
## `src/host_native.zig`.
completion_file_read : U8
completion_file_read = 4

## `kind` code for a small-file read task. Mirrored in `src/host_native.zig`.
task_read_small_file : U8
task_read_small_file = 0

## `kind` code for a delay task. Mirrored in `src/host_native.zig`.
task_delay : U8
task_delay = 1

## `kind` code for a screenshot task. Mirrored in `src/host_native.zig`.
task_screenshot : U8
task_screenshot = 2

## `kind` code for a clipboard-read task. Mirrored in `src/host_native.zig`.
task_read_clipboard : U8
task_read_clipboard = 3

## `kind` code for an ordinary byte-list read task. Mirrored in `src/host_native.zig`.
task_read_file : U8
task_read_file = 4

## Decode the host's clipboard-error code. Mirrored in `src/host_native.zig`.
##
## Named rather than spelled inline, so the same code path every other decoder
## takes is testable the same way they are.
clipboard_error : U8 -> [Unavailable, TooLarge, Busy]
clipboard_error = |code|
	if code == read_err_too_large {
		TooLarge
	} else if code == read_err_busy {
		Busy
	} else {
		Unavailable
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

## Error code for content the frame thread declined to copy into a `Str`.
## Mirrored in `src/host_native.zig`.
read_err_too_large : U8
read_err_too_large = 5

## Error code for work the host would not start. Mirrored in
## `src/host_native.zig`.
read_err_busy : U8
read_err_busy = 3

## Error code for bytes that cannot become a `Str`. Mirrored in
## `src/host_native.zig`.
read_err_not_utf8 : U8
read_err_not_utf8 = 6

## Decode the host's read-error code for a byte-list read. Mirrored in
## `src/host_native.zig`.
read_error : U8 -> Program.FileReadError
read_error = |code|
	if code == 1 {
		NotFound
	} else if code == read_err_busy {
		Busy
	} else if code == 4 {
		Unavailable
	} else if code == read_err_too_large {
		TooLarge
	} else {
		ReadFailed
	}

## Decode the host's read-error code for a string-delivered read.
##
## The same codes plus one, rather than a second table: the two reads fail for
## the same reasons and only differ in what they were asked to produce.
small_file_error : U8 -> Program.SmallFileError
small_file_error = |code|
	if code == read_err_not_utf8 {
		NotUtf8
	} else {
		match read_error(code) {
			NotFound => NotFound
			Busy => Busy
			Unavailable => Unavailable
			TooLarge => TooLarge
			ReadFailed => ReadFailed
		}
	}

## Decode the host's capture-error code for a screenshot.
##
## These are `src/capture.zig`'s codes, the same ones `Capture.screenshot!`
## names, so a path that escapes the output directory is still reported as the
## sandbox refusing it rather than as a failed write.
screenshot_error : U8 -> Program.ScreenshotError
screenshot_error = |code|
	match code {
		1 => PathInvalid
		2 => PathEscapesOutputDir
		3 => AlreadyPending
		7 => OutOfMemory
		10 => Busy
		11 => Unavailable
		_ => WriteFailed
	}

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

## A flattened task shape used by constructor tests. The host-only callback is
## deliberately left out because equality cannot inspect an erased callable.
task_shape : Program.Task(msg) -> { kind : U8, path : Str, millis : U64 }
task_shape = |task| {
	raw = Program.normalize(task)
	{
		kind: raw.kind,
		path: raw.path,
		millis: raw.millis,
	}
}

string_result_message : Try(Str, Program.SmallFileError) -> Str
string_result_message = |result|
	match result {
		Ok(contents) => contents
		Err(_) => "failed"
	}

unit_result_message : Try({}, [Busy]) -> Str
unit_result_message = |result|
	match result {
		Ok({}) => "elapsed"
		Err(Busy) => "busy"
	}

## Host-free four-by-four texture fixture for upload validation.
tiny_texture : Assets.Texture
tiny_texture = Assets.Texture.from_host(AssetsHost.Texture.from_resource(Box.box({ handle: 0, width: 4, height: 4 })))

## Pixel fixture matching `tiny_texture`.
sixteen_pixels : List(Color.Rgba)
sixteen_pixels = List.repeat({ r: 1, g: 2, b: 3, a: 255 }, 16)

expect Program.check_uploads([]) == Ok({})
expect Program.check_uploads([tiny_texture.update(sixteen_pixels)]) == Ok({})
expect Program.check_uploads([tiny_texture.update(List.repeat({ r: 0, g: 0, b: 0, a: 0 }, 15))]) == Err(PixelCountMismatch)

## Regions must fit entirely within the texture.
expect Program.check_uploads([tiny_texture.update_region({ x: 0, y: 0, width: 2, height: 2, pixels: List.repeat({ r: 0, g: 0, b: 0, a: 0 }, 4) })]) == Ok({})
expect Program.check_uploads([tiny_texture.update_region({ x: 3, y: 0, width: 2, height: 2, pixels: List.repeat({ r: 0, g: 0, b: 0, a: 0 }, 4) })]) == Err(RegionOutOfBounds)
expect Program.check_uploads([tiny_texture.update_region({ x: 0, y: 0, width: 0, height: 2, pixels: [] })]) == Err(RegionOutOfBounds)

## The budget applies to the cycle's cumulative uploads.
expect Assets.upload_bytes(sixteen_pixels) == 64
expect check_uploads_from([tiny_texture.update(sixteen_pixels)], 0, 0, 100) == Ok({})
expect check_uploads_from([tiny_texture.update(sixteen_pixels), tiny_texture.update(sixteen_pixels)], 0, 0, 100) == Err(UploadBudgetExceeded)
expect check_uploads_from([tiny_texture.update(sixteen_pixels), tiny_texture.update(sixteen_pixels)], 0, 0, 128) == Ok({})

## Non-upload actions do not affect the upload budget.
expect Program.check_uploads([Program.exit(0), tiny_texture.update(sixteen_pixels)]) == Ok({})

## Task constructors expose no IDs or completion unions. `normalize` moves each
## request and its erased callback envelope into the flat ABI record; the host
## gives the envelope its private ticket when it takes ownership.
expect task_shape(Program.read_small_file("data.txt", string_result_message)) == { kind: 0, path: "data.txt", millis: 0 }
expect task_shape(Program.read_file("data.bin", |_| "file")) == { kind: 4, path: "data.bin", millis: 0 }
expect task_shape(Program.delay(250, unit_result_message)) == { kind: 1, path: "", millis: 250 }
expect task_shape(Program.screenshot("scene.png", |_| "screenshot")) == { kind: 2, path: "scene.png", millis: 0 }
expect task_shape(Program.read_clipboard(|_| "clipboard")) == { kind: 3, path: "", millis: 0 }

small_task = Program.normalize(Program.read_small_file("data.txt", string_result_message))

delay_task = Program.normalize(Program.delay(1, unit_result_message))

clipboard_task = Program.normalize(
	Program.read_clipboard(
		|result| match result {
			Ok(text) => text
			Err(_) => "clipboard failed"
		},
	),
)

expect Program.complete({ raw: { kind: 0, ticket: 20, err: 0, contents: "hi", bytes: [] }, deliver: small_task.deliver }) == "hi"
expect Program.complete({ raw: { kind: 0, ticket: 20, err: 1, contents: "", bytes: [] }, deliver: small_task.deliver }) == "failed"
expect Program.complete({ raw: { kind: 1, ticket: 21, err: 0, contents: "", bytes: [] }, deliver: delay_task.deliver }) == "elapsed"
expect Program.complete({ raw: { kind: 1, ticket: 21, err: 1, contents: "", bytes: [] }, deliver: delay_task.deliver }) == "busy"
expect Program.complete({ raw: { kind: 3, ticket: 22, err: 0, contents: "pasted", bytes: [] }, deliver: clipboard_task.deliver }) == "pasted"

## A file is arbitrary bytes and a `Str` is UTF-8. Only the read that answers
## with a string can report this, which is why the two reads no longer share one
## error type.
expect small_file_error(read_err_not_utf8) == NotUtf8
expect small_file_error(1) == NotFound
expect small_file_error(2) == ReadFailed
expect small_file_error(4) == Unavailable
expect small_file_error(read_err_too_large) == TooLarge
expect read_error(1) == NotFound
expect read_error(2) == ReadFailed
expect read_error(4) == Unavailable
expect read_error(read_err_too_large) == TooLarge
expect screenshot_error(2) == PathEscapesOutputDir
expect screenshot_error(99) == WriteFailed
expect screenshot_error(3) == AlreadyPending
expect clipboard_error(4) == Unavailable

## Another process decides how much text the clipboard holds, so the frame
## thread refuses to copy an unbounded one rather than stalling on it.
expect clipboard_error(read_err_too_large) == TooLarge

## Saturation is its own answer everywhere it can happen. A clipboard the host
## would not read yet is not an `Unavailable` one, and a screenshot it would
## not start is not one this app already had outstanding. Each of those would
## send an app looking for a fault that is not there, instead of asking again
## next cycle.
expect clipboard_error(read_err_busy) == Busy
expect small_file_error(read_err_busy) == Busy
expect read_error(read_err_busy) == Busy
expect screenshot_error(10) == Busy

## A screenshot the worker had no room for is refused rather than encoded on
## the frame thread. Both of these mean the file was not written, and the
## difference between them is whether asking again is worth anything.
expect screenshot_error(11) == Unavailable
expect Program.capture_from_host({ status: 0, err: 0, frames: 0, dropped: 0, bytes: 0 }) == Idle
expect Program.capture_from_host({ status: 1, err: 0, frames: 12, dropped: 1, bytes: 0 }) == Active({ frames: 12, dropped: 1 })
expect Program.capture_from_host({ status: 2, err: 8, frames: 3, dropped: 0, bytes: 0 }) == Failed({ frames: 3, reason: WriteFailed })
expect Program.capture_from_host({ status: 2, err: 0, frames: 3, dropped: 0, bytes: 0 }) == Failed({ frames: 3, reason: Unknown })

## A recording that finished is not one that never ran. Both would have been
## `Idle` before, which left an app waiting for its capture with nothing to
## wait on.
expect Program.capture_from_host({ status: 3, err: 0, frames: 300, dropped: 4, bytes: 98_304 }) == Finished({ frames: 300, bytes: 98_304 })

## A start the host would not arm is reported too, because an action has no
## other way to say so.
expect Program.capture_from_host({ status: 2, err: 2, frames: 0, dropped: 0, bytes: 0 }) == Failed({ frames: 0, reason: PathEscapesOutputDir })
