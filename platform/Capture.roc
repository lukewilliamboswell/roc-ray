## Capture module - screenshots and recordings of the app's own output.
##
## An app can record itself: draw a visualization, start a recording, and get a
## PNG, GIF, or WebM out the other side. Frames are read back from the
## framebuffer at the end of each frame, so nothing here draws or needs a
## `Draw.Frame`.
##
## Every path here is relative to the output directory set with
## `App.default.with_output_dir`, and one that would escape it -- absolute, or
## containing `..` -- is refused rather than rewritten. Capture is the only
## file-writing capability the platform grants.
##
## Nothing here is an effect an app can call. Recording starts and stops through
## actions, a screenshot is a `Program.Task`, and the live state is sampled onto
## `step.capture` every cycle. That is not tidiness: an effectful `stop!` is
## reachable from `render!`, where it would finalize a file -- an encode and a
## write -- in the middle of drawing a frame.
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

	## How hard the encoder works to choose colours for each frame.
	Quality : RrtCapture.Quality

	## A validated recording request. Update it through its receivers.
	Recording : RrtCapture.Recording

	## Live recording state, sampled onto every `Program.Step` as `step.capture`.
	##
	## There is no effect that asks for this, and that is deliberate: starting
	## and stopping are actions, so this is the only channel their outcome has.
	##
	## `Finished` is separate from `Idle` on purpose. A recording that reaches
	## its frame cap finalizes itself with nothing to tell the app, and `Idle`
	## would be indistinguishable from never having recorded at all -- so an app
	## waiting for its capture to complete would have nothing to wait on.
	Status : [
		Idle,
		Active({ frames : U64, dropped : U64 }),
		Finished({ frames : U64, bytes : U64 }),
		Failed({ frames : U64, reason : FailureReason }),
	]

	## Why a recording is not running.
	##
	## The first four are refusals of a `Capture.start` action -- the request
	## was never armed, and nothing was written. The rest are a running
	## recording that stopped early. They share one type because they reach the
	## app the same way, in `Failed`, and an app that just wants to know whether
	## its capture worked should not have to care which kind it got.
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

	## A 25 FPS half-scale GIF of at most 300 frames, using fixed-step timing
	## and balanced encoder quality.
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
	## Apply a `SetVirtualMouse` action. Platform-internal: `main.roc`'s adapter
	## calls this, and an app reaches it through `Capture.set_virtual_mouse`.
	apply_virtual_mouse! : Pointer => {}
	apply_virtual_mouse! = |pointer|
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

	## Drive `host.mouse` from a script, as an action a pure `update` can
	## return. The platform applies it in the cycle that asked for it, so the
	## scripted pointer reaches `render!` on the very next draw, exactly as
	## `Capture.set_virtual_mouse!` did from inside an effectful update.
	set_virtual_mouse : Pointer -> [SetVirtualMouse(Pointer), ..]
	set_virtual_mouse = |pointer| SetVirtualMouse(pointer)

	## Begin recording, as an action a pure `update` can return.
	##
	## Frames accumulate until the recording hits its frame cap, a
	## `Capture.stop` action is applied, or the app exits -- all three finalize
	## the file.
	##
	## An action rather than a task because there is nothing to correlate back:
	## a recording is either running or it is not, and `step.capture` says which
	## on every cycle. A start the host refuses shows up there as `Failed`
	## carrying the reason, on the very next step.
	##
	## There is deliberately no effectful form. One reachable from `render!`
	## could finalize a file in the middle of drawing a frame, which is both a
	## stall nobody asked for and an ordering nobody can see.
	start : Recording -> [StartRecording(Recording), ..]
	start = |recording| StartRecording(recording)

	## Finish the current recording and write its file, as an action.
	##
	## Stopping when nothing is recording does nothing and is not an error: the
	## state the app asked for is the state it already had. The frame count and
	## the file size arrive on the next step, as `Finished`.
	stop : [StopRecording, ..]
	stop = StopRecording

	## Apply a `StartRecording` action. Platform-internal.
	##
	## The refusal code is dropped here rather than propagated: an action has
	## nobody to return it to, so the host latches it and the app reads it off
	## `step.capture`. Failing the cycle instead would take the app down for a
	## bad path.
	apply_start! : Recording => {}
	apply_start! = |recording| {
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

	## Apply a `StopRecording` action. Platform-internal.
	##
	## The frame count and byte count it returns are dropped for the same
	## reason, and reach the app as `Finished` on the next step instead.
	apply_stop! : () => {}
	apply_stop! = || {
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
