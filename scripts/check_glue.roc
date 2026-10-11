#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
}

import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Stderr
import cli.Stdout
import src/Glue

## Regenerate the host's Zig ABI with the compiler under test and compare it
## with the committed `src/roc_platform_abi.zig`. Run from the repository root.
##
## The compiler under test is `$ROC_NIGHTLY`, or `roc` on `PATH`. Its glue
## specification comes from the source archive its nightly release attaches,
## checked against the release's SHA-256 digest; `--roc-repo DIR` reads it
## from a Roc checkout instead, for a compiler built from source.
##
##   scripts/check_glue.roc                    fail when the ABI differs
##   scripts/check_glue.roc --update           rewrite the committed ABI
##   scripts/check_glue.roc --roc-repo ../roc  take the glue spec from a checkout
##
## A difference with no change to `platform/` means the compiler changed the
## ABI: review it, regenerate, and release.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	options = match parse(args.map(OsStr.display), { update: Bool.False, roc_repo: "" }) {
		Ok(parsed) => parsed
		Err(BadArguments) => {
			_ = Stderr.line!("usage: scripts/check_glue.roc [--update] [--roc-repo DIR]")
			return Err(Exit(2))
		}
	}
	work = match capture!("mktemp", ["-d", "-t", "rocray_glue_XXXXXX"]) {
		Ok(output) => output.trim()
		Err(_) => return Err(Exit(1))
	}
	result = run!(options, work)
	_ = Cmd.new_str("rm").args_str(["-rf", work]).exec_exit_code!()
	match result {
		Ok({}) => Ok({})
		Err(_) => Err(Exit(1))
	}
}

Options : { update : Bool, roc_repo : Str }

parse : List(Str), Options -> Try(Options, [BadArguments])
parse = |args, options|
	match args {
		[] => Ok(options)
		["--update", .. as rest] => parse(rest, { ..options, update: Bool.True })
		["--roc-repo", repo, .. as rest] => parse(rest, { ..options, roc_repo: repo })
		_ => Err(BadArguments)
	}

committed = "src/roc_platform_abi.zig"

run! : Options, Str => Try({}, [ScriptFailed])
run! = |options, work| {
	roc = match Env.var_str!(OsStr.from_str("ROC_NIGHTLY")) {
		Ok(value) => if value.is_empty() "roc" else value
		Err(_) => "roc"
	}
	version = capture!(roc, ["version"])?.trim()
	say!("Compiler under test: ${version} (${roc})")?

	# Roc's glue command misreports a spec under a path component containing
	# `-` as missing, so the spec is unpacked without the archive's own
	# directory name.
	if options.roc_repo.is_empty() {
		tag = match Glue.nightly_tag(version) {
			Ok(found) => found
			Err(NotANightly) => return fail!("this compiler is not a nightly release; name its source with --roc-repo DIR")
		}
		fetch_source!(tag, work)?
	} else {
		# A nightly names its commit; a compiler built from source is taken
		# to be built from the checkout's HEAD.
		revision = match Glue.nightly_tag(version) {
			Ok(tag) => tag.split_on("-").last() ?? "HEAD"
			Err(NotANightly) => "HEAD"
		}
		commit = capture!("git", ["-C", options.roc_repo, "rev-parse", "--verify", "${revision}^{commit}"])?.trim()
		say!("Glue source: ${options.roc_repo} @ ${commit}")?
		succeed!("git", ["-C", options.roc_repo, "archive", "--format=tar", "--output=${work}/glue.tar", commit, "src/glue"])?
		succeed!("tar", ["-xf", "${work}/glue.tar", "-C", work])?
	}

	generated = "${work}/generated/roc_platform_abi.zig"
	succeed!("mkdir", ["${work}/generated"])?
	succeed!(roc, ["glue", "${work}/src/glue/src/ZigGlue.roc", "${work}/generated", "platform/main.roc"])?
	succeed!("zig", ["fmt", generated])?

	if options.update {
		succeed!("cp", [generated, committed])?
		say!("Updated ${committed}")
	} else {
		match Cmd.new_str("git").args_str(["diff", "--no-index", "--stat", "--exit-code", committed, generated]).exec_exit_code!() {
			Ok(0) => say!("PASS ${committed} matches what ${version} generates")
			Ok(_) => {
				_ = Cmd.new_str("git").args_str(["--no-pager", "diff", "--no-index", committed, generated]).exec_exit_code!()
				fail!("${committed} differs from what ${version} generates. If this change did not touch platform/, the compiler changed the ABI: review the diff, run scripts/check_glue.roc --update, and release.")
			}
			Err(_) => fail!("could not run git diff")
		}
	}
}

## Download a nightly's source archive, check it against the digest in the
## release metadata, and unpack `src/glue` into `work`.
fetch_source! : Str, Str => Try({}, [ScriptFailed])
fetch_source! = |tag, work| {
	asset = Glue.source_asset(tag)
	archive = "${work}/${asset}"
	say!("Glue source: roc-lang/nightlies ${tag} ${asset}")?
	digest = capture!("gh", ["api", "repos/roc-lang/nightlies/releases/tags/${tag}", "--jq", ".assets[] | select(.name == \"${asset}\") | .digest"])?
	expected = match Glue.sha256_of_digest(digest) {
		Ok(hex) => hex
		Err(NotSha256) => return fail!("release ${tag} records no SHA-256 digest for ${asset}")
	}
	succeed!("gh", ["release", "download", tag, "--repo", "roc-lang/nightlies", "--pattern", asset, "--dir", work])?
	actual = Glue.sha256_of_sum(capture!("sha256sum", [archive])?)
	if actual != expected {
		return fail!("${asset} has SHA-256 ${actual}, but the release records ${expected}")
	}
	succeed!("tar", ["-xzf", archive, "-C", work, "--strip-components=1", "${asset.drop_suffix(".tar.gz")}/src/glue"])
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

## Run a program with inherited output; a non-zero exit is an error.
succeed! : Str, List(Str) => Try({}, [ScriptFailed])
succeed! = |program, args|
	match Cmd.new_str(program).args_str(args).exec_exit_code!() {
		Ok(0) => Ok({})
		Ok(code) => fail!("${program} ${Str.join_with(args, " ")} exited with code ${code.to_str()}")
		Err(_) => fail!("could not run ${program}")
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
