## Internal capture transport and hosted effects.
##
## This module is intentionally not exposed by the platform package. Public
## applications use `Capture`, which maps these flat primitive codes onto tag
## unions and hides the numbering.
##
## The flattening functions live here rather than beside the tag unions in the
## `roc-ray-types` package. The numbers are this host's wire format, not shared
## vocabulary, and a pure package that named them would freeze them at its own
## release cadence. `Capture.start!` and the startup config both flatten
## through here, so the two cannot drift.
import Draw
import rrt.Capture as RrtCapture

CaptureHost := [].{

	## A recording request flattened to primitives the host ABI can carry.
	StartRecording : {
		path : Str,
		format : U8,
		fps : I32,
		max_frames : U64,
		scale_numerator : U32,
		scale_denominator : U32,
		every_nth : U32,
		timing : U8,
		cursor : U8,
		quality : U8,
	}

	## Outcome of finalizing a recording. `err` is `0` when the file was written.
	StopResult : {
		err : U8,
		frames : U64,
		bytes : U64,
	}

	## A scripted pointer state. `active` false hands control back to hardware.
	VirtualMouse : {
		active : Bool,
		x : F32,
		y : F32,
		left : Bool,
		middle : Bool,
		right : Bool,
		wheel : F32,
	}

	set_virtual_mouse! : VirtualMouse => {}

	## A scripted keyboard state. `active` false hands control back to hardware.
	##
	## `keys` carries the raylib key codes held down, and only those. Press and
	## release edges are derived by the host from consecutive frames exactly as
	## they are for hardware, so nothing here describes an edge.
	VirtualKeys : {
		active : Bool,
		keys : List(U64),
	}

	set_virtual_keys! : VirtualKeys => {}

	## Queue Unicode codepoints as the text entered on the next frame.
	##
	## The host delivers them once and then forgets them, the way a real
	## keyboard's characters arrive on one frame and not the next.
	set_virtual_text! : List(U32) => {}

	## Arm a recording. The refusal code is latched by the host rather than
	## acted on here, so the outcome is observed the same way whichever phase
	## started it: an app reads it off `input.capture` on the next cycle.
	start_recording! : StartRecording => U8

	## Finalize the running recording and write its file.
	stop_recording! : () => StopResult

	## Capture the framebuffer at the end of this frame and write it as a PNG.
	##
	## Waits: the calling task parks until the file has been written, so the
	## returned code is the write's own outcome rather than a promise.
	screenshot! : Str => U8

	## A render target and the path its pixels are written to.
	##
	## The target crosses as the public `Draw.RenderTexture` rather than as its
	## transport handle, the same way `DrawHost.LoadStoreShader` carries an
	## `Assets.Store`: the host resolves the handle it already knows.
	TextureShot : {
		target : Draw.RenderTexture,
		path : Str,
	}

	## Read a render target back and write it as a PNG.
	##
	## Waits: the readback itself is synchronous, because it needs the graphics
	## context the frame thread holds. The calling task parks for the encode and
	## the write, so the returned code is the write's own outcome.
	screenshot_texture! : TextureShot => U8

	## Which pixels a readback reads, flattened for the host ABI.
	##
	## `screen` picks the last presented frame and leaves `target` unread; when
	## it is false the pixels come from `target`. `Capture.Source` is the tag
	## union this pair encodes, and it passes `Draw.RenderTexture.stub` as the
	## unread target so the field always carries a value.
	PixelSource : {
		target : Draw.RenderTexture,
		screen : Bool,
	}

	## One pixel's channels and why they are or are not real.
	##
	## `err` is `0` when the colour was read; otherwise the channels are zero
	## and the code names the refusal.
	PixelResult : {
		err : U8,
		r : U8,
		g : U8,
		b : U8,
		a : U8,
	}

	## A point in a source, in pixels from its top-left corner.
	PixelProbe : {
		source : PixelSource,
		x : I32,
		y : I32,
	}

	## Read one pixel out of a source.
	##
	## Synchronous: the screen is read from a snapshot the host already holds,
	## and a render target is read through the graphics context this thread
	## owns, so nothing here parks.
	pixel_at! : PixelProbe => PixelResult

	## A rectangle in a source, in pixels from its top-left corner.
	RegionProbe : {
		source : PixelSource,
		x : I32,
		y : I32,
		width : I32,
		height : I32,
	}

	## Packed RGBA8 bytes and why they are or are not there.
	##
	## The list is handed over rather than copied, the same ownership transfer
	## `FilesHost.read_bytes!` uses, so a large region costs no second buffer.
	RegionResult : {
		err : U8,
		bytes : List(U8),
	}

	## Read a rectangle of a source as row-major, top-down RGBA8 bytes.
	read_region! : RegionProbe => RegionResult

	## Flatten a format to the code the host reads. Shared by the startup config
	## and the runtime effects so the two cannot drift.
	format_code : RrtCapture.Format -> U8
	format_code = |value|
		match value {
			Png => 0
			Gif => 1
			WebM => 2
		}

	## Flatten a timing strategy to the code the host reads.
	timing_code : RrtCapture.Timing -> U8
	timing_code = |value|
		match value {
			RealTime => 0
			FixedStep => 1
		}

	## Flatten a cursor mode to the code the host reads.
	cursor_code : RrtCapture.Cursor -> U8
	cursor_code = |value|
		match value {
			NoCursor => 0
			DrawCursor => 1
		}

	## Flatten an encoder quality to the code the host reads.
	##
	## The host maps these onto whatever knob the chosen encoder actually has --
	## for GIF, msf_gif's palette search depth -- so the numbering here is the
	## only thing the two sides have to agree on.
	quality_code : RrtCapture.Quality -> U8
	quality_code = |value|
		match value {
			Fast => 0
			Balanced => 1
			Best => 2
		}

	## Flatten a scale to the numerator and denominator the host applies.
	##
	## A zero in either position would make the host fall back to the source
	## size, so normalize it here where the intent is still visible.
	scale_ratio : RrtCapture.Scale -> { numerator : U32, denominator : U32 }
	scale_ratio = |value|
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
}

expect CaptureHost.format_code(Png) == 0
expect CaptureHost.format_code(Gif) == 1
expect CaptureHost.format_code(WebM) == 2
expect CaptureHost.timing_code(RealTime) == 0
expect CaptureHost.timing_code(FixedStep) == 1
expect CaptureHost.cursor_code(NoCursor) == 0
expect CaptureHost.cursor_code(DrawCursor) == 1
expect CaptureHost.quality_code(Fast) == 0
expect CaptureHost.quality_code(Balanced) == 1
expect CaptureHost.quality_code(Best) == 2
expect CaptureHost.scale_ratio(Full) == { numerator: 1, denominator: 1 }
expect CaptureHost.scale_ratio(Half) == { numerator: 1, denominator: 2 }
expect CaptureHost.scale_ratio(Quarter) == { numerator: 1, denominator: 4 }
expect CaptureHost.scale_ratio(Ratio({ numerator: 2, denominator: 3 })) == { numerator: 2, denominator: 3 }
expect CaptureHost.scale_ratio(Ratio({ numerator: 1, denominator: 0 })) == { numerator: 1, denominator: 1 }
expect CaptureHost.scale_ratio(Ratio({ numerator: 0, denominator: 4 })) == { numerator: 1, denominator: 1 }
