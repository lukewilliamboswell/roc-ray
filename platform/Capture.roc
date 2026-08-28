## Screenshots and recordings of the app's rendered output.
##
## Record the window framebuffer as a PNG sequence, GIF, or WebM. Recorded
## frames use the window dimensions. Export a `Draw.RenderTexture` for a still
## image at another size.
##
## Every path here is relative to the output directory set with
## `App.default.with_output_dir`, and one that would escape it -- absolute, or
## containing `..` -- is refused rather than rewritten. Capture is the only
## path-sandboxed writer the platform grants: `Files.write_text!` and
## `Files.write_bytes!` write wherever the process may write, while everything
## here is confined to the output directory.
##
## `start!` and `stop!` control recording. `screenshot!` writes a presented
## frame, and `screenshot_texture!` writes an offscreen render texture.
## Recording state is sampled into `input.capture` each cycle.
##
## `pixel_at!` and `read_region!` return pixels from the last presented frame
## or a render texture without writing a file. Both are refused in `render!`.
##
## The types and pure helpers live in the companion `roc-ray-types` package so
## reusable packages can depend on them without depending on this platform.
## This module re-exports them, so `Recording` here and in the package are the
## same nominal type.
import rrt.Capture as RrtCapture
import Host
import Color
import Draw

capture_format_code = |value|
	match value {
		Png => 0
		Gif => 1
		WebM => 2
	}

capture_timing_code = |value|
	match value {
		RealTime => 0
		FixedStep => 1
	}

capture_cursor_code = |value|
	match value {
		NoCursor => 0
		DrawCursor => 1
	}

capture_quality_code = |value|
	match value {
		Fast => 0
		Balanced => 1
		Best => 2
	}

capture_scale_ratio = |value|
	match value {
		Full => { numerator: 1, denominator: 1 }
		Half => { numerator: 1, denominator: 2 }
		Quarter => { numerator: 1, denominator: 4 }
		Ratio(r) =>
			if r.numerator == 0 or r.denominator == 0 {
				{ numerator: 1, denominator: 1 }
			} else {
				{ numerator: r.numerator, denominator: r.denominator }
			}
		}

