## Private application/host request conversion.
## This module is intentionally absent from the package exposes list.
import AppHost
import Capture
import Files
import Window

AppTransport := [].{
	normalize : AppHost.Request(msg) -> AppHost.SubmittedRequest(msg)
	normalize = |operation|
		match operation {
			ReadText(request) => { kind: request_read_small_file, path: request.path, millis: 0, deliver: deliver_text(request.callback) }
			ReadBytes(request) => { kind: request_read_file, path: request.path, millis: 0, deliver: deliver_bytes(request.callback) }
			Delay(request) => { kind: request_delay, path: "", millis: request.millis, deliver: deliver_delay(request.callback) }
			Screenshot(request) => { kind: request_screenshot, path: request.path, millis: 0, deliver: deliver_screenshot(request.callback) }
			ReadClipboard(request) => { kind: request_read_clipboard, path: "", millis: 0, deliver: deliver_clipboard(request.callback) }
			ListDirectory(request) => { kind: request_list_dir, path: request.path, millis: 0, deliver: deliver_listing(request.callback) }
		}

	receive_response : AppHost.PendingResponse(msg) -> msg
	receive_response = |response| {
		deliver = Box.unbox(response.deliver)
		Box.unbox(deliver(response.raw))
	}

	capture_status : AppHost.RawCaptureStatus -> Capture.Status
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

deliver_text : (Try(Str, Files.ReadTextError) -> msg) -> Box(AppHost.RawResponse -> Box(msg))
deliver_text = |callback| Box.box(
	|raw| if raw.kind != completion_small_file_read {
		crash "roc-ray: text-read callback received the wrong response kind"
	} else {
		Box.box(callback(if raw.err == 0 Ok(raw.contents) else Err(small_file_error(raw.err))))
	},
)

deliver_bytes : (Try(List(U8), Files.ReadBytesError) -> msg) -> Box(AppHost.RawResponse -> Box(msg))
deliver_bytes = |callback| Box.box(
	|raw| if raw.kind != completion_file_read {
		crash "roc-ray: byte-read callback received the wrong response kind"
	} else {
		Box.box(callback(if raw.err == 0 Ok(raw.bytes) else Err(read_error(raw.err))))
	},
)

deliver_listing : (Try(List(Files.Entry), Files.ListError) -> msg) -> Box(AppHost.RawResponse -> Box(msg))
deliver_listing = |callback| Box.box(
	|raw| if raw.kind != completion_dir_listed {
		crash "roc-ray: directory-list callback received the wrong response kind"
	} else {
		Box.box(callback(if raw.err == 0 Ok(decode_listing(raw.bytes)) else Err(list_error(raw.err))))
	},
)

deliver_delay : (Try({}, [Busy]) -> msg) -> Box(AppHost.RawResponse -> Box(msg))
deliver_delay = |callback| Box.box(
	|raw| if raw.kind != completion_delay {
		crash "roc-ray: delay callback received the wrong response kind"
	} else {
		Box.box(callback(if raw.err == 0 Ok({}) else Err(Busy)))
	},
)

deliver_screenshot : (Try({}, Capture.ScreenshotError) -> msg) -> Box(AppHost.RawResponse -> Box(msg))
deliver_screenshot = |callback| Box.box(
	|raw| if raw.kind != completion_screenshot_finished {
		crash "roc-ray: screenshot callback received the wrong response kind"
	} else {
		Box.box(callback(if raw.err == 0 Ok({}) else Err(screenshot_error(raw.err))))
	},
)

deliver_clipboard : (Try(Str, Window.ClipboardReadError) -> msg) -> Box(AppHost.RawResponse -> Box(msg))
deliver_clipboard = |callback| Box.box(
	|raw| if raw.kind != completion_clipboard_read {
		crash "roc-ray: clipboard callback received the wrong response kind"
	} else {
		Box.box(callback(if raw.err == 0 Ok(raw.contents) else Err(clipboard_error(raw.err))))
	},
)

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

## `kind` code for a serviced directory listing. Mirrored in `src/host_native.zig`.
completion_dir_listed : U8
completion_dir_listed = 5

## `kind` code for a small-file read request. Mirrored in `src/host_native.zig`.
request_read_small_file : U8
request_read_small_file = 0

## `kind` code for a delay request. Mirrored in `src/host_native.zig`.
request_delay : U8
request_delay = 1

## `kind` code for a screenshot request. Mirrored in `src/host_native.zig`.
request_screenshot : U8
request_screenshot = 2

## `kind` code for a clipboard-read request. Mirrored in `src/host_native.zig`.
request_read_clipboard : U8
request_read_clipboard = 3

## `kind` code for an ordinary byte-list read request. Mirrored in `src/host_native.zig`.
request_read_file : U8
request_read_file = 4

## `kind` code for a directory listing request. Mirrored in `src/host_native.zig`.
request_list_dir : U8
request_list_dir = 5

## Entry kinds in an encoded listing. Mirrored in `src/host_native.zig`.
dir_entry_file : U8
dir_entry_file = 1

dir_entry_dir : U8
dir_entry_dir = 2

## The host refused to list the path because it is not a directory. Mirrored in
## `src/host_native.zig`.
read_err_not_a_directory : U8
read_err_not_a_directory = 7

## Decode the host's listing-error code. Mirrored in `src/host_native.zig`.
list_error : U8 -> Files.ListError
list_error = |code|
	if code == 1 {
		NotFound
	} else if code == read_err_busy {
		Busy
	} else if code == 4 {
		Unavailable
	} else if code == read_err_too_large {
		TooLarge
	} else if code == read_err_not_a_directory {
		NotADirectory
	} else {
		ReadFailed
	}

## Decode a listing's bytes into entries.
##
## The encoding is one entry after another, each a kind byte, the entry's name,
## and a NUL. A name cannot contain a NUL on any platform the host runs on, so
## the terminator is unambiguous and the whole listing is one host allocation
## that reached Roc without being copied.
##
## Truncated input -- a kind byte with no terminator after it -- ends the
## listing rather than being guessed at. The host writes the terminator, so
## that cannot happen; answering with the entries that were whole is what keeps
## this total.
decode_listing : List(U8) -> List(Files.Entry)
decode_listing = |bytes| decode_entries(bytes, 0, [])

decode_entries : List(U8), U64, List(Files.Entry) -> List(Files.Entry)
decode_entries = |bytes, at, found|
	if at >= List.len(bytes) {
		found
	} else {
		match List.get(bytes, at) {
			Err(_) => found
			Ok(code) =>
				match index_of_nul(bytes, at + 1) {
					Err(_) => found
					Ok(end) =>
						decode_entries(
							bytes,
							end + 1,
							List.append(found, { name: entry_name(bytes, at + 1, end), kind: entry_kind(code) }),
						)
					}
			}
	}

## Copy one entry's name out of the listing.
##
## The copy is the point. A sublist of a host-delivered list is a seamless view
## onto the host's buffer, so a name retained that way would pin the whole
## listing for as long as the app held it. `release_excess_capacity` gives the
## name storage of its own -- and it has to happen before `from_utf8_lossy`,
## which may share the storage it is given.
entry_name : List(U8), U64, U64 -> Str
entry_name = |bytes, start, end|
	Str.from_utf8_lossy(List.release_excess_capacity(List.sublist(bytes, { start: start, len: end - start })))

entry_kind : U8 -> Files.EntryKind
entry_kind = |code|
	if code == dir_entry_file {
		File
	} else if code == dir_entry_dir {
		Dir
	} else {
		Other
	}

index_of_nul : List(U8), U64 -> Try(U64, [NotFound])
index_of_nul = |bytes, at|
	match List.get(bytes, at) {
		Err(_) => Err(NotFound)
		Ok(byte) =>
			if byte == 0 {
				Ok(at)
			} else {
				index_of_nul(bytes, at + 1)
			}
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

## Error code for content the host declined to copy into a `Str`.
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
read_error : U8 -> Files.ReadBytesError
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
small_file_error : U8 -> Files.ReadTextError
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
screenshot_error : U8 -> Capture.ScreenshotError
screenshot_error = |code|
	match code {
		1 => PathInvalid
		2 => PathEscapesOutputDir
		3 => AlreadyPending
		7 => WriteFailed
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
