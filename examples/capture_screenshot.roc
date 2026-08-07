app [Model, program] { rr: platform "../platform/main.roc" }

import rr.App
import rr.Capture
import rr.Color
import rr.Draw
import rr.Host
import rr.Program
import rr.Text

## Take a single screenshot, and show what the output sandbox refuses.
##
## Every capture path is relative to the directory set with `with_output_dir`.
## A path that would escape it -- absolute, or containing `..` -- is refused
## rather than quietly rewritten, because writing files is the only filesystem
## capability the platform grants an app.
##
## Press S to write `shots/scene.png`, E to watch an escaping path be refused,
## ESC to exit. With no keypress it screenshots itself on frame 3 and exits, so
## the headless CI sweep still runs it.
Model : {
	title : Text.Prepared,
	help : Text.Prepared,

	## Every outcome is prepared once at startup rather than re-laid-out each
	## frame, which keeps `render!` free of the allocation and its error.
	idle : Text.Prepared,
	saved : Text.Prepared,
	save_failed : Text.Prepared,
	refused : Text.Prepared,
	result : Text.Prepared,
}

program = { init!, update!, render! }

init! : App.Init(Model, [ResourceLimit])
init! = App.init(
	App.default
		.with_title("RocRay Capture: Screenshot")
		.with_size({ width: 640, height: 360 })
		.with_output_dir("shots"),
	|_host|
		{
			idle = Text.from("no capture yet").size(16).prepare!()?
			Ok({
				title: Text.from("Screenshot demo").size(28).prepare!()?,
				help: Text.from("S = save, E = try to escape the sandbox, ESC = quit").size(16).prepare!()?,
				idle: idle,
				saved: Text.from("saved shots/scene.png").size(16).prepare!()?,
				save_failed: Text.from("could not write shots/scene.png").size(16).prepare!()?,
				refused: Text.from("refused ../escaped.png (PathEscapesOutputDir)").size(16).prepare!()?,
				result: idle,
			})
		},
)

## Screenshots are host effects driven by input, so they belong here. Asking
## for one during drawing would put an effect outside the message stream.
update! : Model, Program.Input => Try({ model : Model, cmds : List(Program.Cmd) }, [Exit(I64), ..])
update! = |model, input|
	match input {
		Frame(host) => {
			if host.key_pressed(KeyEscape) {
				host.exit!(0)
			}

			# `..` cannot reach outside the output directory, so this reports
			# PathEscapesOutputDir rather than writing beside the example source.
			escaped =
				if host.key_pressed(KeyE) {
					match Capture.screenshot!("../escaped.png") {
						Err(PathEscapesOutputDir) => Ok(model.refused)
						# Any other outcome means the sandbox let something through.
						_ => Ok(model.save_failed)
					}
				} else {
					Err(NotRequested)
				}

			saved =
				if host.key_pressed(KeyS) or host.frame_count == 3 {
					match Capture.screenshot!("scene.png") {
						Ok({}) => Ok(model.saved)
						Err(_) => Ok(model.save_failed)
					}
				} else {
					Err(NotRequested)
				}

			# The screenshot is written at the end of this frame, so leave the
			# host a frame to do it before asking to exit.
			if host.frame_count > 3 {
				host.exit!(0)
			}

			next = match (escaped, saved) {
				(Ok(text), _) => { ..model, result: text }
				(_, Ok(text)) => { ..model, result: text }
				_ => model
			}
			Ok({ model: next, cmds: [] })
		}

		_ => Ok({ model: model, cmds: [] })
	}

render! : Model, Draw.Frame => Try(Model, [Exit(I64), ..])
render! = |model, frame| {
	frame.clear!(Color.from_hex_rgb(0x121420))
	model.title.draw!(frame, { pos: { x: 32, y: 28 }, color: Color.white, align: Text.align_top_left })
	model.help.draw!(frame, { pos: { x: 32, y: 64 }, color: Color.from_hex_rgb(0x81a1c1), align: Text.align_top_left })
	model.result.draw!(frame, { pos: { x: 32, y: 300 }, color: Color.from_hex_rgb(0xa3be8c), align: Text.align_top_left })

	frame.circle!({
		center: { x: 320, y: 190 },
		radius: 70,
		style: Draw.filled(Color.from_hex_rgb(0x5e81ac)),
	})

	Ok(model)
}
