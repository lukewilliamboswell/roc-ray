## Shared host-owned SQLite connection value.
##
## The handle is an opaque, reference-counted native resource identity for an
## open database connection. Opening, preparing, and closing remain platform
## operations; this value lets reusable packages retain connection identity
## without importing the platform.
import Handle

SqliteDb := { handle : SqliteDbHandle }.{
	SqliteDbHandle : Handle([SqliteDbResource])

	## Resource-free connection value for pure tests.
	##
	## The handle never resolves to an open database. Do not use it to test
	## opening, statement preparation, or resource lifetime.
	stub : SqliteDb
	stub = { handle: Handle.stub }
}
