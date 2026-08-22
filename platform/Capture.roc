## Screenshots and recordings of the app's rendered output.
##
## Recorded frames are captured from the framebuffer at the end of each frame,
## and so are the size of the window. Supported outputs are PNG image sequences,
## GIF, and WebM. A still image can also be exported from an offscreen
## `Draw.RenderTexture` of any size, which is how output larger than the window
## is produced.
##
## Every path here is relative to the output directory set with
## `App.default.with_output_dir`, and one that would escape it -- absolute, or
## containing `..` -- is refused rather than rewritten. Capture is the only
## file-writing capability the platform grants.
##
## Recording starts and stops through `Capture.start!` and `Capture.stop!`,
## a single frame is written by `Capture.screenshot!`, and recording state is
## available as `input.capture` each cycle.
##
## Pixels also come back the other way, without becoming a file. `pixel_at!`
## reads one pixel and `read_region!` reads a rectangle, from either the last
## presented frame or a `Draw.RenderTexture`; both are refused in `render!`,
## and both say what they cost.
##
## The types and pure helpers live in the companion `roc-ray-types` package so
## reusable packages can depend on them without depending on this platform.
## This module re-exports them, so `Recording` here and in the package are the
## same nominal type.
import rrt.Capture as RrtCapture
import CaptureHost
import Color
import Draw

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
	Recording : RrtCapture.Recording

	## Live recording state, sampled onto every `App.Input` as `input.capture`.
	##
	## `Finished` remains observable after automatic finalization at the frame cap.
	Status : [
		Idle,
		Active({ frames : U64, dropped : U64 }),
		Finished({ frames : U64, bytes : U64 }),
		Failed({ frames : U64, reason : FailureReason }),
	]

	## Why a recording is not running.
	##
	## `PathInvalid`, `PathEscapesOutputDir`, `AlreadyRecording`, and
	## `BudgetExceeded` reject a start request before anything is written. The
	## remaining reasons may stop an active recording.
	FailureReason : [
		PathInvalid,
		PathEscapesOutputDir,
		AlreadyRecording,
		BudgetExceeded,
		UnsupportedFormat,
		OutOfMemory,
		WriteFailed,
		EncodeFailed,
		Unknown,
	]

	## Why a screenshot did not become a file.
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
		err = CaptureHost.screenshot!(path)
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
	## Legal in `init!`, where it blocks, and in tasks, where it parks; refused
	## in `update!` and `render!`. Nothing here waits on the frame loop, which is
	## why `init!` is allowed where a `screenshot!` cannot be -- but drawing into
	## a target is only possible during `render!`, so a target no `render!` has
	## drawn into holds undefined pixels.
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
		err = CaptureHost.screenshot_texture!({ target, path })
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
		result = CaptureHost.pixel_at!({ source: pixel_source(source), x: point.x, y: point.y })
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
		result = CaptureHost.read_region!({
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

	## Most RGBA bytes one `read_region!` may deliver: 128 MiB, or 8192 by 4096
	## pixels.
	##
	## The same budget the still exports in `screenshot_texture!` draw on, and
	## for the same reason: each holds one RGBA image in host memory at a time.
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
		ratio = RrtCapture.scale_ratio(recording.scale())
		_refusal = CaptureHost.start_recording!({
			path: recording.path(),
			format: RrtCapture.format_code(recording.format()),
			fps: recording.fps(),
			max_frames: recording.max_frames(),
			scale_numerator: ratio.numerator,
			scale_denominator: ratio.denominator,
			every_nth: recording.every_nth(),
			timing: RrtCapture.timing_code(recording.timing()),
			cursor: RrtCapture.cursor_code(recording.cursor()),
			quality: RrtCapture.quality_code(recording.quality()),
		})
		{}
	}

	## Finish the current recording and write its file.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`, where an
	## encode and a file write would land in the middle of drawing a frame.
	##
	## Stopping while idle does nothing. The next input reports the frame count
	## and file size as `Finished`.
	stop! : () => {}
	stop! = || {
		_finished = CaptureHost.stop_recording!()
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
pixel_source : Capture.Source -> CaptureHost.PixelSource
pixel_source = |source|
	match source {
		Screen => { target: Draw.RenderTexture.stub, screen: Bool.True }
		Target(target) => { target, screen: Bool.False }
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
