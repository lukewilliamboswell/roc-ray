## Shared host-owned asset-store value.
##
## The handle is an opaque, reference-counted native resource identity for an
## open, explicitly located directory. Opening a store and resolving assets
## through it remain platform operations; this value lets reusable packages
## retain store identity without importing the platform.
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
