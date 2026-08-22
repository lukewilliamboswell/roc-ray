## Writing to the process's standard output, and the typed outcome of a write.
##
## This is how an app that is a step in a pipeline says what it did: a headless
## CI harness reporting what it verified, a batch render naming the frame it is
## on, a benchmark printing the numbers that go with its recording. It is not a
## debugging channel -- `dbg` already goes to standard error from the compiler's
## own runtime -- and it is not a log framework.
##
## These effects are queued. A call copies the bytes into a host-owned queue and
## returns; one host thread drains that queue and does the writing. A pipe whose
## reader is slow or has stopped -- `myapp | head -1` -- delays that thread and
## nothing else, which is why a write does not have to wait and does not have to
## be a task. Every one of them is legal in `init!`, in `update!`, and in tasks;
## they are refused in `render!`, with a message naming the effect and the fix,
## because a frame only draws.
##
## So printing is written where the app decides to print, including in the same
## `update!` that exits:
##
## ```roc
## update! = |model, _input| {
##     if model.finished {
##         _ = Stdout.line!("verified 42 cases")
##         Err(Exit(0))
##     } else {
##         Ok(model)
##     }
## }
## ```
##
## That works because the host drains what is queued before the process exits.
## The drain is bounded by the queue, so an app is never waiting on an unbounded
## amount of output at shutdown.
##
## The queue holds 256 kibibytes, which is also the largest a single payload can
## be. A payload past that is `TooLarge` and can never be queued. A payload that
## does not fit in what is free right now is `BufferFull`, with nothing queued:
## a write is all-or-nothing, so a refusal never leaves half a line in the pipe.
## One write per frame at 60 Hz against a reader keeping up costs nothing, and
## against a reader that has stalled it shows up as `BufferFull` rather than as
## a dropped frame -- an app can count those, report them, or ignore them, but
## it is told. Nothing here is buffered by the app's own runtime, so there is
## nothing to flush; ordering against `dbg`, `expect`, and crash output, which
## the compiler's runtime writes directly, is not defined.
##
## What the drained write itself went on to do is not visible from the call: a
## queued effect answers whether the bytes were accepted, not whether they were
## delivered. An app that must act on the delivery uses a file write from a
## task, which does wait and does report.
import StdioHost

Stdout := [].{

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
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	##
	## The newline is always a single `\n`, on every platform. The text and its
	## terminator are queued together, so nothing else can land between them. At
	## most 256 kibibytes cross per call, counting the string's UTF-8 bytes and
	## the newline; a longer string is `TooLarge` and nothing is queued.
	line! : Str => Try({}, WriteError)
	line! = |text| StdioHost.write_result(StdioHost.write_line!(StdioHost.stdout, text))

	## Write a string with no newline after it. Bounded exactly as `line!` is.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	write! : Str => Try({}, WriteError)
	write! = |text| StdioHost.write_result(StdioHost.write_text!(StdioHost.stdout, text))

	## Write bytes that are not necessarily text.
	##
	## Legal in `init!`, `update!`, and tasks; refused in `render!`.
	##
	## The bytes are passed through as they are: no encoding validation, no
	## newline, no translation. Bounded exactly as `line!` is, counting the length
	## of the list.
	write_bytes! : List(U8) => Try({}, WriteError)
	write_bytes! = |bytes| StdioHost.write_result(StdioHost.write_bytes!(StdioHost.stdout, bytes))
}
