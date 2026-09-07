## Private host-owned asset-store value.
##
## Internal typed ARC identity used by platform adapters and the native host.
## Applications use the corresponding public resource API.
import Handle

Store := { handle : StoreHandle }.{
	StoreHandle : Handle([StoreResource])

	## Resource-free store value for pure tests.
	##
	## The handle never resolves to an open directory, so every load made
	## through it fails the way a load through a released store does. Do not use
	## it to test asset resolution, manifest validation, or resource lifetime.
	stub : Store
	stub = { handle: Handle.stub }
}
