## Shared identity for host-owned resources.
##
## A handle is an opaque, reference-counted token whose phantom resource type
## keeps unrelated host resources distinct without changing their runtime
## representation. Only the host can manufacture a live handle.
Handle(_resource) :: Box(U64).{
	is_eq : Handle(_resource), Handle(_resource) -> Bool
	is_eq = |Handle.(a), Handle.(b)| Box.unbox(a) == Box.unbox(b)

	to_hash : Handle(_resource), Hasher -> Hasher
	to_hash = |Handle.(value), hasher| U64.to_hash(Box.unbox(value), hasher)

	## Resource-free handle for pure tests.
	##
	## This value never resolves to a host resource. Resource modules use it to
	## construct their documented test stubs; it must not be used to test host
	## operations or resource lifetime.
	stub : Handle(_resource)
	stub = Handle.(Box.box(U64.highest))
}
