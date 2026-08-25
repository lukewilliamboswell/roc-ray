## Plot the line lengths of files while a source tree is still being scanned.
##
## Run this app from the directory you want to inspect. Use the wheel to scroll,
## Shift-wheel to zoom, drag to pan, R to return to new results, N to change the
## horizontal scale, and Escape to quit. Run with `--record-demo` to create the
## gallery GIF from built-in sample data. This larger example uses Tasks for
## file work, limits how much work and data it keeps at once, and draws many
## points efficiently.
app [Model, program] {
	rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc2/CaTEYs2hRbxfDqcG6deiU9kmGXaR5T1tEgf4ASxHt1S1.tar.zst",
	roc: "nightly-2026-08-23-fb208ba",
}

import rr.App
import rr.Files
import "assets/fonts/LiberationSans-Regular.ttf" as liberation_sans : List(U8)
import rr.Camera
import rr.Capture
import rr.Color
import rr.Draw
import rr.Math
import rr.Task
import rr.Text

## Walk a source tree and plot every line while it is still being discovered.
##
## Nothing about the dataset is known when this starts. There is no list of
## files: `Files.list!` reports one directory, the app decides which of its
## entries are worth descending into or reading, and enqueues more work. Run
## from the root of this repository it finds around five hundred files and a
## quarter of a million lines, and it is drawing the first of them a few frames
## in.
##
## Each line is one point -- x is how far into its file it falls, y is how many
## columns it runs to -- and each file gets a lane. The lanes stack downward
## into a strip far taller than any window, so the figure scrolls.
##
## Five things have to compose for that to work, and this example exists to show
## that they do.
##
## Discovery is incremental. `Files.list!` lists one directory and never its
## children, so a walk is the app's own loop: a listing arrives, its
## subdirectories become more listings and its files become reads, and all of it
## goes through the same backlog as everything else. A host-side recursive walk
## would be one unbounded operation that no backlog could pace.
##
## Reads never block the frame. Each listing and each read runs inside
## `Task.spawn!`. The task parks on the host's event loop while the frame loop
## keeps drawing, and its return value arrives later as an ordinary `Msg`. The
## delivered `List(U8)` is a seamless view onto the buffer the host already
## allocated, so no file bytes are copied to hand it over.
##
## Everything is paced. The host runs 32 tasks at once and queues the rest, so
## nothing is ever refused -- but this walk would happily ask for five hundred
## files at once and hold every one of them in memory. So the app keeps its own
## backlog of `Work` and starts at most `max_in_flight` tasks from it.
## `arrival_limit` bounds the other end, the bytes that have already been
## delivered and not yet parsed, which no host limit knows anything about. Both
## bounds are plain data rather than opaque handles, so the pacing is testable
## with ordinary equality. The queue depth in the masthead is the backlog being
## real.
##
## Parsing is incremental. `update!` runs inside the frame, so it may not scan a
## 400 KB file in one go. `scan_chunk` walks a bounded window of one file per
## cycle and answers with the points it found and where to resume. The frame
## time does not depend on how big the files are, only on the budget.
##
## Drawing is batched and bounded. Every point is one `Draw.TextureInstance` in
## a single list, drawn with one `frame.texture_instances!` call from one sprite
## the batch tints per lane.
##
## That leaves what is kept and what is not. A quarter of a million points is
## about sixteen megabytes of instances, and the model is copied once per frame,
## so keeping all of them would cost a gigabyte a second of copying to draw a
## figure that is mostly off screen. So they are not kept.
##
## There are two tiers, and the split is the whole memory story. Every file
## keeps a summary, forever: its path, its length, and the distribution of its
## line lengths in twenty buckets. That is a couple of hundred bytes a file, it
## is what the gutter and the density strips are drawn from, and it never grows
## with how long the app runs. Only `point_budget` points are kept, though. They
## are held as runs, one per file, in the order they were parsed; when the
## budget is exceeded the oldest run is dropped. A lane whose points have gone
## still draws -- as the density its summary describes, rather than as
## line-by-line detail.
##
## Scrolling to a lane whose points were dropped asks for the file again. That
## is the point rather than a workaround: a re-read is `Work` like any other, it
## is paced like any other, and a figure that can throw away detail and fetch it
## back on demand is one that does not care how large the tree is.
##
## Wheel scrolls, shift-wheel zooms at the pointer, drag pans, `R` returns to
## the live edge, `N` switches the x scale, `ESC` quits.
##
## Paths are resolved relative to the working directory, so run it from the
## root of the tree it should plot:
##
##     roc examples/live_plot/main.roc
##
## Run with `--record-demo` to plot a deterministic built-in source tree and
## write `examples/gallery/live_plot.gif`.
## State kept between updates: queued and active file work, partial parsing
## results, bounded point data, permanent per-file summaries, camera position,
## drawing resources, and prepared labels. These categories let scanning,
## parsing, interaction, and drawing advance a little at a time without keeping
## every line from every file in memory.
Model : {
	demo : Bool,

	## The one sprite behind every point, and the offscreen buffer it is
	## painted into. A batch draws a single texture, so hundreds of differently
	## coloured lanes come from hundreds of tints of this, not from hundreds of
	## textures and hundreds of batches.
	##
	## It is a render texture rather than a generated one because the sprite is
	## a radial falloff -- a bright core inside a wide soft halo -- and
	## `Assets.generate_color_texture!` only makes flat fills. Drawing two
	## `circle_gradient!`s into a 64x64 buffer costs one scope at the top of
	## `render!` and buys the whole look: tens of thousands of these composited
	## additively stop being a scatter of dots and become a density field.
	glow : Draw.RenderTexture,

	## The backlog of listings and reads. Only `max_in_flight` of these are
	## running as tasks at once, however much the walk has discovered.
	queue : WorkQueue,

	## What the walk has found so far, and what it is still owed.
	walk : Walk,

	## Byte lists the host has delivered but the parser has not started on.
	##
	## Holding one of these is the whole ownership story: there is no handle to
	## release and no host resource to remember. It is an ordinary Roc list, it
	## keeps the file's storage alive exactly as long as something references
	## it, and dropping it is what frees the file.
	arrivals : List(Arrival),

	## The file being parsed right now. `Idle` between files.
	parsing : [Idle, Parsing(Scan)],

	## One entry per file that has been parsed, in the order they were parsed.
	##
	## This is the permanent tier, and a lane's index in it is its position in
	## the figure: lane `n` is drawn at `n * lane_height`, which is what lets a
	## point's y say which lane it belongs to without storing anything per point.
	lanes : List(Lane),

	## The batch. One instance per line of every file whose points are still
	## being kept, in world coordinates.
	instances : List(Draw.TextureInstance),

	## Which lanes those points belong to, oldest first.
	##
	## `instances` is the concatenation of these runs in this order, so dropping
	## the oldest run is dropping a prefix of the list, and appending a newly
	## parsed file is appending to the end of both.
	runs : List(Run),

	## The lane a re-read is currently being fetched for, if any. At most one is
	## outstanding, so scrolling fast through evicted lanes queues one file
	## rather than hundreds.
	refetching : [Nothing, Fetching(U64)],

	## The longest line found anywhere so far, copied out of its file.
	peak : Peak,

	## Reads and lines per unit time, for the masthead's two graphs.
	rates : Rates,

	## Pan and zoom. A camera is a plain value, so the view costs the plot
	## nothing: the instances never move when it changes.
	camera : Camera.Camera2D,

	## Whether the view is pinned to the newest lane. Any scroll or drag drops
	## out of it; `R` returns.
	following : Bool,

	## The logical window size this cycle. `render!` is handed the model and a
	## frame but not the input, so laying the furniture out means sampling the
	## size in `update!`, where the input is.
	screen : Math.Vec2,

	## Wrapped animation clock for the sweep, in seconds.
	sweep : F32,

	## The opening move, 0 to 1.
	entrance : F32,

	## Smoothed frame rate, for the figure's own instrumentation.
	fps : F32,

	## Whether traces are drawn at their true length or normalised to fill the
	## plot. Toggled with `N`; see `XMode`.
	x_mode : XMode,

	## The zoom bucket `instances` was last sized for. Points are sized in world
	## units, so a magnified view would magnify them too; rebuilding the list
	## keeps them a constant size on screen. Doing it per frame would allocate
	## per frame, so it is done per bucket -- see `dot_step_of`.
	dot_step : I32,

	## Two atlases of one face. A glyph atlas is rasterised at the size it is
	## loaded at, so the figures and labels get one and the small tracked
	## capitals get another.
	font : Text.Font,
	small : Text.Font,
	title : Text.Prepared,
	eyebrow : Text.Prepared,
	deck : Text.Prepared,
	hint : Text.Prepared,
}

## How the x axis is scaled.
##
## `Normalised` gives every file the full width of the plot, so its trace is the
## shape of that file and two files can be compared however different their
## lengths. `True` puts every file on one shared scale, so the width of a trace
## is how long the file is -- which is the more honest picture and the less
## readable one, because these files run from nine lines to eleven thousand.
##
## The figure opens `Normalised` and keeps the length comparison the other mode
## would have given: the gutter draws each file's length as a bar.
XMode : [Normalised, True]

## What the directory walk has found and what it still owes.
##
## Only counts: the work itself lives in `pending`, and a walk that kept its own
## copy of the backlog would be a second place for it to go wrong.
Walk : {
	dirs_found : U64,
	dirs_listed : U64,
	dirs_failed : U64,
	files_found : U64,
	files_skipped : U64,
	bytes_read : U64,
}

## A delivered file, waiting its turn to be parsed.
Arrival : {
	path : Str,
	bytes : List(U8),

	## Set when this file is being fetched back for a lane that already exists,
	## rather than being met for the first time.
	replaces : [New, Lane(U64)],
}

## One retained run of points, and which lane's they are.
Run : {
	lane : U64,
	count : U64,
}

## Where the incremental parser is inside one file.
##
## `cursor` is the byte to resume at, `col` is how many columns of the current
## line were already seen by an earlier cycle, and `line` is the index of that
## line within the file -- which is also its x coordinate.
Scan : {
	lane : U64,
	bytes : List(U8),
	cursor : U64,
	col : U64,
	line : U64,
	tint : Color.Rgba,

	## World units per line index, for the points this scan emits. While a file
	## is still arriving its length is not known yet, so this is an estimate
	## from its byte count; `scan_once` corrects it in one pass when the file
	## ends. See `estimated_lines`.
	x_scale : F32,

	## World-unit size of the points this scan emits, refreshed from the model
	## each cycle so that zooming mid-parse sizes new points like the old ones.
	size : F32,
}

## Everything kept about one file, forever.
##
## This is the tier that does not grow with how long the app runs: a couple of
## hundred bytes a file, whatever the file's size, and it is what a lane whose
## points have been dropped is still drawn from.
Lane : {
	path : Str,
	tint : Color.Rgba,
	lines : U64,
	bytes : U64,
	progress : Progress,

	## World units per line index for this lane's points, as they are currently
	## laid out. Every point in a lane is `line * x_scale` across, so changing a
	## lane's scale is one multiplication per point -- which is what makes
	## `relayout` cheap enough to run on an event rather than on a frame.
	x_scale : F32,

	## Distribution of line lengths, `hist_buckets` buckets from zero columns to
	## `max_columns`. It is drawn as a violin in the gutter, and -- for a lane
	## whose points have been dropped -- as the density strip that stands in for
	## them in the plot.
	hist : List(U64),
}

## A file's position in the pipeline.
##
## There is no failure case: a file that could not be read never becomes a lane
## at all, because a lane is created from the bytes rather than from the
## discovery, and it is counted in the masthead's skipped total instead. A lane
## in this figure is always a file that was read.
Progress : [Working, Ready]

## The longest line seen, as a bounded copy of its bytes rather than a view.
Peak : {
	path : Str,
	columns : U64,
	text : Str,
}

## Throughput over the last `rate_window` samples.
##
## The counters accumulate within the current sample and the list holds the
## finished ones, so a graph never shows a partial bucket as a dip.
Rates := {
	samples : List(Sample),
	clock : F32,
	bytes : U64,
	lines : U64,
}.{
	is_eq : _

	new = || Rates.{ samples: [], clock: 0, bytes: 0, lines: 0 }

	add_bytes = |rates, count| Rates.{ samples: rates.samples, clock: rates.clock, bytes: rates.bytes + count, lines: rates.lines }

	add_lines = |rates, count| Rates.{ samples: rates.samples, clock: rates.clock, bytes: rates.bytes, lines: rates.lines + count }

	sample = |rates, delta| {
		ticked = rates.clock + delta
		if ticked < sample_period {
			Rates.{ samples: rates.samples, clock: ticked, bytes: rates.bytes, lines: rates.lines }
		} else {
			kept = if List.len(rates.samples) >= rate_window {
				List.drop_first(rates.samples, 1)
			} else {
				rates.samples
			}
			Rates.{
				samples: List.append(kept, { bytes: rates.bytes, lines: rates.lines }),
				clock: ticked - sample_period,
				bytes: 0,
				lines: 0,
			}
		}
	}

	peak = |rates, measure| List.fold(rates.samples, 1, |most, item| U64.max(most, measure(item)))

	latest = |rates, measure|
		match List.last(rates.samples) {
			Ok(item) => measure(item)
			Err(_) => 0
		}

	recent_mean = |rates, measure| {
		len = List.len(rates.samples)
		span = U64.min(len, mean_window)
		if span == 0 {
			0
		} else {
			total = List.fold(List.sublist(rates.samples, { start: len - span, len: span }), 0, |sum, item| sum + measure(item))
			U64.to_f32(total) / U64.to_f32(span)
		}
	}
}

## A sample stays open until its period has elapsed.
expect {
	part = Rates.{ samples: [], clock: 0, bytes: 900, lines: 4 }.sample(sample_period / 2)
	List.is_empty(part.samples) and part.bytes == 900
}

expect {
	closed = Rates.{ samples: [], clock: 0, bytes: 900, lines: 4 }.sample(sample_period)
	closed.samples == [{ bytes: 900, lines: 4 }] and closed.bytes == 0 and closed.lines == 0
}

## Sampling keeps a fixed-size history.
expect {
	full = List.repeat({ bytes: 1, lines: 1 }, rate_window)
	rolled = Rates.{ samples: full, clock: 0, bytes: 7, lines: 7 }.sample(sample_period)
	List.len(rolled.samples) == rate_window and List.last(rolled.samples) == Ok({ bytes: 7, lines: 7 })
}

expect Rates.{ samples: [{ bytes: 3, lines: 1 }, { bytes: 9, lines: 2 }], clock: 0, bytes: 0, lines: 0 }.peak(|item| item.bytes) == 9

## An empty history still has a peak because it is used as a divisor.
expect Rates.new().peak(|item| item.bytes) == 1
expect Rates.new().latest(|item| item.lines) == 0
expect Rates.{ samples: [{ bytes: 1, lines: 5 }], clock: 0, bytes: 0, lines: 0 }.latest(|item| item.lines) == 5

