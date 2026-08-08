## Program module - the shape of a message-driven application.
##
## The host hands `update` one `Step` per cycle: everything it observed since
## the last one, gathered into a single value. `update` is a *pure* function --
## it returns the next model plus the work it wants done, and Roc's effect
## system structurally forbids it from doing any of that work itself.
##
## Work comes in two kinds, and the difference is the whole point:
##
## * an `Action` is applied by the platform straight away, in the same cycle,
##   before anything is drawn. It never reports back. Playing a sound, setting
##   the cursor, uploading pixels -- things that happen and are then over.
## * a `Task` is handed to the host, never blocks, and always answers with
##   exactly one `Completion` on a later `Step`. Reading a file, writing a
##   screenshot, asking the system for its clipboard.
##
## Actions never cross the host boundary: the platform's own `update_for_host!`
## adapter is effectful, so it interprets them by calling effects that already
## exist. That is why an `Action` may hold rich values -- a `Audio.Sound`, an
## `Assets.Texture` -- while a `Task` must flatten to scalars.
##
## One `Step` per cycle, rather than one call per event, is deliberate. Each
## call crosses the ABI and boxes and unboxes the model, which Roc treats as
## expensive; batching makes that a fixed cost per rendered frame instead of one
## that grows with how much happened. It also means a task cannot complete
## re-entrantly inside the very `update` that issued it.
##
## Roc still only ever runs on one thread. The host owns whatever concurrency
## exists, and `Box(Model)` is never shared.
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

