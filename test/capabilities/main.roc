app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-09-07-14d9829" }

import rr.App
import rr.Assets
import rr.Cmd
import rr.Capture
import rr.Files
import rr.Task

Model : { allowed : Bool }

Msg : [Checked(Bool)]

program = { init!, update!, render! }

denied : Try(a, [PermissionDenied, ..]) -> Bool
denied = |result| match result {
	Err(PermissionDenied) => Bool.True
	_ => Bool.False
}

init! : App.Init(Model, [Failed])
init! = App.init(
	App.default.with_default_font({ path: "missing.ttf", size: 20 }),
	|io| {
		args = io.args!()
		if args.contains("--probe-crash") {
			crash "DENIED_OUTPUT_LEAK"
		}
		allowed = args.contains("--expect-allowed")
		if !denied(App.Io.stub.files().write_text!("stub.txt", "must never be written")) {
			return Err(Failed)
		}
		if args.contains("--host-caps-allow-all") {
			return Err(Failed)
		}
		if !allowed {
			ok = denied(io.default_font!())
				and denied(io.http().get_utf8!("http://127.0.0.1:1/"))
					and denied(io.commands().run!(Cmd.new("roc-ray-caps-command-must-not-run")))
						and denied(io.udp().bind!({ ip: "127.0.0.1", port: 0 }))
							and denied(io.assets().open!(Assets.working_directory(".")))
								and denied(io.files().read_text!("missing.txt"))
									and denied(io.files().write_text!("denied.txt", "must never be written"))
										and denied(io.env().read!("PATH"))
											and denied(io.sqlite().open!(":memory:"))
												and denied(io.audio().load_sound!("missing.wav"))
													and denied(io.audio().load_music!("missing.ogg"))
														and denied(io.tilemaps().load_tmx!("missing.tmx"))
															and denied(io.clipboard().read_text!())
																and denied(io.clipboard().set_text!("must never reach the clipboard"))
																	and denied(io.stdout().line!("DENIED_OUTPUT_LEAK"))
																		and denied(io.stderr().line!("DENIED_OUTPUT_LEAK"))
																			and denied(io.capture().start!(Capture.default))
																				and denied(io.capture().stop!())
			if !ok {
				return Err(Failed)
			}
		}
		Ok(
			{ allowed: allowed },
		)
	},
)

check! : Files.Access, Bool => Msg
check! = |files, allowed| {
	result = files.write_text!("task.txt", "task authority")
	if allowed {
		Checked(result == Ok({}) and files.read_text!("task.txt") == Ok("task authority"))
	} else {
		Checked(denied(result))
	}
}

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64), ..])
update! = |model, input, io| {
	if input.time.cycle_count == 0 {
		files = io.files()
		Task.spawn!(input, || check!(files, model.allowed))
	}
	match List.first(input.messages) {
		Ok(Checked(Bool.True)) => Err(Exit(0))
		Ok(Checked(Bool.False)) => Err(Exit(3))
		Err(_) => if input.time.cycle_count > 120 Err(Exit(4)) else Ok(model)
	}
}

render! : Model, _ => Try({}, [Exit(I64), ..])
render! = |_model, _frame| Ok({})
