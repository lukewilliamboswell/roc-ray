app [Model, program] {
	rr: platform "../../platform/main.roc",
	roc: "nightly-2026-08-19-edec830",
}

import rr.App
import rr.Assets
import rr.Camera
import rr.Color
import rr.Draw
import rr.Input
import rr.Math
import rr.Program
import rr.TaskQueue
import rr.Text

## Stream a large dataset into a plot that is drawn while it is still arriving.
##
## The dataset is this repository's own Zig sources: fourteen files, about a
## megabyte, twenty-six thousand lines. Each line becomes one point -- x is the
## line's index in its file, y is its length in columns -- and each file gets a
## horizontal lane of its own, so the finished picture is the shape of the code
## base. Nothing about it is precomputed: the plot is empty on the first frame
## and fills in over the next second or so while the frame keeps moving.
##
## Four things have to compose for that to work, and this example exists to show
## that they do.
##
## **Reads never block the frame.** `Program.read_file` is a `Task`: `update`
## returns it and carries on, and the bytes come back later as an ordinary
## `Msg`. The delivered `List(U8)` is a seamless view onto the buffer the host
## already allocated, so no file bytes are copied to hand it over.
##
## **Reads are paced.** The platform accepts 32 unanswered tasks across the whole
## app; fourteen would fit, but pacing is not something to discover at the
## fifteenth file. `TaskQueue` holds the backlog and releases at most
## `max_in_flight` -- four here, small enough that the pacing is real and
## visible in the status line.
##
## **Parsing is incremental.** `update` is pure and runs inside the frame, so it
## may not scan a 400 KB file in one go. `scan_chunk` walks a bounded window of
## one file per cycle and answers with the points it found and where to resume.
## The frame time does not depend on how big the files are, only on the budget.
##
## **Drawing is batched.** Every point is one `Draw.TextureInstance` in a single
## list, drawn with one `frame.texture_instances!` call from one 8x8 white
## texture that the batch tints per lane. Twenty-six thousand points cost one
## crossing of the Roc/host boundary, not twenty-six thousand.
##
## The instance list is append-only, and that is deliberate: the points are in
## world coordinates and panning and zooming move a `Camera2D` rather than the
## data. Once the last file is parsed this app allocates nothing per frame, and
## a drag costs the same whether it is showing a hundred points or all of them.
##
## Wheel zooms at the pointer, drag pans, `R` refits the view, `ESC` quits.
##
## Paths are resolved relative to the working directory, so run it from the
## repository root:
##
##     roc build examples/live_plot/main.roc --output live_plot
##     ./live_plot
Model : {

	## The one texture behind every point. A batch draws a single texture, so
	## fourteen differently coloured lanes come from fourteen tints of this,
	## not from fourteen textures and fourteen batches.
	dot : Draw.Texture,

	## The read backlog. Only `max_in_flight` of these reach the host at once.
	queue : TaskQueue.TaskQueue(Msg),

	## One lane index per task still waiting in `queue`, in the same order.
	##
	## A `Task` owns a callback and says nothing about itself, so the queue
	## cannot report which files it just sent. It does not have to: `release` is
	## FIFO, so the first `List.len(released.tasks)` entries here name exactly
	## the tasks it released. That is the whole of how the HUD knows which four
	## files are being read right now rather than only how many.
	##
	## The two lists are only in lockstep because they are written together --
	## enqueued together on the first cycle, popped together on every release,
	## and appended together when a refused read goes back on the queue.
	queued : List(U64),

	## Byte lists the host has delivered but the parser has not started on.
	##
	## Holding one of these is the whole ownership story: there is no handle to
	## release and no host resource to remember. It is an ordinary Roc list, it
	## keeps the file's storage alive exactly as long as something references
	## it, and dropping it is what frees the file.
	arrivals : List(Arrival),

	## The file being parsed right now. `Idle` between files.
	parsing : [Idle, Parsing(Scan)],

	## Per-file progress and totals, one entry per entry of `sources`.
	lanes : List(Lane),

	## The batch. One instance per line parsed so far, in world coordinates.
	instances : List(Draw.TextureInstance),

	## The longest line found anywhere so far, copied out of its file.
	peak : Peak,

	## Pan and zoom. A camera is a plain value, so the view costs the plot
	## nothing: the instances never move when it changes.
	camera : Camera.Camera2D,

	## Whether `camera` has been fitted to a real window size yet. `init!` runs
	## before any frame has been sampled, so the first `update` is the earliest
	## point at which the fit can be computed.
	fitted : Bool,

	## Wrapped animation clock for the sweep, in seconds.
	sweep : F32,

	title : Text.Prepared,
	hint : Text.Prepared,
}

## One file to plot, and the colour of its lane.
Source : {
	path : Str,
	tint : Color.Rgba,
}

## A delivered file, waiting its turn to be parsed.
Arrival : {
	lane : U64,
	bytes : List(U8),
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
}

## What the HUD says about one file.
Lane : {
	progress : Progress,
	lines : U64,
	bytes : U64,
}

## A file's position in the pipeline.
##
## `Pending` is waiting in the backlog and `Reading` is with the host. The
## queue reports those two as counts rather than per task, so telling them apart
## is the app's own bookkeeping -- see `Model.queued`.
Progress : [Pending, Reading, Buffered, Working, Ready, Failed(Str)]

## The longest line seen, as a bounded copy of its bytes rather than a view.
Peak : {
	lane : U64,
	columns : U64,
	text : Str,
}

## How much of one file a single `update` is allowed to scan.
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

	## The lane index travels with the result on purpose. A `Task` owns the
	## callback that turns its one result into this message, and the platform
	## consumed that callback to deliver it -- so a retry has to be built from
	## scratch, and this message is all the app will have to build it from.
	FileRead(U64, Try(List(U8), Program.FileReadError)),
]

program = { init!, update, render! }

# ---------------------------------------------------------------------------
# The dataset
# ---------------------------------------------------------------------------