Capture := [].{

	## Container and codec written for a capture.
	Format : RrtCapture.Format

	## How far each captured frame is downscaled from the framebuffer.
	Scale : RrtCapture.Scale

	## Whether simulation time follows the wall clock or advances in exact steps.
	Timing : RrtCapture.Timing

	## Whether the host composites a pointer glyph into captured frames.
	Cursor : RrtCapture.Cursor

	## How hard the encoder works to choose colours for each frame.
	Quality : RrtCapture.Quality

	## A validated recording request. Update it through its receivers.
	##
	## Declared in the `roc-ray-types` package's `Capture` and re-exported here,
	## which is also where its receivers are documented.
	Recording : RrtCapture.Recording

	## Live recording state, sampled onto every `App.Input` as `input.capture`.
	##
	## `Finished` remains observable after automatic finalization at the frame cap.
	Status : RrtCapture.Status

	## Why a recording is not running.
	##
	## `PathInvalid`, `PathEscapesOutputDir`, `AlreadyRecording`, and
	## `BudgetExceeded` reject a start request before anything is written. The
	## remaining reasons may stop an active recording.
	FailureReason : RrtCapture.FailureReason

	## Why a screenshot did not become a file.
	##
	## `PathInvalid` is a path the sandbox cannot even resolve: empty, absolute,
	## containing `..`, or holding a NUL byte. `PathEscapesOutputDir` is the
	## resolvable path that lands outside the output directory. Both are the
	## app's own string to fix.
	##
	## `Busy` is the host at its limit across every capture request at once, so
	## nothing was captured or written. It is about right now: the same
	## screenshot offered on a later frame may well be taken, which is what
	## separates it from `Unavailable`. `AlreadyPending` is narrower still --
	## this app's own previous screenshot is still waiting for its frame.
	##
	## `Unavailable` is the host having no capture facility to use at all --
	## the app is shutting down and the wait was cancelled before the frame
	## ended. It is not what a call from the wrong callback gets: that is a
	## programmer error and stops the app. See `screenshot!`.
	ScreenshotError : [PathInvalid, PathEscapesOutputDir, AlreadyPending, WriteFailed, Busy, Unavailable]

	## Write one PNG of the app's rendered output.
	##
	## The framebuffer is read back at the end of the frame that asked -- after
	## the draw batch is flushed and before the buffers are swapped, so the
	## pixels are the ones just drawn -- and the PNG is encoded and written off
	## the frame thread. This call waits for that write, so it parks the task
	## until the file exists and answers with the write's own outcome.
	##
	## Legal only in a task, where it parks the task; refused in `init!`,
	## `update!`, and `render!`. Every other waiting effect also works in
	## `init!`, where it blocks; a screenshot cannot, because what it waits for
	## is the end of a frame and `init!` runs before the frame loop has drawn
	## one. Spawn a task from `update!` instead -- on the first cycle if the
	## shot is meant to be of the first frame:
	##
	## ```roc
	## if input.time.cycle_count == 0 {
	##     Task.spawn!(input, || Shot(Capture.screenshot!("frame0.png")))
	## }
	## ```
	##
	## A headless run has no framebuffer at all and answers `Ok({})` without
	## writing, so a screenshotting app still runs under `--host-headless`.
	##
	## Only one screenshot can be in flight: a second one while the first is
	## still waiting for its frame is `AlreadyPending`.
	screenshot! : Str => Try({}, ScreenshotError)
	screenshot! = |path| {
		err = Host.capture_screenshot!(path)
		if err == 0 {
			Ok({})
		} else {
			Err(screenshot_error(err))
		}
	}

	## Why an offscreen export did not become a file.
	##
	## `TargetUnavailable` is a render target that no longer resolves to a host
	## resource -- a released one, or the `Draw.RenderTexture.stub` a pure test
	## holds. `BudgetExceeded` is an image too large for the host to hold at all,
	## so retrying will not help; `Busy` is one that would fit were other exports
	## not in flight, so a later frame may take it. `Unavailable` is the app
	## shutting down before the write started.
	TextureExportError : [
		PathInvalid,
		PathEscapesOutputDir,
		TargetUnavailable,
		BudgetExceeded,
		Busy,
		OutOfMemory,
		ReadbackFailed,
		WriteFailed,
		Unavailable,
	]

	## Write one PNG of what a render target holds, at the target's own size.
	##
	## This is how an app exports an image larger than its window: draw the
	## composition into a `Draw.RenderTexture` of the size the output needs and
	## export the target rather than the frame. Transparency survives, unlike a
	## `screenshot!`, whose framebuffer readback is always opaque.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`. Nothing here waits on the
	## frame loop, which is why `init!` is allowed where a `screenshot!` cannot
	## be -- but drawing into a target is only possible during `render!`, so a
	## target no `render!` has drawn into holds undefined pixels.
	##
	## The pixels are the ones the last completed `render!` left in the target,
	## so an app that draws its composition every frame exports what it last
	## showed. The path is resolved under the output directory exactly as
	## `screenshot!` resolves one.
	##
	## A headless run has no pixels to read and answers `Ok({})` without writing,
	## so an exporting app still runs under `--host-headless`.
	##
	## ```roc
	## Task.spawn!(input, || Exported(Capture.screenshot_texture!(poster, "poster.png")))
	## ```
	screenshot_texture! : Draw.RenderTexture, Str => Try({}, TextureExportError)
	screenshot_texture! = |target, path| {
		err = Host.capture_screenshot_texture!({ target: target.for_host(), path })
		if err == 0 {
			Ok({})
		} else {
			Err(texture_export_error(err))
		}
	}

	## Where a pixel readback takes its pixels from.
	##
	## `Screen` is the last frame the host presented, which is the frame on
	## screen while `update!` runs, at the framebuffer's own size. `Target` is
	## an offscreen `Draw.RenderTexture`, holding whatever the last completed
	## `render!` drew into it, at the target's own size.
	Source : [Screen, Target(Draw.RenderTexture)]

	## A rectangle of pixels, in pixels right and down from the source's
	## top-left corner.
	Region : {
		x : I32,
		y : I32,
		width : I32,
		height : I32,
	}

	## Why a readback produced no pixels.
	##
	## `RegionOutOfBounds` is a point or rectangle that is not entirely inside
	## the source, or a rectangle larger than one read may deliver; neither
	## becomes possible on a later frame. `TargetUnavailable` is a render target
	## that no longer resolves to a host resource -- a released one, or the
	## `Draw.RenderTexture.stub` a pure test holds. `Busy` is the readback budget
	## being committed elsewhere -- to still exports in flight, or to the
	## delivery slots that carry byte lists to this app -- or, for a render
	## target bigger than `max_readback_bytes` on its own, committed for good.
	## `ReadbackFailed` is the graphics driver declining to hand the pixels
	## over. `Unavailable` is there being nothing to read at all -- a headless
	## run, or a `Screen` read before the host has a presented frame to read.
	PixelReadError : [RegionOutOfBounds, TargetUnavailable, Busy, ReadbackFailed, Unavailable]

	## Read the colour of one pixel.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	##
	## This is the cheap read. A point needs no allocation and no delivery slot,
	## which a one-pixel `read_region!` would still take for the same four
	## bytes, so a colour picker should ask for a point.
	##
	## ```roc
	## picked = match Capture.pixel_at!(Screen, { x: 40, y: 24 }) {
	##     Ok(color) => color
	##     Err(_) => Color.black
	## }
	## ```
	##
	## Reading `Screen` costs one full framebuffer readback per frame for as
	## long as the app keeps reading: the host snapshots the frame it presents
	## so that a later `update!` has defined pixels to look at, and stops
	## snapshotting once a frame goes by with no read. Nothing is snapshotted
	## before the first read, so the first `Screen` read of a run -- and every
	## `Screen` read from `init!`, which runs before any frame -- is
	## `Unavailable`, and the next cycle's read is not.
	##
	## Reading `Target` costs one readback of the whole target per call, however
	## small the point, because that is what the graphics API will give. Read a
	## region once rather than a point many times.
	##
	## A headless run has no pixels of any kind and answers `Unavailable`, so an
	## app that reads pixels has to say what it does without them before it can
	## run under `--host-headless`.
	pixel_at! : Source, { x : I32, y : I32 } => Try(Color.Rgba, PixelReadError)
	pixel_at! = |source, point| {
		result = Host.capture_pixel_at!({ source: pixel_source(source), x: point.x, y: point.y })
		if result.err == 0 {
			Ok(Color.rgba(result.r, result.g, result.b, result.a))
		} else {
			Err(pixel_read_error(result.err))
		}
	}

	## Read a rectangle of a source as packed RGBA8 bytes.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	##
	## The bytes are row-major and top-down: four bytes per pixel in red,
	## green, blue, alpha order, `width` pixels per row, the source's topmost
	## requested row first. A `Screen` region is always opaque, because reading
	## the framebuffer forces alpha; a `Target` region keeps the alpha the app
	## drew.
	##
	## ```roc
	## strip = Capture.read_region!(Target(poster), { x: 0, y: 0, width: 64, height: 1 })?
	## ```
	##
	## The list is handed over rather than copied, so a large region costs no
	## second buffer -- and, like every other handed-over byte list, it occupies
	## one of a bounded number of delivery slots until the app drops it. A read
	## with no slot free is `Busy`.
	##
	## The bound is `Capture.max_readback_bytes`: a region above it is
	## `RegionOutOfBounds` rather than something a later frame could take. The
	## per-call and per-frame costs are the ones `pixel_at!` describes; this is
	## not a per-frame operation on a whole window.
	read_region! : Source, Region => Try(List(U8), PixelReadError)
	read_region! = |source, region| {
		result = Host.capture_read_region!({
			source: pixel_source(source),
			x: region.x,
			y: region.y,
			width: region.width,
			height: region.height,
		})
		if result.err == 0 {
			Ok(result.bytes)
		} else {
			Err(pixel_read_error(result.err))
		}
	}

	## Most RGBA bytes one `read_region!` may deliver: 128 mebibytes, which is
	## 8192 by 4096 pixels.
	##
	## `screenshot_texture!` draws on the same budget, for the same reason: each
	## holds one whole RGBA image in host memory while it works, so the two
	## cannot both be given the whole of it.
	max_readback_bytes : U64
	max_readback_bytes = 128 * 1024 * 1024

	## A 25 FPS half-scale GIF of at most 300 frames, using fixed-input timing
	## and balanced encoder quality.
	default : Recording
	default = RrtCapture.default

	## Begin recording.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	##
	## Frames accumulate until the recording hits its frame cap, `Capture.stop!`
	## is called, or the app exits -- all three finalize the file.
	##
	## A rejected start appears as `Failed` in `input.capture` on the next cycle;
	## the call itself reports nothing, so the recording's outcome is observed
	## the same way whichever phase started it.
	start! : Recording => {}
	start! = |recording| {
		ratio = capture_scale_ratio(recording.scale())
		_refusal = Host.capture_start_recording!({
			path: recording.path(),
			format: capture_format_code(recording.format()),
			fps: recording.fps(),
			max_frames: recording.max_frames(),
			scale_numerator: ratio.numerator,
			scale_denominator: ratio.denominator,
			every_nth: recording.every_nth(),
			timing: capture_timing_code(recording.timing()),
			cursor: capture_cursor_code(recording.cursor()),
			quality: capture_quality_code(recording.quality()),
		})
		{}
	}

	## Finish the current recording and write its file.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`. An encode and
	## a file write would otherwise land in the middle of drawing a frame.
	##
	## Stopping while idle does nothing. The next input reports the frame count
	## and file size as `Finished`.
	stop! : () => {}
	stop! = || {
		_finished = Host.capture_stop_recording!()
		{}
	}

}

