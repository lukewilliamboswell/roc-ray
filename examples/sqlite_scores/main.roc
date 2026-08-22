app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-08-21-90da19f" }

import rr.App
import rr.Color
import rr.Draw
import rr.Files
import rr.Random
import rr.Sqlite
import rr.Task
import rr.Time

## A high-score board that outlives the process.
##
## `init!` opens the database, runs the schema, and loads the top ten before the
## first frame -- startup is the one place a waiting effect may block, and a
## board with nothing in it is not worth drawing. After that every read and
## write happens on a task, so a slow disk costs a query rather than a frame.
##
## The pattern worth copying is the round trip. `update!` spawns a task that
## writes and then re-reads in one straight line, and the task answers with the
## rows it read. The model never guesses what the database now holds; it is
## told. That is what keeps a failed write visible instead of silently letting
## the screen and the disk disagree.
##
## The insert is prepared once in `init!` and kept in the model, because the
## same statement runs on every keypress and re-parsing it each time would be
## work for nothing. The read is a one-shot `Sqlite.query!`, which does not
## occupy a statement slot.
##
## Each row is stamped with `Time.now!` rather than with the cycle's simulation
## clock, and the board renders that stamp as an ISO 8601 instant. A row
## outlives the process that wrote it, so the only clock it can be measured
## against is the world's.
Model : {
	db : Sqlite.Db,
	insert : Sqlite.Stmt,
	rows : List(Entry),
	status : Status,
	pending : Bool,
	rng : Random.State,
	font : Draw.Font,
}

## One row of the board, in the app's own vocabulary rather than the database's.
## Decoding into this is what makes a renamed column an error in one place.
##
## `played_at` is a wall-clock instant rather than a count of simulation
## seconds, because it has to mean the same thing across the two runs of the
## process that the database spans.
Entry : { name : Str, score : I64, played_at : Time.Timestamp }

Status : [Ready, Working, Failed(Str)]

Msg : [Refreshed(List(Entry)), Failed(Str)]

## `Files` creates the directory on its way; opening a database does not.
db_dir : Str
db_dir = "sqlite_scores_out"

db_path : Str
db_path = "sqlite_scores_out/scores.db"

## `played_at` is a REAL holding fractional seconds since the Unix epoch, and
## `name` is UNIQUE, so the board exercises three column types and gives a
## repeated name an outcome the app can show rather than a silently duplicated
## row.
schema : Str
schema = "CREATE TABLE IF NOT EXISTS runs(name TEXT NOT NULL UNIQUE, score INTEGER NOT NULL, played_at REAL NOT NULL);"

top_ten : Str
top_ten = "SELECT name, score, CAST(played_at AS INTEGER) AS played_s FROM runs ORDER BY score DESC, name ASC LIMIT 10"

insert_run : Str
insert_run = "INSERT INTO runs VALUES (:name, :score, :played_at)"

## A small fixed cast, so the example needs no text entry.
runner_names : List(Str)
runner_names = ["ada", "grace", "alan", "edsger", "barbara", "ken", "donald", "margaret", "linus", "tim"]

program = { init!, update!, render! }

init! : App.Init(Model, [ResourceLimit, ..])
init! = App.init(
	App.default.with_title("RocRay SQLite Scores").with_frame_pacing(Capped(60)),
	|startup| {
		# A write builds the tree on its way, which is how the directory the
		# database lives in comes to exist.
		_ = Files.write_bytes!("${db_dir}/.keep", [])

		rng = Random.seed(U64.to_u32_wrap(App.entropy!(startup)))
		font = Draw.default_font!()

		# A store that will not open is shown rather than fatal: the stub
		# handles keep the model well-formed, every later call through them
		# answers `Misuse`, and the status line says what went wrong.
		match open_board!() {
			Err(reason) =>
				Ok({
					db: Sqlite.Db.stub,
					insert: Sqlite.Stmt.stub,
					rows: [],
					status: Failed(reason),
					pending: Bool.False,
					rng,
					font,
				})
			Ok(opened) =>
				Ok({
					db: opened.db,
					insert: opened.insert,
					rows: opened.rows,
					status: Ready,
					pending: Bool.False,
					rng,
					font,
				})
			}
	},
)

## Open the store and read the first board. Waits, which `init!` permits.
open_board! : () => Try({ db : Sqlite.Db, insert : Sqlite.Stmt, rows : List(Entry) }, Str)
open_board! = || {
	db = Sqlite.Db.open!(db_path) ? |err| describe(err)
	Sqlite.exec_script!(db, schema) ? |err| describe(err)
	insert = Sqlite.prepare!(db, insert_run) ? |err| describe(err)
	rows = read_board!(db)?
	Ok({ db, insert, rows })
}

## Read the board and decode it into the app's own rows.
##
## Waits, so it is only ever reached from `init!` or from inside a task.
read_board! : Sqlite.Db => Try(List(Entry), Str)
read_board! = |db| {
	rows = Sqlite.query!({ db, query: top_ten, bindings: [] }) ? |err| describe(err)
	Ok(List.map(rows, decode_entry))
}

