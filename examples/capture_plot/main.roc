## Renders an animated bar chart to `captures/plot.webm`, then exits. The
## window stays hidden, but a display is still required; use `xvfb-run` on a
## machine without one. This example shows how to configure recording, advance
## animation by the same amount for every recorded frame, and track progress.
app [Model, program] { rr: platform "https://github.com/lukewilliamboswell/roc-ray/releases/download/0.10.0-rc3/3vVeddfDE6rraq5j8v1cGHtFNaQhC6dij1zGRN63NGP1.tar.zst", roc: "nightly-2026-08-23-fb208ba" }

import rr.App
import rr.Capture
import rr.Color
import rr.Draw
import rr.Text

## The Model keeps the animation time, completed-frame count, and prepared
## labels between updates. Each Input passed to `update!` includes recording
## progress, so the count reflects frames actually captured.
Model : {
	elapsed : F32,

	## Frames the host says it has written, straight from `input.capture`. The
	## progress bar is drawn from it, so the recording reports on itself.
	frames : U64,
	title : Text.Prepared,
	status : Text.Prepared,
}

program = { init!, update!, render! }

bar_count = 12.U64

## Frames recorded before the host finalizes the files and the app exits.
recorded_frames = 75.U64

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default
		.with_title("RocRay Capture: Plot")
		.with_size({ width: 640, height: 360 })
		.with_frame_pacing(Capped(60))
		.with_visible(Bool.False)
		.with_output_dir("captures")
		.with_recording(
			Capture.default
				.with_path("plot.webm")
				.with_format(WebM)
				.with_fps(25)
				.with_max_frames(recorded_frames)
				.with_scale(Half)
				.with_timing(FixedStep),
		),
	|_startup| {
		font = Draw.default_font!()
		Ok({
			elapsed: 0,
			frames: 0,
			title: Text.from("Recording a plot", font).size(24).prepare!()?,
			status: Text.from("captures/plot.webm", font).size(14).prepare!()?,
		})
	},
)

## Elapsed time advances on the tick rather than inside the draw, so the plot
## is a pure function of the model when `render!` runs.
##
## Nothing here waits, so there is no task to spawn and no message to fold in.
## A recording's outcome arrives on `input.capture` instead: it is sampled like
## the devices and the clock, not asked for with an effect.
Msg : []

update! : Model, App.Input(Msg) => Try(Model, [Exit(I64), ..])
update! = |model, program_input| {
	# The host finalizes the file itself once the recording reaches its frame
	# cap, and says so with `Finished`. Match on that rather than on `Idle`:
	# `Idle` is also what a run with no recording at all looks like -- a
	# headless run is exactly that -- so treating it as done would exit on the
	# first cycle having captured nothing and call it a success.
	match program_input.capture {
		Finished(_) => Err(Exit(0))
		Failed(_) => Err(Exit(1))
		Idle => Ok({ ..model, elapsed: model.elapsed + program_input.time.elapsed_seconds })
		Active(progress) => Ok({ ..model, elapsed: model.elapsed + program_input.time.elapsed_seconds, frames: progress.frames })
	}
}

render! : Model, Draw.Frame => Try({}, [Exit(I64), ..])
render! = |model, frame| {
	size = frame.size!()
	frame.rectangle_gradient_v!({ x: 0, y: 0, width: size.width, height: size.height, color_top: bg_top, color_bottom: bg_bottom })

	model.title.draw!(frame, { pos: { x: 32, y: 26 }, color: ink })

	# A recording indicator that reads at a glance in the finished file: the
	# dot pulses on the same fixed step the frames are captured on.
	pulse = 4 + 2 * F32.sin(model.elapsed * 6)
	frame.circle!({ center: { x: 38, y: 66 }, radius: pulse, style: Draw.filled(rec) })
	model.status.draw!(frame, { pos: { x: 52, y: 58 }, color: muted })

	draw_progress!(frame, { x: size.width - 232, y: 34, width: 200 }, model.frames)
	draw_bars!(frame, model.elapsed, size)
	Ok({})
}

## How much of the recording is written, as a bar and a count. `frames` comes
## from `input.capture`, so this is the host's number rather than a guess.
draw_progress! : Draw.Frame, { x : F32, y : F32, width : F32 }, U64 => {}
draw_progress! = |frame, at, frames| {
	share = F32.min(U64.to_f32(frames) / U64.to_f32(recorded_frames), 1)
	frame.text_at!({ pos: { x: at.x, y: at.y }, text: "${U64.to_str(frames)} / ${U64.to_str(recorded_frames)} frames", size: 13, color: muted })
	frame.rounded_rectangle!({ x: at.x, y: at.y + 22, width: at.width, height: 6, radius: 0.5, segments: 6, style: Draw.filled(track) })
	if share > 0 {
		frame.rounded_rectangle!({ x: at.x, y: at.y + 22, width: at.width * share, height: 6, radius: 0.5, segments: 6, style: Draw.filled(rec) })
	}
}

draw_bars! : Draw.Frame, F32, Draw.FrameSize => {}
draw_bars! = |frame, elapsed, size| {
	baseline = size.height - 44

	# Four gridlines behind the bars, so the wave has something to be measured
	# against and a duplicated frame is easier to spot.
	List.for_each!(
		List.map_with_index(List.repeat({}, 4), |_unit, index| U64.to_f32(index + 1) * 42),
		|step| frame.line!({ start: { x: 32, y: baseline - step }, end: { x: size.width - 32, y: baseline - step }, stroke: Stroke({ color: grid, thickness: 1 }) }),
	)
	frame.line!({ start: { x: 32, y: baseline }, end: { x: size.width - 32, y: baseline }, stroke: Stroke({ color: axis, thickness: 1.5 }) })

	List.repeat({}, bar_count)
		|> List.map_with_index(|_, index| U64.to_f32(index))
		|> List.for_each!(
			|offset| {
				# A travelling wave, so every frame differs and a dropped or
				# duplicated frame is visible in the finished sequence.
				phase = elapsed * 2.2 + offset * 0.5
				height = 40 + 90 * (1 + F32.sin(phase)) / 2
				x = 40 + offset * 46
				top = baseline - height
				# The gradient runs the bar's own length rather than the
				# window's, so a tall bar is brighter than a short one.
				frame.rectangle_gradient_v!({ x: x, y: top, width: 34, height: height, color_top: bar_top, color_bottom: bar_bottom })
				frame.rectangle!({ x: x, y: top, width: 34, height: 3, style: Draw.filled(bar_cap) })
				frame.circle!({ center: { x: x + 17, y: top - 10 }, radius: 2.5, style: Draw.filled(Color.with_alpha(bar_cap, 150)) })
			},
		)
}

bg_top = Color.from_hex_rgb(0x0b0e17)

bg_bottom = Color.from_hex_rgb(0x171f31)

ink = Color.from_hex_rgb(0xe8ecf5)

muted = Color.from_hex_rgb(0x8a97b0)

grid = Color.from_hex_rgba(0xffffff1a)

axis = Color.from_hex_rgb(0x39445c)

track = Color.from_hex_rgb(0x232c3f)

rec = Color.from_hex_rgb(0xef7d7d)

bar_top = Color.from_hex_rgb(0x7fd6d0)

bar_bottom = Color.from_hex_rgb(0x4667b4)

bar_cap = Color.from_hex_rgb(0xbdf0ea)
