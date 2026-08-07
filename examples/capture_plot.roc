app [Model, program] { rr: platform "../platform/main.roc" }

import rr.App
import rr.Capture
import rr.Color
import rr.Draw
import rr.Host
import rr.Text

## Render an animated bar chart to a file, with no runtime capture code.
##
## The recording is declared in the startup config, so the host arms it before
## the first frame and finalizes it on exit. Because it asks for `FixedStep`
## timing, `host.frame_time` is exactly 1/25s every frame no matter how long the
## readback actually took -- so the animation in the file is smooth and
## identical between runs, even though capturing stalls the GPU.
##
## `with_visible(Bool.False)` keeps the window off screen while still rendering
## on the GPU, so this runs like a batch job: start it and collect the frames.
## It still needs a display server, so wrap it in `xvfb-run` on a machine
## without one. That is not the same as the host's `--headless` flag, which
## swaps in a stub backend that draws nothing and therefore captures nothing.
##
## Run it, then open `captures/plot.webm`. Swap `.with_format(Gif)` and a
## `.gif` path if you want something to drop straight into a README --
## GIF is more portable, WebM is far smaller and keeps full colour.
Model : {
	elapsed : F32,
	title : Text.Prepared,
	status : Text.Prepared,
}

program = { init!, render! }

bar_count : U64
bar_count = 12

## Frames recorded before the host finalizes the files and the app exits.
recorded_frames : U64
recorded_frames = 75

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default
		.with_title("RocRay Capture: Plot")
		.with_size({ width: 640, height: 360 })
		.with_frame_pacing(Capped(60))
		.with_visible(Bool.False)
		.with_output_dir("captures")
		.with_recording(
			Record(
				Capture.default
					.with_path("plot.webm")
					.with_format(WebM)
					.with_fps(25)
					.with_max_frames(recorded_frames)
					.with_scale(Half)
					.with_timing(FixedStep),
			),
		),
	|_host|
		Ok({
			elapsed: 0,
			title: Text.from("Recording a plot").size(28).prepare!()?,
			status: Text.from("captures/plot.webm").size(16).prepare!()?,
		}),
)

render! : Model, Host, Draw.Frame => Try(Model, [Exit(I64), ..])
render! = |model, host, frame| {
	elapsed = model.elapsed + host.frame_time

	frame.clear!(Color.from_hex_rgb(0x121420))
	model.title.draw!(frame, { pos: { x: 32, y: 28 }, color: Color.white, align: Text.align_top_left })
	model.status.draw!(frame, { pos: { x: 32, y: 64 }, color: Color.from_hex_rgb(0x81a1c1), align: Text.align_top_left })

	draw_bars!(frame, elapsed)

	# Once the recording has written every frame it was asked for there is
	# nothing left to capture, so shut down and let the host finalize.
	match Capture.status!() {
		Active(progress) => if progress.frames >= recorded_frames host.exit!(0) else {}
		_ => {}
	}

	Ok({ ..model, elapsed: elapsed })
}

draw_bars! : Draw.Frame, F32 => {}
draw_bars! = |frame, elapsed|
	List.repeat({}, bar_count)
		|> List.map_with_index(|_, index| U64.to_f32(index))
		|> List.for_each!(
			|offset| {
				# A travelling wave, so every frame differs and a dropped or
				# duplicated frame is visible in the finished sequence.
				phase = elapsed * 2.2 + offset * 0.5
				height = 40 + 90 * (1 + F32.sin(phase)) / 2
				frame.rectangle!({
					x: 40 + offset * 46,
					y: 320 - height,
					width: 34,
					height: height,
					style: Draw.filled(Color.from_hex_rgb(0x5e81ac)),
				})
			},
		)
