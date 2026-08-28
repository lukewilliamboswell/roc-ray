## SQLite connections, prepared statements, queries, and typed outcomes.
##
## All database effects wait. They are legal in `init!`, where they block
## startup, and in tasks, where they park the task. They are refused in
## `update!` and `render!`.
##
## Use the free `query!` and `execute!` functions for one-off SQL. Retain a
## prepared `Stmt` when reusing the same query or command. Transactions use
## explicit `BEGIN`, `COMMIT`, and `ROLLBACK` SQL.
##
## `Db` and `Stmt` are reference-counted host resources. Final release closes
## them automatically; `Db.close!` provides deliberate early closure. Paths
## are resolved from the process working directory and are not sandboxed.
## `":memory:"` creates a private in-memory database.
##
## At most eight connections and sixty-four statements may be open. Queries
## refuse results above one million cells or `Config.max_result_bytes` rather
## than truncating them. The default byte limit is sixteen megabytes.
import Host

Sqlite := [].{

	## A value stored in, or read out of, a database column.
	Value : [
		Null,
		Integer(I64),
		Real(F64),
		String(Str),
		Bytes(List(U8)),
	]

	## The five things a `Value` can be, without the payload. Reported by
	## `UnexpectedType` when a column held something other than what a decoder
	## asked for.
	ValueKind : [Null, Integer, Real, String, Bytes]

	## A named parameter binding. `name` includes SQLite's parameter prefix, so
	## `{ name: ":id", value: Integer(42) }` binds `:id`.
	##
	## A binding whose name the statement does not mention is a
	## `SqliteErr(OutOfRange, _)` rather than a silent no-op: a typo in a
	## parameter name would otherwise run the query with a NULL nobody asked
	## for.
	Binding : { name : Str, value : Value }

	## SQLite's own result codes.
	##
	## Extended result codes are reduced to the primary code they extend, so a
	## `UNIQUE` violation is `Constraint` rather than a number an app would have
	## to know. The accompanying `Str` carries SQLite's message, which is where
	## the detail went.
	##
	## `Interrupt` is what shutdown looks like from inside a query. Rather than
	## making the window wait for a long statement to finish, the host
	## interrupts every connection with work in flight, and each of those calls
	## answers `SqliteErr(Interrupt, _)`. A task that treats it as a database
	## failure will report one on the way out; a task that is about to be
	## cancelled anyway has nothing to report.
	ErrCode : [
		Error,
		Internal,
		Perm,
		Abort,
		Busy,
		Locked,
		NoMem,
		ReadOnly,
		Interrupt,
		IOErr,
		Corrupt,
		NotFound,
		Full,
		CanNotOpen,
		Protocol,
		Empty,
		Schema,
		TooBig,
		Constraint,
		Mismatch,
		Misuse,
		NoLFS,
		AuthDenied,
		Format,
		OutOfRange,
		NotADatabase,
		Notice,
		Warning,
		Row,
		Done,
		Unknown(I64),
	]

	## Why a connection was not opened.
	##
	## `TooManyConnections` means eight are already open; releasing a `Db` the
	## app no longer needs frees a slot.
	OpenErr : [SqliteErr(ErrCode, Str), TooManyConnections]

	## Why a statement was not prepared.
	##
	## `MultipleStatements` is a query string holding more than one statement;
	## `exec_script!` is the call that runs several. `TooManyStatements` means
	## sixty-four are already prepared.
	PrepareErr : [SqliteErr(ErrCode, Str), TooManyStatements, MultipleStatements]

	## Why a query produced no rows to decode.
	##
	## `ResultTooLarge` is the per-connection cap on a single result, and it is
	## a refusal: nothing is delivered, because a truncated result set is wrong
	## data rather than an error. Narrow the query, or raise
	## `Config.max_result_bytes`.
	QueryErr : [SqliteErr(ErrCode, Str), ResultTooLarge, MultipleStatements]

	## Why a statement that should change data did not.
	##
	## `RowsReturnedUseQueryInstead` is a `SELECT` handed to `execute!`, which
	## has nowhere to put the rows.
	ExecuteErr : [SqliteErr(ErrCode, Str), ResultTooLarge, MultipleStatements, RowsReturnedUseQueryInstead]

	## Why a query did not produce exactly one row.
	ExactlyOneErr : [SqliteErr(ErrCode, Str), ResultTooLarge, MultipleStatements, NoRowsReturned, TooManyRowsReturned]

	## Why a column did not decode.
	##
	## `NoSuchField` names a column the row does not have -- usually a name
	## that does not match the `SELECT`. `UnexpectedType` reports what was
	## actually there. `IntOutOfBounds` is an integer that does not fit the
	## width asked for.
	DecodeErr : [NoSuchField(Str), UnexpectedType(ValueKind), IntOutOfBounds]

	## How a connection is opened.
	##
	## `ReadWriteCreate` creates the file if it is not there. `ReadOnly` opens
	## an existing database for reading only, and the host locks that
	## connection down further: schema-rewriting tricks are disabled and
	## `ATTACH` cannot reach a second file, so a connection opened to visualize
	## someone else's data cannot be talked into writing.
	Mode : [ReadWriteCreate, ReadWrite, ReadOnly]

	## Per-connection limits.
	##
	## `busy_timeout_ms` is how long a statement waits for another process's
	## write lock before answering `SqliteErr(Busy, _)`.
	##
	## `max_result_bytes` caps the text and blob payload of one query. A query
	## that would exceed it fails with `ResultTooLarge` rather than returning
	## part of its rows.
	##
	## A plain record; build one with
	## `{ ..Sqlite.default_config, mode: ReadOnly }` rather than a chain of
	## `with_*` calls.
	Config : { mode : Mode, busy_timeout_ms : U64, max_result_bytes : U64 }

	## Read/write/create, a five second busy timeout, sixteen megabytes of
	## result payload.
	default_config : Config
	default_config = {
		mode: ReadWriteCreate,
		busy_timeout_ms: 5_000,
		max_result_bytes: 16 * 1024 * 1024,
	}

	## What a statement that changes data did.
	##
	## `changes` counts the rows the statement inserted, updated, or deleted.
	## `last_insert_rowid` is the rowid of the most recent successful insert on
	## this connection, and is only meaningful after one.
	Outcome : { changes : I64, last_insert_rowid : I64 }

	## An open database connection.
	##
	## The host owns the connection; this is a reference-counted handle to it.
	## Keep it in the model, copy it freely, and let the last reference close
	## it.
	Db :: Host.SqliteDb.{

		## Open or create a database under `default_config`.
		##
		## The parent directory must already exist. Unlike `Files.write_text!`,
		## which builds the tree on its way, opening a database does not create
		## one: a database file is normally placed beside an application rather
		## than into a directory the application is inventing, and a mistyped
		## path should be `SqliteErr(CanNotOpen, _)` rather than a new empty
		## tree. Create it with a write if the app owns that decision.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it
		## parks the task; refused in `update!` and `render!`.
		open! : Str => Try(Db, OpenErr)
		open! = |path| Db.open_with!(path, default_config)

		## Open a database with explicit limits and access mode.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it
		## parks the task; refused in `update!` and `render!`.
		open_with! : Str, Config => Try(Db, OpenErr)
		open_with! = |path, config| {
			result = Host.sqlite_open!(
				path,
				mode_code(config.mode),
				config.busy_timeout_ms,
				config.max_result_bytes,
			)
			if result.err == 0 {
				Ok(Db.(result.db))
			} else if result.err == err_too_many_connections {
				Err(TooManyConnections)
			} else {
				Err(sqlite_err(result.err, result.message))
			}
		}

		## Close this connection now rather than when its last handle is
		## released.
		##
		## Releasing the final handle closes the connection anyway, so this is
		## never required for safety. It exists because closing a database in
		## WAL mode may checkpoint, which is real disk work: doing it here, on
		## a task, keeps it off the frame the last handle happened to be
		## dropped in.
		##
		## Statements prepared against this connection keep working until they
		## are released; SQLite defers the close until the last one is gone.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it
		## parks the task; refused in `update!` and `render!`.
		close! : Db => Try({}, [SqliteErr(ErrCode, Str)])
		close! = |Db.(db)| {
			result = Host.sqlite_close!(db)
			if result.err == 0 {
				Ok({})
			} else {
				Err(sqlite_err(result.err, result.message))
			}
		}

		## Resource-free connection value for pure tests.
		##
		## The handle never resolves to an open database, so every call through
		## it fails as `SqliteErr(Misuse, _)`, the same way a call through a
		## released handle does. It exists for the app that keeps a `Db` in its
		## model, to let a pure `expect` build that model. Do not use it to
		## test queries or resource lifetime.
		stub : Db
		stub = Db.(Box.box(U64.highest))
	}

	## One row of a result, with its column names.
	##
	## A row is ordinary Roc data by the time an app sees it: the whole result
	## crossed the boundary at once, so reading a column is a lookup rather
	## than an effect. Decode with the receivers below.
	Row := { names : List(Str), values : List(Value) }.{

		## Two rows are equal when their names and values are. Worth having so
		## a decoded result can be compared to an expected one in a test.
		is_eq : _

		## This row's column names, in the order the query selected them.
		names : Row -> List(Str)
		names = |Row.(row)| row.names

		## This row's values, in column order.
		values : Row -> List(Value)
		values = |Row.(row)| row.values

		## The value in a named column, still tagged.
		value : Row, Str -> Try(Value, [NoSuchField(Str), ..])
		value = |Row.(row), name|
			match List.find_first_index(row.names, |candidate| candidate == name) {
				Ok(index) =>
					match List.get(row.values, index) {
						Ok(found) => Ok(found)
						Err(_) => Err(NoSuchField(name))
					}
				Err(_) => Err(NoSuchField(name))
			}

		## Decode a `TEXT` column.
		str : Row, Str -> Try(Str, DecodeErr)
		str = |row, name|
			match Row.value(row, name)? {
				String(text) => Ok(text)
				other => Err(UnexpectedType(kind_of(other)))
			}

		## Decode a `BLOB` column.
		bytes : Row, Str -> Try(List(U8), DecodeErr)
		bytes = |row, name|
			match Row.value(row, name)? {
				Bytes(blob) => Ok(blob)
				other => Err(UnexpectedType(kind_of(other)))
			}

		## Decode a `REAL` column.
		f64 : Row, Str -> Try(F64, DecodeErr)
		f64 = |row, name|
			match Row.value(row, name)? {
				Real(number) => Ok(number)
				other => Err(UnexpectedType(kind_of(other)))
			}

		## Decode an `INTEGER` column.
		i64 : Row, Str -> Try(I64, DecodeErr)
		i64 = |row, name| Row.integer(row, name)

		## Decode an `INTEGER` column that must fit in an `I32`.
		i32 : Row, Str -> Try(I32, DecodeErr)
		i32 = |row, name| in_bounds(I64.to_i32_try(Row.integer(row, name)?))

		## Decode an `INTEGER` column that must fit in an `I16`.
		i16 : Row, Str -> Try(I16, DecodeErr)
		i16 = |row, name| in_bounds(I64.to_i16_try(Row.integer(row, name)?))

		## Decode an `INTEGER` column that must fit in an `I8`.
		i8 : Row, Str -> Try(I8, DecodeErr)
		i8 = |row, name| in_bounds(I64.to_i8_try(Row.integer(row, name)?))

		## Decode a non-negative `INTEGER` column.
		u64 : Row, Str -> Try(U64, DecodeErr)
		u64 = |row, name| in_bounds(I64.to_u64_try(Row.integer(row, name)?))

		## Decode an `INTEGER` column that must fit in a `U32`.
		u32 : Row, Str -> Try(U32, DecodeErr)
		u32 = |row, name| in_bounds(I64.to_u32_try(Row.integer(row, name)?))

		## Decode an `INTEGER` column that must fit in a `U16`.
		u16 : Row, Str -> Try(U16, DecodeErr)
		u16 = |row, name| in_bounds(I64.to_u16_try(Row.integer(row, name)?))

		## Decode an `INTEGER` column that must fit in a `U8`.
		u8 : Row, Str -> Try(U8, DecodeErr)
		u8 = |row, name| in_bounds(I64.to_u8_try(Row.integer(row, name)?))

		## Decode a nullable `TEXT` column.
		nullable_str : Row, Str -> Try([NotNull(Str), Null], DecodeErr)
		nullable_str = |row, name|
			match Row.value(row, name)? {
				Null => Ok(Null)
				String(text) => Ok(NotNull(text))
				other => Err(UnexpectedType(kind_of(other)))
			}

		## Decode a nullable `BLOB` column.
		nullable_bytes : Row, Str -> Try([NotNull(List(U8)), Null], DecodeErr)
		nullable_bytes = |row, name|
			match Row.value(row, name)? {
				Null => Ok(Null)
				Bytes(blob) => Ok(NotNull(blob))
				other => Err(UnexpectedType(kind_of(other)))
			}

		## Decode a nullable `REAL` column.
		nullable_f64 : Row, Str -> Try([NotNull(F64), Null], DecodeErr)
		nullable_f64 = |row, name|
			match Row.value(row, name)? {
				Null => Ok(Null)
				Real(number) => Ok(NotNull(number))
				other => Err(UnexpectedType(kind_of(other)))
			}

		## Decode a nullable `INTEGER` column.
		nullable_i64 : Row, Str -> Try([NotNull(I64), Null], DecodeErr)
		nullable_i64 = |row, name|
			match Row.value(row, name)? {
				Null => Ok(Null)
				Integer(number) => Ok(NotNull(number))
				other => Err(UnexpectedType(kind_of(other)))
			}

		## Build a row without a database, for pure tests.
		##
		## Row decoding is where an app's own logic usually sits -- which
		## column means what, and what to do when one is missing -- so it is
		## worth an `expect`. `names` and `values` are paired by position.
		for_tests : List(Str), List(Value) -> Row
		for_tests = |column_names, column_values| Row.({ names: column_names, values: column_values })

		## Read an `INTEGER` column without a width conversion.
		integer : Row, Str -> Try(I64, DecodeErr)
		integer = |row, name|
			match Row.value(row, name)? {
				Integer(number) => Ok(number)
				other => Err(UnexpectedType(kind_of(other)))
			}
	}

	## A compiled statement, ready to run again with different bindings.
	##
	## Preparing once and running many times skips re-parsing the SQL, which is
	## what a per-frame or per-record write wants. The host owns the compiled
	## statement; the last handle released finalizes it, and the connection it
	## came from stays open at least that long.
	Stmt :: Host.SqliteStmt.{

		## Run this statement, which must not return rows.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it
		## parks the task; refused in `update!` and `render!`.
		execute! : Stmt, List(Binding) => Try(Outcome, ExecuteErr)
		execute! = |Stmt.(stmt), bindings|
			executed(Host.sqlite_run_stmt!(stmt, List.map(bindings, binding_wire)))

		## Run this statement and decode every row it returns.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it
		## parks the task; refused in `update!` and `render!`.
		query! : Stmt, List(Binding) => Try(List(Row), QueryErr)
		query! = |Stmt.(stmt), bindings|
			queried(Host.sqlite_run_stmt!(stmt, List.map(bindings, binding_wire)))

		## Run this statement, which must return exactly one row.
		##
		## Legal in `init!`, where it blocks startup, and in tasks, where it
		## parks the task; refused in `update!` and `render!`.
		query_exactly_one! : Stmt, List(Binding) => Try(Row, ExactlyOneErr)
		query_exactly_one! = |Stmt.(stmt), bindings|
			exactly_one(Host.sqlite_run_stmt!(stmt, List.map(bindings, binding_wire)))

		## Resource-free statement value for pure tests. See `Db.stub`.
		stub : Stmt
		stub = Stmt.(Box.box(U64.highest))
	}

	## Compile one statement for repeated use.
	##
	## The string must hold exactly one statement; several is
	## `MultipleStatements`, and `exec_script!` is the call that runs those.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	prepare! : Db, Str => Try(Stmt, PrepareErr)
	prepare! = |Db.(db), query| {
		result = Host.sqlite_prepare!(db, query)
		if result.err == 0 {
			Ok(Stmt.(result.stmt))
		} else if result.err == err_too_many_statements {
			Err(TooManyStatements)
		} else if result.err == err_multiple_statements {
			Err(MultipleStatements)
		} else {
			Err(sqlite_err(result.err, result.message))
		}
	}

	## Run one statement that changes data and does not return rows.
	##
	## This does not occupy a prepared-statement slot: the statement is
	## compiled, run, and finalized inside the call. Use `prepare!` when the
	## same SQL runs many times.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	execute! : { db : Db, query : Str, bindings : List(Binding) } => Try(Outcome, ExecuteErr)
	execute! = |{ db: Db.(db), query, bindings }|
		executed(Host.sqlite_run_once!(db, query, List.map(bindings, binding_wire)))

	## Run one query and decode every row it returns.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	query! : { db : Db, query : Str, bindings : List(Binding) } => Try(List(Row), QueryErr)
	query! = |{ db: Db.(db), query, bindings }|
		queried(Host.sqlite_run_once!(db, query, List.map(bindings, binding_wire)))

	## Run one query that must return exactly one row.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	query_exactly_one! : { db : Db, query : Str, bindings : List(Binding) } => Try(Row, ExactlyOneErr)
	query_exactly_one! = |{ db: Db.(db), query, bindings }|
		exactly_one(Host.sqlite_run_once!(db, query, List.map(bindings, binding_wire)))

	## Run every statement in a script, for schema setup and migrations.
	##
	## Takes no bindings and returns no rows, because a script is SQL the app
	## wrote rather than SQL assembled from input. Anything that needs a
	## parameter, or answers with data, is a query.
	##
	## Legal in `init!`, where it blocks startup, and in tasks, where it parks
	## the task; refused in `update!` and `render!`.
	exec_script! : Db, Str => Try({}, [SqliteErr(ErrCode, Str)])
	exec_script! = |Db.(db), script| {
		result = Host.sqlite_exec_script!(db, script)
		if result.err == 0 {
			Ok({})
		} else {
			Err(sqlite_err(result.err, result.message))
		}
	}

	## Describe an error code, for a log line or an error screen.
	errcode_to_str : ErrCode -> Str
	errcode_to_str = |code|
		match code {
			Error => "Error: SQL error or missing database"
			Internal => "Internal: internal logic error in SQLite"
			Perm => "Perm: access permission denied"
			Abort => "Abort: callback routine requested an abort"
			Busy => "Busy: the database file is locked"
			Locked => "Locked: a table in the database is locked"
			NoMem => "NoMem: an allocation failed"
			ReadOnly => "ReadOnly: attempt to write a readonly database"
			Interrupt => "Interrupt: operation was interrupted"
			IOErr => "IOErr: a disk I/O error occurred"
			Corrupt => "Corrupt: the database disk image is malformed"
			NotFound => "NotFound: unknown opcode in file control"
			Full => "Full: insertion failed because the database is full"
			CanNotOpen => "CanNotOpen: unable to open the database file"
			Protocol => "Protocol: database lock protocol error"
			Empty => "Empty: the database is empty"
			Schema => "Schema: the database schema changed"
			TooBig => "TooBig: string or blob exceeds the size limit"
			Constraint => "Constraint: abort due to constraint violation"
			Mismatch => "Mismatch: data type mismatch"
			Misuse => "Misuse: library used incorrectly"
			NoLFS => "NoLFS: uses OS features unsupported on this host"
			AuthDenied => "AuthDenied: authorization denied"
			Format => "Format: auxiliary database format error"
			OutOfRange => "OutOfRange: a bound parameter is out of range"
			NotADatabase => "NotADatabase: the file is not a database"
			Notice => "Notice: notification from the SQLite log"
			Warning => "Warning: warning from the SQLite log"
			Row => "Row: another row is ready"
			Done => "Done: the statement has finished"
			Unknown(other) => "Unknown: result code ${I64.to_str(other)}"
		}
}

