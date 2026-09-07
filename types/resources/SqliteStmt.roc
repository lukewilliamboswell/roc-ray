## Shared host-owned SQLite statement value.
##
## The handle is an opaque, reference-counted native resource identity for a
## prepared statement. Preparation, binding, and execution remain platform
## operations; this value lets reusable packages retain statement identity
## without importing the platform.
import Handle

SqliteStmt := { handle : SqliteStmtHandle }.{
	SqliteStmtHandle : Handle([SqliteStmtResource])

	## Resource-free statement value for pure tests.
	##
	## The handle never resolves to a prepared statement. Do not use it to test
	## binding, execution, or resource lifetime.
	stub : SqliteStmt
	stub = { handle: Handle.stub }
}