Sample : {
	bytes : U64,
	lines : U64,
}

## How much of one file a single `update!` is allowed to scan.
Budget : {
	max_lines : U64,
	max_bytes : U64,
}

## What one bounded scan found, and how to resume after it.
##
## `full` says the line budget, not the end of the window, is what stopped the
## scan. `best` locates the longest line inside this chunk as an offset into the
## file, so the caller can decide whether it is worth copying out.
ScanResult : {
	dots : List(Draw.TextureInstance),

	## The column count of each line this chunk closed, in order. It is the same
	## information the dots carry, in the form the histogram wants; recovering it
	## from a point's y would mean inverting the plot's own geometry.
	cols : List(U64),
	consumed : U64,
	col : U64,
	lines : U64,
	best : BestLine,
	full : Bool,
}

## Where a line starts in the file, and how long it is.
BestLine : {
	start : U64,
	columns : U64,
}

Msg : [

	## The path travels with the result on purpose. The task that produced it is
	## gone by the time the message arrives, so this message is all the app has
	## to work from -- to attribute the result, and to rebuild the work if it
	## ever needs asking for again.
	Listed(Str, Try(List(Files.Entry), Files.ListError)),
	FileRead(Str, [New, Lane(U64)], Try(List(U8), Files.ReadBytesError)),
]

## One unit of deferred work the walk has discovered but not yet started.
##
## Ordinary data, so the backlog can be compared, counted and tested without a
## window. `start_work!` is the only place it becomes an effect.
Work : [ListDir(Str), ReadFile(Str, [New, Lane(U64)])]

max_in_flight = 6.U64

## The app-owned backlog and the number of tasks still expected to answer.
## Keeping them in one type puts all changes to the work limit in one place.
WorkQueue := { pending : List(Work), in_flight : U64 }.{
	is_eq : _

	new = || WorkQueue.{ pending: [], in_flight: 0 }

	enqueue = |queue, work| WorkQueue.{ pending: List.append(queue.pending, work), in_flight: queue.in_flight }

	completed = |queue| WorkQueue.{ pending: queue.pending, in_flight: if queue.in_flight == 0 0 else queue.in_flight - 1 }

	take_ready = |queue| {
		room = if queue.in_flight >= max_in_flight 0 else max_in_flight - queue.in_flight
		split = List.split_at(queue.pending, U64.min(room, List.len(queue.pending)))
		{
			queue: WorkQueue.{ pending: split.others, in_flight: queue.in_flight + List.len(split.before) },
			starting: split.before,
		}
	}
}

expect WorkQueue.{ pending: [ListDir("a"), ListDir("b"), ListDir("c")], in_flight: 4 }.take_ready()
	== { queue: WorkQueue.{ pending: [ListDir("c")], in_flight: 6 }, starting: [ListDir("a"), ListDir("b")] }
expect WorkQueue.new().take_ready() == { queue: WorkQueue.new(), starting: [] }
expect WorkQueue.new().completed() == WorkQueue.new()

program = { init!, update!, render! }

demo_frames = 150.U64

record_demo_flag : Str
record_demo_flag = "--record-demo"

live_plot_config : List(Str) -> App.Config
live_plot_config = |args| {
	base = App.default
		.with_title("A tree, streamed - RocRay live plot")
		.with_size({ width: 1240, height: 860 })
		.with_min_size({ width: 980, height: 640 })
		.with_resizable(Bool.True)
		.with_frame_pacing(VSync)

	if List.contains(args, record_demo_flag) {
		base
			.with_visible(Bool.False)
			.with_output_dir("examples/gallery")
			.with_recording(
				Capture.default
					.with_path("live_plot.gif")
					.with_format(Gif)
					.with_fps(25)
					.with_max_frames(demo_frames)
					.with_scale(Half)
					.with_timing(FixedStep),
			)
	} else {
		base
	}
}

## A small built-in tree for reproducible capture. Each file still enters as a
## `FileRead` message and goes through the ordinary bounded parser.
demo_paths : List(Str)
demo_paths = [
	"platform/App.roc",
	"platform/Draw.roc",
	"src/runtime.zig",
	"src/capture.zig",
	"examples/breakout.roc",
	"examples/particles.roc",
	"docs/guide.md",
	"platform/Color.roc",
	"src/render.zig",
	"tests/host.c",
	"examples/snake.roc",
	"platform/Task.roc",
	"scripts/gallery.py",
	"docs/design.md",
	"platform/Files.roc",
	"src/input.zig",
	"examples/plot.roc",
	"README.md",
]

demo_bytes : U64 -> List(U8)
demo_bytes = |file_index| {
	lines = List.map_with_index(
		List.repeat({}, 96),
		|_unit, line_index| {
			width = 12 + ((line_index * 29 + file_index * 17 + (line_index % 7) * 11) % 104)
			Str.repeat(
				if line_index % 5 == 0 {
					"#"
				} else {
					"x"
				},
				width,
			)
		},
	)
	Str.to_utf8(Str.join_with(lines, "\n"))
}

demo_message : U64 -> Try(Msg, [None])
demo_message = |cycle| {
	interval = 6
	if cycle % interval != 0 {
		Err(None)
	} else {
		index = cycle / interval
		match List.get(demo_paths, index) {
			Ok(path) => Ok(FileRead(path, New, Ok(demo_bytes(index))))
			Err(_) => Err(None)
		}
	}
}

# ---------------------------------------------------------------------------
# The tree
# ---------------------------------------------------------------------------

## Directory names the walk will not descend into.
##
## Not a general ignore mechanism: it is the four or five places a source tree
## keeps things that are not source, and a walk that went into them would spend
## its whole budget on build output and object files.
skipped_dirs : List(Str)
skipped_dirs = [".git", ".jj", ".hg", ".svn", ".zig-cache", "zig-out", "node_modules", ".roc", "target", ".venv", "__pycache__"]

## The file extensions the walk reads, and the colour each one is drawn in.
##
## One table doing two jobs on purpose. A file whose extension is not here is
## not read at all, so this is the filter; and the tint is looked up from the
## same row, so the figure's palette is the set of languages in the tree rather
## than an arbitrary ramp. Reading the legend tells you what the tree is made of.
##
## Blues are the C family, greens are the scripting languages, sand and amber
## are the ones this repository is actually written in, and greys are the
## surrounding text and configuration.
languages : List({ ext : Str, tint : Color.Rgba })
languages = [
	{ ext: "roc", tint: Color.from_hex_rgb(0xe6b168) },
	{ ext: "zig", tint: Color.from_hex_rgb(0xe08a5a) },
	{ ext: "c", tint: Color.from_hex_rgb(0x5f9fd0) },
	{ ext: "h", tint: Color.from_hex_rgb(0x4d7fb0) },
	{ ext: "cpp", tint: Color.from_hex_rgb(0x5f9fd0) },
	{ ext: "hpp", tint: Color.from_hex_rgb(0x4d7fb0) },
	{ ext: "py", tint: Color.from_hex_rgb(0x6fbf8f) },
	{ ext: "sh", tint: Color.from_hex_rgb(0x7fc0ae) },
	{ ext: "js", tint: Color.from_hex_rgb(0xd6c46e) },
	{ ext: "ts", tint: Color.from_hex_rgb(0xc8b866) },
	{ ext: "css", tint: Color.from_hex_rgb(0x8f9fd8) },
	{ ext: "html", tint: Color.from_hex_rgb(0xc78fb2) },
	{ ext: "xml", tint: Color.from_hex_rgb(0xb08fd0) },
	{ ext: "tmx", tint: Color.from_hex_rgb(0xa885c8) },
	{ ext: "tsx", tint: Color.from_hex_rgb(0xa885c8) },
	{ ext: "fs", tint: Color.from_hex_rgb(0x9f8fd0) },
	{ ext: "vs", tint: Color.from_hex_rgb(0x9f8fd0) },
	{ ext: "md", tint: Color.from_hex_rgb(0x9aa8bd) },
	{ ext: "txt", tint: Color.from_hex_rgb(0x8b98ab) },
	{ ext: "toml", tint: Color.from_hex_rgb(0x79879a) },
	{ ext: "json", tint: Color.from_hex_rgb(0x79879a) },
	{ ext: "yml", tint: Color.from_hex_rgb(0x6d7b8d) },
	{ ext: "yaml", tint: Color.from_hex_rgb(0x6d7b8d) },
]

## The colour a file is drawn in, or nothing if the walk should not read it.
tint_of : Str -> Try(Color.Rgba, [Unread])
tint_of = |path|
	match List.find_first(languages, |language| language.ext == extension_of(path)) {
		Ok(language) => Ok(language.tint)
		Err(_) => Err(Unread)
	}

## Everything after a path's last dot, if that dot is in its last segment.
##
## `main.roc` is `roc`, `.gitignore` is nothing rather than `gitignore` -- a
## leading dot names the file, it does not give it a type -- and a path with a
## dot in a directory name but not in its filename has no extension at all.
extension_of : Str -> Str
extension_of = |path| {
	bytes = Str.to_utf8(path)
	at = last_dot(bytes, List.len(bytes))
	if at == 0 or at >= List.len(bytes) {
		""
	} else {
		Str.from_utf8_lossy(List.release_excess_capacity(List.sublist(bytes, { start: at, len: List.len(bytes) - at })))
	}
}

## Where a path's extension starts, or zero if it has none.
last_dot : List(U8), U64 -> U64
last_dot = |bytes, at|
	if at == 0 {
		0
	} else {
		before = at - 1
		match List.get(bytes, before) {
			# A dot at the start of a segment names the file rather than typing
			# it, so it is not an extension.
			Ok(46) => if before == 0 or is_separator(bytes, before - 1) {
				0
			} else {
				at
			}
			Ok(47) => 0
			Ok(_) => last_dot(bytes, before)
			Err(_) => 0
		}
	}

is_separator : List(U8), U64 -> Bool
is_separator = |bytes, at| List.get(bytes, at) == Ok(47)

## Join a directory to one of its entries.
join_path : Str, Str -> Str
join_path = |dir, name|
	if dir == "." {
		name
	} else {
		Str.concat(dir, Str.concat("/", name))
	}

## The root the walk starts from. Everything else is discovered.
walk_root : Str
walk_root = "."

## Run one unit of work as a task. The only effectful line in the walk.
start_work! : App.Input(Msg), Work => {}
start_work! = |input, work|
	match work {
		ListDir(path) => Task.spawn!(input, || Listed(path, Files.list!(path)))
		ReadFile(path, slot) => Task.spawn!(input, || FileRead(path, slot, Files.read_bytes!(path)))
	}

## Turn one directory's entries into the work they imply.
##
## Directories become listings and readable files become reads; everything else
## is counted and dropped. Both go on the same queue, which is what makes the
## walk breadth-first in practice and, more to the point, paced: discovering a
## directory of four hundred files cannot outrun the reads.
enqueue_entries : Model, Str, List(Files.Entry) -> Model
enqueue_entries = |model, dir, entries|
	List.fold(
		entries,
		model,
		|acc, entry| {
			path = join_path(dir, entry.name)
			match classify(entry) {
				Descend => {
					..acc,
					walk: { ..acc.walk, dirs_found: acc.walk.dirs_found + 1 },
					queue: acc.queue.enqueue(ListDir(path)),
				}

				Read => {
					..acc,
					walk: { ..acc.walk, files_found: acc.walk.files_found + 1 },
					queue: acc.queue.enqueue(ReadFile(path, New)),
				}

				Ignore => { ..acc, walk: { ..acc.walk, files_skipped: acc.walk.files_skipped + 1 } }
			}
		},
	)

## What the walk does with one entry.
##
## Pulled out of `enqueue_entries` so it can be tested: `enqueue_entries` needs
## a `Model`, and a `Model` holds host resources that only `init!` can produce,
## but every decision it makes lives here and needs nothing.
Decision : [Descend, Read, Ignore]

classify : Files.Entry -> Decision
classify = |entry|
	match entry.kind {
		Dir => if List.contains(skipped_dirs, entry.name) {
			Ignore
		} else {
			Descend
		}
		File =>
			match tint_of(entry.name) {
				Ok(_) => Read
				Err(_) => Ignore
			}

		Other => Ignore
	}

describe_list_error : Files.ListError -> Str
describe_list_error = |reason|
	match reason {
		NotFound => "not found"
		NotADirectory => "not a directory"
		ReadFailed => "read failed"
		Busy => "host busy"
		Unavailable => "listings unavailable"
		TooLarge => "too many entries"
	}

describe_read_error : Files.ReadBytesError -> Str
describe_read_error = |reason|
	match reason {
		NotFound => "not found"
		ReadFailed => "read failed"
		Busy => "host busy"
		Unavailable => "reads unavailable"
		TooLarge => "over the host's per-file limit"
	}

# ---------------------------------------------------------------------------
# Pacing
# ---------------------------------------------------------------------------

## How many delivered-but-unparsed files the app will hold before it stops
## asking for more.
##
## This is backpressure, and it is a different bound from `max_in_flight`: that
## one limits what the host is working on, this one limits what has already
## arrived. The parser consumes one bounded window a frame whatever it is given,
## so without this the reads win the race and the model ends up holding the
## whole tree in memory to parse it a window at a time.
arrival_limit = 8.U64

# ---------------------------------------------------------------------------
# What is kept
# ---------------------------------------------------------------------------

## How many points may be held at once.
##
## The binding cost is not drawing them -- one batch of a quarter of a million
## instances draws fine -- it is that the model is copied once per frame, so
## every retained point is paid for on every frame whether or not it is on
## screen. Sixty thousand instances is about four megabytes, which is what this
## figure spends. Raising it costs frame time in exact proportion.
point_budget = 60_000.U64

## Drop whole runs from the front until the budget is met.
##
## Oldest first, and never the run currently being parsed: `instances` is the
## runs concatenated in order, so dropping the oldest is dropping a prefix, and
## a prefix drop leaves every remaining point exactly where it was.
evict : Model -> Model
evict = |model| {
	trimmed = trim(model.instances, model.runs, point_budget)
	{ ..model, instances: trimmed.instances, runs: trimmed.runs }
}

## The pure half of `evict`, so the retention rule can be tested without a
## `Model`. Never drops the last run: that is the file being parsed right now,
## and dropping it would leave the scan appending to points that are not there.
trim : List(Draw.TextureInstance), List(Run), U64 -> { instances : List(Draw.TextureInstance), runs : List(Run) }
trim = |instances, runs, budget|
	if List.len(instances) <= budget or List.len(runs) <= 1 {
		{ instances: instances, runs: runs }
	} else {
		match List.first(runs) {
			Err(_) => { instances: instances, runs: runs }
			Ok(oldest) => trim(List.drop_first(instances, oldest.count), List.drop_first(runs, 1), budget)
		}
	}

## Whether a lane's points are still being kept.
has_run : List(Run), U64 -> Bool
has_run = |runs, lane| List.any(runs, |run| run.lane == lane)

