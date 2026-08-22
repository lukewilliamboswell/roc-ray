## Internal SQLite transport and hosted effects.
##
## This module is intentionally not exposed by the platform package. Public
## applications use `Sqlite`, which maps these flat records onto tag unions and
## hides the wire encoding.
##
## Every effect here waits, so each carries the `during_wait` phase set in
## `src/host_native.zig`. On a task the host parks the coroutine while the
## query runs on a blocking-pool thread and the frame loop keeps drawing; in
## `init!` the same call blocks while the loop is pumped, which is what opening
## a database at startup wants.
##
## `err` is SQLite's own result code, so `0` is success and everything else is
## a number SQLite defined. The three refusals the host makes on its own behalf
## are negative, which SQLite never returns, so one number never means two
## things across the boundary.
##
## No tag union crosses the boundary, matching `HttpHost` and the
## `InputFromHostCycle` rule in `main.roc`.
##
## One query is one crossing. basic-cli's SQLite reads a column at a time,
## which is affordable when each read is an ordinary function call and ruinous
## here, where each one would be a waiting effect that parks the task: a
## hundred-row, five-column query would park it six hundred times. So a query
## answers with its whole result, and `Sqlite` decodes it.
##
## Rows are encoded rather than delivered as records containing strings.
## `cells` is scalars only and every byte a cell refers to -- column names,
## text, blobs -- lives in one shared `payload` allocation, the same shape
## `FilesHost.list!` uses. That keeps the blocking worker free to fill plain
## host memory with no Roc allocator in reach, and makes the whole result two
## allocations instead of one per string.
SqliteHost := [].{

	## Opaque database connection. The `sqlite3*` is owned by a typed host ARC
	## heap, so a copied Roc value keeps the connection open and the last one
	## released closes it.
	Db :: Box(U64).{

		## The invalid token, as a resource-free handle. See `Sqlite.Db.stub`.
		stub : Db
		stub = Db.(Box.box(0))
	}

	## Opaque prepared statement. Its heap slot retains the connection's, so a
	## statement cannot outlive the database it was prepared against.
	Stmt :: Box(U64).{

		## The invalid token, as a resource-free handle. See `Sqlite.Stmt.stub`.
		stub : Stmt
		stub = Stmt.(Box.box(0))
	}

	## One column of one row, in row-major order, `ncols` to a row.
	##
	## `kind` is SQLite's own column type: `1` integer, `2` real, `3` text,
	## `4` blob, `5` null. `integer` and `real` carry the value for the first
	## two; `start` and `len` locate it in `payload` for the other two. The
	## unused fields are zero, not meaningful.
	Cell : {
		kind : U8,
		integer : I64,
		real : F64,
		start : U64,
		len : U64,
	}

	## One parameter binding, flattened. `kind` uses the same numbering as
	## `Cell.kind`, and only the field that `kind` names is read.
	BindingWire : {
		name : Str,
		kind : U8,
		integer : I64,
		real : F64,
		text : Str,
		blob : List(U8),
	}

	## A connection, or the failure that replaced it. `db` is the invalid
	## handle when `err` is not `0`.
	OpenResult : { err : I64, message : Str, db : Db }

	## A prepared statement, or the failure that replaced it.
	PrepareResult : { err : I64, message : Str, stmt : Stmt }

	## An operation with nothing to hand back but its outcome.
	StatusResult : { err : I64, message : Str }

	## One finished query.
	##
	## `names` holds `ncols` NUL-terminated column names in column order.
	## `cells` holds `ncols * row_count` cells. `payload` is the shared byte
	## buffer that `names`, text cells and blob cells all index into; it is one
	## host allocation and is empty when nothing referred to it.
	##
	## `changes` and `last_insert_rowid` are read after the statement finished,
	## so they describe this statement rather than the connection's history.
	QueryResult : {
		err : I64,
		message : Str,
		names : List(U8),
		ncols : U64,
		row_count : U64,
		cells : List(Cell),
		payload : List(U8),
		changes : I64,
		last_insert_rowid : I64,
	}

	## Open or create a database. `mode` is `0` read/write/create, `1`
	## read/write, `2` read-only.
	open! : Str, U8, U64, U64 => OpenResult

	## Close a connection early. The final handle release closes it anyway;
	## this is for paying a checkpoint at a time the app chooses.
	close! : Db => StatusResult

	## Compile one statement for reuse.
	prepare! : Db, Str => PrepareResult

	## Bind and run a prepared statement to completion, then reset it.
	run_stmt! : Stmt, List(BindingWire) => QueryResult

	## Prepare, bind, run and finalize in one call, without occupying a
	## statement slot.
	run_once! : Db, Str, List(BindingWire) => QueryResult

	## Run every statement in a script. No bindings, and no rows come back.
	exec_script! : Db, Str => StatusResult
}
