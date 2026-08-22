## Writing to the process's standard error, and the typed outcome of a write.
##
## Standard error is where an app says something went wrong while standard
## output is carrying the answer someone is piping elsewhere, so a diagnostic
## does not corrupt the data stream. Everything else about it -- the bound, the
## phases, the newline, the absence of buffering -- is the same as `Stdout`,
## and the two are deliberately interchangeable at the call site.
##
## These effects wait. Every one of them is legal in `init!`, where it blocks
## startup until the bytes are out, and in tasks, where it parks the task while
## the frame loop keeps drawing. They are refused in `update!` and `render!`,
## with a message naming the effect and the fix. Standard error is usually
## unbuffered and usually a terminal, but it can be redirected into a pipe like
## any other descriptor, so it waits for the same reason `Stdout` does.
##
## ```roc
## Task.spawn!(input, || { _ = Stderr.line!("asset ${name} failed to load"); Reported })
## ```
##
## The compiler's own `dbg`, `expect`, and crash output also goes here, written
## directly by the runtime rather than through this module. Ordering between
## the two is not defined, and this module is the app's channel rather than a
## replacement for either.
import StdioHost

Stderr := [].{

	## Why a write did not reach standard error.
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
	line! = |text| StdioHost.write_result(StdioHost.write_line!(StdioHost.stderr, text))

	## Write a string with no newline after it.
	##
	## Bounded and retried exactly as `line!` is.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	write! : Str => Try({}, WriteError)
	write! = |text| StdioHost.write_result(StdioHost.write_text!(StdioHost.stderr, text))

	## Write bytes that are not necessarily text.
	##
	## The bytes are passed through as they are: no encoding validation, no
	## newline, no translation. Bounded and retried exactly as `line!` is,
	## counting the length of the list.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	write_bytes! : List(U8) => Try({}, WriteError)
	write_bytes! = |bytes| StdioHost.write_result(StdioHost.write_bytes!(StdioHost.stderr, bytes))
}
