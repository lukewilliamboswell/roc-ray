## Internal blob transport and hosted effects.
##
## This module is intentionally not exposed by the platform package. Public
## applications use `File.Blob`; the boxed resource below is what the host ABI
## actually carries, kept opaque so an app cannot invent one.
FileHost := [].{

	## A host-owned byte buffer, named by a box the host allocated.
	##
	## The box refcount owns the blob lifetime. The host installs one reference
	## when a read finishes, and `roc_dealloc` releases the slot after the final
	## reference is dropped.
	##
	## `handle` inside it packs a slot index, a generation and a resource kind,
	## so the host can validate a box that reached it through the ABI rather
	## than trusting a pointer. `byte_len` travels beside it so asking a blob
	## how big it is costs no host call at all.
	Blob :: { resource : Box({ handle : U64, byte_len : U64 }) }.{

		## Wrap what the host sent. Platform-internal.
		from_resource : Box({ handle : U64, byte_len : U64 }) -> Blob
		from_resource = |resource| { resource: resource }

		## The scalar the host validates.
		token : Blob -> U64
		token = |blob| (Box.unbox(blob.resource)).handle

		## Size in bytes, as reported when the blob was installed.
		size : Blob -> U64
		size = |blob| (Box.unbox(blob.resource)).byte_len
	}

	## Outcome of reading one byte of a blob. `err` is `0` when `byte` is it.
	ByteResult : {
		err : U8,
		byte : U8,
	}

	## Read a single byte without copying the rest.
	##
	## Takes the whole blob rather than its token: the argument is what keeps
	## the box alive across the call, and a bare `U64` would let Roc drop the
	## last reference before the host had read the bytes it names.
	blob_byte! : { blob : Blob, offset : U64 } => ByteResult
}
