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
## A blob is freed when the app stops holding it, and there is nothing to call.
## It is an ordinary refcounted Roc value that happens to have a file behind it:
## drop it from the model and the host frees the bytes, keep two copies and the
## bytes outlive the first one. That is the whole lifetime story -- there is no
## `release`, so there is no way to invalidate a copy someone else is still
## using, and no way to leak one by forgetting.
import FileHost

File := [].{

	## A refcounted handle to bytes the host owns.
	##
	## Deliberately not the bytes. Copying it copies one word no matter how
	## large the file was, so it can sit in a model, be passed around, and be
	## matched on without the payload ever moving. What it does share with the
	## bytes is a lifetime: the last copy to go is what frees them.
	Blob :: FileHost.Blob.{

		## Wrap the transport handle. Platform-internal: an app cannot build a
		## `FileHost.Blob`, so it cannot invent a blob.
		from_host : FileHost.Blob -> Blob
		from_host = |raw| Blob.(raw)

		## Unwrap to the transport handle. Platform-internal, and useless
		## outside the platform: `FileHost` is not exposed, so an app can hold
		## the result and do nothing with it. This exists so `Program` can pass
		## a blob to the host without the boxed resource appearing in a public
		## type, which is what stops an app hand-assembling one.
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
		##
		## `OutOfBounds` is the only way this fails. The bytes cannot have gone
		## anywhere: holding the `Blob` to call this on is what keeps them.
		byte! : Blob, U64 => Try(U8, [OutOfBounds])
		byte! = |blob, offset| {
			result = FileHost.blob_byte!({ blob: blob.to_host(), offset: offset })
			if result.err == 0 {
				Ok(result.byte)
			} else {
				Err(OutOfBounds)
			}
		}
	}
}