## Add this cycle's points to the run being parsed.
grow_run : List(Run), U64 -> List(Run)
grow_run = |runs, added|
	match List.last(runs) {
		Err(_) => runs
		Ok(current) =>
			match List.set(runs, List.len(runs) - 1, { ..current, count: current.count + added }) {
				Ok(grown) => grown
				Err(_) => runs
			}
		}

# ---------------------------------------------------------------------------
# Incremental parsing
# ---------------------------------------------------------------------------

## What one `update!` may scan.
##
## Both halves matter. `max_lines` bounds how many points a cycle appends, which
## is what keeps the growing instance list from being rebuilt in one huge step.
## `max_bytes` bounds the scan itself, because a line budget alone does not:
## a generated file with one 300 KB line has a single line in it, and scanning
## for its end would cost a frame. `update!` runs inside the frame, so its cost
## has to be bounded by something the input cannot inflate.
scan_budget : Budget
scan_budget = { max_lines: 2_048, max_bytes: 65_536 }

newline = 10.U8

## Scan the next bounded window of one file into plot points.
##
## The window is a sublist of the delivered bytes, which for a host-delivered
## read is a view rather than a copy. The fold is the whole parser: a newline
## closes a line, emits its point and resets the column counter; anything else
## is one more column. Once `max_lines` lines have been closed the fold stops
## consuming, so `consumed` -- not the window length -- is what advances the
## cursor, and the next cycle resumes exactly where this one stopped.
##
## Taking the budget as an argument rather than reading the constant is what
## makes the boundary testable: the `expect`s below drive it with budgets of one
## and two lines over inputs small enough to write down.
scan_chunk : Scan, Budget -> ScanResult
scan_chunk = |scan, budget| {
	place = placement_for(scan)
	remaining = List.len(scan.bytes) - scan.cursor
	window = List.sublist(scan.bytes, { start: scan.cursor, len: U64.min(remaining, budget.max_bytes) })

	List.fold(
		window,
		{ dots: [], cols: [], consumed: 0, col: scan.col, lines: 0, best: { start: 0, columns: 0 }, full: Bool.False },
		|acc, byte|
			if acc.full {
				acc
			} else if byte == newline {
				lines = acc.lines + 1
				{
					dots: List.append(acc.dots, plot_dot(scan.line + acc.lines, acc.col, place)),
					cols: List.append(acc.cols, acc.col),
					consumed: acc.consumed + 1,
					col: 0,
					lines: lines,
					best: longer_line(acc.best, scan.cursor + acc.consumed - acc.col, acc.col),
					full: lines >= budget.max_lines,
				}
			} else {
				{ ..acc, consumed: acc.consumed + 1, col: acc.col + 1 }
			},
	)
}

## Everything about where one lane's points go that does not vary per line.
Placement : {
	baseline : F32,
	tint : Color.Rgba,
	x_scale : F32,
	size : F32,
}

placement_for : Scan -> Placement
placement_for = |scan| {
	baseline: lane_baseline(scan.lane),
	tint: scan.tint,
	x_scale: scan.x_scale,
	size: scan.size,
}

## Keep whichever of two lines has more columns.
longer_line : BestLine, U64, U64 -> BestLine
longer_line = |current, start, columns|
	if columns > current.columns {
		{ start, columns }
	} else {
		current
	}

## Place one line's point in world space.
##
## `x` is the line's index times the lane's scale and nothing else, which is
## what lets `relayout` move a whole lane by multiplying: a point at index `n`
## under scale `a` is at `n * a`, so the same point under scale `b` is at
## `x * b / a`, and no line index has to be stored anywhere to find it again.
plot_dot : U64, U64, Placement -> Draw.TextureInstance
plot_dot = |line, columns, place| {
	x = U64.to_f32(line) * place.x_scale
	y = place.baseline - column_offset(U64.to_f32(columns))
	{
		source: dot_source,
		dest: Math.rect(x, y, place.size, place.size),
		origin: { x: place.size / 2, y: place.size / 2 },
		rotation: 0,
		tint: place.tint,
	}
}

## Do this cycle's parsing: start a file if none is open, then scan one window.
##
## Exactly one window is scanned per cycle whatever happens here, which is what
## makes the bound a bound. A file that finishes leaves the parser `Idle` and
## the next one starts on the following cycle.
advance : Model -> Model
advance = |model|
	match model.parsing {
		# The scale and the point size are refreshed from the model rather than
		# carried, so a zoom or a mode change part-way through a file does not
		# leave the rest of it laid out under the old one.
		Parsing(scan) => scan_once(model, { ..scan, x_scale: scale_of(model, scan.lane), size: current_dot_size(model) })
		Idle =>
			match List.first(model.arrivals) {
				Ok(arrival) => open_scan(model, arrival)
				Err(_) => model
			}
		}

## Give a delivered file a lane and start scanning it.
##
## A lane is created here rather than when the file was discovered, so a lane's
## index is its position in parse order. That is what makes the retained runs a
## prefix-droppable sequence, and it is why nothing has to be sorted anywhere.
open_scan : Model, Arrival -> Model
open_scan = |model, arrival| {
	tint =
		match tint_of(arrival.path) {
			Ok(found) => found
			Err(_) => ink_faint
		}

	slot =
		match arrival.replaces {
			New => List.len(model.lanes)
			Lane(index) => index
		}

	fresh = {
		path: arrival.path,
		tint: tint,
		lines: 0,
		bytes: List.len(arrival.bytes),
		progress: Working,
		x_scale: line_scale,
		hist: List.repeat(0, hist_buckets),
	}

	# A re-read rebuilds the same summary from the same bytes, so the lane is
	# reset to empty first rather than counting every line twice.
	lanes =
		match arrival.replaces {
			New => List.append(model.lanes, fresh)
			Lane(index) =>
				match List.set(model.lanes, index, fresh) {
					Ok(reset) => reset
					Err(_) => model.lanes
				}
			}

	started = {
		..model,
		arrivals: List.drop_first(model.arrivals, 1),
		lanes: lanes,
		runs: List.append(model.runs, { lane: slot, count: 0 }),
		refetching: match arrival.replaces {
			New => model.refetching
			Lane(_) => Nothing
		},
	}

	# The lane records the scale its points are being drawn under, because that
	# -- not the scale it had before it was read -- is what the correction at
	# the end is relative to.
	scale = scale_of(started, slot)
	scan_once(
		{ ..started, lanes: set_scale(started.lanes, slot, scale) },
		{
			lane: slot,
			bytes: arrival.bytes,
			cursor: 0,
			col: 0,
			line: 0,
			tint: tint,
			x_scale: scale,
			size: current_dot_size(started),
		},
	)
}

scan_once : Model, Scan -> Model
scan_once = |model, scan| {
	result = scan_chunk(scan, scan_budget)
	cursor = scan.cursor + result.consumed
	done = cursor >= List.len(scan.bytes)

	# A file whose last line has no newline still has a last line.
	tail =
		if done and result.col > 0 {
			[plot_dot(scan.line + result.lines, result.col, placement_for(scan))]
		} else {
			[]
		}

	cols = if done and result.col > 0 {
		List.append(result.cols, result.col)
	} else {
		result.cols
	}
	dots = List.concat(result.dots, tail)
	grown = {
		..model,
		# One concat per cycle, not one per point. The model is still
		# referenced by the box it arrived in, so the first write to a
		# collection copies it -- batching a cycle's points into one append is
		# what turns 512 copies into one.
		instances: List.concat(model.instances, dots),
		runs: grow_run(model.runs, List.len(dots)),
		peak: retain_peak(model.peak, scan, result.best, lane_path(model, scan.lane)),
		lanes: add_lines(add_columns(model.lanes, scan.lane, cols), scan.lane, List.len(dots)),
		rates: model.rates.add_lines(List.len(dots)),
	}

	if done {
		# Dropping `scan` here is what frees the file. Nothing else references
		# those bytes by now: the arrival was moved out of `arrivals` when the
		# scan started, and the points are plain numbers.
		#
		# Marking the lane `Ready` is also what makes its true length known, so
		# this is the moment the estimate it was drawn under is corrected --
		# one pass over the batch, once per file, and the lane snaps to its
		# final width.
		relayout({ ..grown, parsing: Idle, lanes: set_progress(grown.lanes, scan.lane, Ready) })
	} else {
		{ ..grown, parsing: Parsing({ ..scan, cursor: cursor, col: result.col, line: scan.line + result.lines }) }
	}
}

## How much of the longest line to keep for the HUD.
peak_bytes = 56.U64

## Keep the longest line found so far, as bytes of its own.
##
## This is the one place the app retains a piece of a delivered read, and it is
## the reason `List.release_excess_capacity` exists. A sublist of a delivered
## file is a seamless view onto the host's buffer: retaining 56 bytes of a
## 400 KB file that way would pin all of it for as long as the HUD shows that
## line. `release_excess_capacity` deliberately copies those `peak_bytes` bytes
## into a list of their own, so the file is freed when the scan ends.
##
## `Str.from_utf8_lossy` may share storage with the list it is given, which is
## exactly why the copy has to happen first rather than being left to it.
retain_peak : Peak, Scan, BestLine, Str -> Peak
retain_peak = |peak, scan, best, path|
	if best.columns <= peak.columns {
		peak
	} else {
		slice = List.sublist(scan.bytes, { start: best.start, len: U64.min(best.columns, peak_bytes) })
		{
			path: path,
			columns: best.columns,
			text: Str.from_utf8_lossy(List.release_excess_capacity(slice)),
		}
	}

# ---------------------------------------------------------------------------
# Lane bookkeeping
# ---------------------------------------------------------------------------

update_lane : List(Lane), U64, (Lane -> Lane) -> List(Lane)
update_lane = |lanes, index, change|
	List.map_with_index(
		lanes,
		|lane, at|
			if at == index {
				change(lane)
			} else {
				lane
			},
	)

set_progress : List(Lane), U64, Progress -> List(Lane)
set_progress = |lanes, index, progress| update_lane(lanes, index, |lane| { ..lane, progress: progress })

set_scale : List(Lane), U64, F32 -> List(Lane)
set_scale = |lanes, index, scale| update_lane(lanes, index, |lane| { ..lane, x_scale: scale })

add_lines : List(Lane), U64, U64 -> List(Lane)
add_lines = |lanes, index, lines| update_lane(lanes, index, |lane| { ..lane, lines: lane.lines + lines })

lane_path : Model, U64 -> Str
lane_path = |model, index|
	match List.get(model.lanes, index) {
		Ok(lane) => lane.path
		Err(_) => ""
	}

## How many buckets the per-file distribution is drawn with. Twenty over 120
## columns is one bucket per six columns: fine enough that the 60-to-90 column
## ridge most source files have is a ridge, coarse enough to stay smooth at
## forty pixels tall.
hist_buckets = 20.U64

bucket_of : U64 -> U64
bucket_of = |columns| U64.min(columns * hist_buckets / 120, hist_buckets - 1)

## Fold one cycle's line lengths into a lane's distribution.
##
## The counting is done here rather than inside `scan_chunk`'s byte fold because
## the list it writes into is local to this call, so after the first bucket is
## written it is unshared and every later write is in place -- a few hundred
## increments on a twenty-element list, once a cycle.
add_columns : List(Lane), U64, List(U64) -> List(Lane)
add_columns = |lanes, index, cols| update_lane(lanes, index, |lane| { ..lane, hist: List.fold(cols, lane.hist, bump_bucket) })

bump_bucket : List(U64), U64 -> List(U64)
bump_bucket = |hist, columns| {
	at = bucket_of(columns)
	match List.get(hist, at) {
		Ok(count) =>
			match List.set(hist, at, count + 1) {
				Ok(bumped) => bumped
				Err(_) => hist
			}

		Err(_) => hist
	}
}

## The tallest bucket in a distribution, which is what a violin is scaled to.
hist_peak : List(U64) -> U64
hist_peak = |hist| List.fold(hist, 1, U64.max)

## How many bytes of delivered file this app is currently pinning.
##
## An arrival holds its file's bytes from the moment they are delivered until
## the scan that consumes them starts, and nothing else in the model does.
## Showing the total makes the ownership visible: it rises while the reads
## outrun the parser and falls back to zero as the parser catches up.
held_bytes : List(Arrival) -> U64
held_bytes = |arrivals| List.fold(arrivals, 0, |total, arrival| total + List.len(arrival.bytes))

ready_count : List(Lane) -> U64
ready_count = |lanes|
	List.count_if(
		lanes,
		|lane|
			match lane.progress {
				Ready => Bool.True
				_ => Bool.False
			},
	)

total_lines : List(Lane) -> U64
total_lines = |lanes| List.fold(lanes, 0, |sum, lane| sum + lane.lines)

# ---------------------------------------------------------------------------
# Throughput
# ---------------------------------------------------------------------------

## How long one sample of the throughput graphs covers, and how many are kept.
## Eight seconds of history at ten samples a second.
sample_period = 0.1.F32

rate_window = 80.U64

## How many samples the headline figure averages over: one second.
mean_window = 10.U64

## A per-sample count as a per-second rate.
per_second : F32 -> F32
per_second = |count| count / sample_period

# ---------------------------------------------------------------------------
# Plot geometry
# ---------------------------------------------------------------------------

## World units per line index on the shared scale, so a lane is as wide as its
## file is long. Twelve thousand lines is the full width of the plot; the
## longest file in this repository is about eleven thousand.
line_scale = 0.08.F32

## Columns past this are clipped to the top of the lane rather than allowed to
## rescale it. A plot whose axes move every time a longer line arrives cannot
## be read while it is still filling in, which is the state this app is in for
## most of its interesting life.
max_columns = 120.F32

## How much of a lane, in world units, the trace may use. The rest is the gap
## to the lane below.
lane_span = 32.4.F32

lane_height = 40.F32

## How far above its baseline a line of `columns` columns is drawn.
##
## The scale is a square root rather than linear, and that is a decision about
## the data rather than about the picture. Source lines are not spread evenly
## from nothing to `max_columns`: most of them are short, so under a linear
## scale nine tenths of every lane is packed into its bottom third and the
## figure is a stack of flat bands. The square root gives the crowded end the
## room and takes it from the long tail, which is what makes the ridge each file
## has, and the clear air above it, something that can be seen.
##
## `draw_rules!` marks eighty columns so the distortion is stated rather than
## hidden, and the violins in the gutter are drawn against the same scale.
column_offset : F32 -> F32
column_offset = |columns| F32.sqrt(F32.min(columns, max_columns) / max_columns) * lane_span

## The y a zero-length line sits on, for one lane.
lane_baseline : U64 -> F32
lane_baseline = |lane| U64.to_f32(lane) * lane_height + lane_span

## How wide the plot is, in world units. Unlike its height, this never changes:
## it is the axis both x scales are defined against.
world_width : F32
world_width = 12_000 * line_scale

