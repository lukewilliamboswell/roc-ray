#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.25.0/CZsY7tYZwR3rj9kYbpaCfxki2yVAaRL8bBwMLvB2xkbA.tar.zst",
}

import cli.Cmd
import cli.OsStr
import cli.Path
import cli.Stderr
import cli.Stdout

## Everything `blueprint run check` checks, in order. Run from the repository
## root, inside the Blueprint environment.
##
##   1. no compiler pin outside `scripts/` (`scripts/check_no_pins.roc`);
##   2. the scripts: the tests of their pure modules under `scripts/src/`,
##      `roc-stable check` of each script, and `roc-stable fmt --check`;
##   3. the repository lints, `zig build lint`.
##
## `roc-stable` runs the scripts. Bare `roc`, the latest nightly, is what the
## platform and its examples are tested with, by `blueprint run test`.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	if !args.is_empty() {
		_ = Stderr.line!("usage: scripts/check_all.roc")
		return Err(Exit(2))
	}
	match run!({}) {
		Ok({}) => Ok({})
		Err(_) => Err(Exit(1))
	}
}

run! : {} => Try({}, [ScriptFailed])
run! = |{}| {
	section!("Compilers")?
	succeed!("roc-stable", ["version"])?

	section!("Compiler pins")?
	succeed!("scripts/check_no_pins.roc", [])?

	section!("Scripts")?
	for source in roc_files!("scripts/src")? {
		succeed!("roc-stable", ["test", source])?
	}
	for script in roc_files!("scripts")? {
		succeed!("roc-stable", ["check", script])?
	}
	succeed!("roc-stable", ["fmt", "--check", "scripts"])?

	section!("Lints")?
	succeed!("zig", ["build", "lint"])
}

# The `.roc` files directly inside `directory`, in a stable order.
roc_files! : Str => Try(List(Str), [ScriptFailed])
roc_files! = |directory|
	match Path.list!(Path.unix(directory)) {
		Ok(entries) => Ok(entries.map(Path.display).keep_if(|path| path.ends_with(".roc")).sort_with(by_name))
		Err(_) => fail!("could not list ${directory}")
	}

# Byte order, so listings are the same on every file system.
by_name : Str, Str -> [Before, Same, After]
by_name = |a, b| by_bytes(a.to_utf8(), b.to_utf8())

by_bytes : List(U8), List(U8) -> [Before, Same, After]
by_bytes = |a, b|
	match (a, b) {
		([], []) => Same
		([], _) => Before
		(_, []) => After
		([x, .. as rest_a], [y, .. as rest_b]) => if (x < y) Before else if (x > y) After else by_bytes(rest_a, rest_b)
	}

section! : Str => Try({}, [ScriptFailed])
section! = |name|
	match Stdout.line!("\n== ${name}") {
		Ok({}) => Ok({})
		Err(_) => Err(ScriptFailed)
	}

fail! : Str => Try(_, [ScriptFailed])
fail! = |message| {
	_ = Stderr.line!("error: ${message}")
	Err(ScriptFailed)
}

## Print a command, then run it with inherited output; a non-zero exit is an
## error.
succeed! : Str, List(Str) => Try({}, [ScriptFailed])
succeed! = |program, args| {
	_ = Stdout.line!("+ ${program} ${Str.join_with(args, " ")}")
	match Cmd.new_str(program).args_str(args).exec_exit_code!() {
		Ok(0) => Ok({})
		Ok(code) => fail!("${program} ${Str.join_with(args, " ")} exited with code ${code.to_str()}")
		Err(_) => fail!("could not run ${program}")
	}
}