## Every file the plot streams in, in the order they are requested.
##
## The list is static data because it has to be: there is no directory-listing
## effect, and a visualiser of a fixed repository does not need one. Adding a
## file here is the only change needed to plot it.
sources : List(Source)
sources = [
	{ path: "src/backend_raylib.zig", tint: Color.from_hex_rgb(0xff6b6b) },
	{ path: "src/capture.zig", tint: Color.from_hex_rgb(0xffa94d) },
	{ path: "src/capture_vp8.zig", tint: Color.from_hex_rgb(0xffd43b) },
	{ path: "src/gif_encoder.zig", tint: Color.from_hex_rgb(0xa9e34b) },
	{ path: "src/graphical_smoke.zig", tint: Color.from_hex_rgb(0x51cf66) },
	{ path: "src/host_native.zig", tint: Color.from_hex_rgb(0x38d9a9) },
	{ path: "src/host_resource.zig", tint: Color.from_hex_rgb(0x22b8cf) },
	{ path: "src/png.zig", tint: Color.from_hex_rgb(0x4dabf7) },
	{ path: "src/roc_ffi.zig", tint: Color.from_hex_rgb(0x748ffc) },
	{ path: "src/roc_platform_abi.zig", tint: Color.from_hex_rgb(0x9775fa) },
	{ path: "src/tilemap_batch.zig", tint: Color.from_hex_rgb(0xda77f2) },
	{ path: "src/tmx_loader.zig", tint: Color.from_hex_rgb(0xf783ac) },
	{ path: "src/webm_muxer.zig", tint: Color.from_hex_rgb(0xff8787) },
	{ path: "src/xml.zig", tint: Color.from_hex_rgb(0xced4da) },
]

## Ask the host for one file, remembering which lane the answer belongs to.
read_task : U64 -> Program.Task(Msg)
read_task = |lane| Program.read_file(path_for(lane), |result| FileRead(lane, result))

path_for : U64 -> Str
path_for = |lane|
	match List.get(sources, lane) {
		Ok(source) => source.path
		Err(_) => ""
	}

tint_for : U64 -> Color.Rgba
tint_for = |lane|
	match List.get(sources, lane) {
		Ok(source) => source.tint
		Err(_) => Color.white
	}

# ---------------------------------------------------------------------------
# Pacing
# ---------------------------------------------------------------------------

## How many reads may be with the host at once.
##
## The platform's own ceiling is 32 tasks in flight for the whole app, so all
## fourteen files would in fact fit. Four is chosen instead so the pacing is
## real rather than theoretical: the status line genuinely shows files waiting,
## and the recipe in `TaskQueue`'s module documentation is genuinely exercised
## rather than just being present.
max_in_flight : U64
max_in_flight = 4

# ---------------------------------------------------------------------------
# Incremental parsing
# ---------------------------------------------------------------------------

## What one `update` may scan.
##
## Both halves matter. `max_lines` bounds how many points a cycle appends, which
## is what keeps the growing instance list from being rebuilt in one huge step.
## `max_bytes` bounds the scan itself, because a line budget alone does not:
## a generated file with one 300 KB line has a single line in it, and scanning
## for its end would cost a frame. `update` is pure and runs inside the frame,
## so its cost has to be bounded by something the input cannot inflate.
scan_budget : Budget
scan_budget = { max_lines: 512, max_bytes: 12_288 }

