## Private conversion from public commands to hosted apply-phase operations.
## This module is intentionally absent from the platform exposes list.
import Capture
import CaptureHost
import Mouse
import rrt.Capture as RrtCapture

CommandApply := [].{
	set_mouse_source! : Mouse.Source => {}
	set_mouse_source! = |source|
		match source {
			Hardware => CaptureHost.set_virtual_mouse!({ active: Bool.False, x: 0, y: 0, left: Bool.False, middle: Bool.False, right: Bool.False, wheel: 0 })
			Virtual(state) => CaptureHost.set_virtual_mouse!({ active: Bool.True, x: state.x, y: state.y, left: state.left, middle: state.middle, right: state.right, wheel: state.wheel })
		}

	start_recording! : Capture.Recording => {}
	start_recording! = |recording| {
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

	stop_recording! : () => {}
	stop_recording! = || {
		_finished = CaptureHost.stop_recording!()
		{}
	}
}
