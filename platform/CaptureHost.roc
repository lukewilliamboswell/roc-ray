## Internal capture transport and hosted effects.
##
## This module is intentionally not exposed by the platform package. Public
## applications use `Capture`, which maps these flat primitive codes onto tag
## unions and hides the numbering.
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

	## Live recording state. `status` is idle/active/failed; `err` carries the
	## latched reason when a recording stopped early.
	StatusResult : {
		status : U8,
		err : U8,
		frames : U64,
		dropped : U64,
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

	screenshot! : Str => U8
	set_virtual_mouse! : VirtualMouse => {}
	start_recording! : StartRecording => U8
	stop_recording! : () => StopResult
	recording_status! : () => StatusResult
}
