## File module - reading a file without paying for it on the frame thread.
##
## There are two ways to read a file, and the difference is what the answer
## costs rather than how it is spelled.
##
## `ReadSmallFile` answers with a `Str`. Building that string is a copy, and it
## happens on the frame thread while the host is draining finished work, so the
## host caps it -- past the cap the read comes back as `TooLarge`. It is the
## right call for a config file or a saved game, and it is honest about being
## the wrong one for anything big.
##
## `ReadFile` answers with a `Blob`: a small handle to bytes the *host* owns.
## The worker allocated and filled that memory off-thread, and completing the
## read installs the allocation into a host slot -- no copy, and nothing
## proportional to the file happens during the frame. The bytes stay host-side
## until the app asks for some of them, which is what makes every copy in this
## module something the app wrote down.
##
## Getting bytes out of a blob is a `ReadBlobSlice` task, not an effect. There
## is no `to_str!` to reach for, and that is the point: an effect that copies
## can only be called from `render!`, so an app that wanted a string ended up
## copying and UTF-8-scanning the same range on every frame that drew it, for a
## value that changed once. As a task the copy happens once, on the step the
## range was asked for, and `update` puts the result in the model.
##
## There is still a ceiling, and it is worth stating rather than implying: the
## host will not read a file larger than **16 MiB** at all, and a bigger one
## comes back as `TooLarge`. What a blob removes is the cost of the bytes
## crossing into Roc, not an unbounded appetite for them.
##
## A blob is released by hand -- `File.Blob.release` as an action, or
## `release!` inside an effectful function. A handle is a plain scalar that Roc
## copies and drops without telling the host, so nothing else could drive it. A
## blob the app never releases is freed at shutdown rather than lost, and using
## a handle after it is released fails with `Released` rather than reading freed
## memory.
import FileHost

File := [].{

	## An opaque handle to bytes the host owns.
	##
	## Deliberately not the bytes. Copying it copies a couple of words no matter
	## how large the file was, so it can sit in a model, be passed around, and be
	## matched on without the payload ever moving.
	##
	## A handle is not a capability the host trusts: it carries the slot it names
	## *and* the generation of that slot, so a handle kept past its release
	## resolves to nothing even after the slot has been handed to another read.
	Blob :: FileHost.Blob.{

		## Wrap the transport handle. Platform-internal: an app cannot build a
		## `FileHost.Blob`, so it cannot invent a blob.
		from_host : FileHost.Blob -> Blob
		from_host = |raw| Blob.(raw)

		## Unwrap to the transport handle. Platform-internal, and useless
		## outside the platform: `FileHost` is not exposed, so an app can hold
		## the result and do nothing with it. This exists so `Program` can
		## flatten a blob into a task without the scalar handle appearing in a
		## public type, which is what stops an app hand-assembling one.
		to_host : Blob -> FileHost.Blob
		to_host = |Blob.(raw)| raw

		## Size in bytes. Free: the length arrived with the handle, so this is a
		## field read and not a call into the host.
		len : Blob -> U64
		len = |Blob.(raw)| FileHost.Blob.size(raw)

		## Whether the blob holds no bytes.
		is_empty : Blob -> Bool
		is_empty = |blob| blob.len() == 0

		## Read one byte, copying nothing else.
		byte! : Blob, U64 => Try(U8, [OutOfBounds, Released])
		byte! = |Blob.(raw), offset| {
			result = FileHost.blob_byte!({ handle: FileHost.Blob.token(raw), offset: offset })
			if result.err == 0 {
				Ok(result.byte)
			} else if result.err == err_out_of_bounds {
				Err(OutOfBounds)
			} else {
				Err(Released)
			}
		}

		## Free the host's copy of these bytes, as an action a pure `update` can
		## return. Receiver form: `blob.release()`.
		##
		## An action rather than a task because there is nothing to report: the
		## memory is gone by the time the cycle ends, and a completion carrying
		## "yes, really" would only be something else to correlate.
		release : Blob -> [ReleaseBlob(Blob), ..]
		release = |blob| ReleaseBlob(blob)

		## Free the host's copy of these bytes from inside an effectful function.
		##
		## Releasing twice is harmless: the second call finds a stale handle,
		## which is what any other use of it would find too.
		release! : Blob => {}
		release! = |Blob.(raw)| FileHost.release_blob!(FileHost.Blob.token(raw))
	}
}

## Code for a handle that names no live buffer. Mirrored in `src/host_native.zig`.
err_released : U8
err_released = 1

## Code for a range that runs past the end. Mirrored in `src/host_native.zig`.
err_out_of_bounds : U8
err_out_of_bounds = 2
