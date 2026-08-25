## Press Space to add a random score to a SQLite-backed high-score board;
## Escape quits. Scores remain in `sqlite_scores_out/scores.db` between runs.
## This example shows startup database setup, prepared statements, and Tasks:
## work that may wait runs separately and returns rows as a later Message.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/3vVeddfDE6rraq5j8v1cGHtFNaQhC6dij1zGRN63NGP1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Color
import rr.Draw
import rr.Files
import rr.Random
import rr.Sqlite
import rr.Task
import rr.Text
import rr.Time

## State retained between updates: the open database and reusable insert
## statement, the displayed rows and request status, random score generation,
## drawing resources, and animation time. Keeping the last confirmed rows here
## ensures the screen changes only after the database task reports its result.
Model : {
	db : Sqlite.Db,
	insert : Sqlite.Stmt,
	rows : List(Entry),
	status : Status,
	pending : Bool,
	rng : Random.State,
	font : Text.Font,

	## Wall-clock seconds since startup, so the in-flight indicator turns.
	elapsed : F32,
	title : Text.Prepared,
	subtitle : Text.Prepared,
	hint : Text.Prepared,
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

clear_runs : Str
clear_runs = "DELETE FROM runs"

## A small fixed cast, so the example needs no text entry.
runner_names : List(Str)
runner_names = ["ada", "grace", "alan", "edsger", "barbara", "ken", "donald", "margaret", "linus", "tim"]

program = { init!, update!, render! }

init! : App.Init(Model, [ResourceLimit, ..])
init! = App.init(
	App.default.with_title("RocRay SQLite Scores").with_size({ width: 880, height: 560 }).with_frame_pacing(Capped(60)),
	|startup| {
		# A write builds the tree on its way, which is how the directory the
		# database lives in comes to exist.
		_ = Files.write_bytes!("${db_dir}/.keep", [])

		rng = Random.seed(U64.to_u32_wrap(App.entropy!(startup)))
		font = Draw.default_font!()
		title = Text.from("High scores that outlive the process", font).size(26).prepare!()?
		subtitle = Text.from("the write and the re-read share one task, so the board is told what the database holds", font).size(15).prepare!()?
		hint = Text.from("SPACE  record a run        R  reset the board        ESC  quit", font).size(14).spacing(2.0).prepare!()?

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
					elapsed: 0,
					title,
					subtitle,
					hint,
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
					elapsed: 0,
					title,
					subtitle,
					hint,
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

## Wipe every run, then read the board back.
##
## The same round trip as a write: the task does not answer "cleared", it
## answers with what the table now holds, so an app that shows an empty board
## is showing one the database agrees is empty. A one-shot `execute!` serves
## here because the statement runs rarely and has nothing to bind.
reset_board! : Sqlite.Db => Msg
reset_board! = |db| {
	match Sqlite.execute!({ db, query: clear_runs, bindings: [] }) {
		Err(err) => Failed(describe(err))
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
	folded = List.fold(input.messages, { ..model, elapsed: model.elapsed + input.time.elapsed_seconds }, apply_message)

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
		Task.spawn!(input, || reset_board!(db))
		Ok({ ..folded, status: Working, pending: Bool.True })
	} else {
		Ok(folded)
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	size = frame.size!()
	frame.rectangle_gradient_v!({ x: 0, y: 0, width: size.width, height: size.height, color_top: bg_top, color_bottom: bg_bottom })
	frame.circle_gradient!({ center: { x: size.width * 0.5, y: -40 }, radius: size.height, color_inner: Color.from_hex_rgba(0x3a5f9c33), color_outer: Color.from_hex_rgba(0x00000000) })

	model.title.draw!(frame, { pos: { x: 44, y: 36 }, color: ink })
	model.subtitle.draw!(frame, { pos: { x: 44, y: 72 }, color: muted })

	width = size.width - 88
	frame.rounded_rectangle!({ x: 44, y: 112, width: width, height: 388, radius: 0.05, segments: 8, style: Draw.filled_and_outlined(panel, card_edge, 1) })
	frame.text_at!({ pos: { x: 68, y: 126 }, text: "#", size: 13, color: faint })
	frame.text_at!({ pos: { x: 104, y: 126 }, text: "RUNNER", size: 13, color: faint })
	frame.text_at!({ pos: { x: 268, y: 126 }, text: "SCORE", size: 13, color: faint })
	frame.text_at!({ pos: { x: 596, y: 126 }, text: "RECORDED", size: 13, color: faint })
	frame.line!({ start: { x: 44, y: 152 }, end: { x: 44 + width, y: 152 }, stroke: Stroke({ color: card_edge, thickness: 1 }) })

	if List.is_empty(model.rows) {
		frame.text_at!({ pos: { x: 68, y: 190 }, text: "No runs yet -- press SPACE to record one", size: 18, color: muted })
	} else {
		best = List.fold(model.rows, 1, |top, entry| I64.max(top, entry.score))
		List.for_each!(
			List.map_with_index(model.rows, |entry, index| { entry, index }),
			|row| draw_entry!(frame, row.index, row.entry, best, width),
		)
	}

	draw_status!(frame, model.status, model.elapsed, size.height - 46)
	model.hint.draw!(frame, { pos: { x: 44, y: size.height - 40 }, color: faint })
	Ok({})
}

## One row: rank badge, name, score with a bar for its share of the best score,
## and the wall-clock instant the run was written.
draw_entry! : Draw.Frame, U64, Entry, I64, F32 => {}
draw_entry! = |frame, index, entry, best, width| {
	y = 168 + U64.to_f32(index) * 32
	if index % 2 == 1 {
		frame.rectangle!({ x: 45, y: y - 6, width: width - 2, height: 30, style: Draw.filled(Color.from_hex_rgba(0xffffff06)) })
	}
	medal = if index == 0 gold else if index < 3 silver else faint
	frame.circle!({ center: { x: 74, y: y + 9 }, radius: 11, style: Draw.filled(Color.with_alpha(medal, 40)) })
	frame.text_at!({ pos: { x: if index < 9 70 else 66, y: y }, text: U64.to_str(index + 1), size: 16, color: medal })
	frame.text_at!({ pos: { x: 104, y: y }, text: entry.name, size: 19, color: ink })

	# The bar is the row's score against the board's best, so the shape of the
	# board is readable before any of the numbers are.
	share = I64.to_f32(entry.score) / I64.to_f32(I64.max(best, 1))
	frame.rectangle!({ x: 348, y: y + 6, width: 220, height: 6, style: Draw.filled(Color.from_hex_rgba(0xffffff0c)) })
	frame.rectangle!({ x: 348, y: y + 6, width: 220 * share, height: 6, style: Draw.filled(Color.with_alpha(accent_ok, 190)) })
	frame.text_at!({ pos: { x: 268, y: y }, text: I64.to_str(entry.score), size: 19, color: accent_ok })
	frame.text_at!({ pos: { x: 596, y: y + 1 }, text: Time.Timestamp.to_iso_8601(entry.played_at), size: 15, color: faint })
}

## The status line, with a comet while a task is in flight and a resting dot
## once it has answered.
draw_status! : Draw.Frame, Status, F32, F32 => {}
draw_status! = |frame, status, elapsed, y| {
	color = status_color(status)
	center = { x: 44 + width_of_indicator, y: y - 46 }
	match status {
		Working =>
			List.for_each!(
				spinner_dots,
				|dot| {
					angle = elapsed * 3.6 - dot.lag
					frame.circle!({
						center: { x: center.x + 8 * F32.cos(angle), y: center.y + 8 * F32.sin(angle) },
						radius: dot.radius,
						style: Draw.filled(Color.with_alpha(color, dot.alpha)),
					})
				},
			)

		_ => frame.circle!({ center: center, radius: 5, style: Draw.filled(color) })
	}
	frame.text_at!({ pos: { x: center.x + 20, y: center.y - 9 }, text: status_line(status), size: 16, color: color })
}

## Half the indicator's width, so the status line has the same left margin as
## everything else on the screen.
width_of_indicator = 12.F32

spinner_dots : List({ lag : F32, radius : F32, alpha : U8 })
spinner_dots = [
	{ lag: 0, radius: 3.2, alpha: 255 },
	{ lag: 0.32, radius: 2.7, alpha: 190 },
	{ lag: 0.64, radius: 2.2, alpha: 135 },
	{ lag: 0.96, radius: 1.8, alpha: 85 },
]

bg_top = Color.from_hex_rgb(0x0b0e17)

bg_bottom = Color.from_hex_rgb(0x151b2a)

panel = Color.from_hex_rgb(0x141a28)

card_edge = Color.from_hex_rgb(0x2a3348)

ink = Color.from_hex_rgb(0xe8ecf5)

muted = Color.from_hex_rgb(0x8a97b0)

faint = Color.from_hex_rgb(0x5c6880)

gold = Color.from_hex_rgb(0xf2c777)

silver = Color.from_hex_rgb(0xb9c4d8)

accent_ok = Color.from_hex_rgb(0x7fd6a2)

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
		Ready => accent_ok
		Working => gold
		Failed(_) => Color.from_hex_rgb(0xef7d7d)
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
	font: Text.font_stub,
	elapsed: 0,
	title: Text.Prepared.stub,
	subtitle: Text.Prepared.stub,
	hint: Text.Prepared.stub,
}