## How tall the plot is right now. It grows by one lane every time a file
## finishes being read, which is why the figure scrolls rather than fits.
world_height : List(Lane) -> F32
world_height = |lanes| F32.max(U64.to_f32(List.len(lanes)) * lane_height, lane_height)

## The sprite the batch draws, in pixels. It is painted once per frame by
## `paint_glow!` and sampled by every one of the instances.
##
## A render texture's colour attachment is vertically flipped when it is
## sampled, which normally means asking it for `render_texture_source`. This
## sprite is radially symmetric, so its flip is its own reflection and the
## source rectangle can be the plain one -- which is what lets `plot_dot` stay a
## pure function that no test has to build a framebuffer to call.
sprite_size = 64.F32

dot_source : Math.Rect
dot_source = Math.rect(0, 0, sprite_size, sprite_size)

## Size of one point at low zoom, in world units. The sprite is mostly halo, so
## the solid core of this is about a quarter of it.
dot_size = 5.6.F32

## Points are sized in world units, so a magnified view magnifies them. The fix
## is to shrink them as the view grows, and the catch is that doing it from the
## raw zoom would rewrite the batch on every frame a wheel is turning.
##
## So the zoom is quantised first. Each step is a factor of `step_ratio`, and
## only crossing a step boundary rewrites anything.
step_ratio = 1.5.F32

max_dot_step = 9.I32

## The zoom the first step is taken at. Below it a point is drawn at `dot_size`
## and simply gets smaller with the view, which is what should happen when the
## whole figure is being looked at from further away.
step_base = 1.2.F32

dot_step_of : F32 -> I32
dot_step_of = |zoom| steps_above(zoom, step_base, 0)

steps_above : F32, F32, I32 -> I32
steps_above = |zoom, threshold, step|
	if step >= max_dot_step or zoom < threshold {
		step
	} else {
		steps_above(zoom, threshold * step_ratio, step + 1)
	}

dot_size_for : I32 -> F32
dot_size_for = |step| shrink(dot_size, step)

shrink : F32, I32 -> F32
shrink = |size, step|
	if step <= 0 {
		size
	} else {
		shrink(size / step_ratio, step - 1)
	}

current_dot_size : Model -> F32
current_dot_size = |model| dot_size_for(model.dot_step)

## How much of the window the figure's furniture keeps for itself: a masthead
## above, a key below, and a gutter on the left carrying one row per visible
## file.
hud_top = 200.F32

hud_bottom = 84.F32

hud_left = 360.F32

margin = 30.F32

## The part of the window the plot may draw in. `render!` scissors to this, so
## a dragged plot cannot scribble over the furniture.
plot_area : Math.Vec2 -> Math.Rect
plot_area = |screen|
	Math.rect(hud_left, hud_top, F32.max(screen.x - hud_left - margin, 1), F32.max(screen.y - hud_top - hud_bottom, 1))

min_zoom = 0.04.F32

max_zoom = 24.F32

# ---------------------------------------------------------------------------
# Layout of the batch
# ---------------------------------------------------------------------------
#
# The instance list is append-only and lives in world coordinates, so scrolling
# and zooming cost it nothing. What follows is the handful of things that
# genuinely do move points: a file whose true length has just become known, a
# switch between the two x scales, and a zoom large enough that world-sized
# points would no longer be point-sized on screen.
#
# All three are events, not frames. Between them this app allocates nothing per
# frame beyond what a cycle of parsing appends.

## Where lane `index`'s points should sit, given the mode and what is known
## about the file's length.
##
## A finished file is scaled by the lines it actually has. An unfinished one is
## scaled by an estimate from its byte count, so its trace grows across roughly
## the right span while it is still being read rather than crawling out of the
## left edge and then leaping.
target_scale : XMode, Lane -> F32
target_scale = |mode, lane|
	match mode {
		True => line_scale
		Normalised =>
			match lane.progress {
				Ready => normalised_scale(lane.lines)
				_ => normalised_scale(estimated_lines(lane.bytes))
			}
		}

scale_of : Model, U64 -> F32
scale_of = |model, index|
	match List.get(model.lanes, index) {
		Ok(lane) => target_scale(model.x_mode, lane)
		Err(_) => line_scale
	}

## Spread `span` lines across the full width of the plot. The last line lands on
## the right edge, so two lanes of different lengths end level.
normalised_scale : U64 -> F32
normalised_scale = |span|
	if span <= 1 {
		world_width
	} else {
		world_width / U64.to_f32(span - 1)
	}

## Lines per byte, for a file that has not been counted yet.
##
## Source files average a little under forty bytes a line. Erring high keeps an
## in-progress trace inside its lane, so the correction when the true count
## arrives pulls the trace out rather than snapping it back.
bytes_per_line = 42.U64

estimated_lines : U64 -> U64
estimated_lines = |bytes| U64.max(bytes / bytes_per_line, 1)

## Move every point to where the current mode and zoom say it belongs.
relayout : Model -> Model
relayout = |model| {
	..model,
	instances: rescale(model.instances, factors_for(model.x_mode, model.lanes), current_dot_size(model)),
	lanes: List.map(model.lanes, |lane| { ..lane, x_scale: target_scale(model.x_mode, lane) }),
	dot_step: dot_step_of(model.camera.zoom()),
}

## What each lane's points must be multiplied by to get from where they are to
## where the mode says they belong. A lane already in the right place answers 1,
## which is most of them most of the time.
factors_for : XMode, List(Lane) -> List(F32)
factors_for = |mode, lanes| List.map(lanes, |lane| target_scale(mode, lane) / lane.x_scale)

## Apply those factors, and resize every point while the list is being walked
## anyway. This is the only function in the app that touches every retained
## instance, and nothing calls it from a frame.
rescale : List(Draw.TextureInstance), List(F32), F32 -> List(Draw.TextureInstance)
rescale = |instances, factors, size|
	List.map(
		instances,
		|instance| {
			factor =
				match List.get(factors, lane_of(instance.dest.y)) {
					Ok(found) => found
					Err(_) => 1
				}
			{
				..instance,
				dest: Math.rect(instance.dest.x * factor, instance.dest.y, size, size),
				origin: { x: size / 2, y: size / 2 },
			}
		},
	)

## Which lane a point belongs to, read back off its y.
##
## Lanes are `lane_height` apart and a point never leaves its own band, so a
## point's lane is recoverable from its position and needs no per-point storage.
lane_of : F32 -> U64
lane_of = |y|
	match F32.floor_to_u64_try(y / lane_height) {
		Ok(index) => index
		Err(_) => 0
	}

# ---------------------------------------------------------------------------
# The view
# ---------------------------------------------------------------------------

## The zoom at which the plot exactly fills the width of its area.
##
## Width, not both axes: the figure is a strip hundreds of lanes tall and
## fitting all of it would make every lane a pixel high. The vertical axis is
## scrolled instead.
fit_zoom : Math.Vec2 -> F32
fit_zoom = |screen| Math.clamp(plot_area(screen).width / world_width, min_zoom, max_zoom)

## How many world units of plot the area shows at this zoom.
visible_height : Math.Rect, F32 -> F32
visible_height = |area, zoom| area.height / zoom

## How much empty space is allowed below the newest lane, as a fraction of the
## window.
##
## Without it the bottom of the strip is a hard stop, and following the live
## edge would pin the lane being parsed to the very bottom pixel of the plot --
## which is the one place a reader cannot watch it, because the trace grows into
## an edge rather than into space.
tail_room = 0.15.F32

## Keep a scroll position inside the strip, plus that room at the end.
clamp_scroll : F32, List(Lane), Math.Rect, F32 -> F32
clamp_scroll = |y, lanes, area, zoom| {
	visible = visible_height(area, zoom)
	half = visible / 2
	Math.clamp(y, half, F32.max(world_height(lanes) + visible * tail_room - half, half))
}

## Where the view sits when it is following the newest lane.
##
## The newest lane is placed three quarters of the way down rather than at the
## bottom edge, so the lane being parsed has room under it and the eye is not
## tracking something that is about to leave the screen.
follow_scroll : List(Lane), Math.Rect, F32 -> F32
follow_scroll = |lanes, area, zoom| clamp_scroll(world_height(lanes) - visible_height(area, zoom) * tail_room, lanes, area, zoom)

## Build the camera for a scroll position. The builders sanitize rather than
## refuse, so this is a plain expression and `update!` stays total.
camera_at : Math.Rect, F32, F32 -> Camera.Camera2D
camera_at = |area, zoom, scroll|
	Camera.new({ target: { x: world_width / 2, y: scroll }, offset: Math.center(area), rotation: 0, zoom: zoom })

## Zoom about the pointer, so the point under it stays under it.
##
## This is the whole recipe: read the world point beneath the pointer, change
## the zoom, read it again, and shift the target by the difference. Both reads
## use the platform's own `screen_to_world`, so the plot cannot drift away from
## what `Draw.with_camera!` will actually do with the same camera.
zoom_at : Camera.Camera2D, Math.Vec2, F32 -> Camera.Camera2D
zoom_at = |camera, pointer, wheel|
	if wheel == 0 {
		camera
	} else {
		before = camera.screen_to_world(pointer)
		# Clamping the *factor* rather than only the result keeps a violent
		# wheel spin from flipping its sign and mirroring the plot.
		factor = Math.clamp(1 + wheel * 0.14, 0.5, 2)
		zoomed = camera.with_zoom(Math.clamp(camera.zoom() * factor, min_zoom, max_zoom))
		after = zoomed.screen_to_world(pointer)
		zoomed.with_target(zoomed.target().add(before.sub(after)))
	}

## Drag the world with the pointer: a screen-space delta is a world-space delta
## divided by the zoom.
pan : Camera.Camera2D, Math.Vec2 -> Camera.Camera2D
pan = |camera, delta| camera.with_target(camera.target().sub(delta.scale(1 / camera.zoom())))

## Scroll by a fixed number of screen pixels a notch, whatever the zoom, so the
## wheel moves the page rather than the world.
scroll_pixels = 110.F32

scroll_by : Camera.Camera2D, F32 -> Camera.Camera2D
scroll_by = |camera, notches|
	if notches == 0 {
		camera
	} else {
		camera.with_target({ x: camera.target().x, y: camera.target().y - notches * scroll_pixels / camera.zoom() })
	}

## The lanes the plot area currently covers, as indices into `lanes`.
##
## With hundreds of lanes, everything the furniture draws has to be driven from
## this rather than from a scan of every lane: a per-lane loop that asked the
## camera where each one was would cost hundreds of host calls a frame to
## discover that fifteen of them are on screen.
Visible : { first : U64, last : U64 }

visible_lanes : Camera.Camera2D, Math.Rect, List(Lane) -> Visible
visible_lanes = |camera, area, lanes| {
	top = camera.screen_to_world({ x: area.x, y: area.y }).y
	bottom = camera.screen_to_world({ x: area.x, y: area.y + area.height }).y
	count = List.len(lanes)
	first = U64.min(
		lane_index_at(top),
		if count == 0 {
			0
		} else {
			count - 1
		},
	)
	last = U64.min(
		lane_index_at(bottom),
		if count == 0 {
			0
		} else {
			count - 1
		},
	)
	{ first: first, last: last }
}

lane_index_at : F32 -> U64
lane_index_at = |y|
	match F32.floor_to_u64_try(F32.max(y, 0) / lane_height) {
		Ok(index) => index
		Err(_) => 0
	}

## How long the sweep takes to cross the plot, in seconds.
sweep_period = 7.F32

## How long the opening move takes, in seconds.
entrance_seconds = 1.1.F32

## Cubic ease-out: fast at the start, settling rather than stopping.
ease_out : F32 -> F32
ease_out = |t| {
	inverted = 1 - Math.clamp(t, 0, 1)
	1 - inverted * inverted * inverted
}

other_mode : XMode -> XMode
other_mode = |mode|
	match mode {
		Normalised => True
		True => Normalised
	}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

init! : App.Init(Model, _)
init! = App.init_for_args(
	live_plot_config,
	|startup| {
		# Two sizes of the same face rather than one scaled about. A glyph atlas
		# is rasterised at the size it is loaded at, so a masthead drawn from a
		# 15-pixel atlas is soft and a table label drawn from a 34-pixel one is
		# muddy. Loading the face twice costs two resources and nothing else.
		text_font = Draw.font_from_bytes!({ format: Ttf, bytes: liberation_sans, size: 17 })?
		small_font = Draw.font_from_bytes!({ format: Ttf, bytes: liberation_sans, size: 11 })?
		display_font = Draw.font_from_bytes!({ format: Ttf, bytes: liberation_sans, size: 34 })?

		# The sprite the whole batch is drawn from, painted by `paint_glow!` at
		# the top of every frame.
		glow = Draw.load_render_texture!({ width: 64, height: 64 })?

		eyebrow = Text.from("STREAMED FROM THE WORKING DIRECTORY", small_font).size(11).spacing(3.2).prepare!()?
		title = Text.from("A tree, one line at a time", display_font).size(30).prepare!()?
		deck =
			Text.from("Every readable file under this directory is found, read and parsed while the frame keeps moving. One point is one line.", text_font)
				.size(14)
				.prepare!()?
		hint =
			Text.from("WHEEL scroll      SHIFT-WHEEL zoom      DRAG pan      R live edge      N true scale      ESC quit", small_font)
				.size(11)
				.spacing(1.6)
				.prepare!()?

		Ok({
			demo: List.contains(App.args!(startup), record_demo_flag),
			glow: glow,
			queue: WorkQueue.new(),
			walk: { dirs_found: 0, dirs_listed: 0, dirs_failed: 0, files_found: 0, files_skipped: 0, bytes_read: 0 },
			arrivals: [],
			parsing: Idle,
			lanes: [],
			instances: [],
			runs: [],
			refetching: Nothing,
			peak: { path: "", columns: 0, text: "" },
			rates: Rates.new(),
			camera: Camera.default,
			following: Bool.True,
			# The configured size, replaced by the sampled one on the first
			# cycle. `render!` never sees this value: a cycle updates first.
			screen: { x: 1240, y: 860 },
			sweep: 0,
			entrance: 0,
			fps: 0,
			x_mode: Normalised,
			dot_step: 0,
			font: text_font,
			small: small_font,
			title: title,
			eyebrow: eyebrow,
			deck: deck,
			hint: hint,
		})
	},
)

