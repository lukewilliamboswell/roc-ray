## Describing screenshots and recordings.
##
## These types are pure data: they say what to capture and how, and carry no
## effects. The effects that act on them live in the platform's `Capture`
## module, which re-exports everything declared here, so an app names them
## through `Capture` and never depends on this package directly.

CaptureFormat := [Png, Gif, WebM].{

	## Compare two of these values.
	is_eq : _
}

CaptureScale := [Full, Half, Quarter, Ratio({ numerator : U32, denominator : U32 })].{

	## Compare two of these values.
	is_eq : _
}

CaptureTiming := [RealTime, FixedStep].{

	## Compare two of these values.
	is_eq : _
}

CaptureCursor := [NoCursor, DrawCursor].{

	## Compare two of these values.
	is_eq : _
}

CaptureQuality := [Fast, Balanced, Best].{

	## Compare two of these values.
	is_eq : _
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
