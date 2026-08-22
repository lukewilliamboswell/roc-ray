## Writing to the process's standard error, and the typed outcome of a write.
##
## Standard error is where an app says something went wrong while standard
## output is carrying the answer someone is piping elsewhere, so a diagnostic
## does not corrupt the data stream. Everything else about it -- the bound, the
## phases, the newline, the absence of buffering -- is the same as `Stdout`,
## and the two are deliberately interchangeable at the call site.
##
## These effects are queued. A call copies the bytes into a host-owned queue of
## its own -- the two streams do not share one -- and returns; one host thread
## drains both queues and does the writing. Every one of them is legal in
## `init!`, in `update!`, and in tasks; they are refused in `render!`, with a
## message naming the effect and the fix. Standard error is usually unbuffered
## and usually a terminal, but it can be redirected into a pipe like any other
## descriptor, and the queue is what keeps that off the frame thread:
##
## ```roc
## update! = |model, _input| {
##     if model.asset_failed {
##         _ = Stderr.line!("asset ${model.asset_name} failed to load")
##         Err(Exit(1))
##     } else {
##         Ok(model)
##     }
## }
## ```
##
## The queue holds 256 kibibytes, which is also the largest a single payload can
## be. A payload past that is `TooLarge`; one that does not fit right now is
## `BufferFull` with nothing queued, so a refusal never leaves half a line in
## the pipe. What is queued when the app exits is drained before the process
## does, so a diagnostic written in the same `update!` that returns
## `Err(Exit(1))` still reaches the terminal.
##
## The compiler's own `dbg`, `expect`, and crash output also goes here, written
## directly by the runtime rather than through this module. Ordering between
## the two is not defined, and this module is the app's channel rather than a
## replacement for either.
import StdioHost

Stderr := [].{

	## Why a write was not queued.
	##
	## `BufferFull` is the queue having no room for this payload right now, and
	## nothing was queued; the drainer is behind, and the same call may succeed
	## a moment later. `TooLarge` is a payload bigger than the whole queue,
	## which no amount of draining will ever fit. `Unavailable` is there being
	## no queue to write into: the reader on the other end has gone away, which
	## is an ordinary way for a pipeline to end, or the host is shutting down.
	WriteError : [BufferFull, TooLarge, Unavailable]

	## Write a string and then a newline.
	##
	## The newline is always a single `\n`, on every platform. The text and its
	## terminator are queued together, so nothing else can land between them.
	##
	## At most 256 kibibytes cross per call, counting the string's UTF-8 bytes
	## and the newline; a longer string is `TooLarge` and nothing is queued.
	##
	## Legal in `init!`, in `update!`, and in tasks; refused in `render!`.
	line! : Str => Try({}, WriteError)
	line! = |text| StdioHost.write_result(StdioHost.write_line!(StdioHost.stderr, text))

	## Write a string with no newline after it.
	##
	## Bounded exactly as `line!` is.
	##
	## Legal in `init!`, in `update!`, and in tasks; refused in `render!`.
	write! : Str => Try({}, WriteError)
	write! = |text| StdioHost.write_result(StdioHost.write_text!(StdioHost.stderr, text))

	## Write bytes that are not necessarily text.
	##
	## The bytes are passed through as they are: no encoding validation, no
	## newline, no translation. Bounded exactly as `line!` is, counting the
	## length of the list.
	##
	## Legal in `init!`, in `update!`, and in tasks; refused in `render!`.
	write_bytes! : List(U8) => Try({}, WriteError)
	write_bytes! = |bytes| StdioHost.write_result(StdioHost.write_bytes!(StdioHost.stderr, bytes))
}
