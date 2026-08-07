## Capture module - screenshots and recordings of the app's own output.
##
## An app can record itself: draw a visualization, start a recording, and get a
## PNG, GIF, or WebM out the other side. Frames are read back from the
## framebuffer at the end of each frame, so nothing here draws or needs a
## `Draw.Frame`.
##
## Every path is relative to the output directory set with
## `App.default.with_output_dir`. Absolute paths and paths containing `..` are
## refused -- this is the only file-writing capability the platform grants.
##
## The types and pure helpers live in the companion `roc-ray-types` package so
## reusable packages can depend on them without depending on this platform.
## This module re-exports them, so `Recording` here and in the package are the
## same nominal type and its receivers are available either way.
##
## Receivers are documented in the [roc-ray-types docs](../types/),
## which is where the nominal is declared.
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

	## A validated recording request. Update it through its receivers.
	Recording : RrtCapture.Recording

	## Live recording state, as reported by `Capture.status!`.
	Status : [
		Idle,
		Active({ frames : U64, dropped : U64 }),
		Failed({ frames : U64, reason : FailureReason }),
	]

	## Why a running recording stopped early.
	FailureReason : [OutOfMemory, WriteFailed, EncodeFailed, Unknown]

	## Where pointer input comes from.
	##
	## `Virtual` makes the host report a scripted pointer to `render!` instead
	## of the hardware one. Positions are in the same logical drawing
	## coordinates as `host.mouse`.
	Pointer : [
		Real,
		Virtual({ x : F32, y : F32, left : Bool, middle : Bool, right : Bool, wheel : F32 }),
	]

	## A `Virtual` pointer at a position, with no buttons held.
	at : { x : F32, y : F32 } -> Pointer
	at = |pos| Virtual({ x: pos.x, y: pos.y, left: Bool.False, middle: Bool.False, right: Bool.False, wheel: 0 })

	## A `Virtual` pointer at a position with the left button held.
	clicking_at : { x : F32, y : F32 } -> Pointer
	clicking_at = |pos| Virtual({ x: pos.x, y: pos.y, left: Bool.True, middle: Bool.False, right: Bool.False, wheel: 0 })

	## A 25 FPS half-scale GIF of at most 300 frames, using fixed-step timing.
	default : Recording
	default = RrtCapture.default

	## Drive `host.mouse` from a script instead of from the hardware pointer.
	##
	## The real operating-system cursor is untouched: this replaces only what
	## the app is told, so ordinary hover, hit-test, and drag code reacts to it
	## exactly as it would to a real pointer -- which is what makes a recorded
	## demo exercise the real input path rather than a parallel fake one.
	##
	## Press and release edges are derived from consecutive frames, so
	## `mouse.button_pressed(Left)` fires on the frame a virtual click starts.
	## Pass `Real` to hand control back to the hardware.
	##
	## The pointer is invisible in a recording unless the recording also asks
	## for `DrawCursor`, because the system cursor is not part of the
	## framebuffer that gets captured.
	set_virtual_mouse! : Pointer => {}
	set_virtual_mouse! = |pointer|
		match pointer {
			Real =>
				CaptureHost.set_virtual_mouse!({
					active: Bool.False,
					x: 0,
					y: 0,
					left: Bool.False,
					middle: Bool.False,
					right: Bool.False,
					wheel: 0,
				})

			Virtual(state) =>
				CaptureHost.set_virtual_mouse!({
					active: Bool.True,
					x: state.x,
					y: state.y,
					left: state.left,
					middle: state.middle,
					right: state.right,
					wheel: state.wheel,
				})
		}

	## Write a single still image of the current frame.
	##
	## The extension selects the encoder; `.png` is the portable choice. The
	## file is written at the end of the frame in which this is called, so the
	## image shows everything the app drew this frame.
	screenshot! : Str => Try({}, [PathInvalid, PathEscapesOutputDir, WriteFailed, OutOfMemory, ..])
	screenshot! = |path|
		match CaptureHost.screenshot!(path) {
			0 => Ok({})
			1 => Err(PathInvalid)
			2 => Err(PathEscapesOutputDir)
			7 => Err(OutOfMemory)
			_ => Err(WriteFailed)
		}

	## Begin recording. Frames accumulate until the recording hits its frame
	## cap, `Capture.stop!` is called, or the app exits -- all three finalize
	## the file.
	start! : Recording => Try({}, [AlreadyRecording, PathInvalid, PathEscapesOutputDir, UnsupportedFormat, BudgetExceeded, ..])
	start! = |recording| {
		ratio = RrtCapture.scale_ratio(recording.scale())
		result = CaptureHost.start_recording!({
			path: recording.path(),
			format: RrtCapture.format_code(recording.format()),
			fps: recording.fps(),
			max_frames: recording.max_frames(),
			scale_numerator: ratio.numerator,
			scale_denominator: ratio.denominator,
			every_nth: recording.every_nth(),
			timing: RrtCapture.timing_code(recording.timing()),
			cursor: RrtCapture.cursor_code(recording.cursor()),
		})
		match result {
			0 => Ok({})
			1 => Err(PathInvalid)
			2 => Err(PathEscapesOutputDir)
			3 => Err(AlreadyRecording)
			5 => Err(UnsupportedFormat)
			_ => Err(BudgetExceeded)
		}
	}

	## Finish the current recording and write its file, reporting how many
	## frames it holds and how large it is on disk.
	stop! : () => Try({ frames : U64, bytes : U64 }, [NotRecording, OutOfMemory, WriteFailed, EncodeFailed, ..])
	stop! = || {
		result = CaptureHost.stop_recording!()
		match result.err {
			0 => Ok({ frames: result.frames, bytes: result.bytes })
			4 => Err(NotRecording)
			7 => Err(OutOfMemory)
			8 => Err(WriteFailed)
			_ => Err(EncodeFailed)
		}
	}

	## Check on a recording without stopping it.
	##
	## A recording that ran out of memory or could not write reports `Failed`
	## rather than crashing the app, so a long capture can degrade without
	## taking the visualization down with it.
	status! : () => Status
	status! = || {
		result = CaptureHost.recording_status!()
		if result.status == 1 {
			Active({ frames: result.frames, dropped: result.dropped })
		} else if result.status == 2 {
			Failed({ frames: result.frames, reason: failure_reason(result.err) })
		} else {
			Idle
		}
	}
}

failure_reason : U8 -> Capture.FailureReason
failure_reason = |code|
	match code {
		7 => OutOfMemory
		8 => WriteFailed
		9 => EncodeFailed
		_ => Unknown
	}

expect failure_reason(7) == OutOfMemory
expect failure_reason(8) == WriteFailed
expect failure_reason(9) == EncodeFailed
expect failure_reason(0) == Unknown
expect failure_reason(200) == Unknown
