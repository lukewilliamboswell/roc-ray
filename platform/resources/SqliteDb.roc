## Private host-owned SQLite connection value.
##
## Internal typed ARC identity used by platform adapters and the native host.
## Applications use the corresponding public resource API.
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
