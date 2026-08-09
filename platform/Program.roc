## Message-driven application updates and deferred host work.
##
## The host calls pure `update` once per cycle with a `Step`. The result contains
## the next model, immediate `Action` values, and asynchronous `Task` values.
## Actions run in order before rendering and produce no completion. Each accepted
## task produces exactly one `Completion` on a later step.
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
import File
import FileHost
import AssetsHost

Program := [].{

	## Everything the host observed since the previous cycle.
	##
	## `completed` contains all task completions available for this cycle.
	## `capture` contains the recording status sampled for this cycle.
	Step : {
		input : Input.Snapshot,
		window : Window.Snapshot,
		time : Time.Frame,
		completed : List(Completion),
		capture : Capture.Status,
	}

	## What `update` returns: the next model, plus work for the platform.
	##
	## `actions` run this cycle, in order, before `render!`. `tasks` go to the
	## host and answer on a later `Step`.
	Next(model) : {
		model : model,
		actions : List(Action),
		tasks : TaskBatch,
	}

	## The most tasks the host will take from one cycle.
	## Use `fill` to spread larger queues across cycles.
	max_tasks_per_step : U64
	max_tasks_per_step = 8

	## The tasks one cycle is handing over: at most `max_tasks_per_step` of them.
	## The opaque representation preserves the limit during construction.
	TaskBatch :: List(Task).{

		## Add one task, or refuse because this cycle is full.
		##
		## `Busy` means the batch is full; no work has been submitted. The task
		## can be retried in the next cycle. Receiver form: `batch.add(task)`.
		add : TaskBatch, Task -> Try(TaskBatch, [Busy])
		add = |TaskBatch.(tasks), task|
			if List.len(tasks) >= max_tasks_per_step {
				Err(Busy)
			} else {
				Ok(TaskBatch.(List.append(tasks, task)))
			}

		## How many tasks this cycle is handing over.
		len : TaskBatch -> U64
		len = |TaskBatch.(tasks)| List.len(tasks)

		## Whether this cycle is handing over no work.
		is_empty : TaskBatch -> Bool
		is_empty = |batch| batch.len() == 0

		## Flatten for the host. Platform-internal: `TaskToHost` is transport.
		to_host_list : TaskBatch -> List(TaskToHost)
		to_host_list = |TaskBatch.(tasks)| List.map(tasks, to_host)
	}

	## An empty task batch.
	no_tasks : TaskBatch
	no_tasks = TaskBatch.([])

	## A cycle that wants exactly one thing done.
	## One task always fits, so this cannot fail.
	task : Task -> TaskBatch
	task = |one| TaskBatch.([one])

	## Take as much of a work list as this cycle will carry, and hand back the
	## rest.
	##
	## Store `deferred` in the model and pass it to `fill` on the next cycle.
	fill : List(Task) -> { batch : TaskBatch, deferred : List(Task) }
	fill = |requested| {
		batch: TaskBatch.(List.take_first(requested, max_tasks_per_step)),
		deferred: List.drop_first(requested, max_tasks_per_step),
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
	## Every task carries an `id` the app chooses and the host echoes back, so a
	## completion can be matched to the request that caused it.
	##
	## `ReadSmallFile` returns a UTF-8 `Str` and rejects files above its inline
	## copy limit. `ReadFile` returns a refcounted `File.Blob` for files up to the
	## host's 16 MiB per-file limit. Use `ReadBlobSlice` to copy a UTF-8 range from
	## a blob. `Screenshot` captures the end of the frame that submitted it.
	Task : [
		ReadSmallFile({ id : U64, path : Str }),
		ReadFile({ id : U64, path : Str }),
		Delay({ id : U64, millis : U64 }),
		Screenshot({ id : U64, path : Str }),
		ReadClipboard({ id : U64 }),
		ReadBlobSlice({ id : U64, blob : File.Blob, offset : U64, count : U64 }),
	]

	## A completed task and its operation-specific result.
	Completion : [
		SmallFileRead({ id : U64, result : Try(Str, SmallFileError) }),
		FileRead({ id : U64, result : Try(File.Blob, FileReadError) }),
		DelayElapsed({ id : U64, result : Try({}, [Busy]) }),
		ScreenshotFinished({ id : U64, result : Try({}, ScreenshotError) }),
		ClipboardRead({ id : U64, result : Try(Str, [Unavailable, TooLarge, Busy]) }),
		BlobSliceRead({ id : U64, result : Try(Str, [NotUtf8, TooLarge, OutOfBounds, Busy]) }),
	]

	## Why a `ReadFile` produced no blob.
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

	## The flat record a `Task` becomes on the way out to the host.
	##
	## Unions do not cross the host boundary in this platform; every effect
	## flattens to scalars behind a `U8` tag first. Actions never come here at
	## all -- they are applied in Roc, by the platform's own adapter.
	TaskToHost : {
		kind : U8,
		id : U64,
		path : Str,
		millis : U64,

		## `ReadBlobSlice` only, and empty for every other kind. Holds the blob
		## itself so the bytes remain alive until the host reads the slice.
		##
		## The list is empty for other task kinds, which have no blob value.
		blob : List(File.Blob),
		offset : U64,
		count : U64,
	}

	## The flat record one completion arrives in.
	##
	## A successful `ReadFile` places one blob handle in `blob` without copying
	## the payload. The list is empty for other kinds and failed reads.
	CompletionFromHost : {
		kind : U8,
		id : U64,
		err : U8,
		contents : Str,
		blob : List(File.Blob),
	}

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

	## Flatten a `Task` for the host.
	to_host : Task -> TaskToHost
	to_host = |pending|
		match pending {
			ReadSmallFile(request) => { kind: task_read_small_file, id: request.id, path: request.path, millis: 0, blob: [], offset: 0, count: 0 }
			ReadFile(request) => { kind: task_read_file, id: request.id, path: request.path, millis: 0, blob: [], offset: 0, count: 0 }
			Delay(request) => { kind: task_delay, id: request.id, path: "", millis: request.millis, blob: [], offset: 0, count: 0 }
			Screenshot(request) => { kind: task_screenshot, id: request.id, path: request.path, millis: 0, blob: [], offset: 0, count: 0 }
			ReadClipboard(request) => { kind: task_read_clipboard, id: request.id, path: "", millis: 0, blob: [], offset: 0, count: 0 }
			ReadBlobSlice(request) => {
				kind: task_read_blob_slice,
				id: request.id,
				path: "",
				millis: 0,
				blob: [request.blob],
				offset: request.offset,
				count: request.count,
			}
		}

	## Rebuild a `Completion` from the host's flat record.
	##
	## An unrecognized kind indicates an internal ABI mismatch and causes a
	## transport failure.
	completion_from_host : CompletionFromHost -> Completion
	completion_from_host = |raw|
		if raw.kind == completion_small_file_read {
			SmallFileRead({
				id: raw.id,
				result: if raw.err == 0 Ok(raw.contents) else Err(small_file_error(raw.err)),
			})
		} else if raw.kind == completion_file_read {
			FileRead({
				id: raw.id,
				result: if raw.err == 0 blob_from_host(raw.blob) else Err(read_error(raw.err)),
			})
		} else if raw.kind == completion_delay {
			DelayElapsed({
				id: raw.id,
				result: if raw.err == 0 Ok({}) else Err(Busy),
			})
		} else if raw.kind == completion_screenshot_finished {
			ScreenshotFinished({
				id: raw.id,
				result: if raw.err == 0 Ok({}) else Err(screenshot_error(raw.err)),
			})
		} else if raw.kind == completion_blob_slice_read {
			BlobSliceRead({
				id: raw.id,
				result: if raw.err == 0 Ok(raw.contents) else Err(blob_error(raw.err)),
			})
		} else if raw.kind == completion_clipboard_read {
			ClipboardRead({
				id: raw.id,
				result: if raw.err == 0 Ok(raw.contents) else Err(clipboard_error(raw.err)),
			})
		} else {
			crash "roc-ray: host sent an unknown completion kind"
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

## Take the handle a finished `ReadFile` installed.
##
## This transfers the refcounted handle without copying its payload. A
## successful read with no handle indicates an internal ABI mismatch.
blob_from_host : List(File.Blob) -> Try(File.Blob, Program.FileReadError)
blob_from_host = |delivered|
	match List.first(delivered) {
		Ok(blob) => Ok(blob)
		Err(_) => {
			crash "roc-ray: host reported a finished file read with no blob"
		}
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

## `kind` code for a read delivered as a host-owned blob. Mirrored in
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

## `kind` code for a blob-delivered read task. Mirrored in `src/host_native.zig`.
task_read_file : U8
task_read_file = 4

## `kind` code for a blob-slice task. Mirrored in `src/host_native.zig`.
task_read_blob_slice : U8
task_read_blob_slice = 5

## `kind` code for a finished blob slice. Mirrored in `src/host_native.zig`.
completion_blob_slice_read : U8
completion_blob_slice_read = 5

## Decode the host's blob-error code. Mirrored in `src/host_native.zig`.
##
## There is no code for a released blob, because there is no way to release
## one: the task holds a reference to the blob it is slicing, so the bytes
## cannot be gone while the host is reading them.
blob_error : U8 -> [NotUtf8, TooLarge, OutOfBounds, Busy]
blob_error = |code|
	if code == 2 {
		OutOfBounds
	} else if code == 4 {
		TooLarge
	} else if code == 5 {
		Busy
	} else {
		NotUtf8
	}

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

## Decode the host's read-error code for a blob-delivered read. Mirrored in
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

## A flattened task with its blob list reduced to a count.
##
## `Program.to_host(task) == { ... }` would say this directly, and cannot: the
## transport record carries the handle list, a handle is a boxed host resource,
## and comparing a `Box` crashes the interpreter that runs `expect`. Compiled
## apps are unaffected. Everything the flattening actually decides is a scalar,
## so nothing is lost by comparing the scalars.
task_shape : Program.Task -> { kind : U8, id : U64, path : Str, millis : U64, offset : U64, count : U64, blobs : U64 }
task_shape = |pending| {
	raw = Program.to_host(pending)
	{
		kind: raw.kind,
		id: raw.id,
		path: raw.path,
		millis: raw.millis,
		offset: raw.offset,
		count: raw.count,
		blobs: List.len(raw.blob),
	}
}

## What kind of completion a transport record decoded to.
##
## `Program.completion_from_host(raw) == SmallFileRead(...)` would say all of
## this in one line, and cannot be used. A `Completion` may be a `FileRead`, a
## `FileRead` carries a `File.Blob`, and a blob is a boxed host resource -- so
## the union's equality has to walk a `Box`, which crashes the interpreter that
## runs `expect`. Compiled apps are unaffected; the three helpers below check
## the same decode by naming what came out of it.
decoded_kind : Program.CompletionFromHost -> Str
decoded_kind = |raw|
	match Program.completion_from_host(raw) {
		SmallFileRead(_) => "small_file_read"
		FileRead(_) => "file_read"
		DelayElapsed(_) => "delay"
		ScreenshotFinished(_) => "screenshot"
		ClipboardRead(_) => "clipboard"
		BlobSliceRead(_) => "blob_slice"
	}

## The id a decoded completion carries, whichever kind it turned out to be.
##
## The property that matters is that it is the app's own id and not the host's
## idea of one: an app correlates its outstanding work by this and nothing else.
decoded_id : Program.CompletionFromHost -> U64
decoded_id = |raw|
	match Program.completion_from_host(raw) {
		SmallFileRead(finished) => finished.id
		FileRead(finished) => finished.id
		DelayElapsed(finished) => finished.id
		ScreenshotFinished(finished) => finished.id
		ClipboardRead(finished) => finished.id
		BlobSliceRead(finished) => finished.id
	}

## Whether a decoded completion reports a failure rather than an answer.
decoded_failed : Program.CompletionFromHost -> Bool
decoded_failed = |raw|
	match Program.completion_from_host(raw) {
		SmallFileRead(finished) => finished.result.is_err()
		FileRead(finished) => finished.result.is_err()
		DelayElapsed(finished) => finished.result.is_err()
		ScreenshotFinished(finished) => finished.result.is_err()
		ClipboardRead(finished) => finished.result.is_err()
		BlobSliceRead(finished) => finished.result.is_err()
	}

## The string a decoded read or clipboard completion delivered.
decoded_contents : Program.CompletionFromHost -> Str
decoded_contents = |raw|
	match Program.completion_from_host(raw) {
		SmallFileRead(finished) => match finished.result {
			Ok(contents) => contents
			Err(_) => ""
		}
		ClipboardRead(finished) => match finished.result {
			Ok(contents) => contents
			Err(_) => ""
		}
		_ => ""
	}

## Host-free blob fixture with a sixteen-mebibyte reported length.
sample_blob : File.Blob
sample_blob = File.Blob.from_host(FileHost.Blob.from_resource(Box.box({ handle: 0x0001_0002_0003, byte_len: 16 * 1024 * 1024 })))

## A finished blob read, as the host phrases it: one handle, no payload.
sample_blob_read : {} -> Program.CompletionFromHost
sample_blob_read = |{}| {
	kind: 4,
	id: 3,
	err: 0,
	contents: "",
	blob: [sample_blob],
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

## A work list one longer than a cycle will carry, for the batch expects below.
nine_delays : List(Program.Task)
nine_delays = [
	Delay({ id: 1, millis: 1 }),
	Delay({ id: 2, millis: 1 }),
	Delay({ id: 3, millis: 1 }),
	Delay({ id: 4, millis: 1 }),
	Delay({ id: 5, millis: 1 }),
	Delay({ id: 6, millis: 1 }),
	Delay({ id: 7, millis: 1 }),
	Delay({ id: 8, millis: 1 }),
	Delay({ id: 9, millis: 1 }),
]

expect Program.no_tasks.len() == 0
expect Program.no_tasks.is_empty()
expect Program.task(Delay({ id: 1, millis: 5 })).len() == 1

## What a cycle takes of a work list one longer than it will carry.
filled_nine : { batch : Program.TaskBatch, deferred : List(Program.Task) }
filled_nine = Program.fill(nine_delays)

expect filled_nine.batch.len() == Program.max_tasks_per_step
expect List.len(filled_nine.deferred) == 1

## The ninth task is refused, and refused *purely*: nothing has been submitted,
## so an app that gets this can hold the task and offer it again next cycle.
expect filled_nine.batch.add(Delay({ id: 99, millis: 1 })).is_err()
expect Program.no_tasks.add(Delay({ id: 99, millis: 1 })).is_ok()
expect Program.task(Delay({ id: 9, millis: 250 })).to_host_list().len() == 1
expect task_shape(ReadSmallFile({ id: 7, path: "data.txt" })) == { kind: 0, id: 7, path: "data.txt", millis: 0, offset: 0, count: 0, blobs: 0 }
expect task_shape(ReadFile({ id: 7, path: "data.bin" })) == { kind: 4, id: 7, path: "data.bin", millis: 0, offset: 0, count: 0, blobs: 0 }
expect task_shape(Delay({ id: 9, millis: 250 })) == { kind: 1, id: 9, path: "", millis: 250, offset: 0, count: 0, blobs: 0 }
expect task_shape(Screenshot({ id: 4, path: "scene.png" })) == { kind: 2, id: 4, path: "scene.png", millis: 0, offset: 0, count: 0, blobs: 0 }
expect task_shape(ReadClipboard({ id: 6 })) == { kind: 3, id: 6, path: "", millis: 0, offset: 0, count: 0, blobs: 0 }

## Only the slice task carries a handle, and it carries exactly one -- which is
## what keeps the bytes alive from the app naming the range to the host reading
## it.
expect task_shape(ReadBlobSlice({ id: 12, blob: sample_blob, offset: 4, count: 8 })) == { kind: 5, id: 12, path: "", millis: 0, offset: 4, count: 8, blobs: 1 }
## Every kind routes to its own completion, and carries the app's own id
## through. Answering the wrong kind would retire an id its owner is still
## waiting on, so this is checked for all six rather than for the interesting
## ones.
expect decoded_kind({ kind: 0, id: 3, err: 0, contents: "hi", blob: [] }) == "small_file_read"
expect decoded_kind({ kind: 1, id: 5, err: 0, contents: "", blob: [] }) == "delay"
expect decoded_kind({ kind: 2, id: 8, err: 0, contents: "", blob: [] }) == "screenshot"
expect decoded_kind({ kind: 3, id: 2, err: 0, contents: "", blob: [] }) == "clipboard"
expect decoded_kind({ kind: 4, id: 3, err: 3, contents: "", blob: [] }) == "file_read"
expect decoded_kind({ kind: 5, id: 2, err: 5, contents: "", blob: [] }) == "blob_slice"
expect decoded_id({ kind: 0, id: 3, err: 0, contents: "hi", blob: [] }) == 3
expect decoded_id({ kind: 1, id: 5, err: 0, contents: "", blob: [] }) == 5
expect decoded_id({ kind: 2, id: 8, err: 0, contents: "", blob: [] }) == 8
expect decoded_id({ kind: 3, id: 2, err: 0, contents: "", blob: [] }) == 2
expect decoded_id({ kind: 4, id: 3, err: 3, contents: "", blob: [] }) == 3
expect decoded_id({ kind: 5, id: 2, err: 5, contents: "", blob: [] }) == 2

## `err == 0` is the only thing that makes an answer, and the payload rides
## along with it.
expect decoded_failed({ kind: 0, id: 3, err: 0, contents: "hi", blob: [] }) == Bool.False
expect decoded_contents({ kind: 0, id: 3, err: 0, contents: "hi", blob: [] }) == "hi"
expect decoded_failed({ kind: 0, id: 3, err: 1, contents: "", blob: [] }) == Bool.True
expect decoded_failed({ kind: 1, id: 5, err: 0, contents: "", blob: [] }) == Bool.False
expect decoded_failed({ kind: 2, id: 8, err: 0, contents: "", blob: [] }) == Bool.False
expect decoded_failed({ kind: 3, id: 2, err: 0, contents: "pasted", blob: [] }) == Bool.False
expect decoded_contents({ kind: 3, id: 2, err: 0, contents: "pasted", blob: [] }) == "pasted"
expect decoded_failed({ kind: 4, id: 3, err: 3, contents: "", blob: [] }) == Bool.True
expect decoded_failed({ kind: 5, id: 2, err: 5, contents: "", blob: [] }) == Bool.True

## A delay the host would not start is reported as such rather than as one that
## elapsed instantly -- the app asked to be told later, and never was.
expect decoded_failed({ kind: 1, id: 5, err: 1, contents: "", blob: [] }) == Bool.True

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
## would not read yet is not an `Unavailable` one, a slice it would not start
## yet is not one that ran off the end, and a screenshot it would not start is
## not one this app already had outstanding. Each of those would send an app
## looking for a fault that is not there, instead of asking again next cycle.
expect clipboard_error(read_err_busy) == Busy
expect small_file_error(read_err_busy) == Busy
expect read_error(read_err_busy) == Busy
expect blob_error(5) == Busy
expect blob_error(2) == OutOfBounds
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
