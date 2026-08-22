## Internal standard-stream transport and hosted effects.
##
## This module is intentionally not exposed by the platform package. Public
## applications use `Stdout` and `Stderr`, which name the stream for the app
## and map these flat primitive codes onto a tag union.
##
## One host function serves both streams: `stream` is the file descriptor
## number, `1` for standard output and `2` for standard error, so the two
## public modules differ only in the number they pass and in what their docs
## call the destination. The decode below is shared for the same reason --
## there is one error table across both streams, and one place is the only way
## to keep it from drifting.
##
## Every effect here waits, so each carries the `during_wait` phase set in
## `src/host_native.zig`. A write to a pipe whose reader is slow or has stopped
## blocks until the pipe drains, which is unbounded in the app's own terms, so
## these park a task on the frame thread's event loop rather than running
## inside `update!` or `render!`.
StdioHost := [].{

	## The file descriptor standard output is written to.
	stdout : U8
	stdout = 1

	## The file descriptor standard error is written to.
	stderr : U8
	stderr = 2

	## Write a string's UTF-8 bytes to one stream. `0` means every byte
	## reached the stream; anything else is a code `write_result` names.
	write_text! : U8, Str => U8

	## Write a string's UTF-8 bytes and then one newline.
	##
	## The newline is appended by the host rather than by the app, so a line is
	## one write rather than two: the string does not have to be copied to grow
	## it, and nothing another thread writes can land between the text and its
	## terminator.
	write_line! : U8, Str => U8

	## Write arbitrary bytes to one stream. Same codes as `write_text!`.
	write_bytes! : U8, List(U8) => U8

	## Turn a write's error code into its terminal outcome.
	##
	## The codes are the ones `src/host_native.zig` uses for every write:
	## `NotFound` cannot happen to a stream that is already open, and
	## `BrokenPipe` is the one failure only a stream can have, so it is
	## numbered past the shared table.
	write_result : U8 -> Try({}, [BrokenPipe, PermissionDenied, NoSpace, TooLarge, WriteFailed, Unavailable])
	write_result = |code|
		if code == 0 {
			Ok({})
		} else if code == 4 {
			Err(Unavailable)
		} else if code == 5 {
			Err(TooLarge)
		} else if code == 8 {
			Err(PermissionDenied)
		} else if code == 9 {
			Err(NoSpace)
		} else if code == 10 {
			Err(BrokenPipe)
		} else {
			Err(WriteFailed)
		}
}

expect StdioHost.write_result(0) == Ok({})
expect StdioHost.write_result(2) == Err(WriteFailed)
expect StdioHost.write_result(4) == Err(Unavailable)
expect StdioHost.write_result(5) == Err(TooLarge)
expect StdioHost.write_result(8) == Err(PermissionDenied)
expect StdioHost.write_result(9) == Err(NoSpace)
expect StdioHost.write_result(10) == Err(BrokenPipe)

## An unknown code is a failure rather than a crash: the host and this table are
## versioned together, but a write that cannot be named is still a write that
## did not happen.
expect StdioHost.write_result(99) == Err(WriteFailed)
