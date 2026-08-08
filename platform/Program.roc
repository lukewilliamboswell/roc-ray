## Program module - the shape of a message-driven application.
##
## The host hands `update!` one `Step` per cycle: everything it observed since
## the last one, gathered into a single value. `update!` returns the next model
## plus a list of `Command`s describing work it wants done. Slow work runs on a
## host worker and comes back as a `Completion` on a later `Step`, so a read
## never stalls a frame.
##
## One `Step` per cycle, rather than one call per event, is deliberate. Each
## call crosses the ABI and boxes and unboxes the model, which Roc treats as
## expensive; batching makes that a fixed cost per rendered frame instead of one
## that grows with how much happened. It also means a command cannot complete
## re-entrantly inside the very `update!` that issued it.
##
## Roc still only ever runs on one thread. The host owns whatever concurrency
## exists, and `Box(Model)` is never shared.
import Host

Program := [].{

	## Everything the host observed since the previous cycle.
	##
	## `completed` is bounded per step, so a burst of finished work cannot
	## consume a whole frame; the remainder arrives on the next one. It is empty
	## on an ordinary frame, which is the case that has to stay cheap.
	Step : {
		input : Host,
		time : Time,
		completed : List(Completion),
	}

	## When this cycle happened, and how much time it covers.
	Time : {
		frame_count : U64,
		timestamp_nanos : U64,
		elapsed_seconds : F32,
	}

	## What `update!` returns: the next model, plus work for the host.
	Next(model) : {
		model : model,
		commands : List(Command),
	}

	## A command that finished, carrying the result its own operation can
	## actually produce.
	##
	## Deliberately not a shared bag of possible values: that let a read report a
	## payload a timer could never have, and made one error case unreachable in
	## practice. It gets worse, not better, once HTTP and SQLite exist.
	Completion : [
		SmallFileRead({ id : U64, result : Try(Str, ReadError) }),
		DelayElapsed({ id : U64 }),
	]

	## Why a read produced no contents.
	##
	## `Busy` and `Unavailable` are refusals rather than failures: the host
	## declined to start the work, so nothing was read and, importantly, nothing
	## ran on the frame thread instead. Every accepted command still yields
	## exactly one completion.
	ReadError : [
		NotFound,
		ReadFailed,
		Busy,
		Unavailable,
		TooLarge,
	]

	## Work for the host to do. Returning one never blocks.
	##
	## `ReadSmallFile` is named for what it is: the answer is delivered as a Roc
	## string, and the frame thread will not copy an unbounded one, so anything
	## past the host's limit comes back as `TooLarge`. A general file API needs
	## a host-owned handle instead, which is a separate operation.
	Command : [
		ReadSmallFile({ id : U64, path : Str }),
		Delay({ id : U64, millis : U64 }),
	]

	## The flat record a `Command` becomes on the way out to the host.
	##
	## Unions do not cross the host boundary in this platform; every effect
	## flattens to scalars behind a `U8` tag first.
	CommandToHost : {
		kind : U8,
		id : U64,
		path : Str,
		millis : U64,
	}

	## The flat record one completion arrives in.
	CompletionFromHost : {
		kind : U8,
		id : U64,
		err : U8,
		contents : Str,
	}

	## Flatten a `Command` for the host.
	to_host : Command -> CommandToHost
	to_host = |command|
		match command {
			ReadSmallFile(request) => { kind: cmd_read_small_file, id: request.id, path: request.path, millis: 0 }
			Delay(request) => { kind: cmd_delay, id: request.id, path: "", millis: request.millis }
		}

	## Rebuild a `Completion` from the host's flat record.
	##
	## The host and the app are built together, so an unrecognised kind is not a
	## newer host talking to an older app -- it is transport that disagrees with
	## itself. Reinterpreting it as an elapsed delay would invent a timer nobody
	## asked for, so this refuses loudly instead.
	completion_from_host : CompletionFromHost -> Completion
	completion_from_host = |raw|
		if raw.kind == completion_small_file_read {
			SmallFileRead({
				id: raw.id,
				result: if raw.err == 0 Ok(raw.contents) else Err(read_error(raw.err)),
			})
		} else if raw.kind == completion_delay {
			DelayElapsed({ id: raw.id })
		} else {
			crash "roc-ray: host sent an unknown completion kind"
		}
}

## `kind` code for a finished small-file read. Mirrored in `src/host_native.zig`.
completion_small_file_read : U8
completion_small_file_read = 0

## `kind` code for an elapsed delay. Mirrored in `src/host_native.zig`.
completion_delay : U8
completion_delay = 1

## `kind` code for a small-file read command. Mirrored in `src/host_native.zig`.
cmd_read_small_file : U8
cmd_read_small_file = 0

## `kind` code for a delay command. Mirrored in `src/host_native.zig`.
cmd_delay : U8
cmd_delay = 1

## Decode the host's read-error code. Mirrored in `src/host_native.zig`.
read_error : U8 -> Program.ReadError
read_error = |code|
	if code == 1 {
		NotFound
	} else if code == 3 {
		Busy
	} else if code == 4 {
		Unavailable
	} else if code == 5 {
		TooLarge
	} else {
		ReadFailed
	}

expect Program.to_host(ReadSmallFile({ id: 7, path: "data.txt" })) == { kind: 0, id: 7, path: "data.txt", millis: 0 }
expect Program.to_host(Delay({ id: 9, millis: 250 })) == { kind: 1, id: 9, path: "", millis: 250 }
expect Program.completion_from_host({ kind: 0, id: 3, err: 0, contents: "hi" }) == SmallFileRead({ id: 3, result: Ok("hi") })
expect Program.completion_from_host({ kind: 0, id: 3, err: 1, contents: "" }) == SmallFileRead({ id: 3, result: Err(NotFound) })
expect Program.completion_from_host({ kind: 0, id: 3, err: 3, contents: "" }) == SmallFileRead({ id: 3, result: Err(Busy) })
expect Program.completion_from_host({ kind: 1, id: 5, err: 0, contents: "" }) == DelayElapsed({ id: 5 })