## One row, in the app's vocabulary.
##
## A column that is missing or holds the wrong type falls back rather than
## failing the whole read: this board would rather show nine rows and a zero
## than nothing at all. An app that must not paper over a schema change should
## propagate the `DecodeErr` instead.
decode_entry : Sqlite.Row -> Entry
decode_entry = |row| {
	name: or_else_str(Sqlite.Row.str(row, "name"), "?"),
	score: or_else_i64(Sqlite.Row.i64(row, "score"), 0),
	played_at: to_timestamp(or_else_i64(Sqlite.Row.i64(row, "played_s"), 0)),
}

## Rebuild the instant a run was recorded from the whole seconds the query
## casts it down to.
##
## A second is always a valid instant, so the fallback only names a value
## `from_parts` will not produce here rather than a state the board can reach.
to_timestamp : I64 -> Time.Timestamp
to_timestamp = |seconds|
	match Time.Timestamp.from_parts({ seconds, nanosecond: 0 }) {
		Ok(at) => at
		Err(InvalidNanosecond) => Time.Timestamp.epoch
	}

or_else_str : Try(Str, _), Str -> Str
or_else_str = |result, fallback|
	match result {
		Ok(found) => found
		Err(_) => fallback
	}

or_else_i64 : Try(I64, _), I64 -> I64
or_else_i64 = |result, fallback|
	match result {
		Ok(found) => found
		Err(_) => fallback
	}

## Record one run and read the board back, on a task.
##
## Write and read inside one closure, so the message carries the board as it is
## after the write. Two separate tasks could answer out of order and leave the
## model showing a board that never existed.
record_run! : Sqlite.Db, Sqlite.Stmt, Str, I64 => Msg
record_run! = |db, insert, name, score| {
	# The clock is read here rather than in `update!`, so the row is stamped
	# with the instant the write happened. `Time.now!` does not wait, so it
	# costs the task nothing to ask on its own.
	played_at = Time.now!()
	written =
		Sqlite.Stmt.execute!(
			insert,
			[
				{ name: ":name", value: String(name) },
				{ name: ":score", value: Integer(score) },
				{ name: ":played_at", value: Real(epoch_seconds(played_at)) },
			],
		)

	match written {
		Err(SqliteErr(Constraint, _)) =>
		# `name` is UNIQUE, so a repeat is an ordinary outcome to report
		# rather than a failure to recover from.
			Failed("${name} already has a run")
		Err(other) => Failed(describe(other))
		Ok(_outcome) =>
			match read_board!(db) {
				Ok(rows) => Refreshed(rows)
				Err(reason) => Failed(reason)
			}
		}
}

## Fractional seconds since the Unix epoch, which is what the REAL column
## holds. Keeping the subsecond part is why the column is a REAL rather than an
## INTEGER, even though the board only ever shows whole seconds.
epoch_seconds : Time.Timestamp -> F64
epoch_seconds = |at|
	I64.to_f64(Time.Timestamp.seconds_since_epoch(at))
		+ U32.to_f64(Time.Timestamp.subsecond_nanoseconds(at)) / 1_000_000_000

## Turn any of this module's errors into a line worth putting on screen.
##
## `SqliteErr` is the only one carrying detail the database chose, so it is the
## only one that gets the code spelled out.
##
## The union stays open, so the one function serves every call that can fail
## here -- `open!`, `prepare!`, `query!`, and `execute!` each add refusals of
## their own that this catch-all covers.
describe : [SqliteErr(Sqlite.ErrCode, Str), ..] -> Str
describe = |err|
	match err {
		SqliteErr(code, message) => "${Sqlite.errcode_to_str(code)} (${message})"
		_ => "the platform refused the query"
	}

## Fold one message into the model. Pure, so an `expect` can exercise it.
apply_message : Model, Msg -> Model
apply_message = |model, message|
	match message {
		Refreshed(rows) => { ..model, rows, status: Ready, pending: Bool.False }
		Failed(reason) => { ..model, status: Failed(reason), pending: Bool.False }
	}

