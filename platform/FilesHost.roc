## Internal filesystem transport and hosted effects.
##
## This module is intentionally not exposed by the platform package. Public
## applications use `Files`, which maps these flat primitive codes onto tag
## unions and hides the numbering.
##
## Every effect here waits, so each carries the `during_wait` phase set in
## `src/host_native.zig`. On a task the host parks the coroutine on its event
## loop and the frame loop keeps running; in `init!` the same call blocks while
## the loop is pumped, which is what startup asset loading wants.
##
## Reads answer with a record because they carry a payload; writes answer with
## a bare error code because there is nothing to hand back but the outcome.
FilesHost := [].{

	## A finished text read. `contents` is the file when `err` is `0`, and an
	## empty string otherwise.
	TextResult : {
		err : U8,
		contents : Str,
	}

	## A finished byte read, or one encoded directory listing. `bytes` is the
	## payload when `err` is `0`, and empty otherwise.
	##
	## The list owns the host's own allocation rather than a copy of it: the
	## read fills native memory and that allocation moves into Roc list ARC.
	BytesResult : {
		err : U8,
		bytes : List(U8),
	}

	## Read a bounded UTF-8 file. The host validates the encoding, so a file
	## that is not text is reported rather than delivered as an invalid `Str`.
	read_text! : Str => TextResult

	## Read a bounded file as bytes, without copying its payload.
	read_bytes! : Str => BytesResult

	## List one directory into the encoded form `Files` decodes.
	list! : Str => BytesResult

	## Replace a file's contents with this UTF-8 string. `0` means the file is
	## on disk; anything else is a `WRITE_ERR_*` code `Files` names.
	write_text! : Str, Str => U8

	## Replace a file's contents with these bytes. Same codes as `write_text!`.
	write_bytes! : Str, List(U8) => U8
}
