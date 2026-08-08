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
## read installs the allocation into a host slot -- no copy, no size limit, and
## nothing proportional to the file happens during the frame. The bytes stay
## host-side until the app asks for some of them, which is what makes every copy
## in this module something the app wrote down.
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

		## Size in bytes. Free: the length arrived with the handle, so this is a
		## field read and not a call into the host.
		len : Blob -> U64
		len = |Blob.(raw)| FileHost.Blob.size(raw)

		## Whether the blob holds no bytes.
		is_empty : Blob -> Bool
		is_empty = |blob| blob.len() == 0

		## Copy the whole blob into a string.
		##
		## The explicit copy, and the only one this module makes without being
		## given a range. It costs `len` bytes on the calling thread, which is
		## why it refuses with `TooLarge` above the host's copy limit -- the same
		## limit `ReadSmallFile` is capped at, because it is the same cost. Walk
		## a large blob with `slice_to_str!` instead.
		##
		## `NotUtf8` is not a formality: a blob is bytes, and a `Str` is not.
		to_str! : Blob => Try(Str, [NotUtf8, TooLarge, Released])
		to_str! = |Blob.(raw)| {
			result = FileHost.blob_slice!({
				handle: FileHost.Blob.token(raw),
				offset: 0,
				count: FileHost.Blob.size(raw),
			})
			if result.err == 0 Ok(result.contents) else Err(copy_error(result.err))
		}

		## Copy `count` bytes starting at `offset` into a string.
		##
		## The bounded form, for reading a header, showing a preview, or walking
		## a large blob a chunk at a time. A range that runs past the end is
		## `OutOfBounds` rather than being silently clamped: a short read that
		## looks like a complete one is worse than a refusal.
		slice_to_str! : Blob, { offset : U64, count : U64 } => Try(Str, [NotUtf8, TooLarge, OutOfBounds, Released])
		slice_to_str! = |Blob.(raw), range| {
			result = FileHost.blob_slice!({
				handle: FileHost.Blob.token(raw),
				offset: range.offset,
				count: range.count,
			})
			if result.err == 0 Ok(result.contents) else Err(slice_error(result.err))
		}

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

## Decode the host's copy-error code for a whole-blob copy. A blob that no
## longer names bytes is `Released` however the host phrased it.
copy_error : U8 -> [NotUtf8, TooLarge, Released]
copy_error = |code|
	if code == err_not_utf8 {
		NotUtf8
	} else if code == err_too_large {
		TooLarge
	} else {
		Released
	}

## Decode the host's copy-error code for a ranged copy.
slice_error : U8 -> [NotUtf8, TooLarge, OutOfBounds, Released]
slice_error = |code|
	if code == err_not_utf8 {
		NotUtf8
	} else if code == err_too_large {
		TooLarge
	} else if code == err_out_of_bounds {
		OutOfBounds
	} else {
		Released
	}

## Code for a handle that names no live buffer. Mirrored in `src/host_native.zig`.
err_released : U8
err_released = 1

## Code for a range that runs past the end. Mirrored in `src/host_native.zig`.
err_out_of_bounds : U8
err_out_of_bounds = 2

## Code for bytes that are not valid UTF-8. Mirrored in `src/host_native.zig`.
err_not_utf8 : U8
err_not_utf8 = 3

## Code for a copy larger than the host will make in one go. Mirrored in
## `src/host_native.zig`.
err_too_large : U8
err_too_large = 4

expect copy_error(err_not_utf8) == NotUtf8
expect copy_error(err_too_large) == TooLarge
expect copy_error(err_released) == Released
expect slice_error(err_out_of_bounds) == OutOfBounds
expect slice_error(err_not_utf8) == NotUtf8
expect slice_error(err_released) == Released
