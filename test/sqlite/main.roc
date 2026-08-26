app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-26-b29bef3" }

import rr.App
import rr.Draw
import rr.Files
import rr.Sqlite
import rr.Task

## Does a value written to a database come back as the value that was written?
##
## Nothing else in the suite runs a query, so a binding that bound the wrong
## column, a decoder that read the wrong cell, a payload offset off by one, or
## an error that arrived as success would pass every other stage. This probe
## writes one row holding all five `Value` kinds, reads it back, compares each
## one, and then walks the error paths that an app is most likely to hit.
##
## It runs from a scratch directory and only ever touches `probe_out/`, so it
## leaves nothing behind in the tree.
Model : { checked : Bool }

Msg : [Checked(U64)]

program = { init!, update!, render! }

init! : App.Init(Model, [])
init! = App.init(App.default.with_title("sqlite"), |_startup| Ok({ checked: Bool.False }))

## A correct run scores every bit. Any property that does not hold subtracts
## its own bit, so the exit code says which property went wrong.
expected_score : U64
expected_score = 2047

score : Bool, U64 -> U64
score = |held, bit| if held bit else 0

expect score(Bool.True, 8) == 8
expect score(Bool.False, 8) == 0
expect 1 + 2 + 4 + 8 + 16 + 32 + 64 + 128 + 256 + 512 + 1024 == expected_score

## Text with a NUL-unsafe shape on purpose: a binding that went through a C
## string would truncate at the newline-free tail, and a length-confused one
## would drop the last character.
probe_text : Str
probe_text = "row one\nsecond line\u(e9)\u(2713)"

## Bytes that are not valid UTF-8, so a blob that took the text path would come
## back mangled rather than equal.
probe_blob : List(U8)
probe_blob = [0, 1, 0xff, 0xfe, 0x80, 0]

schema : Str
schema = "CREATE TABLE kinds(i INTEGER NOT NULL, r REAL NOT NULL, s TEXT NOT NULL, b BLOB NOT NULL, n TEXT); CREATE TABLE unique_names(name TEXT NOT NULL UNIQUE);"

## Write every `Value` kind, read them back, and compare.
check! : () => Msg
check! = || {
	# Opening a database does not create its parent directory, so make one the
	# way an app would. A write creates the tree on its way.
	match Files.write_bytes!("probe_out/.keep", []) {
		Ok({}) => {}
		Err(_) => return Checked(0)
	}

	db =
		match Sqlite.Db.open!("probe_out/probe.db") {
			Ok(opened) => opened
			Err(_) => return Checked(0)
		}

	match Sqlite.exec_script!(db, schema) {
		Ok({}) => {}
		Err(_) => return Checked(0)
	}

	inserted =
		Sqlite.execute!({
			db,
			query: "INSERT INTO kinds VALUES (:i, :r, :s, :b, :n)",
			bindings: [
				{ name: ":i", value: Integer(-4242) },
				{ name: ":r", value: Real(1.5) },
				{ name: ":s", value: String(probe_text) },
				{ name: ":b", value: Bytes(probe_blob) },
				{ name: ":n", value: Null },
			],
		})

	outcome =
		match inserted {
			Ok(found) => found
			Err(_) => return Checked(0)
		}

	# One row changed, and the rowid of a fresh table's first row is 1.
	changed = score(outcome.changes == 1, 1)
	rowid = score(outcome.last_insert_rowid == 1, 2)

	row =
		match Sqlite.query_exactly_one!({
			db,
			query: "SELECT i, r, s, b, n FROM kinds",
			bindings: [],
		}) {
			Ok(found) => found
			Err(_) => return Checked(changed + rowid)
		}

	read_back =
		score(Sqlite.Row.i64(row, "i") == Ok(-4242), 4)
			+ score(Sqlite.Row.f64(row, "r") == Ok(1.5), 8)
			+ score(Sqlite.Row.str(row, "s") == Ok(probe_text), 16)
			+ score(Sqlite.Row.bytes(row, "b") == Ok(probe_blob), 32)
			+ score(Sqlite.Row.nullable_str(row, "n") == Ok(Null), 64)

	# Column names travel beside the values, so a name the query did not select
	# has to be missing rather than resolving to a neighbouring column.
	names = score(Sqlite.Row.names(row) == ["i", "r", "s", "b", "n"], 128)
	missing = score(Sqlite.Row.i64(row, "nope") == Err(NoSuchField("nope")), 256)

	# A prepared statement run twice must answer for its own bindings each time
	# rather than reusing the previous run's.
	reused =
		match Sqlite.prepare!(db, "SELECT :n + 1 AS answer") {
			Err(_) => 0
			Ok(stmt) => {
				first = stmt.query_exactly_one!([{ name: ":n", value: Integer(1) }])
				second = stmt.query_exactly_one!([{ name: ":n", value: Integer(41) }])
				match (first, second) {
					(Ok(a), Ok(b)) =>
						score(
							Sqlite.Row.i64(a, "answer") == Ok(2) and Sqlite.Row.i64(b, "answer") == Ok(42),
							512,
						)
					_ => 0
				}
			}
		}

	Checked(changed + rowid + read_back + names + missing + reused + error_paths!(db))
}