Program := [].{

	## Everything the host observed since the previous cycle.
	##
	## The three observations are kept apart on purpose. `input` is what the
	## devices said, `window` is what the window looked like, `time` is when it
	## happened -- one value each, sampled together but never merged, so a
	## helper can ask for exactly the one it needs.
	##
	## `completed` is bounded because *acceptance* is bounded: the host will
	## only ever hold so many unanswered tasks at once, so a burst of finished
	## work cannot consume a whole frame. Nothing is ever held back, though --
	## a completion the host has is a completion this step carries. It is empty
	## on an ordinary frame, which is the case that has to stay cheap.
	##
	## `capture` is sampled rather than asked for: a pure `update` cannot call
	## `Capture.status!`, and a recording's state is one small record, so the
	## host fills it in on every step whether or not anything is recording.
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
		tasks : List(Task),
	}

	## Something the platform does on the app's behalf during this cycle.
	##
	## An action produces no completion, so nothing has to be correlated back to
	## it; it is applied and forgotten. Ordering within the list is preserved,
	## and the whole list is applied before anything is drawn.
	##
	## `PlaySound` deliberately carries volume, pitch, and pan together rather
	## than being reachable through three separate actions: one atomic value
	## cannot be got into the wrong order, and it is one action instead of four.
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
		SetShaderF32Uniform({ uniform : Draw.F32Uniform, value : F32 }),
		SetVirtualMouse(Capture.Pointer),
		ReleaseBlob(File.Blob),
	]

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
	## `ReadSmallFile` is named for what it is: the answer is delivered as a Roc
	## string, and the frame thread will not copy an unbounded one, so anything
	## past the host's limit comes back as `TooLarge`. It stays because a config
	## file wants a string and nothing else.
	##
	## `ReadFile` is the same read without that ceiling, because it does not
	## produce a string: the worker's allocation is installed into a host slot
	## and the app is handed a `File.Blob` -- a handle, not the bytes. Nothing
	## proportional to the file happens on the frame thread, so there is nothing
	## to cap. The app copies out the parts it wants, when it wants them, and
	## releases the blob with `File.Blob.release`.
	##
	## `Screenshot` is a task rather than an action because the write can fail
	## and apps branch on that. The host reads the framebuffer at the end of the
	## frame that asked -- the same instant `Capture.screenshot!` used -- so the
	## pixels are unchanged and only the report arrives a cycle later.
	Task : [
		ReadSmallFile({ id : U64, path : Str }),
		ReadFile({ id : U64, path : Str }),
		Delay({ id : U64, millis : U64 }),
		Screenshot({ id : U64, path : Str }),
		ReadClipboard({ id : U64 }),
	]

	## A task that finished, carrying the result its own operation can actually
	## produce.
	##
	## Deliberately not a shared bag of possible values: that let a read report a
	## payload a timer could never have, and made one error case unreachable in
	## practice. It gets worse, not better, once HTTP and SQLite exist.
	Completion : [
		SmallFileRead({ id : U64, result : Try(Str, ReadError) }),
		FileRead({ id : U64, result : Try(File.Blob, ReadError) }),
		DelayElapsed({ id : U64, result : Try({}, [Busy]) }),
		ScreenshotFinished({ id : U64, result : Try({}, ScreenshotError) }),
		ClipboardRead({ id : U64, result : Try(Str, [Unavailable, TooLarge]) }),
	]

	## Why a read produced no contents.
	##
	## `Busy` and `Unavailable` are refusals rather than failures: the host
	## declined to start the work, so nothing was read and, importantly, nothing
	## ran on the frame thread instead. Every accepted task still yields exactly
	## one completion.
	##
	## Both reads report the same failures, because they fail for the same
	## reasons. `TooLarge` means different sizes for each: for `ReadSmallFile`
	## it is the string the frame thread declined to build, and for `ReadFile` it
	## is a file larger than the host will read at all. `Busy` covers a full blob
	## table as well as a full request queue -- in both cases the host declined
	## rather than made room by taking something away.
	ReadError : [
		NotFound,
		ReadFailed,
		Busy,
		Unavailable,
		TooLarge,
	]

	## Why a screenshot was not written. The same refusals `Capture.screenshot!`
	## reports, including the sandbox refusing a path that escapes the output
	## directory.
	ScreenshotError : [
		PathInvalid,
		PathEscapesOutputDir,
		AlreadyPending,
		OutOfMemory,
		WriteFailed,
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
	}

	## The flat record one completion arrives in.
	##
	## `blob` and `blob_len` are the whole point of the blob path: a finished
	## `ReadFile` puts a slot token and a length here, not a payload, so the
	## record a 16 MiB read arrives in is exactly as big as the one an elapsed
	## timer arrives in.
	CompletionFromHost : {
		kind : U8,
		id : U64,
		err : U8,
		contents : Str,
		blob : U64,
		blob_len : U64,
	}

	## The flat record a cycle's recording state arrives in.
	##
	## Mirrors `CaptureHost.StatusResult`, which `Capture.status!` decodes; this
	## is the same observation, sampled once per step instead of asked for.
	CaptureFromHost : {
		status : U8,
		err : U8,
		frames : U64,
		dropped : U64,
	}

	## Flatten a `Task` for the host.
	to_host : Task -> TaskToHost
	to_host = |task|
		match task {
			ReadSmallFile(request) => { kind: task_read_small_file, id: request.id, path: request.path, millis: 0 }
			ReadFile(request) => { kind: task_read_file, id: request.id, path: request.path, millis: 0 }
			Delay(request) => { kind: task_delay, id: request.id, path: "", millis: request.millis }
			Screenshot(request) => { kind: task_screenshot, id: request.id, path: request.path, millis: 0 }
			ReadClipboard(request) => { kind: task_read_clipboard, id: request.id, path: "", millis: 0 }
		}

	## Rebuild a `Completion` from the host's flat record.
	##
	## The host and the app are built together, so an unrecognised kind is not a
	## newer host talking to an older app -- it is transport that disagrees with
	## itself. Reinterpreting it as an elapsed delay would invent a timer nobody
	## asked for, so this refuses loudly instead.
	completion_from_host : CompletionFromHost -> Completion
	completion_from_host = |raw|
		if raw.kind == completion_small_file_read {
			SmallFileRead({
				id: raw.id,
				result: if raw.err == 0 Ok(raw.contents) else Err(read_error(raw.err)),
			})
		} else if raw.kind == completion_file_read {
			FileRead({
				id: raw.id,
				result: if raw.err == 0 Ok(blob_from_host(raw)) else Err(read_error(raw.err)),
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
		} else if raw.kind == completion_clipboard_read {
			ClipboardRead({
				id: raw.id,
				result: if raw.err == 0 {
					Ok(raw.contents)
				} else if raw.err == read_err_too_large {
					Err(TooLarge)
				} else {
					Err(Unavailable)
				},
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
		} else {
			Idle
		}
}

## Rebuild the handle a finished `ReadFile` installed.
##
## Nothing is copied here and nothing can be: the record carries a slot token
## and a length, and the bytes never left the host.
blob_from_host : Program.CompletionFromHost -> File.Blob
blob_from_host = |raw|
	File.Blob.from_host(FileHost.Blob.from_raw({ handle: raw.blob, byte_len: raw.blob_len }))

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

## `status` code for a running recording. Mirrored in `src/capture.zig`.
capture_status_active : U8
capture_status_active = 1

## `status` code for a recording that stopped early. Mirrored in `src/capture.zig`.
capture_status_failed : U8
capture_status_failed = 2

## Error code for content the frame thread declined to copy into a `Str`.
## Mirrored in `src/host_native.zig`.
read_err_too_large : U8
read_err_too_large = 5

## Decode the host's read-error code. Mirrored in `src/host_native.zig`.
read_error : U8 -> Program.ReadError
read_error = |code|
	if code == 1 {
		NotFound
	} else if code == 3 {
		Busy
	} else if code == 4 {
		Unavailable
	} else if code == read_err_too_large {
		TooLarge
	} else {
		ReadFailed
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
		_ => WriteFailed
	}

## Name every failure code a recording can latch. Mirrors `Capture.status!`.
capture_failure : U8 -> Capture.FailureReason
capture_failure = |code|
	match code {
		5 => UnsupportedFormat
		7 => OutOfMemory
		8 => WriteFailed
		9 => EncodeFailed
		_ => Unknown
	}

## A finished blob read, as the host phrases it: a token, a length, no payload.
##
## Sixteen mebibytes of file, and the record is the same handful of words an
## elapsed timer arrives in. That is the property the blob path exists for, so
## it is asserted rather than described.
sample_blob_read : Program.CompletionFromHost
sample_blob_read = { kind: 4, id: 3, err: 0, contents: "", blob: 0x0001_0002_0003, blob_len: 16 * 1024 * 1024 }

expect Program.to_host(ReadSmallFile({ id: 7, path: "data.txt" })) == { kind: 0, id: 7, path: "data.txt", millis: 0 }
expect Program.to_host(ReadFile({ id: 7, path: "data.bin" })) == { kind: 4, id: 7, path: "data.bin", millis: 0 }
expect Program.to_host(Delay({ id: 9, millis: 250 })) == { kind: 1, id: 9, path: "", millis: 250 }
expect Program.to_host(Screenshot({ id: 4, path: "scene.png" })) == { kind: 2, id: 4, path: "scene.png", millis: 0 }
expect Program.to_host(ReadClipboard({ id: 6 })) == { kind: 3, id: 6, path: "", millis: 0 }
expect Program.completion_from_host({ kind: 0, id: 3, err: 0, contents: "hi", blob: 0, blob_len: 0 }) == SmallFileRead({ id: 3, result: Ok("hi") })
expect Program.completion_from_host({ kind: 0, id: 3, err: 1, contents: "", blob: 0, blob_len: 0 }) == SmallFileRead({ id: 3, result: Err(NotFound) })
expect Program.completion_from_host({ kind: 0, id: 3, err: 3, contents: "", blob: 0, blob_len: 0 }) == SmallFileRead({ id: 3, result: Err(Busy) })
expect Program.completion_from_host(sample_blob_read) == FileRead({ id: 3, result: Ok(blob_from_host(sample_blob_read)) })
expect blob_from_host(sample_blob_read).len() == 16 * 1024 * 1024
expect Program.completion_from_host({ kind: 4, id: 3, err: 3, contents: "", blob: 0, blob_len: 0 }) == FileRead({ id: 3, result: Err(Busy) })
expect Program.completion_from_host({ kind: 4, id: 3, err: 5, contents: "", blob: 0, blob_len: 0 }) == FileRead({ id: 3, result: Err(TooLarge) })
expect Program.completion_from_host({ kind: 1, id: 5, err: 0, contents: "", blob: 0, blob_len: 0 }) == DelayElapsed({ id: 5, result: Ok({}) })

## A delay the host would not start is reported as such rather than as one that
## elapsed instantly -- the app asked to be told later, and never was.
expect Program.completion_from_host({ kind: 1, id: 5, err: 1, contents: "", blob: 0, blob_len: 0 }) == DelayElapsed({ id: 5, result: Err(Busy) })
expect Program.completion_from_host({ kind: 2, id: 8, err: 0, contents: "", blob: 0, blob_len: 0 }) == ScreenshotFinished({ id: 8, result: Ok({}) })
expect Program.completion_from_host({ kind: 2, id: 8, err: 2, contents: "", blob: 0, blob_len: 0 }) == ScreenshotFinished({ id: 8, result: Err(PathEscapesOutputDir) })
expect Program.completion_from_host({ kind: 2, id: 8, err: 99, contents: "", blob: 0, blob_len: 0 }) == ScreenshotFinished({ id: 8, result: Err(WriteFailed) })
expect Program.completion_from_host({ kind: 3, id: 2, err: 0, contents: "pasted", blob: 0, blob_len: 0 }) == ClipboardRead({ id: 2, result: Ok("pasted") })
expect Program.completion_from_host({ kind: 3, id: 2, err: 4, contents: "", blob: 0, blob_len: 0 }) == ClipboardRead({ id: 2, result: Err(Unavailable) })

## Another process decides how much text the clipboard holds, so the frame
## thread refuses to copy an unbounded one rather than stalling on it.
expect Program.completion_from_host({ kind: 3, id: 2, err: 5, contents: "", blob: 0, blob_len: 0 }) == ClipboardRead({ id: 2, result: Err(TooLarge) })
expect Program.capture_from_host({ status: 0, err: 0, frames: 0, dropped: 0 }) == Idle
expect Program.capture_from_host({ status: 1, err: 0, frames: 12, dropped: 1 }) == Active({ frames: 12, dropped: 1 })
expect Program.capture_from_host({ status: 2, err: 8, frames: 3, dropped: 0 }) == Failed({ frames: 3, reason: WriteFailed })
expect Program.capture_from_host({ status: 2, err: 0, frames: 3, dropped: 0 }) == Failed({ frames: 3, reason: Unknown })