## Name every failure code the host can latch, whether it refused a start or
## stopped a running recording.
##
## `Unknown` means the host reported a code this module has no name for, which
## is a drift bug rather than a state an app should have to handle.
failure_reason : U8 -> Capture.FailureReason
failure_reason = |code|
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

expect failure_reason(1) == PathInvalid
expect failure_reason(2) == PathEscapesOutputDir
expect failure_reason(3) == AlreadyRecording
expect failure_reason(5) == UnsupportedFormat
expect failure_reason(6) == BudgetExceeded
expect failure_reason(7) == OutOfMemory
expect failure_reason(8) == WriteFailed
expect failure_reason(9) == EncodeFailed
expect failure_reason(0) == Unknown
expect failure_reason(200) == Unknown

## Decode the host's capture-error code for a screenshot.
##
## These are `src/capture.zig`'s codes, the same ones a recording's
## `FailureReason` names, so a path that escapes the output directory is still
## reported as the sandbox refusing it rather than as a failed write.
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

expect screenshot_error(1) == PathInvalid
expect screenshot_error(2) == PathEscapesOutputDir
expect screenshot_error(3) == AlreadyPending
expect screenshot_error(7) == WriteFailed
expect screenshot_error(10) == Busy
expect screenshot_error(11) == Unavailable
expect screenshot_error(99) == WriteFailed