## Draw one run's name and score, and the next generator state.
##
## Pure, so the choice of who ran and how well is testable without a database.
next_run : Random.State -> { name : Str, score : I64, state : Random.State }
next_run = |state| {
	picked = Random.step(state, Random.bounded_u64(0, 9))
	scored = Random.step(picked.state, Random.bounded_i32(1, 9999))
	{
		name: or_else_str(List.get(runner_names, picked.value), "anonymous"),
		score: I32.to_i64(scored.value),
		state: scored.state,
	}
}

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, input| {
	folded = List.fold(input.messages, model, apply_message)

	if input.devices.key_pressed(KeyEscape) {
		return Err(Exit(0))
	}

	# One database operation in flight at a time. A second would answer with a
	# board that does not include the first, and the later reply would win.
	if folded.pending {
		return Ok(folded)
	}

	if input.devices.key_pressed(KeySpace) {
		run = next_run(folded.rng)
		db = folded.db
		insert = folded.insert
		Task.spawn!(input, || record_run!(db, insert, run.name, run.score))
		Ok({ ..folded, rng: run.state, status: Working, pending: Bool.True })
	} else if input.devices.key_pressed(KeyR) {
		db = folded.db
		Task.spawn!(
			input,
			|| match read_board!(db) {
				Ok(rows) => Refreshed(rows)
				Err(reason) => Failed(reason)
			},
		)
		Ok({ ..folded, status: Working, pending: Bool.True })
	} else {
		Ok(folded)
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x141820))
	frame.text_at!({ pos: { x: 40, y: 32 }, text: "High scores", size: 30, color: Color.white })
	frame.text_at!({
		pos: { x: 40, y: 74 },
		text: "SPACE records a run   R reloads   ESC quits",
		size: 18,
		color: Color.from_hex_rgb(0x8a93a5),
	})

	if List.is_empty(model.rows) {
		frame.text_at!({
			pos: { x: 40, y: 130 },
			text: "No runs yet -- press SPACE",
			size: 22,
			color: Color.from_hex_rgb(0x8a93a5),
		})
	} else {
		List.for_each!(
			List.map_with_index(model.rows, |entry, index| { entry, index }),
			|row| draw_entry!(frame, row.index, row.entry),
		)
	}

	frame.text_at!({
		pos: { x: 40, y: 470 },
		text: status_line(model.status),
		size: 18,
		color: status_color(model.status),
	})
	Ok({})
}

draw_entry! : Draw.Frame, U64, Entry => {}
draw_entry! = |frame, index, entry| {
	y = 130 + U64.to_f32(index) * 32
	frame.rectangle!({
		x: 36,
		y: y - 6,
		width: 600,
		height: 28,
		style: Draw.filled(if index % 2 == 0 Color.from_hex_rgb(0x1c212b) else Color.from_hex_rgb(0x181d26)),
	})
	frame.text_at!({
		pos: { x: 44, y },
		text: "${U64.to_str(index + 1)}.",
		size: 20,
		color: Color.from_hex_rgb(0x6d778a),
	})
	frame.text_at!({ pos: { x: 84, y }, text: entry.name, size: 20, color: Color.white })
	frame.text_at!({
		pos: { x: 300, y },
		text: I64.to_str(entry.score),
		size: 20,
		color: Color.from_hex_rgb(0x7fd188),
	})
	frame.text_at!({
		pos: { x: 430, y },
		text: Time.Timestamp.to_iso_8601(entry.played_at),
		size: 18,
		color: Color.from_hex_rgb(0x6d778a),
	})
}

status_line : Status -> Str
status_line = |status|
	match status {
		Ready => "Ready"
		Working => "Working..."
		Failed(reason) => "Error: ${reason}"
	}

status_color : Status -> Color.Rgba
status_color = |status|
	match status {
		Ready => Color.from_hex_rgb(0x7fd188)
		Working => Color.from_hex_rgb(0xe0c16a)
		Failed(_) => Color.from_hex_rgb(0xe07a7a)
	}

expect status_line(Ready) == "Ready"
expect status_line(Failed("locked")) == "Error: locked"

## A refresh replaces the board and clears the in-flight flag, so the next
## keypress is accepted.
expect
	apply_message({ ..test_model, pending: Bool.True, status: Working }, Refreshed([test_entry])).rows == [test_entry]

expect apply_message({ ..test_model, pending: Bool.True, status: Working }, Refreshed([])).status == Ready

expect !apply_message({ ..test_model, pending: Bool.True }, Refreshed([])).pending

## A failure keeps the board already on screen and says why.
expect apply_message({ ..test_model, pending: Bool.True }, Failed("locked")).status == Failed("locked")

expect !apply_message({ ..test_model, pending: Bool.True }, Failed("locked")).pending

## A stored second comes back as the instant that stamped it.
expect Time.Timestamp.to_iso_8601(to_timestamp(0)) == "1970-01-01T00:00:00Z"

expect Time.Timestamp.to_iso_8601(to_timestamp(1_700_000_000)) == "2023-11-14T22:13:20Z"

## Whole seconds survive the trip out through the REAL column and back.
expect epoch_seconds(to_timestamp(1_700_000_000)) == 1_700_000_000

## The same seed draws the same run, which is what makes a replay a replay.
expect next_run(Random.seed(7)).name == next_run(Random.seed(7)).name

expect next_run(Random.seed(7)).score == next_run(Random.seed(7)).score

## Every drawn name is one of the cast.
expect List.contains(runner_names, next_run(Random.seed(11)).name)

test_entry : Entry
test_entry = { name: "ada", score: 10, played_at: to_timestamp(1) }

## A resource-free model built from the `stub` handles, so the pure folds above
## can be exercised without a database.
test_model : Model
test_model = {
	db: Sqlite.Db.stub,
	insert: Sqlite.Stmt.stub,
	rows: [],
	status: Ready,
	pending: Bool.False,
	rng: Random.seed(1),
	font: Draw.Font.stub,
}