## The failures an app is most likely to meet, each as its own typed outcome.
error_paths! : Sqlite.Db => U64
error_paths! = |db| {
	# A SELECT handed to execute! has nowhere to put its rows.
	wrong_call =
		match Sqlite.execute!({ db, query: "SELECT 1", bindings: [] }) {
			Err(RowsReturnedUseQueryInstead) => Bool.True
			_ => Bool.False
		}

	# A UNIQUE violation is Constraint even though SQLite reports the extended
	# code 2067, which is what the primary-code reduction is for.
	insert_name! = |name|
		Sqlite.execute!({
			db,
			query: "INSERT INTO unique_names VALUES (:name)",
			bindings: [{ name: ":name", value: String(name) }],
		})

	constrained =
		match (insert_name!("only"), insert_name!("only")) {
			(Ok(_), Err(SqliteErr(Constraint, _))) => Bool.True
			_ => Bool.False
		}

	syntax =
		match Sqlite.query!({ db, query: "SELEKT nope", bindings: [] }) {
			Err(SqliteErr(Error, _)) => Bool.True
			_ => Bool.False
		}

	no_rows =
		match Sqlite.query_exactly_one!({ db, query: "SELECT 1 WHERE 0", bindings: [] }) {
			Err(NoRowsReturned) => Bool.True
			_ => Bool.False
		}

	too_many =
		match Sqlite.query_exactly_one!({ db, query: "SELECT 1 UNION ALL SELECT 2", bindings: [] }) {
			Err(TooManyRowsReturned) => Bool.True
			_ => Bool.False
		}

	# A released handle answers Misuse rather than reaching host memory.
	stubbed =
		match Sqlite.query!({ db: Sqlite.Db.stub, query: "SELECT 1", bindings: [] }) {
			Err(SqliteErr(Misuse, _)) => Bool.True
			_ => Bool.False
		}

	# A query string holding two statements is refused, not half run.
	multiple =
		match Sqlite.query!({ db, query: "SELECT 1; SELECT 2", bindings: [] }) {
			Err(MultipleStatements) => Bool.True
			_ => Bool.False
		}

	score(
		wrong_call and constrained and syntax and no_rows and too_many and stubbed and multiple,
		1024,
	)
}

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	if !model.checked {
		Task.spawn!(input, check!)
		Ok({ checked: Bool.True })
	} else {
		match List.first(input.messages) {
			Ok(Checked(found)) =>
				if found == expected_score {
					Err(Exit(0))
				} else {
					# Exit 3 means a property did not hold. `found` is a bitmap
					# of the ones that did, so a `dbg` here names which failed.
					Err(Exit(3))
				}
			Err(_) => Ok(model)
		}
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