## Decode the host's capture-error code for an offscreen export.
##
## The same `src/capture.zig` codes again, so a path refused by the sandbox
## reads the same here as it does for a screenshot or a recording. An unnamed
## code is drift between this module and the host rather than a state an app can
## do anything about, so it reports as a failed write.
texture_export_error : U8 -> Capture.TextureExportError
texture_export_error = |code|
	match code {
		1 => PathInvalid
		2 => PathEscapesOutputDir
		6 => BudgetExceeded
		7 => OutOfMemory
		8 => WriteFailed
		10 => Busy
		11 => Unavailable
		12 => ReadbackFailed
		13 => TargetUnavailable
		_ => WriteFailed
	}

expect texture_export_error(1) == PathInvalid
expect texture_export_error(2) == PathEscapesOutputDir
expect texture_export_error(6) == BudgetExceeded
expect texture_export_error(7) == OutOfMemory
expect texture_export_error(8) == WriteFailed
expect texture_export_error(10) == Busy
expect texture_export_error(11) == Unavailable
expect texture_export_error(12) == ReadbackFailed
expect texture_export_error(13) == TargetUnavailable
expect texture_export_error(0) == WriteFailed
expect texture_export_error(99) == WriteFailed

## Flatten a `Source` onto the pair the host ABI carries.
##
## The unread half is `Draw.RenderTexture.stub`, a resource-free value the host
## never resolves, so the record always has a target to carry and the host
## never has to read a field that means nothing.
pixel_source : Capture.Source -> Host.CapturePixelSource
pixel_source = |source|
	match source {
		Screen => { target: Draw.RenderTexture.stub.for_host(), screen: Bool.True }
		Target(target) => { target: target.for_host(), screen: Bool.False }
	}

## Decode the host's capture-error code for a pixel readback.
##
## The same `src/capture.zig` codes the exports use, plus the one that is only
## a readback's business: a region outside its source. An unnamed code is drift
## between this module and the host rather than a state an app can act on, so
## it reports as the driver having refused the read.
pixel_read_error : U8 -> Capture.PixelReadError
pixel_read_error = |code|
	match code {
		10 => Busy
		11 => Unavailable
		12 => ReadbackFailed
		13 => TargetUnavailable
		14 => RegionOutOfBounds
		_ => ReadbackFailed
	}

expect pixel_read_error(10) == Busy
expect pixel_read_error(11) == Unavailable
expect pixel_read_error(12) == ReadbackFailed
expect pixel_read_error(13) == TargetUnavailable
expect pixel_read_error(14) == RegionOutOfBounds
expect pixel_read_error(0) == ReadbackFailed
expect pixel_read_error(99) == ReadbackFailed

expect capture_format_code(Png) == 0
expect capture_format_code(Gif) == 1
expect capture_format_code(WebM) == 2
expect capture_timing_code(RealTime) == 0
expect capture_timing_code(FixedStep) == 1
expect capture_cursor_code(NoCursor) == 0
expect capture_cursor_code(DrawCursor) == 1
expect capture_quality_code(Fast) == 0
expect capture_quality_code(Balanced) == 1
expect capture_quality_code(Best) == 2
expect capture_scale_ratio(Full) == { numerator: 1, denominator: 1 }
expect capture_scale_ratio(Half) == { numerator: 1, denominator: 2 }
expect capture_scale_ratio(Quarter) == { numerator: 1, denominator: 4 }
expect capture_scale_ratio(Ratio({ numerator: 2, denominator: 3 })) == { numerator: 2, denominator: 3 }
expect capture_scale_ratio(Ratio({ numerator: 1, denominator: 0 })) == { numerator: 1, denominator: 1 }
expect capture_scale_ratio(Ratio({ numerator: 0, denominator: 4 })) == { numerator: 1, denominator: 1 }
