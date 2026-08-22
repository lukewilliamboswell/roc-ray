## Writing to the process's standard output, and the typed outcome of a write.
##
## This is how an app that is a step in a pipeline says what it did: a headless
## CI harness reporting what it verified, a batch render naming the frame it is
## on, a benchmark printing the numbers that go with its recording. It is not a
## debugging channel -- `dbg` already goes to standard error from the compiler's
## own runtime -- and it is not a log framework.
##
## These effects wait. Every one of them is legal in `init!`, where it blocks
## startup until the bytes are out, and in tasks, where it parks the task while
## the frame loop keeps drawing. They are refused in `update!` and `render!`,
## with a message naming the effect and the fix. A write to a pipe whose reader
## is slow or has stopped -- `myapp | head -1` -- blocks until the pipe drains,
## and how long that takes is another process's decision, so it is not
## something a frame is allowed to wait on.
##
## Writing from `update!` therefore means spawning a task, and a task answers
## with a message:
##
## ```roc
## update! = |model, input| {
##     if model.finished and !(model.reporting) {
##         Task.spawn!(input, || { _ = Stdout.line!("verified 42 cases"); Reported })
##         Ok({ ..model, reporting: Bool.True })
##     } else if List.contains(input.messages, Reported) {
##         Err(Exit(0))
##     } else {
##         Ok(model)
##     }
## }
## ```
##
## Waiting for `Reported` before exiting is the point of that shape, not
## ceremony. Exiting happens from `update!`, and a task still parked when the
## app exits is cancelled, so an app that spawns its report and returns
## `Err(Exit(0))` in the same `update!` can exit with nothing printed. Spawn,
## let the task come back, then exit.
##
## One write per frame at 60 Hz is 60 syscalls a second, each one parking a
## task; against a pipe with a slow reader those parks become backpressure that
## delays the task's message rather than dropping anything. Per-frame output
## belongs behind a rate limit or a debug flag. Nothing here is buffered, so
## every call is one write and there is nothing to flush; ordering against
## `dbg`, `expect`, and crash output, which the compiler's runtime writes
## directly, is not defined.
import StdioHost

Stdout := [].{

	## Why a write did not reach standard output.
	##
	## `BrokenPipe` is the reader on the other end having gone away, which is
	## an ordinary way for a pipeline to end and not necessarily an error the
	## app should report. `TooLarge` is a payload past the host's per-call
	## ceiling of one mebibyte, and nothing was written. `Unavailable` is the
	## host declining to start the write, which is what a shutdown in progress
	## looks like from inside a task.
	WriteError : [BrokenPipe, PermissionDenied, NoSpace, TooLarge, WriteFailed, Unavailable]

	## Write a string and then a newline.
	##
	## The newline is always a single `\n`, on every platform. The whole line
	## is one write, so nothing else can land between the text and its
	## terminator.
	##
	## At most one mebibyte crosses per call, counting the string's UTF-8 bytes
	## and the newline; a longer string is `TooLarge` and nothing is written. A
	## short write is retried by the host until the payload is out, so a
	## partial write is never reported as success.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	line! : Str => Try({}, WriteError)
	line! = |text| StdioHost.write_result(StdioHost.write_line!(StdioHost.stdout, text))

	## Write a string with no newline after it.
	##
	## Bounded and retried exactly as `line!` is.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	write! : Str => Try({}, WriteError)
	write! = |text| StdioHost.write_result(StdioHost.write_text!(StdioHost.stdout, text))

	## Write bytes that are not necessarily text.
	##
	## The bytes are passed through as they are: no encoding validation, no
	## newline, no translation. Bounded and retried exactly as `line!` is,
	## counting the length of the list.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	write_bytes! : List(U8) => Try({}, WriteError)
	write_bytes! = |bytes| StdioHost.write_result(StdioHost.write_bytes!(StdioHost.stdout, bytes))
}
