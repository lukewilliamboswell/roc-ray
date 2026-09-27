app [Model, program] { rr: platform "../../platform/main.roc", roc: "nightly-2026-09-27-a3ce7f1" }

import rr.App
import rr.Assets
import rr.Cmd
import rr.Capture
import rr.Files
import rr.Permission
import rr.Task

## Declared permissions, probed from one app.
##
## The probe mode comes from argv, and so does the declaration set, through
## `init_for_args`: the same binary runs once with narrow declarations and
## once per facility with none, so the driver can tell a runtime refusal from
## a programmer error.
##
## - `--probe=scoped`: narrow declarations. Everything in scope succeeds or
##   fails for its own reasons; everything out of scope is `PermissionDenied`;
##   the app's own resources need no declaration.
## - `--probe=undeclared-FACILITY`: no declarations. The one effect named must
##   stop the app with a message naming the declaration to add.
## - `--probe=invalid-directory`, `--probe=escaping-output`: a malformed
##   config, which must stop startup before `init!` runs.
## - `--probe-crash`: a crash, whose payload is ordinary standard error.
Model : { work : Files.Dir }

Msg : [Checked(Bool)]

program = { init!, update!, render! }

declared_origin = "http://127.0.0.1:9"

declared_variable = "ROC_RAY_PROBE_DECLARED"

mode : List(Str) -> Str
mode = |args| {
	var $found = ""
	for arg in args {
		if Str.starts_with(arg, "--probe=") {
			$found = Str.drop_prefix(arg, "--probe=")
		}
	}
	$found
}

config : List(Str) -> App.Config
config = |args|
	match mode(args) {
		"scoped" =>
			App.default
				.with_permissions([
					HttpOrigin(declared_origin),
					UdpBind(40000),
					Command("git"),
					EnvVar(declared_variable),
					WorkingDirectory(ReadWrite),
				])

		"invalid-directory" => App.default.with_permission(Directory("../outside", ReadOnly))
		"escaping-output" => App.default.with_output_dir("../outside")
		_ => App.default
	}

denied : Try(a, [PermissionDenied, ..]) -> Bool
denied = |result| match result {
	Err(PermissionDenied) => Bool.True
	_ => Bool.False
}

init! : App.Init(Model, [Failed(Str)])
init! = App.init_for_args(
	config,
	|io| {
		args = io.args!()
		if args.contains("--probe-crash") {
			crash "CRASH_PAYLOAD_VISIBLE"
		}
		if !denied(Files.Dir.stub.write_text!("stub.txt", "must never be written")) {
			return Err(Failed("a stub handle wrote a file"))
		}
		match mode(args) {
			"scoped" => scoped!(io)
			"undeclared-http" => undeclared!(denied(io.http().get_utf8!("http://127.0.0.1:1/")))
			"undeclared-udp" => undeclared!(denied(io.udp().bind!({ ip: "127.0.0.1", port: 0 })))
			"undeclared-command" => undeclared!(denied(io.commands().run!(Cmd.new("roc-ray-caps-command-must-not-run"))))
			"undeclared-env" => undeclared!(denied(io.env().read!("PATH")))
			"undeclared-clipboard-read" => undeclared!(denied(io.clipboard().read_text!()))
			"undeclared-clipboard-write" => undeclared!(denied(io.clipboard().set_text!("must never reach the clipboard")))
			"undeclared-files" => undeclared!(denied(io.files().working_directory_read!()))
			"undeclared-app-id" => undeclared!(denied(io.files().app_data!()))
			other => Err(Failed("unknown probe mode: ${other}"))
		}
	},
)

## An undeclared use stops the app inside the effect, so reaching here at all
## is the failure.
undeclared! : Bool => Try(Model, [Failed(Str)])
undeclared! = |_| Err(Failed("an undeclared effect returned instead of stopping the app"))

scoped! : App.Io => Try(Model, [Failed(Str)])
scoped! = |io| {
	# The app's own resources: no declaration, never refused.
	bundle = io.files().beside_executable!() ? |_| Failed("the bundle beside the executable did not open")
	own =
		io.stdout().line!("OWN_STDOUT_WRITTEN") == Ok({})
			and !denied(io.sqlite().open_memory!())
				and !denied(Assets.open!(bundle, IgnoreManifest))
					and !denied(io.capture().start!(Capture.default))
						and !denied(io.capture().stop!())
	if !own {
		return Err(Failed("an app-scoped effect was refused"))
	}
	work = io.files().working_directory!() ? |_| Failed("the declared working directory did not open")
	# Declared facilities, targets outside their scopes: refused, nothing done.
	# A path a handle does not reach is refused the same way.
	outside =
		denied(io.http().get_utf8!("http://127.0.0.1:1/"))
			and denied(io.udp().bind!({ ip: "127.0.0.1", port: 40001 }))
				and denied(io.commands().run!(Cmd.new("roc-ray-caps-command-must-not-run")))
					and denied(io.env().read!("PATH"))
						and denied(work.read_text!("../outside.txt"))
							and denied(work.write_text!("/tmp/roc-ray-caps-must-not-exist.txt", "must never be written"))
								and denied(io.files().open_dir_read!("/etc"))
	if !outside {
		return Err(Failed("an out-of-scope effect was admitted"))
	}
	# Inside the scopes: not refused, whatever else happens.
	inside =
		!denied(io.env().read!(declared_variable))
			and !denied(io.udp().bind!({ ip: "127.0.0.1", port: 40000 }))
	if !inside {
		return Err(Failed("an in-scope effect was refused"))
	}
	Ok({ work: work })
}

check! : Files.Dir => Msg
check! = |files| {
	result = files.write_text!("task.txt", "task authority")
	Checked(result == Ok({}) and files.read_text!("task.txt") == Ok("task authority"))
}

update! : Model, App.Input(Msg), App.Io => Try(Model, [Exit(I64)])
update! = |model, input, _io| {
	if input.time.cycle_count == 0 {
		files = model.work
		Task.spawn!(input, || check!(files))
	}
	match List.first(input.messages) {
		Ok(Checked(Bool.True)) => Err(Exit(0))
		Ok(Checked(Bool.False)) => Err(Exit(3))
		Err(_) => if input.time.cycle_count > 120 Err(Exit(4)) else Ok(model)
	}
}

render! : Model, _ => Try({}, [Exit(I64)])
render! = |_model, _frame| Ok({})
