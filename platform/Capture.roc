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
## Recording starts and stops through `Capture.start!` and `Capture.stop!`,
## a single frame is written by `Capture.screenshot!`, and recording state is
## available as `input.capture` each cycle.
##
## The types and pure helpers live in the companion `roc-ray-types` package so
## reusable packages can depend on them without depending on this platform.
## This module re-exports them, so `Recording` here and in the package are the
## same nominal type.
import rrt.Capture as RrtCapture
import CaptureHost

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

	## Write one PNG of the app's rendered output.
	##
	## The framebuffer is read back at the end of the frame that asked -- after
	## the draw batch is flushed and before the buffers are swapped, so the
	## pixels are the ones just drawn -- and the PNG is encoded and written off
	## the frame thread. This call waits for that write, so it parks the task
	## until the file exists and answers with the write's own outcome.
	##
	## Valid inside a task. In `init!` there is no frame to capture yet, so a
	## windowed run answers `Unavailable`; a headless run has no framebuffer at
	## all and answers `Ok({})` without writing.
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

	screenshot : Str, (Try({}, ScreenshotError) -> msg) -> [Screenshot({ path : Str, callback : Try({}, ScreenshotError) -> msg }), ..]
	screenshot = |path, callback| Screenshot({ path, callback })

	## A 25 FPS half-scale GIF of at most 300 frames, using fixed-input timing
	## and balanced encoder quality.
	default : Recording
	default = RrtCapture.default

	## Begin recording. Valid during `init!`, `update!`, and tasks.
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

	## Finish the current recording and write its file. Valid during `init!`,
	## `update!`, and tasks -- not `render!`, where an encode and a file write
	## would land in the middle of drawing a frame.
	##
	## Stopping while idle does nothing. The next input reports the frame count and
	## file size as `Finished`.
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
