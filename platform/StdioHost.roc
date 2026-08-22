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
## Every effect here is a queued effect, so each carries the `during_update`
## phase set in `src/host_native.zig`. A call copies its payload into a
## host-owned ring and returns; one host thread drains both rings and does the
## blocking writing, so a pipe whose reader is slow or has stopped delays that
## thread rather than a frame or a task.
StdioHost := [].{

	## The file descriptor standard output is written to.
	stdout : U8
	stdout = 1

	## The file descriptor standard error is written to.
	stderr : U8
	stderr = 2

	## Queue a string's UTF-8 bytes for one stream. `0` means every byte was
	## queued; anything else is a code `write_result` names.
	write_text! : U8, Str => U8

	## Queue a string's UTF-8 bytes and then one newline.
	##
	## The newline is appended by the host rather than by the app, so a line is
	## one reservation rather than two: the string does not have to be copied
	## to grow it, and no other write can land between the text and its
	## terminator.
	write_line! : U8, Str => U8

	## Queue arbitrary bytes for one stream. Same codes as `write_text!`.
	write_bytes! : U8, List(U8) => U8

	## Turn a write's error code into its terminal outcome.
	##
	## The codes are the ones `src/stdio_effect.zig` uses. Only the three a
	## caller can act on are named: the queue is full, the payload can never
	## fit, or there is no queue to put it in. What the draining write itself
	## went on to do is not visible from here, so it has no code.
	##
	## An unnamed code is `Unavailable` rather than a crash: the host and this
	## table are versioned together, but a write that cannot be named is still
	## a write the app should not assume arrived.
	write_result : U8 -> Try({}, [BufferFull, TooLarge, Unavailable])
	write_result = |code|
		if code == 0 {
			Ok({})
		} else if code == 5 {
			Err(TooLarge)
		} else if code == 11 {
			Err(BufferFull)
		} else {
			Err(Unavailable)
		}
}

expect StdioHost.write_result(0) == Ok({})
expect StdioHost.write_result(5) == Err(TooLarge)
expect StdioHost.write_result(11) == Err(BufferFull)
expect StdioHost.write_result(4) == Err(Unavailable)

## An unknown code is a refusal rather than a crash, and rather than a success
## the app would go on to depend on.
expect StdioHost.write_result(99) == Err(Unavailable)
