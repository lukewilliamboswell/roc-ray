## Queued writes to standard output.
##
## Each call copies one complete payload into a 256-KiB host-owned queue and
## returns immediately. Writes are legal in `init!`, `update!`, and tasks, and
## refused in `render!`.
##
## A payload larger than the queue returns `TooLarge`; insufficient free space
## returns `BufferFull`. Nothing is partially queued. Accepted writes preserve
## order and are drained during orderly shutdown, but eventual delivery is not
## reported. Ordering against `dbg`, `expect`, and crash output is undefined.
import Host
import Resource

Stdout := [].{

	## Why a write to standard output was not queued. This is this module's
	## own `WriteError`; `Files` declares a different one under the same
	## name, for the different things a file write can refuse.
	##
	## `BufferFull` is the queue having no room for this payload right now, and
	## nothing was queued; the drainer is behind, and the same call may succeed
	## a moment later. `TooLarge` is a payload bigger than the whole queue,
	## which no amount of draining will ever fit. `Unavailable` is there being
	## no queue to write into: the reader on the other end has gone away, which
	## is an ordinary way for a pipeline to end, or the host is shutting down.
	WriteError : [PermissionDenied, BufferFull, TooLarge, Unavailable]

	## Opaque stdout authority supplied by App.Io. Effects return PermissionDenied when external access is disabled.
	Writer :: Resource.Authority.{

		## Private platform construction; no application can manufacture the argument.
		for_host : Resource.Authority -> Writer
		for_host = |authority| Writer.(authority)

		## Write a string and then a newline.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		##
		## The newline is always a single `\n`, on every platform. The text and its
		## terminator are queued together, so nothing else can land between them. At
		## most 256 kibibytes cross per call, counting the string's UTF-8 bytes and
		## the newline; a longer string is `TooLarge` and nothing is queued.
		line! : Writer, Str => Try({}, WriteError)
		line! = |Writer.(authority), text| perform_line!(authority, text)

		## Write a string with no newline after it. Bounded exactly as `line!` is.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		write! : Writer, Str => Try({}, WriteError)
		write! = |Writer.(authority), text| perform_write!(authority, text)

		## Write bytes that are not necessarily text.
		##
		## Legal in `init!`, `update!`, and tasks; refused in `render!`.
		##
		## The bytes are passed through as they are: no encoding validation, no
		## newline, no translation. Bounded exactly as `line!` is, counting the length
		## of the list.
		write_bytes! : Writer, List(U8) => Try({}, WriteError)
		write_bytes! = |Writer.(authority), bytes| perform_write_bytes!(authority, bytes)

	}

}

## Re-lift a queued write's closed error union onto the open one this module
## exposes.
lifted : Try({}, Host.StdioWriteError) -> Try({}, WriteError)
lifted = |result|
	match result {
		Ok({}) => Ok({})
		Err(PermissionDenied) => Err(PermissionDenied)
		Err(BufferFull) => Err(BufferFull)
		Err(TooLarge) => Err(TooLarge)
		Err(Unavailable) => Err(Unavailable)
	}

## Private authority-taking implementations.
perform_line! : Resource.Authority, Str => Try({}, Stdout.WriteError)
perform_line! = |authority, text| lifted(Host.stdio_write_line!(authority, 1, text))

perform_write! : Resource.Authority, Str => Try({}, Stdout.WriteError)
perform_write! = |authority, text| lifted(Host.stdio_write_text!(authority, 1, text))

perform_write_bytes! : Resource.Authority, List(U8) => Try({}, Stdout.WriteError)
perform_write_bytes! = |authority, bytes| lifted(Host.stdio_write_bytes!(authority, 1, bytes))
