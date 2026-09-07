## Private host-owned SQLite statement value.
##
## Internal typed ARC identity used by platform adapters and the native host.
## Applications use the corresponding public resource API.
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
