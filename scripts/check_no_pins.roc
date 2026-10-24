#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.25.0/CZsY7tYZwR3rj9kYbpaCfxki2yVAaRL8bBwMLvB2xkbA.tar.zst",
}

import cli.Cmd
import cli.OsStr
import cli.Path
import cli.Stderr
import cli.Stdout
import src/Pins

## Fail when anything outside `scripts/` names a Roc compiler. Run from the
## repository root.
##
## The platform, its examples and its tests carry no `roc` header field and are
## tested with the latest nightly; the repository has no `.roc-version` and no
## `.github/roc-nightly.json`. Every script under `scripts/` runs on
## `roc-stable`, the nightly `Blueprint.roc` fetches: its first line is the
## `roc-stable` shebang, and a `roc` field, where a script has one, names that
## same nightly.
##
## It reads the files Git tracks or would add, and runs no compiler.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	if !args.is_empty() {
		_ = Stderr.line!("usage: scripts/check_no_pins.roc")
		return Err(Exit(2))
	}
	match run!({}) {
		Ok({}) => Ok({})
		Err(_) => Err(Exit(1))
	}
}

run! : {} => Try({}, [ScriptFailed])
run! = |{}| {
	stable = match Pins.stable_tag(read!("Blueprint.roc")?) {
		Ok(tag) => tag
		Err(NoStableCompiler) => return fail!("Blueprint.roc does not fetch roc-stable with Recipes.roc_nightly(\"<tag>\")")
	}

	listing = capture!("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"])?
	paths = listing.split_on("\u(0)").keep_if(|path| !path.is_empty())

	var $problems = []
	var $checked = 0.U64
	for path in paths {
		if Pins.is_retired_pin_file(path) and exists!(path) {
			$problems = $problems.append("${path}: the platform and its applications use the latest nightly; remove this file")
		}
		if path.ends_with(".roc") and exists!(path) {
			source = read!(path)?
			$checked = $checked + 1
			if Pins.may_pin(path) {
				match Pins.roc_pin(source) {
					Ok(tag) if tag != stable => {
						$problems = $problems.append("${path}: names roc \"${tag}\", but Blueprint.roc runs the scripts on roc-stable ${stable}")
					}
					Err(MalformedPin) => {
						$problems = $problems.append("${path}: the roc header field must be one quoted nightly tag")
					}
					_ => {}
				}
				if Pins.is_script(path) and !Pins.has_stable_shebang(source) {
					$problems = $problems.append("${path}: a script must start with #!/usr/bin/env roc-stable")
				}
			} else {
				match Pins.roc_pin(source) {
					Err(NoPin) => {}
					_ => {
						$problems = $problems.append("${path}: only scripts/ names a compiler; remove the roc header field")
					}
				}
			}
		}
	}

	if !$problems.is_empty() {
		return fail!("compiler pins:\n  ${Str.join_with($problems, "\n  ")}")
	}
	say!("PASS ${$checked.to_str()} Roc files: only scripts/ names a compiler, and the scripts run on roc-stable ${stable}")
}

# A path Git lists can be deleted in the working tree and not yet staged.
exists! : Str => Bool
exists! = |path|
	match Path.is_file!(Path.unix(path)) {
		Ok(found) => found
		Err(_) => Bool.False
	}

read! : Str => Try(Str, [ScriptFailed])
read! = |path|
	match Path.read_utf8!(Path.unix(path)) {
		Ok(text) => Ok(text)
		Err(_) => fail!("could not read ${path}")
	}

say! : Str => Try({}, [ScriptFailed])
say! = |message|
	match Stdout.line!(message) {
		Ok({}) => Ok({})
		Err(_) => Err(ScriptFailed)
	}

fail! : Str => Try(_, [ScriptFailed])
fail! = |message| {
	_ = Stderr.line!("error: ${message}")
	Err(ScriptFailed)
}

## The standard output of a program that must exit 0.
capture! : Str, List(Str) => Try(Str, [ScriptFailed])
capture! = |program, args|
	match Cmd.run!(Cmd.new_str(program).args_str(args)) {
		Ok(output) =>
			match output.status {
				Exited(0) => Ok(Str.from_utf8_lossy(output.stdout_bytes))
				_ => fail!("${program} ${Str.join_with(args, " ")} failed: ${Str.from_utf8_lossy(output.stderr_bytes)}")
			}
		Err(_) => fail!("could not run ${program}")
	}
