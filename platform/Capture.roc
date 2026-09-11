## Screenshots and recordings of the app's rendered output.
##
## Record the window framebuffer as a PNG sequence, GIF, or WebM. Recorded
## frames use the window dimensions. Export a `Draw.RenderTexture` for a still
## image at another size.
##
## Every path here is relative to the output directory set with
## `App.default.with_output_dir`, and one that would escape it -- absolute, or
## containing `..` -- is refused rather than rewritten. Capture is the only
## path-sandboxed writer the platform grants: `Files.Access.write_text!` and
## `Files.Access.write_bytes!` write wherever the process may write, while everything
## here is confined to the output directory.
##
## `start!` and `stop!` control recording. `screenshot!` writes a presented
## frame, and `screenshot_texture!` writes an offscreen render texture.
## Recording state is sampled into `input.capture` each cycle.
##
## `pixel_at!` and `read_region!` return pixels from the last presented frame
## or a render texture without writing a file. Both are refused in `render!`.
##
import Host
import Resource
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

# TODO(follow up): Restore derived equality when Roc handles it through type aliases
# without looping during compilation (nightly-2026-09-10-a670e34).
CaptureFormat := [Png, Gif, WebM].{

	## Compare two of these values.
	is_eq : CaptureFormat, CaptureFormat -> Bool
	is_eq = |a, b| match (a, b) {
		(Png, Png) => Bool.True
		(Gif, Gif) => Bool.True
		(WebM, WebM) => Bool.True
		_ => Bool.False
	}
}

CaptureScale := [Full, Half, Quarter, Ratio({ numerator : U32, denominator : U32 })].{

	## Compare two of these values.
	is_eq : CaptureScale, CaptureScale -> Bool
	is_eq = |a, b| match (a, b) {
		(Full, Full) => Bool.True
		(Half, Half) => Bool.True
		(Quarter, Quarter) => Bool.True
		(Ratio(left), Ratio(right)) => left.numerator == right.numerator and left.denominator == right.denominator
		_ => Bool.False
	}
}

CaptureTiming := [RealTime, FixedStep].{

	## Compare two of these values.
	is_eq : CaptureTiming, CaptureTiming -> Bool
	is_eq = |a, b| match (a, b) {
		(RealTime, RealTime) => Bool.True
		(FixedStep, FixedStep) => Bool.True
		_ => Bool.False
	}
}

CaptureCursor := [NoCursor, DrawCursor].{

	## Compare two of these values.
	is_eq : CaptureCursor, CaptureCursor -> Bool
	is_eq = |a, b| match (a, b) {
		(NoCursor, NoCursor) => Bool.True
		(DrawCursor, DrawCursor) => Bool.True
		_ => Bool.False
	}
}

CaptureQuality := [Fast, Balanced, Best].{

	## Compare two of these values.
	is_eq : CaptureQuality, CaptureQuality -> Bool
	is_eq = |a, b| match (a, b) {
		(Fast, Fast) => Bool.True
		(Balanced, Balanced) => Bool.True
		(Best, Best) => Bool.True
		_ => Bool.False
	}
}