newline : U8
newline = 10

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
	baseline = lane_baseline(scan.lane)
	tint = tint_for(scan.lane)
	remaining = List.len(scan.bytes) - scan.cursor
	window = List.sublist(scan.bytes, { start: scan.cursor, len: U64.min(remaining, budget.max_bytes) })

	List.fold(
		window,
		{ dots: [], consumed: 0, col: scan.col, lines: 0, best: { start: 0, columns: 0 }, full: Bool.False },
		|acc, byte|
			if acc.full {
				acc
			} else if byte == newline {
				lines = acc.lines + 1
				{
					dots: List.append(acc.dots, plot_dot(scan.line + acc.lines, acc.col, baseline, tint)),
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

## Keep whichever of two lines has more columns.
longer_line : BestLine, U64, U64 -> BestLine
longer_line = |current, start, columns|
	if columns > current.columns {
		{ start, columns }
	} else {
		current
	}

## Place one line's point in world space.
plot_dot : U64, U64, F32, Color.Rgba -> Draw.TextureInstance
plot_dot = |line, columns, baseline, tint| {
	x = U64.to_f32(line) * line_scale
	y = baseline - F32.min(U64.to_f32(columns), max_columns) * column_scale
	{
		source: dot_source,
		dest: Math.rect(x, y, dot_size, dot_size),
		origin: { x: dot_size / 2, y: dot_size / 2 },
		rotation: 0,
		tint: tint,
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
		Parsing(scan) => scan_once(model, scan)
		Idle =>
			match List.first(model.arrivals) {
				Ok(arrival) =>
					scan_once(
						{
							..model,
							arrivals: List.drop_first(model.arrivals, 1),
							lanes: set_progress(model.lanes, arrival.lane, Working),
						},
						{ lane: arrival.lane, bytes: arrival.bytes, cursor: 0, col: 0, line: 0 },
					)

				Err(_) => model
			}
		}

scan_once : Model, Scan -> Model
scan_once = |model, scan| {
	result = scan_chunk(scan, scan_budget)
	cursor = scan.cursor + result.consumed
	done = cursor >= List.len(scan.bytes)

	# A file whose last line has no newline still has a last line.
	tail =
		if done and result.col > 0 {
			[plot_dot(scan.line + result.lines, result.col, lane_baseline(scan.lane), tint_for(scan.lane))]
		} else {
			[]
		}

	dots = List.concat(result.dots, tail)
	grown = {
		..model,
		# One concat per cycle, not one per point. The model is still
		# referenced by the box it arrived in, so the first write to a
		# collection copies it -- batching a cycle's points into one append is
		# what turns 512 copies into one.
		instances: List.concat(model.instances, dots),
		peak: retain_peak(model.peak, scan, result.best),
		lanes: add_lines(model.lanes, scan.lane, List.len(dots)),
	}

	if done {
		# Dropping `scan` here is what frees the file. Nothing else references
		# those bytes by now: the arrival was moved out of `arrivals` when the
		# scan started, and the points are plain numbers.
		{ ..grown, parsing: Idle, lanes: set_progress(grown.lanes, scan.lane, Ready) }
	} else {
		{ ..grown, parsing: Parsing({ ..scan, cursor: cursor, col: result.col, line: scan.line + result.lines }) }
	}
}

## How much of the longest line to keep for the HUD.
peak_bytes : U64
peak_bytes = 56

## Keep the longest line found so far, as bytes of its own.
##
## This is the one place the app retains a piece of a delivered read, and it is
## the reason `List.release_excess_capacity` exists. A sublist of a delivered
## file is a seamless view onto the host's buffer: retaining 56 bytes of
## `src/roc_platform_abi.zig` that way would pin all 416 KB of it for as long as
## the HUD shows that line. `release_excess_capacity` deliberately copies those
## `peak_bytes` bytes into a list of their own, so the file is freed when the
## scan ends.
##
## `Str.from_utf8_lossy` may share storage with the list it is given, which is
## exactly why the copy has to happen first rather than being left to it.
retain_peak : Peak, Scan, BestLine -> Peak
retain_peak = |peak, scan, best|
	if best.columns <= peak.columns {
		peak
	} else {
		slice = List.sublist(scan.bytes, { start: best.start, len: U64.min(best.columns, peak_bytes) })
		{
			lane: scan.lane,
			columns: best.columns,
			text: Str.from_utf8_lossy(List.release_excess_capacity(slice)),
		}
	}

# ---------------------------------------------------------------------------
# Lane bookkeeping
# ---------------------------------------------------------------------------

set_progress : List(Lane), U64, Progress -> List(Lane)
set_progress = |lanes, index, progress|
	List.map_with_index(
		lanes,
		|lane, at|
			if at == index {
				{ ..lane, progress: progress }
			} else {
				lane
			},
	)

set_bytes : List(Lane), U64, U64 -> List(Lane)
set_bytes = |lanes, index, bytes|
	List.map_with_index(
		lanes,
		|lane, at|
			if at == index {
				{ ..lane, bytes: bytes }
			} else {
				lane
			},
	)

add_lines : List(Lane), U64, U64 -> List(Lane)
add_lines = |lanes, index, lines|
	List.map_with_index(
		lanes,
		|lane, at|
			if at == index {
				{ ..lane, lines: lane.lines + lines }
			} else {
				lane
			},
	)

## How many bytes of delivered file this app is currently pinning.
##
## A lane holds its file's bytes from the moment they arrive until the scan
## that consumes them finishes, and nothing else in the model does. Showing the
## total makes the ownership visible: it climbs to about a megabyte while the
## reads outrun the parser, then falls back to zero as the lanes finish.
held_bytes : List(Lane) -> U64
held_bytes = |lanes|
	List.fold(
		lanes,
		0,
		|total, lane|
			match lane.progress {
				Buffered => total + lane.bytes
				Working => total + lane.bytes
				_ => total
			},
	)

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

describe_read_error : Program.FileReadError -> Str
describe_read_error = |reason|
	match reason {
		NotFound => "not found"
		ReadFailed => "read failed"
		Busy => "host busy"
		Unavailable => "reads unavailable"
		TooLarge => "over the host's per-file limit"
	}

# ---------------------------------------------------------------------------
# Plot geometry
# ---------------------------------------------------------------------------

## World units per line index, so a lane is as wide as its file is long. The
## largest file here is about 11,000 lines, which makes its lane about 890
## units across; a 142-line file gets 11.
line_scale : F32
line_scale = 0.08

## Columns past this are clipped to the top of the lane rather than allowed to
## rescale it. A plot whose axes move every time a longer line arrives cannot
## be read while it is still filling in, which is the state this app is in for
## most of its interesting life.
max_columns : F32
max_columns = 120

## World units per column, so a `max_columns` line is 43 units tall.
column_scale : F32
column_scale = 0.36

lane_height : F32
lane_height = 52

## The y a zero-length line sits on, for one lane.
lane_baseline : U64 -> F32
lane_baseline = |lane| U64.to_f32(lane) * lane_height + max_columns * column_scale

## The whole plot, in world units.
world_bounds : Math.Rect
world_bounds = Math.rect(0, 0, 12_000 * line_scale, U64.to_f32(List.len(sources)) * lane_height)

## Size of one point, in world units. Points scale with the camera, so a zoom
## does not just spread them apart, it magnifies them.
dot_size : F32
dot_size = 2.2

## The whole of the generated texture. Every instance draws all of it.
dot_source : Math.Rect
dot_source = Math.rect(0, 0, 8, 8)

## How much of the window the HUD keeps for itself. The left gutter is where
## the lane names go, which is why the plot is not centred in the window.
hud_top : F32
hud_top = 106

hud_bottom : F32
hud_bottom = 62

hud_left : F32
hud_left = 330

## The part of the window the plot may draw in. `render!` scissors to this, so
## a dragged plot cannot scribble over the HUD.
plot_area : Math.Vec2 -> Math.Rect
plot_area = |screen|
	Math.rect(hud_left, hud_top, F32.max(screen.x - hud_left, 1), F32.max(screen.y - hud_top - hud_bottom, 1))

min_zoom : F32
min_zoom = 0.05

max_zoom : F32
max_zoom = 24

# ---------------------------------------------------------------------------
# The view
# ---------------------------------------------------------------------------

## Fit the whole plot into the drawable area.
fit_camera : Math.Vec2 -> Camera.Camera2D
fit_camera = |screen| {
	area = plot_area(screen)
	zoom = Math.clamp(F32.min(area.width / world_bounds.width, area.height / world_bounds.height), min_zoom, max_zoom)
	Camera.new({ target: Math.center(world_bounds), offset: Math.center(area), rotation: 0, zoom: zoom })
}

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
		factor = Math.clamp(1 + wheel * 0.12, 0.5, 2)
		zoomed = camera.with_zoom(Math.clamp(camera.zoom() * factor, min_zoom, max_zoom))
		after = zoomed.screen_to_world(pointer)
		zoomed.with_target(zoomed.target().add(before.sub(after)))
	}

## Drag the world with the pointer: a screen-space delta is a world-space delta
## divided by the zoom.
pan : Camera.Camera2D, Math.Vec2 -> Camera.Camera2D
pan = |camera, delta| camera.with_target(camera.target().sub(delta.scale(1 / camera.zoom())))

## How long the sweep takes to cross the plot, in seconds.
sweep_period : F32
sweep_period = 7

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

init! : App.Init(Model, [ResourceLimit, TextureGenerationFailed])
init! = App.init(
	App.static_config(
		App.default
			.with_title("RocRay Live Plot")
			.with_size({ width: 1100, height: 760 })
			.with_min_size({ width: 640, height: 420 })
			.with_resizable(Bool.True)
			.with_frame_pacing(Capped(120)),
	),
	|_startup| {
		font = Draw.default_font!()
		# Solid white, so the batch's per-instance tint is the only thing
		# deciding a point's colour.
		dot = Assets.generate_color_texture!({ width: 8, height: 8, color: Color.white })?
		title = Text.from("Repository visualiser - every line of src/*.zig, plotted as it streams in", font).size(21).prepare!()?
		hint = Text.from("wheel zooms at the pointer - drag pans - R refits - ESC quits", font).size(16).prepare!()?
		Ok({
			dot: dot,
			queue: TaskQueue.new(max_in_flight),
			queued: [],
			arrivals: [],
			parsing: Idle,
			lanes: List.map(sources, |_source| { progress: Pending, lines: 0, bytes: 0 }),
			instances: [],
			peak: { lane: 0, columns: 0, text: "" },
			camera: Camera.default,
			fitted: Bool.False,
			sweep: 0,
			title: title,
			hint: hint,
		})
	},
)

update : Model, Program.Step(Msg) -> Program.Update(Model, Msg)
update = |model, step| {
	# 1. Fold this cycle's completions in. Each one ends a task the queue
	#    released, so each one reports a completion to the queue.
	settled_model = List.fold(step.messages, model, receive)

	# 2. Enqueue the whole dataset once. Nothing is submitted here; the queue
	#    decides how much of it goes out, and when. The lane indices go on in
	#    the same expression and the same order, which is what puts `queued`
	#    in lockstep with the backlog.
	primed =
		if step.time.frame_count == 0 {
			{
				..settled_model,
				queue: settled_model.queue.enqueue_all(List.map_with_index(sources, |_source, lane| read_task(lane))),
				queued: List.map_with_index(sources, |_source, lane| lane),
			}
		} else {
			settled_model
		}

	# 3. One bounded window of parsing, whatever else happened.
	parsed = advance(primed)

	# 4. The view is pure state too, so a headless run pans and zooms the same
	#    way an interactive one does.
	viewed = look(parsed, step)

	# 5. Release whatever fits. Safe on every cycle: with nothing to send, or
	#    no room to send it, this answers with no tasks and the same queue.
	released = viewed.queue.release()

	# 6. `release` is FIFO, so the first `List.len(released.tasks)` lane indices
	#    name exactly the files that just went to the host -- which is how the
	#    HUD says *which* four are being read rather than only how many.
	sent = List.split_at(viewed.queued, List.len(released.tasks))

	Program.static({
		..viewed,
		queue: released.queue,
		queued: sent.others,
		lanes: List.fold(sent.before, viewed.lanes, |lanes, lane| set_progress(lanes, lane, Reading)),
	})
		.with_actions(if step.input.key_pressed(KeyEscape) [Program.exit(0)] else [])
		.with_tasks(released.tasks)
}

## Fold one completion into the model.
receive : Model, Msg -> Model
receive = |model, message|
	match message {
		FileRead(lane, Ok(bytes)) => {
			..model,
			queue: model.queue.completed(),
			# The bytes go straight into the model. There is no copy here and
			# no host handle to hold: the list *is* the ownership.
			arrivals: List.append(model.arrivals, { lane: lane, bytes: bytes }),
			lanes: set_progress(set_bytes(model.lanes, lane, List.len(bytes)), lane, Buffered),
		}

		# A refused task still ended, so its slot is free -- and the work goes
		# back on the queue as a *new* task, because the callback that would
		# have delivered its result is the one that just delivered this. The
		# task goes to the back of the backlog, so its lane index does too, or
		# the two lists would stop naming each other.
		FileRead(lane, Err(Busy)) => {
			..model,
			queue: model.queue.completed().enqueue(read_task(lane)),
			queued: List.append(model.queued, lane),
			lanes: set_progress(model.lanes, lane, Pending),
		}

		FileRead(lane, Err(reason)) => {
			..model,
			queue: model.queue.completed(),
			lanes: set_progress(model.lanes, lane, Failed(describe_read_error(reason))),
		}
	}

## Advance the camera and the sweep clock.
look : Model, Program.Step(Msg) -> Model
look = |model, step| {
	input = step.input
	screen = { x: I32.to_f32(step.window.size.width), y: I32.to_f32(step.window.size.height) }
	fitted_camera = fit_camera(screen)

	# Re-centring on every cycle is what makes a resize keep the same world
	# point in the middle of the plot rather than sliding it.
	base =
		if model.fitted {
			model.camera.with_offset(Math.center(plot_area(screen)))
		} else {
			fitted_camera
		}

	zoomed = zoom_at(base, input.mouse.position(), input.mouse.wheel_delta().y)
	panned = if input.mouse.button_down(Left) pan(zoomed, input.mouse.delta()) else zoomed

	# A long first frame or a resize stall must not jump the sweep across the
	# plot, and wrapping the clock keeps its precision the same after an hour
	# as after a second.
	advanced = model.sweep + F32.min(step.time.elapsed_seconds, 0.05)

	{
		..model,
		camera: if input.key_pressed(KeyR) fitted_camera else panned,
		fitted: Bool.True,
		sweep: if advanced >= sweep_period advanced - sweep_period else advanced,
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ScopeLimit, ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x0c1118))

	# The surface being drawn to, asked for where it is used. Nothing about the
	# window is carried through the model to get here.
	screen = frame.size!()

	# The plot is clipped to its own area so twenty-six thousand points cannot
	# scribble over the status line when the view is dragged.
	frame.with_scissor!(
		plot_area({ x: screen.width, y: screen.height }),
		|clipped|
			clipped.with_camera!(
				model.camera,
				|world| {
					draw_lanes!(world, model)

					# The whole plot, however many points are in it, in one
					# crossing of the Roc/host boundary.
					world.texture_instances!(model.dot, model.instances)

					draw_sweep!(world, model.sweep)
					Ok({})
				},
			),
	)?

	draw_hud!(frame, model)
	Ok({})
}

## One band and one baseline per file. A lane is drawn at the full nominal
## width whatever its file's length, so how far the points reach across it is
## how long that file is relative to the largest one.
draw_lanes! : Draw.Frame, Model => {}
draw_lanes! = |frame, model|
	List.for_each!(
		List.map_with_index(model.lanes, |_lane, index| index),
		|index| {
			baseline = lane_baseline(index)
			frame.rectangle!({
				x: world_bounds.x,
				y: baseline - max_columns * column_scale,
				width: world_bounds.width,
				height: lane_height - 4,
				style: Draw.filled(Color.from_hex_rgb(0x131b26)),
			})
			frame.line!({
				start: { x: world_bounds.x, y: baseline },
				end: { x: world_bounds.x + world_bounds.width, y: baseline },
				stroke: Draw.stroke(Color.with_alpha(tint_for(index), 70), 0.6),
			})
		},
	)

## A slow highlight band crossing the plot, driven by `step.time` alone.
##
## It is here so the frame has something moving in it whether or not data is
## still arriving: a plot that only animates while it loads gives no sign, once
## it is finished, that it is still running at all.
draw_sweep! : Draw.Frame, F32 => {}
draw_sweep! = |frame, sweep| {
	x = world_bounds.x + world_bounds.width * (sweep / sweep_period)
	frame.rectangle!({
		x: x,
		y: world_bounds.y,
		width: world_bounds.width * 0.012,
		height: world_bounds.height,
		style: Draw.filled(Color.rgba(255, 255, 255, 16)),
	})
	frame.line!({
		start: { x: x, y: world_bounds.y },
		end: { x: x, y: world_bounds.y + world_bounds.height },
		stroke: Draw.stroke(Color.rgba(255, 255, 255, 48), 0.8),
	})
}

draw_hud! : Draw.Frame, Model => {}
draw_hud! = |frame, model| {
	screen = frame.size!()
	area = plot_area({ x: screen.width, y: screen.height })

	# No backing bars: `render!` scissors the plot to `area`, so the cleared
	# background is still untouched everywhere the HUD writes.
	model.title.draw!(frame, { pos: { x: 28, y: 22 }, color: Color.white, align: Text.align_top_left })
	frame.text_at!({ pos: { x: 28, y: 54 }, text: status_line(model), size: 17, color: Color.from_hex_rgb(0x8fb8d8) })
	frame.text_at!({ pos: { x: 28, y: 78 }, text: peak_line(model), size: 15, color: Color.from_hex_rgb(0x6f7f95) })
	model.hint.draw!(frame, { pos: { x: 28, y: area.y + area.height + 22 }, color: Color.from_hex_rgb(0x60708a), align: Text.align_top_left })

	draw_lane_labels!(frame, model, area)
}

## Lane names, drawn in screen space beside the lane they belong to.
##
## The label follows its lane through pan and zoom without being scaled by
## either, because `world_to_screen` puts the same transform `Draw.with_camera!`
## applies to the points into pure code the HUD can use.
draw_lane_labels! : Draw.Frame, Model, Math.Rect => {}
draw_lane_labels! = |frame, model, area|
	List.for_each!(
		List.map_with_index(model.lanes, |lane, index| { lane: lane, index: index }),
		|entry| {
			anchor = model.camera.world_to_screen({ x: world_bounds.x, y: lane_baseline(entry.index) })
			if anchor.y < area.y + 10 or anchor.y > area.y + area.height - 4 {
				{}
			} else {
				frame.rectangle!({
					x: 24,
					y: anchor.y - 9,
					width: 8,
					height: 8,
					style: Draw.filled(tint_for(entry.index)),
				})
				frame.text_at!({
					pos: { x: 38, y: anchor.y - 14 },
					text: lane_label(entry.index, entry.lane),
					size: 14,
					color: Color.from_hex_rgb(0x9aa8bd),
				})
			}
		},
	)

## A finished lane says only its name and how many lines it contributed. The
## unfinished ones are the ones worth spending gutter width on.
lane_label : U64, Lane -> Str
lane_label = |index, lane|
	path_for(index)
		|> Str.concat("  ")
		|> Str.concat(U64.to_str(lane.lines))
		|> Str.concat(describe_progress(lane))

describe_progress : Lane -> Str
describe_progress = |lane|
	match lane.progress {
		Pending => "  waiting"
		Reading => "  reading"
		Buffered => "  read, to parse"
		Working => "  parsing"
		Ready => ""
		Failed(reason) => Str.concat("  ", reason)
	}

status_line : Model -> Str
status_line = |model|
	U64.to_str(ready_count(model.lanes))
		|> Str.concat("/")
		|> Str.concat(U64.to_str(List.len(sources)))
		|> Str.concat(" files parsed   ")
		|> Str.concat(U64.to_str(model.queue.pending_len()))
		|> Str.concat(" queued, ")
		|> Str.concat(U64.to_str(model.queue.in_flight()))
		|> Str.concat(" in flight of ")
		|> Str.concat(U64.to_str(model.queue.max_in_flight()))
		|> Str.concat("   ")
		|> Str.concat(U64.to_str(held_bytes(model.lanes) / 1024))
		|> Str.concat(" KiB of file bytes held   ")
		|> Str.concat(U64.to_str(List.len(model.instances)))
		|> Str.concat(" points in 1 batch   zoom ")
		|> Str.concat(percent(model.camera.zoom()))
		|> Str.concat("%")

peak_line : Model -> Str
peak_line = |model|
	if model.peak.columns == 0 {
		"longest line: none yet"
	} else {
		"longest line: "
			|> Str.concat(U64.to_str(model.peak.columns))
			|> Str.concat(" columns in ")
			|> Str.concat(path_for(model.peak.lane))
			|> Str.concat("  ")
			|> Str.concat(model.peak.text)
	}

percent : F32 -> Str
percent = |value|
	match F32.floor_to_u64_try(value * 100) {
		Ok(scaled) => U64.to_str(scaled)
		Err(_) => "?"
	}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
#
# Two layers. Most of what `update` decides lives in a function that needs no
# model -- `scan_chunk`, `read_task`, `zoom_at`, the lane bookkeeping -- and
# those are tested directly, on inputs small enough to write down.
#
# The whole `update` is tested too, and that is the part worth explaining. A
# `Model` here holds a `Texture` and two `Text.Prepared` values, which are host
# resources whose constructors only the platform has. Each of those types
# publishes a resource-free `stub` for exactly this: a pure value whose handle
# never resolves to a host resource, so a model can be written down in an
# `expect`. `Program.Step.for_tests` supplies the other half, the sampled cycle.
# What comes back is asserted on with `Program.action_shape` and
# `Program.task_shape` -- an `Update` holds callbacks and host resources, and
# `==` cannot look inside either.

## A scan positioned at the start of a byte list.
scan_of : List(U8) -> Scan
scan_of = |bytes| { lane: 0, bytes: bytes, cursor: 0, col: 0, line: 0 }

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
	xs = List.map(dots, |dot| dot.dest.x)
	xs == [0, line_scale]
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

## Every y a scan of `sample` produces, gathered by repeatedly resuming with
## `budget`, converted back to the column count that placed it.
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

columns_from_y : F32, U64 -> U64
columns_from_y = |y, lane|
	match F32.floor_to_u64_try((lane_baseline(lane) - y) / column_scale + 0.5) {
		Ok(columns) => columns
		Err(_) => 0
	}

## An empty file is finished by the scan that starts it, and produces nothing.
expect {
	result = scan_chunk(scan_of([]), generous)
	result.consumed == 0 and result.lines == 0 and List.is_empty(result.dots)
}

## The longest line in the chunk is reported by offset, so the caller can decide
## whether copying it out is worth it. "cde" starts at byte 3.
expect {
	result = scan_chunk(scan_of(sample), generous)
	result.best == { start: 3, columns: 3 }
}

## Retaining that line copies it out rather than keeping a view of the file, and
## a shorter line does not displace it.
expect {
	kept = retain_peak({ lane: 0, columns: 0, text: "" }, scan_of(sample), { start: 3, columns: 3 })
	held = retain_peak(kept, scan_of(sample), { start: 0, columns: 2 })
	kept.text == "cde" and held.columns == 3
}

# --- Pacing -----------------------------------------------------------------

## The queue this app starts with, holding every file and having released none.
loaded_queue : TaskQueue.TaskQueue(Msg)
loaded_queue = TaskQueue.new(max_in_flight).enqueue_all(List.map_with_index(sources, |_source, lane| read_task(lane)))

expect loaded_queue.pending_len() == List.len(sources)
expect loaded_queue.in_flight() == 0

## A release hands out the budget and no more, and counts what it handed out.
expect loaded_queue.release().queue.in_flight() == max_in_flight
expect loaded_queue.release().queue.pending_len() == List.len(sources) - max_in_flight

## With nothing completed, the next cycle sends nothing. This is the pacing.
expect List.is_empty(loaded_queue.release().queue.release().tasks)

## One completion frees exactly one slot.
expect List.len(loaded_queue.release().queue.completed().release().tasks) == 1

## Draining the whole backlog takes ceil(14 / 4) rounds of four.
expect drain_rounds(loaded_queue, 0) == 4

drain_rounds : TaskQueue.TaskQueue(Msg), U64 -> U64
drain_rounds = |queue, rounds| {
	released = queue.release()
	if List.is_empty(released.tasks) {
		rounds
	} else {
		drain_rounds(
			List.fold(released.tasks, released.queue, |acc, _task| acc.completed()),
			rounds + 1,
		)
	}
}

## The `Busy` recipe: the refused task's slot is freed and the work is
## re-enqueued as a new task, so the counts end where they started and the file
## is still going to be read.
expect {
	busy = loaded_queue.release().queue.completed().enqueue(read_task(3))
	busy.in_flight() == max_in_flight - 1 and busy.pending_len() == List.len(sources) - max_in_flight + 1
}

# --- The work `update` hands the platform ------------------------------------

## A `Task` owns a callback, so no test can compare two of them; deriving `==`
## over a union that reaches a host resource is worse still. `Program.task_shape`
## reduces a task to the request it carries, which is what an assertion wants
## anyway -- and it is how this test knows the queue releases the files in the
## order `sources` lists them.
expect List.map(loaded_queue.release().tasks, Program.task_shape)
	== [
		ReadFile({ path: "src/backend_raylib.zig" }),
		ReadFile({ path: "src/capture.zig" }),
		ReadFile({ path: "src/capture_vp8.zig" }),
		ReadFile({ path: "src/gif_encoder.zig" }),
	]

## A retry asks for exactly the same file. `Task.map` and the queue rewrite
## callbacks, never requests, so the shape is what survives a round trip.
expect List.map([read_task(9)], Program.task_shape) == [ReadFile({ path: "src/roc_platform_abi.zig" })]

## The one action this app returns, reduced the same way. `Program.action_shape`
## drops host resources an action may carry and keeps its parameters, which is
## the supported way to assert on what an `update` asked the platform to do.
expect List.map(exit_actions(Bool.True), Program.action_shape) == [Exit(0)]
expect List.is_empty(exit_actions(Bool.False))

## What `update`'s `.with_actions(...)` is given. It is a function so that the
## line above can call it; `update` itself needs a `Model`, and a `Model` needs
## the host.
exit_actions : Bool -> List(Program.Action)
exit_actions = |escape| if escape [Program.exit(0)] else []

# --- The view ---------------------------------------------------------------

## Fitting centres the plot and picks the zoom that puts all of it inside the
## drawable area, which is the tighter of the two axes.
expect {
	camera = fit_camera({ x: 1100, y: 760 })
	area = plot_area({ x: 1100, y: 760 })
	expected = F32.min(area.width / world_bounds.width, area.height / world_bounds.height)
	F32.abs(camera.zoom() - expected) < 0.0001 and camera.target() == Math.center(world_bounds)
}

## The whole plot really is inside the view that fit produces.
expect {
	camera = fit_camera({ x: 1100, y: 760 })
	visible = camera.viewport({ x: 1100, y: 760 })
	visible.width >= world_bounds.width and visible.height >= world_bounds.height
}

## Zooming keeps the world point under the pointer under the pointer. That is
## the only thing zoom-at-cursor has to get right.
expect {
	camera = fit_camera({ x: 1100, y: 760 })
	pointer = { x: 300, y: 500 }
	before = camera.screen_to_world(pointer)
	after = zoom_at(camera, pointer, 3).screen_to_world(pointer)
	F32.abs(after.x - before.x) < 0.01 and F32.abs(after.y - before.y) < 0.01
}

expect zoom_at(fit_camera({ x: 1100, y: 760 }), { x: 300, y: 500 }, 3).zoom() > fit_camera({ x: 1100, y: 760 }).zoom()
expect zoom_at(fit_camera({ x: 1100, y: 760 }), { x: 300, y: 500 }, 0).zoom() == fit_camera({ x: 1100, y: 760 }).zoom()

## Zoom stays inside its limits however hard the wheel is spun.
expect zoom_at(fit_camera({ x: 1100, y: 760 }), { x: 300, y: 500 }, 400).zoom() <= max_zoom
expect zoom_at(fit_camera({ x: 1100, y: 760 }), { x: 300, y: 500 }, 0 - 400).zoom() >= min_zoom

## Dragging right moves the world right, which means the target moves left, by
## the screen distance divided by the zoom.
expect {
	camera = fit_camera({ x: 1100, y: 760 }).with_zoom(2)
	moved = pan(camera, { x: 20, y: 0 })
	F32.abs(moved.target().x - (camera.target().x - 10)) < 0.001
}

## Re-centring on a resize keeps the offset at the middle of the new plot area,
## which is what stops a resize sliding the view.
expect {
	resized = fit_camera({ x: 1100, y: 760 }).with_offset(Math.center(plot_area({ x: 700, y: 500 })))
	resized.offset() == Math.center(plot_area({ x: 700, y: 500 }))
}

# --- Bookkeeping ------------------------------------------------------------

expect ready_count([{ progress: Ready, lines: 3, bytes: 9 }, { progress: Pending, lines: 0, bytes: 0 }]) == 1

## Only the lanes that are actually holding a delivered file count towards the
## bytes held: a lane that has been parsed has dropped its bytes, and one that
## has not been read yet never had any.
expect
	held_bytes([
		{ progress: Buffered, lines: 0, bytes: 400 },
		{ progress: Working, lines: 10, bytes: 30 },
		{ progress: Ready, lines: 90, bytes: 9000 },
		{ progress: Pending, lines: 0, bytes: 0 },
		{ progress: Failed("not found"), lines: 0, bytes: 0 },
	])
		== 430

expect {
	lanes = add_lines(set_progress(List.map(sources, |_source| { progress: Pending, lines: 0, bytes: 0 }), 2, Working), 2, 40)
	match List.get(lanes, 2) {
		Ok(lane) => lane.lines == 40 and ready_count(lanes) == 0
		Err(_) => Bool.False
	}
}

## Lanes stack downward, one `lane_height` apart, and all of them fit inside
## the world the view is fitted to.
expect F32.abs(lane_baseline(1) - lane_baseline(0) - lane_height) < 0.001
expect lane_baseline(List.len(sources) - 1) < world_bounds.y + world_bounds.height

## The nominal x extent covers the largest file in the list with room to spare,
## so the fitted view does not have to move while data is still arriving.
expect world_bounds.width > 11_500 * line_scale

# --- The whole `update`, driven the way the platform drives it ---------------

## A real `Model`, built entirely from resource-free stubs.
##
## `Draw.Texture.stub` and `Text.Prepared.stub` are pure values whose handles never
## resolve to a host resource. Nothing here draws, so nothing here needs one --
## and with them this app's actual `update` is reachable from an `expect`.
stub_model : Model
stub_model = {
	dot: { ..Draw.Texture.stub, width: 8, height: 8 },
	queue: TaskQueue.new(max_in_flight),
	queued: [],
	arrivals: [],
	parsing: Idle,
	lanes: List.map(sources, |_source| { progress: Pending, lines: 0, bytes: 0 }),
	instances: [],
	peak: { lane: 0, columns: 0, text: "" },
	camera: Camera.default,
	fitted: Bool.False,
	sweep: 0,
	title: Text.Prepared.stub,
	hint: Text.Prepared.stub,
}

## The very first cycle. `frame_count` is zero, which is what makes this the
## one cycle that enqueues the dataset.
first_step : Program.Step(Msg)
first_step = Program.Step.for_tests({})

## Any cycle after it, one sixtieth of a second later.
later_step : Program.Step(Msg)
later_step = first_step.with_time({ ..Program.first_frame, frame_count: 1, elapsed_seconds: 1 / 60 })

## Run a cycle and keep the model it produced.
stepped : Model, Program.Step(Msg) -> Model
stepped = |model, step| update(model, step).fields().value

## The model after the first cycle, which is where most of these start.
primed_model : Model
primed_model = stepped(stub_model, first_step)

## Escape asks the platform to shut down. This is the app's only action, and
## this is the assertion that it is really reached through `update` rather than
## through the helper that builds it.
expect List.map(update(stub_model, first_step.with_input(Input.none.with_key_pressed(KeyEscape))).fields().actions, Program.action_shape) == [Exit(0)]

## Any other cycle asks for nothing. A key that is merely held is not a press,
## which is the distinction the packed state bits exist for.
expect List.is_empty(update(stub_model, first_step).fields().actions)
expect List.is_empty(update(stub_model, first_step.with_input(Input.none.with_key_down(KeyEscape))).fields().actions)

## The first cycle enqueues all fourteen files and releases the first four, in
## the order `sources` lists them.
expect List.map(update(stub_model, first_step).fields().tasks, Program.task_shape)
	== [
		ReadFile({ path: "src/backend_raylib.zig" }),
		ReadFile({ path: "src/capture.zig" }),
		ReadFile({ path: "src/capture_vp8.zig" }),
		ReadFile({ path: "src/gif_encoder.zig" }),
	]

expect primed_model.queue.in_flight() == max_in_flight
expect primed_model.queue.pending_len() == List.len(sources) - max_in_flight

## Only the first cycle enqueues. The second one finds the budget full and
## sends nothing -- this is the pacing, observed through `update` itself.
expect List.is_empty(update(primed_model, later_step).fields().tasks)

## The lockstep half of that: `queued` names the files that have *not* gone out,
## and the four that have are marked as being read. This is the guarantee
## `TaskQueue.release` states, used for something.
expect primed_model.queued == [4, 5, 6, 7, 8, 9, 10, 11, 12, 13]
expect List.map(List.sublist(primed_model.lanes, { start: 0, len: 5 }), |lane| lane.progress)
	== [Reading, Reading, Reading, Reading, Pending]

## A delivered file frees its slot, and the next file goes out in its place --
## by name, not merely by count.
expect {
	next = update(primed_model, later_step.with_message(FileRead(0, Ok([97, 98, 10, 99, 10]))))
	List.map(next.fields().tasks, Program.task_shape) == [ReadFile({ path: "src/graphical_smoke.zig" })]
		and next.fields().value.queue.in_flight() == max_in_flight
			and next.fields().value.queued == [5, 6, 7, 8, 9, 10, 11, 12, 13]
}

## And the bytes it delivered are parsed in the same cycle: two newline-ended
## lines become two points in the batch.
expect {
	delivered = stepped(primed_model, later_step.with_message(FileRead(0, Ok([97, 98, 10, 99, 10]))))
	List.len(delivered.instances) == 2 and delivered.parsing == Idle
}

## Two files delivered on one cycle are both taken, but only one is parsed --
## `advance` scans exactly one window per cycle whatever arrives.
expect {
	delivered = stepped(primed_model, later_step.with_messages([FileRead(0, Ok([97, 10])), FileRead(1, Ok([98, 10]))]))
	delivered.queue.in_flight() == max_in_flight and List.len(delivered.instances) == 1
}

## A refused read frees its slot and goes back to the *end* of the backlog, and
## its lane index goes with it -- otherwise `queued` would name the wrong file
## from that point on. The lane is waiting again, not being read.
expect {
	busy = stepped(primed_model, later_step.with_message(FileRead(0, Err(Busy))))
	busy.queued == [5, 6, 7, 8, 9, 10, 11, 12, 13, 0]
		and List.get(busy.lanes, 0) == Ok({ progress: Pending, lines: 0, bytes: 0 })
			and busy.queue.in_flight() == max_in_flight
}

## A read that failed for any other reason is not retried, and the lane says so.
expect {
	failed = stepped(primed_model, later_step.with_message(FileRead(2, Err(NotFound))))
	List.get(failed.lanes, 2) == Ok({ progress: Failed("not found"), lines: 0, bytes: 0 })
		and List.len(failed.queued) == List.len(sources) - max_in_flight - 1
}

## The view is pure model state, so the wheel really does zoom through the real
## `update` and not only through `zoom_at`.
expect stepped(primed_model, later_step.with_input(zooming_input)).camera.zoom() > primed_model.camera.zoom()

## And `R` refits, whatever the view was dragged to first.
expect {
	zoomed = stepped(primed_model, later_step.with_input(zooming_input))
	refit = stepped(zoomed, later_step.with_input(Input.none.with_key_pressed(KeyR)))
	# The step's window is `Step.for_tests`'s 800x600 default, and that is the
	# size the refit fits to -- the model no longer carries a screen size.
	F32.abs(refit.camera.zoom() - fit_camera({ x: 800, y: 600 }).zoom()) < 0.0001
}

## A wheel spin with the pointer inside the plot.
zooming_input : Input.Snapshot
zooming_input = Input.none.with_mouse_position({ x: 600, y: 400 }).with_mouse_wheel({ x: 0, y: 3 })

## The sweep clock advances with the frame, and a long stall is clamped rather
## than allowed to jump the highlight across the plot.
expect stepped(stub_model, first_step.with_time({ ..Program.first_frame, elapsed_seconds: 0.02 })).sweep == 0.02
expect stepped(stub_model, first_step.with_time({ ..Program.first_frame, elapsed_seconds: 30 })).sweep == 0.05