## Access mode as the host numbers it. Mirrored in `src/sqlite_effect.zig`.
mode_code : Sqlite.Mode -> U8
mode_code = |mode|
	match mode {
		ReadWriteCreate => 0
		ReadWrite => 1
		ReadOnly => 2
	}

expect mode_code(ReadWriteCreate) == 0
expect mode_code(ReadOnly) == 2

## Host refusals. Negative because SQLite's own result codes never are, so one
## number never means two things. Mirrored in `src/sqlite_effect.zig`.
err_too_many_connections : I64
err_too_many_connections = -1

err_too_many_statements : I64
err_too_many_statements = -2

err_result_too_large : I64
err_result_too_large = -3

err_multiple_statements : I64
err_multiple_statements = -4

## Column type codes, as SQLite numbers them. Mirrored in
## `src/sqlite_effect.zig`.
cell_integer : U8
cell_integer = 1

cell_real : U8
cell_real = 2

cell_text : U8
cell_text = 3

cell_blob : U8
cell_blob = 4

cell_null : U8
cell_null = 5

kind_of : Sqlite.Value -> Sqlite.ValueKind
kind_of = |value|
	match value {
		Null => Null
		Integer(_) => Integer
		Real(_) => Real
		String(_) => String
		Bytes(_) => Bytes
	}