Capture := [].{

	## Container and codec written for a capture.
	##
	## `Png` writes a numbered still per captured frame. `Gif` and `WebM` each
	## write a single animated file, encoded incrementally as frames arrive --
	## so memory stays bounded by one frame and the length of a recording is
	## limited only by `max_frames` and by disk space.
	##
	## `CaptureFormat` in the signature is the module-private nominal this
	## aliases; `Capture.Format` is the name to write.
	Format : CaptureFormat

	## How far each captured frame is downscaled from the framebuffer.
	##
	## Scaling happens after rendering, so it shrinks the output file without
	## changing the window size or what the app draws. A ratio that would round
	## an axis to zero is clamped to one pixel.
	Scale : CaptureScale

	## Whether simulation time follows the wall clock or advances in exact steps.
	##
	## Reading back the framebuffer stalls the GPU, so a `RealTime` recording
	## bakes that stutter into the output and differs between runs. `FixedStep`
	## reports `1/fps` as the frame delta regardless of how long the frame
	## actually took, which is smooth and reproducible.
	Timing : CaptureTiming

	## Whether the host composites a pointer glyph into captured frames.
	##
	## The operating system cursor is not part of the framebuffer, so a
	## recording never shows a pointer unless something draws one.
	Cursor : CaptureCursor

	## How hard the encoder works to choose colours for each frame.
	##
	## This setting affects `Gif` and is ignored by `Png` and `WebM`.
	##
	## `Best` searches the full colour depth. `Balanced` is the default and
	## trades at most 16/255 channel error for faster encoding on flat-colour
	## frames. `Fast` uses a coarser palette and may show visible banding.
	Quality : CaptureQuality

	## A validated recording request. Its fields cannot be updated directly;
	## use its receiver updates so the invariants are preserved.
	Recording :: {
		path : Str,
		format : CaptureFormat,
		fps : I32,
		max_frames : U64,
		scale : CaptureScale,
		every_nth : U32,
		timing : CaptureTiming,
		cursor : CaptureCursor,
		quality : CaptureQuality,
	}.{

		## Compare two of these values.
		is_eq : _

		## Return a recording written to a different path.
		##
		## The path is relative to the app's configured output directory. The
		## host refuses absolute paths and any path containing `..`.
		with_path : Recording, Str -> Recording
		with_path = |rec, value| { ..rec, path: value }

		## Return a recording written in a different format.
		with_format : Recording, Format -> Recording
		with_format = |rec, value| { ..rec, format: value }

		## Return a recording played back at a different frame rate. A
		## non-positive rate falls back to the 25 FPS default.
		with_fps : Recording, I32 -> Recording
		with_fps = |rec, value| { ..rec, fps: normalize_fps(value) }

		## Return a recording that stops after this many captured frames. `0`
		## records until a `Capture.stop` command is applied or the app exits.
		with_max_frames : Recording, U64 -> Recording
		with_max_frames = |rec, value| { ..rec, max_frames: value }

		## Return a recording captured at a different scale.
		with_scale : Recording, Scale -> Recording
		with_scale = |rec, value| { ..rec, scale: value }

		## Return a recording that keeps only every nth rendered frame. `0` and
		## `1` both keep every frame.
		with_every_nth : Recording, U32 -> Recording
		with_every_nth = |rec, value| { ..rec, every_nth: normalize_every_nth(value) }

		## Return a recording using a different simulation timing strategy.
		with_timing : Recording, Timing -> Recording
		with_timing = |rec, value| { ..rec, timing: value }

		## Return a recording that does or does not draw a pointer glyph.
		with_cursor : Recording, Cursor -> Recording
		with_cursor = |rec, value| { ..rec, cursor: value }

		## Return a recording encoded at a different quality.
		with_quality : Recording, Quality -> Recording
		with_quality = |rec, value| { ..rec, quality: value }

		## Inspect the output path.
		path : Recording -> Str
		path = |rec| rec.path

		## Inspect the selected format.
		format : Recording -> Format
		format = |rec| rec.format

		## Inspect the playback frame rate.
		fps : Recording -> I32
		fps = |rec| rec.fps

		## Inspect the frame cap. `0` means the recording is unbounded.
		max_frames : Recording -> U64
		max_frames = |rec| rec.max_frames

		## Inspect the capture scale.
		scale : Recording -> Scale
		scale = |rec| rec.scale

		## Inspect the frame stride.
		every_nth : Recording -> U32
		every_nth = |rec| rec.every_nth

		## Inspect the simulation timing strategy.
		timing : Recording -> Timing
		timing = |rec| rec.timing

		## Inspect whether a pointer glyph is drawn.
		cursor : Recording -> Cursor
		cursor = |rec| rec.cursor

		## Inspect the encoder quality.
		quality : Recording -> Quality
		quality = |rec| rec.quality
	}

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

	## A 25 FPS half-scale GIF of at most 300 frames, using fixed-step timing
	## and balanced encoder quality.
	##
	## Sized so a full-screen recording stays well inside the host's in-memory
	## encoding budget and produces a file small enough to embed in a README.
	default : Recording
	default = {
		path: "recording.gif",
		format: Gif,
		fps: 25,
		max_frames: 300,
		scale: Half,
		every_nth: 1,
		timing: FixedStep,
		cursor: NoCursor,
		quality: Balanced,
	}

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
	ScreenshotError : [PermissionDenied, PathInvalid, PathEscapesOutputDir, AlreadyPending, WriteFailed, Busy, Unavailable]

	## Why an offscreen export did not become a file.
	##
	## `TargetUnavailable` is a render target that no longer resolves to a host
	## resource -- a released one, or the `Draw.RenderTexture.stub` a pure test
	## holds. `BudgetExceeded` is an image too large for the host to hold at all,
	## so retrying will not help; `Busy` is one that would fit were other exports
	## not in flight, so a later frame may take it. `Unavailable` is the app
	## shutting down before the write started.
	TextureExportError : [
		PermissionDenied,
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
		# closed error union to open error union
		match Host.capture_pixel_at!({ source: pixel_source(source), x: point.x, y: point.y }) {
			Ok(pixel) => Ok(Color.rgba(pixel.r, pixel.g, pixel.b, pixel.a))
			Err(Busy) => Err(Busy)
			Err(ReadbackFailed) => Err(ReadbackFailed)
			Err(RegionOutOfBounds) => Err(RegionOutOfBounds)
			Err(TargetUnavailable) => Err(TargetUnavailable)
			Err(Unavailable) => Err(Unavailable)
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
		# closed error union to open error union
		match result {
			Ok(bytes) => Ok(bytes)
			Err(Busy) => Err(Busy)
			Err(ReadbackFailed) => Err(ReadbackFailed)
			Err(RegionOutOfBounds) => Err(RegionOutOfBounds)
			Err(TargetUnavailable) => Err(TargetUnavailable)
			Err(Unavailable) => Err(Unavailable)
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

	## Opaque capture authority supplied by App.Io. Effects return PermissionDenied when external access is disabled.
	Writer :: Resource.Authority.{

		## Private platform construction; no application can manufacture the argument.
		for_host : Resource.Authority -> Writer
		for_host = |authority| Writer.(authority)

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
		##     Task.spawn!(input, || Shot(io.capture().screenshot!("frame0.png")))
		## }
		## ```
		##
		## A headless run has no framebuffer at all and answers `Ok({})` without
		## writing, so a screenshotting app still runs under `--host-headless`.
		##
		## Only one screenshot can be in flight: a second one while the first is
		## still waiting for its frame is `AlreadyPending`.
		screenshot! : Writer, Str => Try({}, ScreenshotError)
		screenshot! = |Writer.(authority), path| perform_screenshot!(authority, path)

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
		## Task.spawn!(input, || Exported(io.capture().screenshot_texture!(poster, "poster.png")))
		## ```
		screenshot_texture! : Writer, Draw.RenderTexture, Str => Try({}, TextureExportError)
		screenshot_texture! = |Writer.(authority), target, path| perform_screenshot_texture!(authority, target, path)

		## Begin recording.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		##
		## Frames accumulate until the recording hits its frame cap, `Capture.Writer.stop!`
		## is called, or the app exits -- all three finalize the file.
		##
		## A rejected start appears as `Failed` in `input.capture` on the next cycle;
		## the call itself reports nothing, so the recording's outcome is observed
		## the same way whichever phase started it.
		start! : Writer, Recording => Try({}, [PermissionDenied, ..])
		start! = |Writer.(authority), recording| perform_start!(authority, recording)

		## Finish the current recording and write its file.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`. An encode and
		## a file write would otherwise land in the middle of drawing a frame.
		##
		## Stopping while idle does nothing. The next input reports the frame count
		## and file size as `Finished`.
		stop! : Writer => Try({}, [PermissionDenied, ..])
		stop! = |Writer.(authority)| perform_stop!(authority)

	}

}

normalize_fps : I32 -> I32
normalize_fps = |value| if value > 0 value else 25

## `0` and `1` both mean "keep every frame"; the host divides by this value.
normalize_every_nth : U32 -> U32
normalize_every_nth = |value| if value > 0 value else 1

expect Capture.default.format() == Gif
expect Capture.default.fps() == 25
expect Capture.default.max_frames() == 300
expect Capture.default.scale() == Half
expect Capture.default.every_nth() == 1
expect Capture.default.timing() == FixedStep
expect Capture.default.cursor() == NoCursor
expect Capture.default.quality() == Balanced
expect Capture.default.path() == "recording.gif"
expect Capture.default.with_path("out/demo.gif").path() == "out/demo.gif"
expect Capture.default.with_format(WebM).format() == WebM
expect Capture.default.with_fps(50).fps() == 50
expect Capture.default.with_fps(0).fps() == 25
expect Capture.default.with_fps(-5).fps() == 25
expect Capture.default.with_max_frames(0).max_frames() == 0
expect Capture.default.with_scale(Full).scale() == Full
expect Capture.default.with_every_nth(3).every_nth() == 3
expect Capture.default.with_every_nth(0).every_nth() == 1
expect Capture.default.with_timing(RealTime).timing() == RealTime
expect Capture.default.with_cursor(DrawCursor).cursor() == DrawCursor
expect Capture.default.with_quality(Fast).quality() == Fast
expect Capture.default.with_quality(Best).quality() == Best

expect CaptureFormat.is_eq(Png, Gif) == Bool.False
expect CaptureScale.is_eq(Half, Full) == Bool.False
expect CaptureScale.is_eq(Ratio({ numerator: 1, denominator: 2 }), Ratio({ numerator: 1, denominator: 2 }))
expect !CaptureScale.is_eq(Ratio({ numerator: 1, denominator: 2 }), Ratio({ numerator: 2, denominator: 2 }))
expect !CaptureScale.is_eq(Ratio({ numerator: 1, denominator: 2 }), Ratio({ numerator: 1, denominator: 3 }))
expect !CaptureScale.is_eq(Half, Ratio({ numerator: 1, denominator: 2 }))
expect !CaptureTiming.is_eq(RealTime, FixedStep)
expect !CaptureCursor.is_eq(NoCursor, DrawCursor)
expect !CaptureQuality.is_eq(Fast, Best)

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

## Private authority-taking implementations.
perform_screenshot! : Resource.Authority, Str => Try({}, Capture.ScreenshotError)
perform_screenshot! = |authority, path| {
	# closed error union to open error union
	match Host.capture_screenshot!(authority, path) {
		Ok({}) => Ok({})
		Err(PermissionDenied) => Err(PermissionDenied)
		Err(AlreadyPending) => Err(AlreadyPending)
		Err(Busy) => Err(Busy)
		Err(PathEscapesOutputDir) => Err(PathEscapesOutputDir)
		Err(PathInvalid) => Err(PathInvalid)
		Err(Unavailable) => Err(Unavailable)
		Err(WriteFailed) => Err(WriteFailed)
	}
}

perform_screenshot_texture! : Resource.Authority, Draw.RenderTexture, Str => Try({}, Capture.TextureExportError)
perform_screenshot_texture! = |authority, target, path| {
	# closed error union to open error union
	match Host.capture_screenshot_texture!(authority, { target: target.for_host(), path }) {
		Ok({}) => Ok({})
		Err(PermissionDenied) => Err(PermissionDenied)
		Err(BudgetExceeded) => Err(BudgetExceeded)
		Err(Busy) => Err(Busy)
		Err(OutOfMemory) => Err(OutOfMemory)
		Err(PathEscapesOutputDir) => Err(PathEscapesOutputDir)
		Err(PathInvalid) => Err(PathInvalid)
		Err(ReadbackFailed) => Err(ReadbackFailed)
		Err(TargetUnavailable) => Err(TargetUnavailable)
		Err(Unavailable) => Err(Unavailable)
		Err(WriteFailed) => Err(WriteFailed)
	}
}

perform_start! : Resource.Authority, Capture.Recording => Try({}, [PermissionDenied, ..])
perform_start! = |authority, recording| {
	ratio = capture_scale_ratio(recording.scale())
	# The host latches the refusal for the next `Input` to report, so there
	# is nothing to answer with here.
	result = Host.capture_start_recording!(
		authority,
		{
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
		},
	)
	match result {
		Err(PermissionDenied) => Err(PermissionDenied)
		_ => Ok({})
	}
}

perform_stop! : Resource.Authority => Try({}, [PermissionDenied, ..])
perform_stop! = |authority| {
	result = Host.capture_stop_recording!(authority)
	match result {
		Err(PermissionDenied) => Err(PermissionDenied)
		_ => Ok({})
	}
}