## The batch's texture: the colour attachment of the sprite buffer, viewed
## without copying it. The reference keeps the framebuffer alive.
sprite_of : Model -> Draw.Texture
sprite_of = |model| Draw.render_texture(model.glow)

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	# 1. Fold this cycle's completions in. Each one ends a task this update
	#    started, so each one frees a slot -- and a listing may enqueue a great
	#    deal more work while it is at it.
	received = List.fold(program_input.messages, model, receive)
	settled_model =
		if model.demo {
			match demo_message(program_input.time.cycle_count) {
				Ok(message) => {
					with_file = { ..received, walk: { ..received.walk, files_found: received.walk.files_found + 1 } }
					receive(with_file, message)
				}
				Err(_) => received
			}
		} else {
			received
		}

	# 2. Ask for the root. Everything else in the walk is discovered from it.
	primed =
		if !model.demo and program_input.time.cycle_count == 0 {
			{
				..settled_model,
				walk: { ..settled_model.walk, dirs_found: 1 },
				queue: settled_model.queue.enqueue(ListDir(walk_root)),
			}
		} else {
			settled_model
		}

	# 3. One bounded window of parsing, whatever else happened, and then the
	#    retention budget. Eviction is here rather than in `render!` because it
	#    is a fact about the model, not about how it is drawn.
	parsed = evict(advance(primed))

	# 4. The view is pure state too, so a headless run scrolls the same way an
	#    interactive one does.
	viewed = look(parsed, program_input)

	# 5. Ask for a file back if the view has scrolled onto a lane whose points
	#    were dropped. At most one of these is outstanding.
	refetched = if model.demo {
		viewed
	} else {
		request_refetch(viewed)
	}

	# 6. Start whatever fits -- unless the parser is already behind. The
	#    in-flight budget bounds how many reads are *running*; this bounds how
	#    many delivered files are waiting for the scanner, which is the thing
	#    that actually pins memory. Without it a fast disk fills the model with
	#    a whole tree of bytes while the parser works through it one window at
	#    a time.
	ready =
		if model.demo or List.len(refetched.arrivals) >= arrival_limit {
			{ queue: refetched.queue, starting: [] }
		} else {
			refetched.queue.take_ready()
		}

	for work in ready.starting {
		start_work!(program_input, work)
	}

	exit =
		if model.demo {
			match program_input.capture {
				Finished(_) => Err(Exit(0))
				Failed(_) => Err(Exit(1))
				_ => Ok({})
			}
		} else if program_input.devices.key_pressed(KeyEscape) {
			Err(Exit(0))
		} else {
			Ok({})
		}

	match exit {
		Err(code) => Err(code)
		Ok({}) => Ok({ ..refetched, queue: ready.queue })
	}
}

## Fold one completion into the model.
receive : Model, Msg -> Model
receive = |model, message|
	match message {
		Listed(dir, Ok(entries)) =>
			enqueue_entries(
				{
					..model,
					queue: model.queue.completed(),
					walk: { ..model.walk, dirs_listed: model.walk.dirs_listed + 1 },
				},
				dir,
				entries,
			)

		# A refused listing still ended, so its slot is free, and the work goes
		# back on the tail of the backlog to be started again. The host queues
		# tasks rather than refusing them, so this branch should never be taken;
		# it is here because the error union says it can be.
		Listed(dir, Err(Busy)) => {
			..model,
			queue: model.queue.completed().enqueue(ListDir(dir)),
		}

		Listed(_dir, Err(_reason)) => {
			..model,
			queue: model.queue.completed(),
			walk: { ..model.walk, dirs_listed: model.walk.dirs_listed + 1, dirs_failed: model.walk.dirs_failed + 1 },
		}

		FileRead(path, slot, Ok(bytes)) => {
			..model,
			queue: model.queue.completed(),
			# The bytes go straight into the model. There is no copy here and
			# no host handle to hold: the list *is* the ownership.
			arrivals: List.append(model.arrivals, { path: path, bytes: bytes, replaces: slot }),
			walk: { ..model.walk, bytes_read: model.walk.bytes_read + List.len(bytes) },
			rates: model.rates.add_bytes(List.len(bytes)),
		}

		FileRead(path, slot, Err(Busy)) => {
			..model,
			queue: model.queue.completed().enqueue(ReadFile(path, slot)),
		}

		FileRead(_path, New, Err(_reason)) => {
			..model,
			queue: model.queue.completed(),
			walk: { ..model.walk, files_skipped: model.walk.files_skipped + 1 },
		}

		# A re-read that failed leaves the lane exactly as it was -- summary
		# without points -- and clears the slot so another can be asked for.
		FileRead(_path, Lane(_index), Err(_reason)) => {
			..model,
			queue: model.queue.completed(),
			refetching: Nothing,
		}
	}

## Advance the camera, the clocks and the throughput samples.
look : Model, App.Input(Msg) -> Model
look = |model, program_input| {
	input = program_input.devices
	screen = { x: I32.to_f32(program_input.window.size.width), y: I32.to_f32(program_input.window.size.height) }
	area = plot_area(screen)

	wheel = input.mouse.wheel_delta().y
	zooming = input.key_down(KeyLeftShift) or input.key_down(KeyRightShift)
	dragging = input.mouse.button_down(Left)
	refit = input.key_pressed(KeyR)

	delta = F32.min(program_input.time.elapsed_seconds, 0.05)
	advanced = model.sweep + delta
	opened = F32.min(model.entrance + delta / entrance_seconds, 1)

	# Any deliberate movement of the view leaves the live edge; `R` returns.
	moved = (wheel != 0) or dragging
	following = if refit {
		Bool.True
	} else {
		model.following and !moved
	}

	fitted = fit_zoom(screen)

	# Re-centring on every cycle is what makes a resize keep the same world
	# point in the middle of the plot rather than sliding it.
	base = model.camera.with_offset(Math.center(area))
	zoomed = if zooming {
		zoom_at(base, input.mouse.position(), wheel)
	} else {
		scroll_by(base, wheel)
	}
	panned = if dragging {
		pan(zoomed, input.mouse.delta())
	} else {
		zoomed
	}

	settled =
		if model.entrance < 1 {
			# The opening move. The camera is the fitted one seen slightly too
			# close, easing back, and pinned to the top of the strip.
			camera_at(area, fitted * Math.lerp(0.87, 1, ease_out(opened)), clamp_scroll(0, model.lanes, area, fitted))
		} else if following {
			camera_at(area, panned.zoom(), follow_scroll(model.lanes, area, panned.zoom()))
		} else {
			panned.with_target({ x: panned.target().x, y: clamp_scroll(panned.target().y, model.lanes, area, panned.zoom()) })
		}

	mode = if input.key_pressed(KeyN) {
		other_mode(model.x_mode)
	} else {
		model.x_mode
	}

	next = {
		..model,
		camera: settled,
		following: following,
		screen: screen,
		sweep: if advanced >= sweep_period {
			advanced - sweep_period
		} else {
			advanced
		},
		entrance: opened,
		fps: if delta > 0 {
			Math.lerp(model.fps, 1 / delta, 0.06)
		} else {
			model.fps
		},
		x_mode: mode,
		rates: model.rates.sample(delta),
	}

	# The two things that move points rather than the view. Both are rare, and
	# checking for them is what keeps them off the frame's critical path.
	if mode != model.x_mode or dot_step_of(settled.zoom()) != model.dot_step {
		relayout(next)
	} else {
		next
	}
}

## Ask for one file back, if the view is looking at a lane whose points were
## dropped and nothing else is already being fetched.
##
## This is the other half of the retention budget. Points are thrown away
## oldest-first without regard for where the view is, which is only reasonable
## because getting them back is a read like any other -- on the same backlog,
## delivered as the same message, parsed by the same scanner.
request_refetch : Model -> Model
request_refetch = |model|
	match model.refetching {
		Fetching(_) => model
		Nothing =>
			if model.following {
				model
			} else {
				area = plot_area(model.screen)
				window = visible_lanes(model.camera, area, model.lanes)
				match first_evicted(model, window) {
					Err(_) => model
					Ok(index) => {
						..model,
						refetching: Fetching(index),
						queue: model.queue.enqueue(ReadFile(lane_path(model, index), Lane(index))),
					}
				}
			}
		}

## The first visible lane that is finished but has no points left.
first_evicted : Model, Visible -> Try(U64, [None])
first_evicted = |model, window| scan_for_evicted(model, window.first, window.last)

scan_for_evicted : Model, U64, U64 -> Try(U64, [None])
scan_for_evicted = |model, at, last|
	if at > last {
		Err(None)
	} else {
		match List.get(model.lanes, at) {
			Err(_) => Err(None)
			Ok(lane) =>
				match lane.progress {
					Ready =>
						if has_run(model.runs, at) {
							scan_for_evicted(model, at + 1, last)
						} else {
							Ok(at)
						}

					_ => scan_for_evicted(model, at + 1, last)
				}
			}
	}

# ---------------------------------------------------------------------------
# The palette
# ---------------------------------------------------------------------------
#
# One ground, four inks, one accent, and the language ramp in `languages`.
# Nothing outside them.

ground_top : Color.Rgba
ground_top = Color.from_hex_rgb(0x0e131b)

ground_bottom : Color.Rgba
ground_bottom = Color.from_hex_rgb(0x090d13)

## Alternating lane bands. The contrast between them is deliberately at the
## edge of visible: they are there to let the eye track one lane across the
## plot, not to be looked at.
band_even : Color.Rgba
band_even = Color.from_hex_rgb(0x131a25)

band_odd : Color.Rgba
band_odd = Color.from_hex_rgb(0x10161f)

rule : Color.Rgba
rule = Color.from_hex_rgb(0x1e2836)

rule_strong : Color.Rgba
rule_strong = Color.from_hex_rgb(0x2f3c4f)

ink : Color.Rgba
ink = Color.from_hex_rgb(0xe6ecf3)

ink_dim : Color.Rgba
ink_dim = Color.from_hex_rgb(0x8fa0b5)

ink_faint : Color.Rgba
ink_faint = Color.from_hex_rgb(0x596677)

accent : Color.Rgba
accent = Color.from_hex_rgb(0xe0a458)

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ScopeUnavailable, ..])
render! = |model, frame| {
	# The sprite first, because everything else samples it. It is one scope and
	# two gradients whatever is on screen.
	paint_glow!(frame, model)?

	draw_page!(frame, model)
	draw_plot!(frame, model)?
	draw_masthead!(frame, model)
	draw_gutter!(frame, model)?
	draw_footer!(frame, model)
	Ok({})
}

## Paint the point sprite: a small bright core inside a wide soft halo.
##
## This is the whole reason the figure reads as a density field rather than a
## scatter. A hard square tells you a line exists there; twenty of them on top
## of each other tell you nothing more. A halo composited additively adds up, so
## where lines of a given length are common the lane glows, and a single
## outlying line stays a single visible spark.
paint_glow! : Draw.Frame, Model => Try({}, [ScopeLimit, ScopeUnavailable, ..])
paint_glow! = |frame, model|
	frame.with_render_texture!(
		model.glow,
		|sprite| {
			sprite.clear!(Color.transparent)
			half = sprite_size / 2
			sprite.circle_gradient!({
				center: { x: half, y: half },
				radius: half,
				color_inner: Color.rgba(255, 255, 255, 90),
				color_outer: Color.rgba(255, 255, 255, 0),
			})
			sprite.circle_gradient!({
				center: { x: half, y: half },
				radius: half * 0.26,
				color_inner: Color.rgba(255, 255, 255, 255),
				color_outer: Color.rgba(255, 255, 255, 0),
			})
			Ok({})
		},
	)

## The ground: one shallow vertical gradient, and nothing else.
draw_page! : Draw.Frame, Model => {}
draw_page! = |frame, model| {
	frame.clear!(ground_bottom)
	frame.rectangle_gradient_v!({
		x: 0,
		y: 0,
		width: model.screen.x,
		height: model.screen.y,
		color_top: ground_top,
		color_bottom: ground_bottom,
	})
}

draw_plot! : Draw.Frame, Model => Try({}, [ScopeLimit, ..])
draw_plot! = |frame, model| {
	area = plot_area(model.screen)
	window = visible_lanes(model.camera, area, model.lanes)

	frame.with_scissor!(
		area,
		|clipped| {
			# The lane bands are drawn in screen space at the y the camera puts
			# them, rather than in world space with the points. A band is a row
			# of the table, so it should span the plot however far the view has
			# been dragged sideways -- which a world-space rectangle stops doing
			# the moment it is panned.
			draw_bands!(clipped, model, area, window)
			draw_rules!(clipped, model, area, window)

			clipped.with_camera!(
				model.camera,
				|world| {
					draw_summaries!(world, model, window)
					draw_points!(world, model)?
					draw_head!(world, model)
					Ok({})
				},
			)?

			draw_sweep!(clipped, model, area)
			Ok({})
		},
	)?

	frame.rectangle!({ x: area.x, y: area.y, width: area.width, height: area.height, style: Draw.outlined(rule, 1) })
	Ok({})
}

## One band per visible file, alternating, with the lane being parsed lifted out
## of the alternation so the eye can find it.
draw_bands! : Draw.Frame, Model, Math.Rect, Visible => {}
draw_bands! = |frame, model, area, window|
	List.for_each!(
		lane_indices(window),
		|index| {
			top = screen_y(model, U64.to_f32(index) * lane_height)
			bottom = screen_y(model, U64.to_f32(index + 1) * lane_height)
			working = is_working(model, index)
			frame.rectangle!({
				x: area.x,
				y: top,
				width: area.width,
				height: F32.max(bottom - top - 1, 1),
				style: Draw.filled(
					if working {
						Color.from_hex_rgb(0x18202c)
					} else if index % 2 == 0 {
						band_even
					} else {
						band_odd
					},
				),
			})
		},
	)

## The two reference lines every lane carries.
##
## The baseline is where a zero-column line would sit. The other is eighty
## columns, which is the only y in this figure that means something outside it:
## it is the width most of these files were written to keep under, so how much
## of a lane's mass sits above it is how often that file broke its own rule.
draw_rules! : Draw.Frame, Model, Math.Rect, Visible => {}
draw_rules! = |frame, model, area, window| {
	named = window.first
	List.for_each!(
		lane_indices(window),
		|index| {
			baseline = screen_y(model, lane_baseline(index))
			eighty = screen_y(model, lane_baseline(index) - column_offset(80))
			if baseline >= area.y and baseline <= area.y + area.height {
				frame.line!({
					start: { x: area.x, y: baseline },
					end: { x: area.x + area.width, y: baseline },
					stroke: Draw.stroke(rule_strong, 1),
				})
			} else {
				{}
			}
			if eighty >= area.y + 16 and eighty <= area.y + area.height {
				frame.line!({
					start: { x: area.x, y: eighty },
					end: { x: area.x + area.width, y: eighty },
					stroke: Draw.stroke(Color.with_alpha(rule_strong, 190), 1),
				})
				# Named once rather than on every lane. It is the only y in the
				# figure that means anything outside it, and the only thing that
				# says the axis is not linear.
				if index == named {
					text_left!(frame, model.small, { x: area.x + 8, y: eighty - 14 }, "80 COLUMNS", 9, 1.6, ink_faint)
				} else {
					{}
				}
			} else {
				{}
			}
		},
	)
}