expect kind_of(Null) == Null
expect kind_of(Integer(1)) == Integer
expect kind_of(Bytes([1, 2])) == Bytes

in_bounds : Try(a, b) -> Try(a, [IntOutOfBounds, ..])
in_bounds = |result|
	match result {
		Ok(value) => Ok(value)
		Err(_) => Err(IntOutOfBounds)
	}

expect in_bounds(Ok(1)) == Ok(1)
expect in_bounds(I64.to_u8_try(-1)) == Err(IntOutOfBounds)

## Rebuild the tag union from the host's code and message.
##
## An extended result code is reduced to the primary code it extends -- SQLite
## builds one as `primary | (detail << 8)` -- so a `UNIQUE` violation is
## `Constraint` and the detail stays in the message. Without this an app
## matching on `Constraint` would miss every constraint SQLite bothered to be
## specific about.
sqlite_err : I64, Str -> [SqliteErr(Sqlite.ErrCode, Str), ..]
sqlite_err = |code, message| SqliteErr(errcode_from_i64(code % 256), message)

errcode_from_i64 : I64 -> Sqlite.ErrCode
errcode_from_i64 = |code|
	match code {
		1 => Error
		2 => Internal
		3 => Perm
		4 => Abort
		5 => Busy
		6 => Locked
		7 => NoMem
		8 => ReadOnly
		9 => Interrupt
		10 => IOErr
		11 => Corrupt
		12 => NotFound
		13 => Full
		14 => CanNotOpen
		15 => Protocol
		16 => Empty
		17 => Schema
		18 => TooBig
		19 => Constraint
		20 => Mismatch
		21 => Misuse
		22 => NoLFS
		23 => AuthDenied
		24 => Format
		25 => OutOfRange
		26 => NotADatabase
		27 => Notice
		28 => Warning
		100 => Row
		101 => Done
		other => Unknown(other)
	}

