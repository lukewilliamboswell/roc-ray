## Internal capture transport and hosted effects.
##
## This module is intentionally not exposed by the platform package. Public
## applications use `Capture`, which maps these flat primitive codes onto tag
## unions and hides the numbering.
import Draw

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
}
