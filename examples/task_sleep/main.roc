## Watch a comet keep moving while a 1.2-second task waits. When the task
## finishes, the window shows which host cycle its message arrived on and stays
## open until you press Escape. This example introduces tasks, work that may
## wait without pausing drawing, and messages, the values finished tasks
## deliver in a later `Input`.
app [Model, program] { rr: platform "../../platform/main.roc" }

import rr.App
import rr.Task
import rr.Color
import rr.Draw
import rr.Text
import rr.Trace

## State kept between host cycles: whether the task is still waiting, the
## current cycle and animation time, and prepared text. The model records the
## cycle the task's message arrived on, so `render!` can show it.
Model : {
	state : State,
	cycle : U64,
	elapsed : F32,
	title : Text.Prepared,
	hint : Text.Prepared,
}

## How far the app has got: waiting on the sleeper, or holding the cycle its
## message arrived on.
State : [Waiting, Woke({ arrived_on : U64 })]

Msg : [Woke]

sleep_millis = 1200.U64

program = { init!, update!, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default.with_title("RocRay Task Sleep").with_frame_pacing(Capped(60)),
	|_io| {
		font = Draw.default_font!()
		Ok({
			state: Waiting,
			cycle: 0,
			elapsed: 0,
			title: Text.from("Sleeping on a task while the frame keeps moving", font).size(22).prepare!()?,
			hint: Text.from("Escape quits", font).size(14).prepare!()?,
		})
	},
)

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, input, io| {
	cycle = input.time.cycle_count
	state = List.fold(input.messages, model.state, |current, message| apply_message(current, message, cycle))
	if cycle == 0 {
		# Spawned from inside `update!`: the task waits on its sleep while the
		# app keeps drawing, and `Woke` arrives on a later input.
		Task.spawn!(
			input,
			|| {
				zone = Trace.begin!("waiting for wake timer")
				Task.sleep!(sleep_millis)
				Trace.end!(zone)
				Woke
			},
		)
		# Printed from `update!` too, one line before any of the waiting starts.
		_ = io.stdout().line!(start_line)
	}

	# Report once, on the cycle the message arrives. The line is queued here
	# and written by the host, so `update!` never waits for the terminal.
	if model.state == Waiting and state != Waiting {
		_ = io.stdout().line!(report_line(cycle))
	}

	Ok({ ..model, state, cycle, elapsed: model.elapsed + input.time.elapsed_seconds })
}

## What `update!` prints on the cycle it spawns the sleeper.
start_line : Str
start_line = "task_sleep: sleeping ${U64.to_str(sleep_millis)} ms on a task while the frame loop keeps drawing"

## What `update!` prints once the sleeper's message comes back.
report_line : U64 -> Str
report_line = |arrived_on|
	"task_sleep: slept ${U64.to_str(sleep_millis)} ms, message arrived on cycle ${U64.to_str(arrived_on)}"

expect report_line(18) == "task_sleep: slept 1200 ms, message arrived on cycle 18"

apply_message : State, Msg, U64 -> State
apply_message = |state, message, cycle|
	match message {
		Woke =>
			match state {
				Waiting => Woke({ arrived_on: cycle })
				already => already
			}
		}

expect match apply_message(Waiting, Woke, 18) {
	Woke({ arrived_on }) => arrived_on == 18
	_ => Bool.False
}

## The cycle the sleeper woke on is the first one that arrived, so a second
## message could not move it.
expect apply_message(Woke({ arrived_on: 18 }), Woke, 25) == Woke({ arrived_on: 18 })

## One full turn of a circle, in radians. The progress ring starts a quarter
## turn back from the right, so it grows clockwise from twelve o'clock.
full_turn = 6.2831855.F32

quarter_turn = full_turn / 4

## The radius of the orbit the comet travels and the ring the arc is drawn on.
ring_radius = 150.F32

## How many straight segments make a whole ring.
ring_segments = 90.U64