## Lanes whose points have been dropped, drawn as the density their summary
## describes.
##
## This is what the retention budget buys back. The detail is gone -- there is
## no line-by-line trace to draw -- but the shape of the file is still known
## exactly, so the lane shows its distribution as a stack of bands rather than
## going blank. Scrolling onto one asks for the file again; until it arrives,
## this is what is there.
draw_summaries! : Draw.Frame, Model, Visible => {}
draw_summaries! = |frame, model, window|
	List.for_each!(
		lane_indices(window),
		|index|
			if has_run(model.runs, index) {
				{}
			} else {
				match List.get(model.lanes, index) {
					Err(_) => {}
					Ok(lane) => draw_density!(frame, lane, index)
				}
			},
	)

draw_density! : Draw.Frame, Lane, U64 => {}
draw_density! = |frame, lane, index| {
	baseline = lane_baseline(index)
	peak = U64.to_f32(hist_peak(lane.hist))
	span = max_columns / U64.to_f32(hist_buckets)

	List.for_each!(
		indexed(lane.hist),
		|entry|
			if entry.value == 0 {
				{}
			} else {
				low = column_offset(U64.to_f32(entry.index) * span)
				high = column_offset(U64.to_f32(entry.index + 1) * span)
				weight = F32.sqrt(U64.to_f32(entry.value) / peak)
				frame.rectangle!({
					x: 0,
					y: baseline - high,
					width: world_width,
					height: F32.max(high - low, 0.4),
					style: Draw.filled(Color.with_alpha(lane.tint, alpha_of(18 + weight * 74))),
				})
			},
	)
}

## Every retained point, in one crossing of the Roc/host boundary -- and then,
## while a file is still being parsed, the last few hundred of them a second
## time.
##
## The second draw is the trail: the same instances, drawn again white and
## additively over their own colour, so the frontier of the scan is a bright
## comet head fading back into the finished trace behind it. It costs a view of
## the tail of the list rather than a copy of it, and it is the difference
## between watching data arrive and watching a picture appear.
draw_points! : Draw.Frame, Model => Try({}, [ScopeLimit, ..])
draw_points! = |frame, model|
	frame.with_blend_mode!(
		Draw.additive_blend,
		|blended| {
			blended.texture_instances!(sprite_of(model), model.instances)

			match model.parsing {
				Idle => {}
				Parsing(_) => {
					total = List.len(model.instances)
					len = U64.min(total, trail_length)
					blended.texture_instances!(
						sprite_of(model),
						List.map_with_index(
							List.sublist(model.instances, { start: total - len, len: len }),
							|instance, at| {
								# Newest last, so the far end of the tail is the
								# brightest part of it.
								heat = U64.to_f32(at + 1) / U64.to_f32(len)
								{ ..instance, tint: Color.with_alpha(Color.white, alpha_of(heat * heat * 150)) }
							},
						),
					)
				}
			}
			Ok({})
		},
	)

## How many of the most recent points the trail covers.
trail_length = 900.U64

## The scan frontier: where in its lane the parser has got to, this instant.
draw_head! : Draw.Frame, Model => {}
draw_head! = |frame, model|
	match model.parsing {
		Idle => {}
		Parsing(scan) => {
			x = U64.to_f32(scan.line) * scan.x_scale
			top = U64.to_f32(scan.lane) * lane_height
			frame.line!({
				start: { x: x, y: top + 2 },
				end: { x: x, y: top + lane_height - 4 },
				stroke: Draw.stroke(Color.with_alpha(accent, 190), 1.4 / model.camera.zoom()),
			})
		}
	}

## A slow highlight crossing the plot, driven by `program_input.time` alone, so the frame
## has something moving in it whether or not data is still arriving.
draw_sweep! : Draw.Frame, Model, Math.Rect => {}
draw_sweep! = |frame, model, area| {
	width = area.width * 0.16
	x = area.x - width + (area.width + width * 2) * (model.sweep / sweep_period)
	frame.rectangle_gradient_h!({
		x: x,
		y: area.y,
		width: width,
		height: area.height,
		color_left: Color.rgba(255, 255, 255, 0),
		color_right: Color.rgba(160, 200, 255, 9),
	})
	frame.rectangle_gradient_h!({
		x: x + width,
		y: area.y,
		width: width * 0.5,
		height: area.height,
		color_left: Color.rgba(160, 200, 255, 9),
		color_right: Color.rgba(255, 255, 255, 0),
	})
}

## Where a world y lands on the screen. Every lane is a row of a table, so the
## rows have to follow the camera even when what is drawn in them does not.
screen_y : Model, F32 -> F32
screen_y = |model, y| model.camera.world_to_screen({ x: 0, y: y }).y

## The visible lanes, as a list to walk. With hundreds of lanes this is the only
## thing the furniture ever iterates.
lane_indices : Visible -> List(U64)
lane_indices = |window|
	if window.last < window.first {
		[]
	} else {
		count_up(window.first, window.last, [])
	}

count_up : U64, U64, List(U64) -> List(U64)
count_up = |at, last, found|
	if at > last {
		found
	} else {
		count_up(at + 1, last, List.append(found, at))
	}

is_working : Model, U64 -> Bool
is_working = |model, index|
	match model.parsing {
		Idle => Bool.False
		Parsing(scan) => scan.lane == index
	}

# ---------------------------------------------------------------------------
# The masthead
# ---------------------------------------------------------------------------

draw_masthead! : Draw.Frame, Model => {}
draw_masthead! = |frame, model| {
	fade = ease_out(model.entrance)

	model.eyebrow.draw!(frame, { pos: { x: margin, y: 26 }, color: fade_to(ink_faint, fade) })
	model.title.draw!(frame, { pos: { x: margin, y: 40 }, color: fade_to(ink, fade) })
	model.deck.draw!(frame, { pos: { x: margin, y: 84 }, color: fade_to(ink_dim, fade) })

	draw_graphs!(frame, model, fade)

	frame.line!({ start: { x: margin, y: 116 }, end: { x: model.screen.x - margin, y: 116 }, stroke: Draw.stroke(rule, 1) })

	draw_figures!(frame, model, fade)
}

## The two things this figure is actually measuring about itself: how fast bytes
## are arriving, and how fast lines are being turned into points.
##
## They are drawn as history rather than as numbers because the number alone
## cannot show the shape of it -- the burst while a directory of small files
## lands, the plateau while a 400 KB file is read, the fall to nothing when the
## walk runs out. `Rates` keeps eight seconds of it in eighty samples.
draw_graphs! : Draw.Frame, Model, F32 => {}
draw_graphs! = |frame, model, fade| {
	width = 208
	gap = 18
	right = model.screen.x - margin
	reading = Str.concat(one_decimal(per_second(model.rates.recent_mean(|sample| sample.bytes)) / 1_048_576), " MiB/s")
	parsing = Str.concat(commas(rounded(per_second(model.rates.recent_mean(|sample| sample.lines)))), " lines/s")

	draw_graph!(
		frame,
		model,
		{
			bounds: Math.rect(right - width * 2 - gap, 24, width, 64),
			label: "READ THROUGHPUT",
			value: reading,
			of: |sample| sample.bytes,
			tint: Color.from_hex_rgb(0x6fa8d8),
			fade: fade,
		},
	)
	draw_graph!(
		frame,
		model,
		{
			bounds: Math.rect(right - width, 24, width, 64),
			label: "PARSE RATE",
			value: parsing,
			of: |sample| sample.lines,
			tint: Color.from_hex_rgb(0x7fc0a0),
			fade: fade,
		},
	)
}

Graph : {
	bounds : Math.Rect,
	label : Str,
	value : Str,
	of : Sample -> U64,
	tint : Color.Rgba,
	fade : F32,
}

draw_graph! : Draw.Frame, Model, Graph => {}
draw_graph! = |frame, model, graph| {
	bounds = graph.bounds
	plot_top = bounds.y + 30
	plot_height = bounds.y + bounds.height - plot_top
	measure = graph.of
	peak = U64.to_f32(model.rates.peak(measure))
	step = bounds.width / U64.to_f32(rate_window)

	text_left!(frame, model.small, { x: bounds.x, y: bounds.y }, graph.label, 9, 1.5, fade_to(ink_faint, graph.fade))
	text_left!(frame, model.font, { x: bounds.x, y: bounds.y + 12 }, graph.value, 14, Draw.default_spacing, fade_to(ink, graph.fade))

	frame.line!({
		start: { x: bounds.x, y: bounds.y + bounds.height },
		end: { x: bounds.x + bounds.width, y: bounds.y + bounds.height },
		stroke: Draw.stroke(Color.with_alpha(rule, alpha_of(graph.fade * 255)), 1),
	})

	# Oldest sample on the left, so the graph reads the way time does. A
	# half-full window draws from the left too, which is why the bars are placed
	# by index rather than right-aligned: a run that has only been going two
	# seconds should look like two seconds of history, not like a full window
	# that happens to be flat.
	List.for_each!(
		indexed(model.rates.samples),
		|entry| {
			height = plot_height * U64.to_f32(measure(entry.value)) / peak
			if height < 0.6 {
				{}
			} else {
				frame.rectangle!({
					x: bounds.x + U64.to_f32(entry.index) * step,
					y: plot_top + plot_height - height,
					width: F32.max(step - 0.8, 0.8),
					height: height,
					style: Draw.filled(Color.with_alpha(graph.tint, alpha_of(graph.fade * 190))),
				})
			}
		},
	)
}

## The figures under the rule, as a row of label-over-value columns.
##
## Everything here is a fact about how the app is working rather than about the
## data. That is deliberate: the walk, the queue and the retention budget are
## what the example is demonstrating, so they get the room.
draw_figures! : Draw.Frame, Model, F32 => {}
draw_figures! = |frame, model, fade| {
	figures = [
		{
			label: "FILES PARSED",
			value: Str.concat(commas(ready_count(model.lanes)), Str.concat(" of ", commas(model.walk.files_found))),
			note: Str.concat("SKIPPED ", commas(model.walk.files_skipped)),
		},
		{ label: "LINES", value: commas(total_lines(model.lanes)), note: Str.concat("READ ", size_str(model.walk.bytes_read)) },
		{
			label: "DIRECTORIES",
			value: Str.concat(commas(model.walk.dirs_listed), Str.concat(" of ", commas(model.walk.dirs_found))),
			note: if model.walk.dirs_failed == 0 {
				""
			} else {
				Str.concat("FAILED ", commas(model.walk.dirs_failed))
			},
		},
		{
			label: "QUEUED",
			value: commas(List.len(model.queue.pending)),
			note: Str.concat("IN FLIGHT ", Str.concat(U64.to_str(model.queue.in_flight), Str.concat(" / ", U64.to_str(max_in_flight)))),
		},
		{
			label: "FILE BYTES HELD",
			value: size_str(held_bytes(model.arrivals)),
			note: Str.concat("TO PARSE ", commas(List.len(model.arrivals))),
		},
		{
			label: "POINTS KEPT",
			value: commas(List.len(model.instances)),
			note: Str.concat("OF ", Str.concat(commas(point_budget), Str.concat(" IN ", Str.concat(commas(List.len(model.runs)), " FILES")))),
		},
		{
			label: "X AXIS",
			value: mode_label(model.x_mode),
			note: if model.following {
				"FOLLOWING"
			} else {
				"HELD"
			},
		},
		{ label: "FRAME RATE", value: Str.concat(U64.to_str(rounded(model.fps)), " fps"), note: "" },
	]

	pitch = (model.screen.x - margin * 2) / U64.to_f32(List.len(figures))

	List.for_each!(
		indexed(figures),
		|entry| {
			x = margin + U64.to_f32(entry.index) * pitch
			text_left!(frame, model.small, { x: x, y: 130 }, entry.value.label, 10, 1.5, fade_to(ink_faint, fade))
			text_left!(frame, model.font, { x: x, y: 144 }, entry.value.value, 17, Draw.default_spacing, fade_to(ink, fade))
			text_left!(frame, model.small, { x: x, y: 166 }, entry.value.note, 9, 1.4, fade_to(Color.with_alpha(ink_faint, 190), fade))
		},
	)
}

mode_label : XMode -> Str
mode_label = |mode|
	match mode {
		Normalised => "normalised"
		True => "true length"
	}

# ---------------------------------------------------------------------------
# The gutter
# ---------------------------------------------------------------------------

## One row per visible file. Only the visible ones: with hundreds of lanes, a
## per-lane loop would cost hundreds of camera queries a frame to discover that
## fifteen of them are on screen.
draw_gutter! : Draw.Frame, Model => Try({}, [ScopeLimit, ..])
draw_gutter! = |frame, model| {
	area = plot_area(model.screen)
	window = visible_lanes(model.camera, area, model.lanes)
	longest = F32.max(U64.to_f32(widest_lane(model, window)), 1)

	frame.with_scissor!(
		Math.rect(0, area.y, hud_left, area.height),
		|clipped| {
			List.for_each!(
				lane_indices(window),
				|index|
					match List.get(model.lanes, index) {
						Err(_) => {}
						Ok(lane) =>
							draw_row!(
								clipped,
								model,
								{
									lane: lane,
									index: index,
									top: screen_y(model, U64.to_f32(index) * lane_height),
									bottom: screen_y(model, U64.to_f32(index + 1) * lane_height),
									longest: longest,
									area: area,
								},
							)
						},
			)
			Ok({})
		},
	)
}

## The longest visible file, which is what the length bars are drawn against.
##
## Scaling to the visible window rather than to the whole tree is what keeps the
## bars readable: one 11,000-line file would otherwise flatten every bar on
## screen to nothing for the rest of the run.
widest_lane : Model, Visible -> U64
widest_lane = |model, window|
	List.fold(
		lane_indices(window),
		1,
		|most, index|
			match List.get(model.lanes, index) {
				Ok(lane) => U64.max(most, lane.lines)
				Err(_) => most
			},
	)

Row : {
	lane : Lane,
	index : U64,
	top : F32,
	bottom : F32,
	longest : F32,
	area : Math.Rect,
}