expect errcode_from_i64(1) == Error
expect errcode_from_i64(5) == Busy
expect errcode_from_i64(19) == Constraint
expect errcode_from_i64(21) == Misuse
expect errcode_from_i64(101) == Done
expect errcode_from_i64(77) == Unknown(77)

## 2067 is SQLITE_CONSTRAINT_UNIQUE: primary code 19 with detail 8 above it.
expect sqlite_err(2067, "unique") == SqliteErr(Constraint, "unique")
expect sqlite_err(5, "busy") == SqliteErr(Busy, "busy")

## Flatten one binding for the host. Only the field `kind` names is read, so
## the others carry whatever is cheapest to write down.
binding_wire : Sqlite.Binding -> Host.SqliteBindingWire
binding_wire = |{ name, value }|
	match value {
		Null => { name, kind: cell_null, integer: 0, real: 0, text: "", blob: [] }
		Integer(number) => { name, kind: cell_integer, integer: number, real: 0, text: "", blob: [] }
		Real(number) => { name, kind: cell_real, integer: 0, real: number, text: "", blob: [] }
		String(text) => { name, kind: cell_text, integer: 0, real: 0, text, blob: [] }
		Bytes(blob) => { name, kind: cell_blob, integer: 0, real: 0, text: "", blob }
	}