render! : Model, Draw.Frame => Try({}, [Exit(I64)])
render! = |model, frame| {
	# How much of the sleep has gone by, capped at a full ring once it is over.
	# Purely a view value, so it is derived here.
	progress = F32.min(model.elapsed * 1000 / U64.to_f32(sleep_millis), 1)
	center = { x: 400.F32, y: 340.F32 }

	frame.rectangle_gradient_v!({ x: 0, y: 0, width: 800, height: 600, color_top: Color.from_hex_rgb(0x1b2136), color_bottom: Color.from_hex_rgb(0x0a0c15) })
	frame.circle_gradient!({ center, radius: 260, color_inner: Color.with_alpha(Color.from_hex_rgb(0x5e81ac), 40), color_outer: Color.with_alpha(Color.from_hex_rgb(0x5e81ac), 0) })

	model.title.draw!(frame, { pos: { x: 40, y: 40 }, color: Color.white })
	frame.text_at!({ pos: { x: 40, y: 78 }, text: "cycle ${U64.to_str(model.cycle)}", size: 20, color: Color.from_hex_rgb(0x88c0d0) })
	frame.text_at!({ pos: { x: 40, y: 106 }, text: describe(model.state), size: 20, color: Color.from_hex_rgb(0xa3be8c) })
	model.hint.draw!(frame, { pos: { x: 40, y: 552 }, color: Color.from_hex_rgb(0x6b7590) })

	# The track, then the arc the sleeper has used up so far.
	frame.circle!({ center, radius: ring_radius, style: Draw.outlined(Color.with_alpha(Color.white, 35), 3) })
	draw_arc!(frame, center, progress)

	# A short trail of the orbiting comet: the same orbit sampled a few
	# moments back, fading out behind the head.
	draw_trail!(frame, center, model.elapsed)
	frame.circle!({ center: orbit(center, model.elapsed), radius: 14, style: Draw.filled_and_outlined(Color.from_hex_rgb(0x88c0d0), Color.white, 3) })

	Ok({})
}

## A point on the ring at `angle` radians.
on_ring : { x : F32, y : F32 }, F32 -> { x : F32, y : F32 }
on_ring = |center, angle| { x: center.x + ring_radius * F32.cos(angle), y: center.y + ring_radius * F32.sin(angle) }

## Where the comet is at a given moment. One function so the head and every
## trail sample are guaranteed to sit on the same orbit.
orbit : { x : F32, y : F32 }, F32 -> { x : F32, y : F32 }
orbit = |center, seconds| on_ring(center, seconds * 2)

draw_trail! : Draw.Frame, { x : F32, y : F32 }, F32 => {}
draw_trail! = |frame, center, seconds| {
	for remaining in (1.U64..=8).iter_rev() {
		fade = U64.to_f32(remaining) / 8
		frame.circle!({ center: orbit(center, seconds - U64.to_f32(remaining) * 0.03), radius: 12 * fade, style: Draw.filled(Color.with_alpha(Color.from_hex_rgb(0x88c0d0), F32.to_u8_wrap(90 * fade))) })
	}
}

## The progress arc, stepped by hand out of short segments so it needs nothing
## more than `frame.line!`.
draw_arc! : Draw.Frame, { x : F32, y : F32 }, F32 => {}
draw_arc! = |frame, center, progress| {
	for step in 0.U64..<ring_segments {
		if U64.to_f32(step) / U64.to_f32(ring_segments) >= progress {
			break
		}
		a = full_turn * U64.to_f32(step) / U64.to_f32(ring_segments) - quarter_turn
		b = full_turn * U64.to_f32(step + 1) / U64.to_f32(ring_segments) - quarter_turn
		frame.line!({
			start: on_ring(center, a),
			end: on_ring(center, b),
			stroke: Draw.stroke(Color.from_hex_rgb(0xa3be8c), 5),
		})
	}
}

describe : State -> Str
describe = |state|
	match state {
		Waiting => "task sleeping ${U64.to_str(sleep_millis)} ms..."
		Woke({ arrived_on }) => "task finished: message arrived on cycle ${U64.to_str(arrived_on)} (spawned on cycle 0)"
	}

expect describe(Woke({ arrived_on: 74 })) == "task finished: message arrived on cycle 74 (spawned on cycle 0)"