draw_row! : Draw.Frame, Model, Row => {}
draw_row! = |frame, model, row| {
	working = is_working(model, row.index)
	kept = has_run(model.runs, row.index)
	height = row.bottom - row.top

	# The tint is a rule down the side of the row rather than a swatch, so it
	# reads as the lane's own edge rather than as a bullet point.
	frame.rectangle!({
		x: margin,
		y: row.top + 2,
		width: 2,
		height: F32.max(height - 5, 2),
		style: Draw.filled(
			Color.with_alpha(
				row.lane.tint,
				if working {
					255
				} else {
					140
				},
			),
		),
	})

	if height < 15 {
		# Zoomed far enough out that a label would not fit in its row. The tint
		# rules alone still show the shape of the tree.
		{}
	} else {
		# Clamped only for a row taller than the whole plot, which is what a
		# deep zoom produces. Clamping a normal row would push its label into
		# its neighbour's the moment it started to scroll off the edge, and the
		# scissor already hides whatever runs past it.
		centred = row.top + height * 0.5 - 15
		label_y =
			if height > row.area.height {
				Math.clamp(centred, row.area.y + 6, row.area.y + row.area.height - 34)
			} else {
				centred
			}

		text_left!(
			frame,
			model.font,
			{ x: margin + 14, y: label_y },
			shorten(row.lane.path, 26),
			12.5,
			Draw.default_spacing,
			if working {
				ink
			} else {
				ink_dim
			},
		)

		right = hud_left - 96
		if working {
			text_right!(frame, model.small, { x: right, y: label_y + 2 }, "parsing", 10, 1.2, accent)
		} else {
			# Dimmer when the lane's points have been dropped, so the gutter
			# says which of the rows on screen are showing detail and which are
			# showing the summary that stands in for it.
			text_right!(
				frame,
				model.font,
				{ x: right, y: label_y },
				commas(row.lane.lines),
				12.5,
				Draw.default_spacing,
				if kept {
					ink_dim
				} else {
					ink_faint
				},
			)
		}

		# What normalising the x axis costs, given back: the file's length as a
		# fraction of the longest one on screen.
		track = right - (margin + 14)
		frame.rectangle!({ x: margin + 14, y: label_y + 20, width: track, height: 2, style: Draw.filled(rule) })
		frame.rectangle!({
			x: margin + 14,
			y: label_y + 20,
			width: track * U64.to_f32(row.lane.lines) / row.longest,
			height: 2,
			style: Draw.filled(
				Color.with_alpha(
					row.lane.tint,
					if kept {
						200
					} else {
						90
					},
				),
			),
		})

		draw_violin!(frame, row.lane, row.top, row.bottom)
	}
}

## The line-length distribution of one file, as a violin sharing the plot's own
## y axis: long lines at the top, short at the bottom, thickness is how many.
##
## It is the summary the lane cannot give. Overlapping points say where the mass
## is only approximately, and only while the file's points are still being kept;
## this says it exactly, in forty pixels, for the whole run.
draw_violin! : Draw.Frame, Lane, F32, F32 => {}
draw_violin! = |frame, lane, top, bottom| {
	height = Math.clamp(bottom - top - 6, 16, 40)
	middle = (top + bottom) / 2
	origin = middle - height / 2
	centre = hud_left - 48
	peak = U64.to_f32(hist_peak(lane.hist))
	span = max_columns / U64.to_f32(hist_buckets)

	List.for_each!(
		indexed(lane.hist),
		|entry|
			if entry.value == 0 {
				{}
			} else {
				# Buckets are even in columns but not in height, because they
				# are placed by the same square root the points are: this is the
				# lane's own y axis, forty pixels wide.
				low = column_offset(U64.to_f32(entry.index) * span) / lane_span
				high = column_offset(U64.to_f32(entry.index + 1) * span) / lane_span
				half = 20 * F32.sqrt(U64.to_f32(entry.value) / peak)
				frame.rectangle!({
					x: centre - half,
					y: origin + height * (1 - high),
					width: half * 2,
					height: F32.max(height * (high - low), 1),
					style: Draw.filled(Color.with_alpha(lane.tint, 110)),
				})
			},
	)
}

# ---------------------------------------------------------------------------
# The footer
# ---------------------------------------------------------------------------

draw_footer! : Draw.Frame, Model => {}
draw_footer! = |frame, model| {
	fade = ease_out(model.entrance)
	bottom = model.screen.y

	text_left!(frame, model.font, { x: margin, y: bottom - hud_bottom + 12 }, peak_line(model), 12.5, Draw.default_spacing, fade_to(ink_dim, fade))

	frame.line!({ start: { x: margin, y: bottom - 46 }, end: { x: model.screen.x - margin, y: bottom - 46 }, stroke: Draw.stroke(rule, 1) })

	model.hint.draw!(frame, { pos: { x: margin, y: bottom - 34 }, color: fade_to(ink_faint, fade) })
	text_right!(
		frame,
		model.small,
		{ x: model.screen.x - margin, y: bottom - 34 },
		Str.concat("ZOOM ", Str.concat(percent(model.camera.zoom()), "%")),
		11,
		2,
		fade_to(ink_faint, fade),
	)
}

# ---------------------------------------------------------------------------
# Text and numbers
# ---------------------------------------------------------------------------

text_left! : Draw.Frame, Text.Font, Math.Vec2, Str, F32, F32, Color.Rgba => {}
text_left! = |frame, font, pos, content, size, spacing, color|
	frame.text!({ pos: pos, text: content, size: size, spacing: spacing, color: color, font: font })

text_right! : Draw.Frame, Text.Font, Math.Vec2, Str, F32, F32, Color.Rgba => {}
text_right! = |frame, font, pos, content, size, spacing, color|
	Text.from(content, font).size(size).spacing(spacing).draw!(frame, { pos, color, align: (Top, Right) })

## The entrance fades the furniture up rather than sliding it, so nothing in the
## figure ever moves except the data.
fade_to : Color.Rgba, F32 -> Color.Rgba
fade_to = |color, fade| Color.with_alpha(color, alpha_of(Math.clamp(fade, 0, 1) * 255))

## `Color` takes alpha as a byte and everything that computes one here computes
## a fraction, so this is the one conversion between them.
alpha_of : F32 -> U8
alpha_of = |value|
	match F32.floor_to_u64_try(Math.clamp(value, 0, 255)) {
		Ok(scaled) =>
			match U64.to_u8_try(scaled) {
				Ok(byte) => byte
				Err(_) => 255
			}

		Err(_) => 0
	}

## `List.for_each!` with the index alongside the element.
indexed : List(a) -> List({ value : a, index : U64 })
indexed = |items| List.map_with_index(items, |value, index| { value: value, index: index })

## Keep the end of a path rather than the start of it, because the end is the
## part that names the file.
##
## The cut is moved forward to a directory boundary when there is one inside the
## room available, so a shortened path reads as a path -- `.../assets/level.tmx`
## rather than `...ts/level.tmx`. Moving it forward only ever shortens the
## result, so this never exceeds `keep`.
shorten : Str, U64 -> Str
shorten = |path, keep| {
	bytes = Str.to_utf8(path)
	len = List.len(bytes)
	if len <= keep {
		path
	} else {
		room = keep - 3
		start =
			match next_separator(bytes, len - room, len) {
				Ok(at) => at + 1
				Err(_) => len - room
			}
		Str.concat("...", Str.from_utf8_lossy(List.release_excess_capacity(List.sublist(bytes, { start: start, len: len - start }))))
	}
}

next_separator : List(U8), U64, U64 -> Try(U64, [None])
next_separator = |bytes, at, len|
	if at >= len {
		Err(None)
	} else if List.get(bytes, at) == Ok(47) {
		Ok(at)
	} else {
		next_separator(bytes, at + 1, len)
	}

## Thousands separators. A quarter of a million lines is a figure a reader is
## meant to take in, and `274822` is not.
commas : U64 -> Str
commas = |value|
	if value < 1000 {
		U64.to_str(value)
	} else {
		commas(value / 1000)
			|> Str.concat(",")
			|> Str.concat(pad_three(value % 1000))
	}

pad_three : U64 -> Str
pad_three = |value|
	if value < 10 {
		Str.concat("00", U64.to_str(value))
	} else if value < 100 {
		Str.concat("0", U64.to_str(value))
	} else {
		U64.to_str(value)
	}

## Bytes at whichever scale reads as a quantity rather than a number.
size_str : U64 -> Str
size_str = |bytes|
	if bytes == 0 {
		"none"
	} else if bytes < 1024 {
		Str.concat(U64.to_str(bytes), " B")
	} else if bytes < 1024 * 1024 {
		Str.concat(commas(bytes / 1024), " KiB")
	} else {
		Str.concat(one_decimal(U64.to_f32(bytes) / 1_048_576), " MiB")
	}

one_decimal : F32 -> Str
one_decimal = |value| {
	tenths = rounded(value * 10)
	Str.concat(commas(tenths / 10), Str.concat(".", U64.to_str(tenths % 10)))
}

## The longest line found anywhere, and as much of it as was kept.
peak_line : Model -> Str
peak_line = |model|
	if model.peak.columns == 0 {
		"Longest line: still reading."
	} else {
		"Longest line: "
			|> Str.concat(commas(model.peak.columns))
			|> Str.concat(" columns, in ")
			|> Str.concat(model.peak.path)
			|> Str.concat("      ")
			|> Str.concat(model.peak.text)
			|> Str.concat(
				if model.peak.columns > peak_bytes {
					"..."
				} else {
					""
				},
			)
	}

percent : F32 -> Str
percent = |value|
	match F32.floor_to_u64_try(value * 100) {
		Ok(scaled) => U64.to_str(scaled)
		Err(_) => "?"
	}

rounded : F32 -> U64
rounded = |value|
	match F32.floor_to_u64_try(value + 0.5) {
		Ok(whole) => whole
		Err(_) => 0
	}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
#
# `update!` cannot be called from an `expect`: a `Model` holds a render texture,
# a font and prepared text, and those are host resources that only `init!` can
# produce. So every decision `update!` makes lives in a function that does not
# need one -- `classify`, `scan_chunk`, `trim`, `Rates.sample`, `zoom_at` -- and
# those are what is tested here.

# --- Walking ----------------------------------------------------------------

expect extension_of("src/host_native.zig") == "zig"
expect extension_of("main.roc") == "roc"
expect extension_of("Makefile") == ""
expect extension_of("archive.tar.gz") == "gz"

## A leading dot names a file rather than typing it, so a dotfile has no
## extension -- otherwise `.gitignore` would be read as a `gitignore` source
## file, and every dotfile in the tree with it.
expect extension_of(".gitignore") == ""
expect extension_of("etc/.gitignore") == ""

## A dot in a directory name is not the file's extension.
expect extension_of("www/0.9.0/index") == ""
expect extension_of("www/0.9.0/index.html") == "html"

expect join_path(".", "src") == "src"
expect join_path("src", "host_native.zig") == "src/host_native.zig"
expect join_path("a/b", "c") == "a/b/c"

## The language table is the filter as well as the palette, so a file it does
## not name is not read at all.
expect tint_of("main.roc") == Ok(Color.from_hex_rgb(0xe6b168))
expect tint_of("vendor/raylib/libraylib.a") == Err(Unread)
expect tint_of("assets/fonts/LiberationSans-Regular.ttf") == Err(Unread)

expect classify({ name: "src", kind: Dir }) == Descend
expect classify({ name: ".git", kind: Dir }) == Ignore
expect classify({ name: "zig-out", kind: Dir }) == Ignore
expect classify({ name: "main.roc", kind: File }) == Read
expect classify({ name: "libraylib.a", kind: File }) == Ignore
expect classify({ name: "link", kind: Other }) == Ignore

## Every directory the walk descends into becomes exactly one more listing, and
## every readable file exactly one more read, so the queue depth is the backlog
## and not an approximation of it.
expect List.count_if(sample_entries, |entry| classify(entry) == Descend) == 1
expect List.count_if(sample_entries, |entry| classify(entry) == Read) == 2
expect List.count_if(sample_entries, |entry| classify(entry) == Ignore) == 3

sample_entries : List(Files.Entry)
sample_entries = [
	{ name: "src", kind: Dir },
	{ name: ".git", kind: Dir },
	{ name: "main.roc", kind: File },
	{ name: "README.md", kind: File },
	{ name: "logo.png", kind: File },
	{ name: "socket", kind: Other },
]

# --- Retention --------------------------------------------------------------

## The runs are the instance list cut up, so their counts add to its length.
## Every test below leans on that.
sample_runs : List(Run)
sample_runs = [{ lane: 0, count: 4 }, { lane: 1, count: 3 }, { lane: 2, count: 2 }]

sample_points : List(Draw.TextureInstance)
sample_points = List.map(count_up(0, 8, []), |line| plot_dot(line, 10, { baseline: lane_baseline(0), tint: ink, x_scale: line_scale, size: dot_size }))

## Under budget, nothing moves.
expect trim(sample_points, sample_runs, 9).runs == sample_runs
expect List.len(trim(sample_points, sample_runs, 9).instances) == 9

## Over budget, whole runs go from the front, and the points that remain are
## exactly the ones the surviving runs describe.
expect {
	trimmed = trim(sample_points, sample_runs, 5)
	trimmed.runs == [{ lane: 1, count: 3 }, { lane: 2, count: 2 }]
		and List.len(trimmed.instances) == 5
			and trimmed.instances == List.drop_first(sample_points, 4)
}

## It drops as many as it takes, not one.
expect trim(sample_points, sample_runs, 2).runs == [{ lane: 2, count: 2 }]

## The last run is the file being parsed, and is never dropped however small the
## budget is -- the scan is still appending to it.
expect trim(sample_points, sample_runs, 0).runs == [{ lane: 2, count: 2 }]
expect List.len(trim(sample_points, sample_runs, 0).instances) == 2

expect has_run(sample_runs, 1)
expect !(has_run(sample_runs, 7))
expect !(has_run([], 0))

## A cycle's points go on the end of the run being parsed, and nowhere else.
expect grow_run(sample_runs, 5) == [{ lane: 0, count: 4 }, { lane: 1, count: 3 }, { lane: 2, count: 7 }]
expect grow_run([], 5) == []

## Ten samples a second, so a sample is a tenth of the rate.
expect per_second(120) == 1200

# --- Incremental parsing ----------------------------------------------------

## A scan positioned at the start of a byte list.
scan_of : List(U8) -> Scan
scan_of = |bytes| { lane: 0, bytes: bytes, cursor: 0, col: 0, line: 0, tint: ink, x_scale: line_scale, size: dot_size }

## Resume a scan where a previous `ScanResult` left off.
resume : Scan, ScanResult -> Scan
resume = |scan, result| {
	..scan,
	cursor: scan.cursor + result.consumed,
	col: result.col,
	line: scan.line + result.lines,
}

## "ab\ncde\nf" -- two closed lines of two and three columns, then a partial.
sample : List(U8)
sample = [97, 98, 10, 99, 100, 101, 10, 102]

generous : Budget
generous = { max_lines: 64, max_bytes: 4096 }

## A closed line becomes one point, and the point's x is the line's index.
expect {
	result = scan_chunk(scan_of(sample), generous)
	result.lines == 2 and List.len(result.dots) == 2
}

expect {
	dots = scan_chunk(scan_of(sample), generous).dots
	List.map(dots, |dot| dot.dest.x) == [0, line_scale]
}

## A shorter line plots higher up its lane than a longer one, and both sit
## above the lane's baseline.
expect {
	dots = scan_chunk(scan_of(sample), generous).dots
	match { first: List.get(dots, 0), second: List.get(dots, 1) } {
		{ first: Ok(first), second: Ok(second) } =>
			first.dest.y > second.dest.y and second.dest.y > 0 and first.dest.y < lane_baseline(0)

		_ => Bool.False
	}
}

## The whole window is consumed when the budget does not bind, and the trailing
## partial line is left in `col` for the caller to finish.
expect {
	result = scan_chunk(scan_of(sample), generous)
	result.consumed == List.len(sample) and result.col == 1 and !(result.full)
}