expect binding_wire({ name: ":a", value: Integer(7) }).kind == cell_integer
expect binding_wire({ name: ":a", value: Integer(7) }).integer == 7
expect binding_wire({ name: ":a", value: Null }).kind == cell_null
expect binding_wire({ name: ":a", value: String("hi") }).text == "hi"

## Turn a finished query into rows, or into the reason there are none.
queried : Host.SqliteQueryResult -> Try(List(Sqlite.Row), Sqlite.QueryErr)
queried = |result|
	if result.err == 0 {
		Ok(decode_rows(result))
	} else if result.err == err_result_too_large {
		Err(ResultTooLarge)
	} else if result.err == err_multiple_statements {
		Err(MultipleStatements)
	} else {
		Err(sqlite_err(result.err, result.message))
	}

## Turn a finished statement into what it changed.
##
## A statement that produced rows is refused rather than reported as a
## successful write: `execute!` has nowhere to put them, and silently dropping
## a `SELECT`'s output would hide the mistake.
executed : Host.SqliteQueryResult -> Try(Sqlite.Outcome, Sqlite.ExecuteErr)
executed = |result|
	if result.err == 0 {
		if result.row_count > 0 {
			Err(RowsReturnedUseQueryInstead)
		} else {
			Ok({ changes: result.changes, last_insert_rowid: result.last_insert_rowid })
		}
	} else if result.err == err_result_too_large {
		Err(ResultTooLarge)
	} else if result.err == err_multiple_statements {
		Err(MultipleStatements)
	} else {
		Err(sqlite_err(result.err, result.message))
	}

