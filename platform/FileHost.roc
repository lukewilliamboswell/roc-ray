## Internal blob transport and hosted effects.
##
## This module is intentionally not exposed by the platform package. Public
## applications use `File.Blob`; the handle below is the scalar the host ABI
## actually carries, kept opaque so an app cannot invent one.
FileHost := [].{

	## A host-owned byte buffer, named by a scalar the host can validate.
	##
	## `handle` packs a slot index, a generation, and a resource kind, so a
	## handle whose slot has been released and reused resolves to nothing rather
	## than to whatever took its place. `byte_len` travels beside it so asking a
	## blob how big it is costs no host call at all.
	Blob :: { handle : U64, byte_len : U64 }.{

		## Wrap what the host sent. Platform-internal.
		from_raw : { handle : U64, byte_len : U64 } -> Blob
		from_raw = |raw| Blob.(raw)

		## The scalar the host validates.
		token : Blob -> U64
		token = |Blob.(raw)| raw.handle

		## Size in bytes, as reported when the blob was installed.
		size : Blob -> U64
		size = |Blob.(raw)| raw.byte_len
	}

	## Outcome of reading one byte of a blob. `err` is `0` when `byte` is it.
	ByteResult : {
		err : U8,
		byte : U8,
	}

	## Read a single byte without copying the rest.
	blob_byte! : { handle : U64, offset : U64 } => ByteResult

	## Free the buffer a handle names. Releasing an already-released handle is
	## not an error; it finds a stale token, exactly as any other use would.
	release_blob! : U64 => {}
}