## The line budget stops the scan at the line it names, and `consumed` stops
## with it rather than running to the end of the window.
expect {
	result = scan_chunk(scan_of(sample), { max_lines: 1, max_bytes: 4096 })
	result.lines == 1 and result.consumed == 3 and result.full
}

## Resuming from that stop finds the second line, and it still lands at the x
## for line index 1 -- the line index is carried across cycles, so where a point
## goes does not depend on which cycle happened to parse it.
expect {
	first = scan_chunk(scan_of(sample), { max_lines: 1, max_bytes: 4096 })
	second = scan_chunk(resume(scan_of(sample), first), { max_lines: 1, max_bytes: 4096 })
	second.lines == 1 and List.map(second.dots, |dot| dot.dest.x) == [line_scale]
}

## A byte budget that cuts a line in half carries the columns already seen into
## the next cycle, so the line's length is the length of the whole line.
expect {
	first = scan_chunk(scan_of(sample), { max_lines: 64, max_bytes: 1 })
	second = scan_chunk(resume(scan_of(sample), first), generous)
	first.lines == 0 and first.col == 1 and second.lines == 2
}

## Scanning a file one byte at a time produces exactly the points that scanning
## it in one go does. This is the property the whole design rests on.
expect columns_of(sample, { max_lines: 64, max_bytes: 1 }) == columns_of(sample, generous)
expect columns_of(sample, { max_lines: 1, max_bytes: 4096 }) == [2, 3]

## The columns a scan reports and the columns its points encode are the same
## numbers, which is what lets the histogram be built from one and the plot from
## the other.
expect scan_chunk(scan_of(sample), generous).cols == columns_of(sample, generous)

columns_of : List(U8), Budget -> List(U64)
columns_of = |bytes, budget| gather(scan_of(bytes), budget, [])

gather : Scan, Budget, List(U64) -> List(U64)
gather = |scan, budget, seen| {
	result = scan_chunk(scan, budget)
	found = List.concat(seen, List.map(result.dots, |dot| columns_from_y(dot.dest.y, scan.lane)))
	if result.consumed == 0 {
		found
	} else {
		gather(resume(scan, result), budget, found)
	}
}

## The inverse of `column_offset`, so a point can be read back as the line
## length that placed it.
columns_from_y : F32, U64 -> U64
columns_from_y = |y, lane| {
	fraction = (lane_baseline(lane) - y) / lane_span
	match F32.floor_to_u64_try(fraction * fraction * max_columns + 0.5) {
		Ok(columns) => columns
		Err(_) => 0
	}
}

## An empty file is finished by the scan that starts it, and produces nothing.
expect {
	result = scan_chunk(scan_of([]), generous)
	result.consumed == 0 and result.lines == 0 and List.is_empty(result.dots)
}

## The longest line in the chunk is reported by offset, so the caller can decide
## whether copying it out is worth it. "cde" starts at byte 3.
expect scan_chunk(scan_of(sample), generous).best == { start: 3, columns: 3 }

## Retaining that line copies it out rather than keeping a view of the file, and
## a shorter line does not displace it.
expect {
	kept = retain_peak({ path: "", columns: 0, text: "" }, scan_of(sample), { start: 3, columns: 3 }, "a.txt")
	held = retain_peak(kept, scan_of(sample), { start: 0, columns: 2 }, "b.txt")
	kept.text == "cde" and kept.path == "a.txt" and held.columns == 3 and held.path == "a.txt"
}

# --- Layout of the batch ----------------------------------------------------

## Which lane a point belongs to is recoverable from its y, for every column a
## line can have. This is what lets the batch be rescaled without recording
## anything per point.
expect lane_of(lane_baseline(0)) == 0
expect lane_of(lane_baseline(9)) == 9
expect lane_of(lane_baseline(9) - lane_span) == 9
expect lane_of(lane_baseline(431)) == 431

## A lane never reaches into its neighbour, which is the assumption above.
expect lane_span < lane_height
expect column_offset(max_columns) == lane_span
expect column_offset(0) == 0

## The crowded end of the scale really does get the room: half the columns take
## more than half the lane.
expect column_offset(max_columns / 2) > lane_span * 0.6

## Normalising puts the last line of a file on the right edge of the plot,
## whatever the file's length.
expect F32.abs(U64.to_f32(299) * normalised_scale(300) - world_width) < 0.001
expect F32.abs(U64.to_f32(11_111) * normalised_scale(11_112) - world_width) < 0.001

## A file drawn under an estimate of its length and then corrected when the true
## length arrives ends up exactly where a file drawn under the true length all
## along would have been. This is the whole of the streaming layout: the
## estimate is allowed to be wrong, and one pass at the end makes it right.
expect {
	lines = 300
	bytes = 40 * 300
	drawn = normalised_scale(estimated_lines(bytes))
	place = { baseline: lane_baseline(0), tint: ink, x_scale: drawn, size: dot_size }
	lane = { ..empty_lane, progress: Ready, lines: lines, bytes: bytes, x_scale: drawn }

	# The estimate really is wrong, or this proves nothing.
	estimated_lines(bytes) != lines
		and match List.first(rescale([plot_dot(lines - 1, 10, place)], factors_for(Normalised, [lane]), dot_size)) {
			Ok(dot) => F32.abs(dot.dest.x - world_width) < 0.01
			Err(_) => Bool.False
		}
}

## A lane already laid out for the mode it is in does not move.
expect factors_for(True, [{ ..empty_lane, progress: Ready, lines: 300, x_scale: line_scale }]) == [1]

## Switching to true length puts a file back on the shared scale, so the same
## line index is at the same x in every lane.
expect {
	lane = { ..empty_lane, progress: Ready, lines: 300, bytes: 12_000, x_scale: normalised_scale(300) }
	place = { baseline: lane_baseline(0), tint: ink, x_scale: lane.x_scale, size: dot_size }
	match List.first(rescale([plot_dot(120, 10, place)], factors_for(True, [lane]), dot_size)) {
		Ok(dot) => F32.abs(dot.dest.x - 120 * line_scale) < 0.01
		Err(_) => Bool.False
	}
}

## Rescaling resizes as it goes, so a point is the size the zoom asked for and
## is still centred on its own coordinates.
expect {
	place = { baseline: lane_baseline(0), tint: ink, x_scale: line_scale, size: dot_size }
	match List.first(rescale([plot_dot(10, 10, place)], [1], 2.0)) {
		Ok(dot) => dot.dest.width == 2.0 and dot.origin == { x: 1.0, y: 1.0 }
		Err(_) => Bool.False
	}
}

empty_lane : Lane
empty_lane = { path: "", tint: ink, lines: 0, bytes: 0, progress: Working, x_scale: line_scale, hist: List.repeat(0, hist_buckets) }

## Points shrink in world units as the view grows, so once the first step has
## been taken their size on screen stays inside a factor of `step_ratio`
## however far it is zoomed.
expect held_on_screen(step_base)
expect held_on_screen(3)
expect held_on_screen(6)
expect held_on_screen(max_zoom)

## Below the first step there is nothing to hold: points get smaller with the
## view, and the batch is never rewritten at all.
expect dot_size_for(dot_step_of(0.5)) == dot_size
expect dot_step_of(1) == dot_step_of(1.1)
expect dot_step_of(1) < dot_step_of(max_zoom)

held_on_screen : F32 -> Bool
held_on_screen = |zoom| {
	size = dot_size_for(dot_step_of(zoom)) * zoom
	size >= dot_size * step_base / step_ratio - 0.001 and size <= dot_size * step_base + 0.001
}

# --- Distributions ----------------------------------------------------------

expect bucket_of(0) == 0
expect bucket_of(119) == hist_buckets - 1
expect bucket_of(4000) == hist_buckets - 1

## Counting is per lane and cumulative across the cycles that scanned it.
expect {
	once = add_columns([empty_lane, empty_lane], 0, [0, 3, 119])
	twice = add_columns(once, 0, [119])
	match { first: List.get(twice, 0), second: List.get(twice, 1) } {
		{ first: Ok(counted), second: Ok(untouched) } =>
			List.get(counted.hist, 0) == Ok(2)
				and List.get(counted.hist, hist_buckets - 1) == Ok(2)
					and hist_peak(counted.hist) == 2
						and untouched.hist == List.repeat(0, hist_buckets)

		_ => Bool.False
	}
}

## An empty distribution still has a peak, because it is a divisor.
expect hist_peak(List.repeat(0, hist_buckets)) == 1

# --- The view ---------------------------------------------------------------

## The strip is as tall as the tree is long, and grows by a lane per file.
expect world_height([]) == lane_height
expect world_height(List.repeat(empty_lane, 500)) == 500 * lane_height

## Scrolling is clamped to the strip, so neither end can be scrolled past.
expect {
	area = plot_area({ x: 1240, y: 860 })
	lanes = List.repeat(empty_lane, 500)
	half = visible_height(area, 1) / 2
	ceiling = world_height(lanes) + visible_height(area, 1) * tail_room - half
	clamp_scroll(0 - 99_999, lanes, area, 1) == half and clamp_scroll(99_999, lanes, area, 1) == ceiling
}

## A tree shorter than the window pins the view rather than letting it drift.
expect {
	area = plot_area({ x: 1240, y: 860 })
	half = visible_height(area, 1) / 2
	clamp_scroll(0, [empty_lane], area, 1) == half and clamp_scroll(500, [empty_lane], area, 1) == half
}

## Following puts the newest lane inside the window with room under it.
expect {
	area = plot_area({ x: 1240, y: 860 })
	lanes = List.repeat(empty_lane, 500)
	zoom = fit_zoom({ x: 1240, y: 860 })
	scroll = follow_scroll(lanes, area, zoom)
	top = scroll - visible_height(area, zoom) / 2
	bottom = scroll + visible_height(area, zoom) / 2
	world_height(lanes) > top and world_height(lanes) < bottom
}

## The fitted zoom is the one that makes the plot exactly as wide as its area.
expect {
	screen = { x: 1240, y: 860 }
	F32.abs(fit_zoom(screen) * world_width - plot_area(screen).width) < 0.001
}

## Only the lanes on screen are ever walked, which is what keeps the furniture's
## cost independent of how large the tree is.
expect {
	screen = { x: 1240, y: 860 }
	area = plot_area(screen)
	zoom = fit_zoom(screen)
	lanes = List.repeat(empty_lane, 500)
	window = visible_lanes(camera_at(area, zoom, follow_scroll(lanes, area, zoom)), area, lanes)
	List.len(lane_indices(window)) < 40 and window.last == List.len(lanes) - 1
}

## A window never names a lane that does not exist, however far the view has
## been scrolled or zoomed out.
expect {
	screen = { x: 1240, y: 860 }
	area = plot_area(screen)
	lanes = List.repeat(empty_lane, 3)
	window = visible_lanes(camera_at(area, min_zoom, 0), area, lanes)
	window.last < List.len(lanes) and window.first <= window.last
}

expect lane_indices({ first: 2, last: 5 }) == [2, 3, 4, 5]
expect lane_indices({ first: 4, last: 4 }) == [4]
expect lane_indices({ first: 5, last: 4 }) == []

## Zooming keeps the world point under the pointer under the pointer. That is
## the only thing zoom-at-cursor has to get right.
expect {
	area = plot_area({ x: 1240, y: 860 })
	camera = camera_at(area, fit_zoom({ x: 1240, y: 860 }), 400)
	pointer = { x: 700, y: 500 }
	before = camera.screen_to_world(pointer)
	after = zoom_at(camera, pointer, 3).screen_to_world(pointer)
	F32.abs(after.x - before.x) < 0.01 and F32.abs(after.y - before.y) < 0.01
}

## Zoom stays inside its limits however hard the wheel is spun.
expect zoom_at(test_camera, { x: 700, y: 500 }, 400).zoom() <= max_zoom
expect zoom_at(test_camera, { x: 700, y: 500 }, 0 - 400).zoom() >= min_zoom
expect zoom_at(test_camera, { x: 700, y: 500 }, 0).zoom() == test_camera.zoom()

## A wheel notch moves the page by the same number of pixels at any zoom, which
## is what makes it a scroll rather than a move through the world.
expect {
	close = test_camera.with_zoom(4)
	far = test_camera.with_zoom(0.5)
	near_delta = (close.target().y - scroll_by(close, 1).target().y) * 4
	far_delta = (far.target().y - scroll_by(far, 1).target().y) * 0.5
	F32.abs(near_delta - far_delta) < 0.001 and F32.abs(near_delta - scroll_pixels) < 0.001
}

expect scroll_by(test_camera, 0).target() == test_camera.target()

## Scrolling never moves the view sideways.
expect scroll_by(test_camera, 3).target().x == test_camera.target().x

## Dragging right moves the world right, which means the target moves left, by
## the screen distance divided by the zoom.
expect {
	camera = test_camera.with_zoom(2)
	moved = pan(camera, { x: 20, y: 0 })
	F32.abs(moved.target().x - (camera.target().x - 10)) < 0.001
}

test_camera : Camera.Camera2D
test_camera = camera_at(plot_area({ x: 1240, y: 860 }), fit_zoom({ x: 1240, y: 860 }), 400)

## The entrance starts where it is and finishes where it is going, and never
## overshoots either.
expect ease_out(0) == 0
expect ease_out(1) == 1
expect ease_out(0.5) > 0.5
expect ease_out(2) == 1

expect other_mode(other_mode(Normalised)) == Normalised
expect mode_label(other_mode(Normalised)) == "true length"

# --- Figures ----------------------------------------------------------------

expect commas(0) == "0"
expect commas(999) == "999"
expect commas(1_000) == "1,000"
expect commas(274_822) == "274,822"
expect commas(1_000_005) == "1,000,005"

expect size_str(0) == "none"
expect size_str(512) == "512 B"
expect size_str(1024) == "1 KiB"
expect size_str(903_168) == "882 KiB"
expect size_str(26_214_400) == "25.0 MiB"

expect one_decimal(0) == "0.0"
expect one_decimal(1.25) == "1.3"

## A path is shortened from the front, because the end of it is the part that
## names the file. A path that fits is left alone.
expect shorten("src/host_native.zig", 40) == "src/host_native.zig"

## The cut lands on a directory boundary when there is one within reach, so the
## result still reads as a path.
expect shorten("examples/cave_climb/assets/cave_climb.tsx", 26) == "...assets/cave_climb.tsx"
expect shorten("a/very/long/path/to/somewhere.roc", 20) == "...to/somewhere.roc"

## With no boundary inside the room available it falls back to a plain cut
## rather than giving up more of the name.
expect shorten("www/0.9.0/Draw/index.html", 12) == "...ndex.html"

## Moving the cut forward only ever shortens, so the bound really is a bound.
expect List.all(
	[3, 8, 12, 20, 26, 40],
	|keep| List.len(Str.to_utf8(shorten("examples/cave_climb/assets/cave_climb.tsx", keep))) <= U64.max(keep, 3),
)