## Turn a finished query into its single row.
exactly_one : Host.SqliteQueryResult -> Try(Sqlite.Row, Sqlite.ExactlyOneErr)
exactly_one = |result|
	if result.err == 0 {
		if result.row_count == 0 {
			Err(NoRowsReturned)
		} else if result.row_count > 1 {
			Err(TooManyRowsReturned)
		} else {
			match List.first(decode_rows(result)) {
				Ok(row) => Ok(row)
				Err(_) => Err(NoRowsReturned)
			}
		}
	} else if result.err == err_result_too_large {
		Err(ResultTooLarge)
	} else if result.err == err_multiple_statements {
		Err(MultipleStatements)
	} else {
		Err(sqlite_err(result.err, result.message))
	}

## Decode a whole result into rows.
##
## The host delivered three things: `ncols` NUL-terminated column names, one
## flat array of `ncols * row_count` scalar cells, and the shared byte payload
## that names, text and blobs all point into. Nothing here can fail: a cell the
## host did not write is not reachable, and a short buffer ends the decode
## rather than being guessed at.
decode_rows : Host.SqliteQueryResult -> List(Sqlite.Row)
decode_rows = |result| {
	names = decode_names(result.names, 0, [])
	decode_row_at(result, names, 0, [])
}

decode_row_at : Host.SqliteQueryResult, List(Str), U64, List(Sqlite.Row) -> List(Sqlite.Row)
decode_row_at = |result, names, row, found|
	if row >= result.row_count {
		found
	} else {
		decode_row_at(
			result,
			names,
			row + 1,
			List.append(found, Sqlite.Row.for_tests(names, decode_cells(result, row * result.ncols, result.ncols, []))),
		)
	}

