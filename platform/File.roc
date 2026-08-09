## Asynchronous file reads and host-owned byte buffers.
##
## `Program.ReadSmallFile` returns a UTF-8 `Str` and is intended for small text
## files. `Program.ReadFile` returns a `Blob`, avoiding a full payload copy onto
## the frame thread. The host rejects files larger than 16 MiB with `TooLarge`.
##
## Use `Program.ReadBlobSlice` to copy and decode a UTF-8 range in `update`, or
## `Blob.byte!` to inspect one byte from an effectful context. Blob storage is
## released automatically after the final Roc reference is dropped.
import FileHost

File := [].{

	## A refcounted handle to bytes the host owns.
	##
	## Copying the handle does not copy the payload. The final reference releases
	## the host allocation.
	Blob :: FileHost.Blob.{

		## Wrap the transport handle. Platform-internal: an app cannot build a
		## `FileHost.Blob`, so it cannot invent a blob.
		from_host : FileHost.Blob -> Blob
		from_host = |raw| Blob.(raw)

		## Unwrap to the transport handle. Platform-internal.
		to_host : Blob -> FileHost.Blob
		to_host = |Blob.(raw)| raw

		## Size in bytes. This does not call into the host.
		len : Blob -> U64
		len = |Blob.(raw)| FileHost.Blob.size(raw)

		## Whether the blob holds no bytes.
		is_empty : Blob -> Bool
		is_empty = |blob| blob.len() == 0

		## Read one byte, copying nothing else.
		## Returns `OutOfBounds` when `offset >= blob.len()`.
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
