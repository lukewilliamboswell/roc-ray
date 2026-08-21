## Screenshots and recordings of the app's rendered output.
##
## Frames are captured from the framebuffer at the end of each frame. Supported
## outputs are PNG image sequences, GIF, and WebM.
##
## Every path here is relative to the output directory set with
## `App.default.with_output_dir`, and one that would escape it -- absolute, or
## containing `..` -- is refused rather than rewritten. Capture is the only
## file-writing capability the platform grants.
##
## Recording starts and stops through commands, screenshots use `App.Request`,
## and recording state is available as `input.capture` each cycle.
##
## The types and pure helpers live in the companion `roc-ray-types` package so
## reusable packages can depend on them without depending on this platform.
## This module re-exports them, so `Recording` here and in the package are the
## same nominal type.
import rrt.Capture as RrtCapture

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

	ScreenshotError : [PathInvalid, PathEscapesOutputDir, AlreadyPending, WriteFailed, Busy, Unavailable]

	screenshot : Str, (Try({}, ScreenshotError) -> msg) -> [Screenshot({ path : Str, callback : Try({}, ScreenshotError) -> msg }), ..]
	screenshot = |path, callback| Screenshot({ path, callback })

	## A 25 FPS half-scale GIF of at most 300 frames, using fixed-input timing
	## and balanced encoder quality.
	default : Recording
	default = RrtCapture.default

	## Begin recording, as a command a pure `update` can return.
	##
	## Frames accumulate until the recording hits its frame cap, a
	## `Capture.stop` command is applied, or the app exits -- all three finalize
	## the file.
	##
	## A rejected start appears as `Failed` in `input.capture` on the next cycle.
	start : Recording -> [StartRecording(Recording), ..]
	start = |recording| StartRecording(recording)

	## Finish the current recording and write its file, as a command.
	##
	## Stopping while idle does nothing. The next input reports the frame count and
	## file size as `Finished`.
	stop : [StopRecording, ..]
	stop = StopRecording

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