decode_cells : Host.SqliteQueryResult, U64, U64, List(Sqlite.Value) -> List(Sqlite.Value)
decode_cells = |result, at, remaining, found|
	if remaining == 0 {
		found
	} else {
		match List.get(result.cells, at) {
			Err(_) => found
			Ok(cell) =>
				decode_cells(result, at + 1, remaining - 1, List.append(found, decode_cell(cell, result.payload)))
			}
	}

decode_cell : Host.SqliteCell, List(U8) -> Sqlite.Value
decode_cell = |cell, payload|
	if cell.kind == cell_integer {
		Integer(cell.integer)
	} else if cell.kind == cell_real {
		Real(cell.real)
	} else if cell.kind == cell_text {
		String(Str.from_utf8_lossy(payload_slice(payload, cell.start, cell.len)))
	} else if cell.kind == cell_blob {
		Bytes(payload_slice(payload, cell.start, cell.len))
	} else {
		Null
	}

## Copy one value out of the shared payload.
##
## The copy is the point, exactly as in `Files.decode_listing`: a sublist of a
## host-delivered list is a view onto the host's buffer, so a single retained
## string would pin the whole result for as long as the app held it.
## `release_excess_capacity` gives it storage of its own, and it has to happen
## before `from_utf8_lossy`, which may share what it is given.
payload_slice : List(U8), U64, U64 -> List(U8)
payload_slice = |payload, start, len|
	List.release_excess_capacity(List.sublist(payload, { start, len }))

## Split the NUL-terminated column names the host wrote.
decode_names : List(U8), U64, List(Str) -> List(Str)
decode_names = |bytes, at, found|
	if at >= List.len(bytes) {
		found
	} else {
		match index_of_nul(bytes, at) {
			Err(_) => found
			Ok(end) =>
				decode_names(
					bytes,
					end + 1,
					List.append(found, Str.from_utf8_lossy(payload_slice(bytes, at, end - at))),
				)
			}
	}

index_of_nul : List(U8), U64 -> Try(U64, [NotFound])
index_of_nul = |bytes, at|
	match List.get(bytes, at) {
		Err(_) => Err(NotFound)
		Ok(byte) =>
			if byte == 0 {
				Ok(at)
			} else {
				index_of_nul(bytes, at + 1)
			}
		}

expect decode_names([], 0, []) == []
expect decode_names(['i', 'd', 0], 0, []) == ["id"]
expect decode_names(['i', 'd', 0, 'n', 0], 0, []) == ["id", "n"]

## A name with no terminator ends the list rather than being guessed at. The
## host writes the terminator, so this cannot happen; answering with the names
## that were whole is what keeps this total.
expect decode_names(['i', 'd', 0, 'n'], 0, []) == ["id"]

expect decode_cell({ kind: 1, integer: 42, real: 0, start: 0, len: 0 }, []) == Integer(42)
expect decode_cell({ kind: 2, integer: 0, real: 1.5, start: 0, len: 0 }, []) == Real(1.5)
expect decode_cell({ kind: 5, integer: 0, real: 0, start: 0, len: 0 }, []) == Null
expect decode_cell({ kind: 3, integer: 0, real: 0, start: 1, len: 2 }, ['x', 'h', 'i']) == String("hi")
expect decode_cell({ kind: 4, integer: 0, real: 0, start: 0, len: 2 }, [7, 8, 9]) == Bytes([7, 8])

## An unknown kind byte decodes as `Null` rather than crashing. The host only
## ever writes the five SQLite defines, so this is unreachable; it is here
## because a total function is cheaper than a guarantee.
expect decode_cell({ kind: 99, integer: 0, real: 0, start: 0, len: 0 }, []) == Null

expect Sqlite.Row.i64(Sqlite.Row.for_tests(["id", "name"], [Integer(3), String("ok")]), "id") == Ok(3)

expect Sqlite.Row.str(Sqlite.Row.for_tests(["id", "name"], [Integer(3), String("ok")]), "name") == Ok("ok")

expect Sqlite.Row.str(Sqlite.Row.for_tests(["id"], [Integer(3)]), "id") == Err(UnexpectedType(Integer))

expect Sqlite.Row.i64(Sqlite.Row.for_tests(["id"], [Integer(3)]), "missing") == Err(NoSuchField("missing"))

expect Sqlite.Row.u8(Sqlite.Row.for_tests(["id"], [Integer(-1)]), "id") == Err(IntOutOfBounds)

expect Sqlite.Row.u8(Sqlite.Row.for_tests(["id"], [Integer(300)]), "id") == Err(IntOutOfBounds)

expect Sqlite.Row.u8(Sqlite.Row.for_tests(["id"], [Integer(200)]), "id") == Ok(200)

expect Sqlite.Row.nullable_str(Sqlite.Row.for_tests(["n"], [Null]), "n") == Ok(Null)

expect Sqlite.Row.nullable_str(Sqlite.Row.for_tests(["n"], [String("x")]), "n") == Ok(NotNull("x"))

expect Sqlite.Row.nullable_f64(Sqlite.Row.for_tests(["n"], [Real(2.5)]), "n") == Ok(NotNull(2.5))

expect Sqlite.Row.bytes(Sqlite.Row.for_tests(["b"], [Bytes([1, 2])]), "b") == Ok([1, 2])

expect Sqlite.Row.names(Sqlite.Row.for_tests(["a", "b"], [Integer(1), Integer(2)])) == ["a", "b"]

expect Sqlite.Row.values(Sqlite.Row.for_tests(["a"], [Integer(1)])) == [Integer(1)]
