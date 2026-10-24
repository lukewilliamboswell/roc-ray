## Pure parts of `scripts/check_no_pins.roc`: which compiler a Roc file names,
## read from its text without running one.
##
## The platform, its examples and its tests name no compiler; they are checked
## with the latest nightly. Only the scripts under `scripts/` are written for
## one compiler, `roc-stable`, the nightly `Blueprint.roc` fetches.
Pins := [].{

	## The nightly tag that the text of `Blueprint.roc` fetches as `roc-stable`.
	stable_tag : Str -> Try(Str, [NoStableCompiler])
	stable_tag = |blueprint|
		match quoted_after(blueprint, "Fetch(\"roc-stable\", Recipes.roc_nightly(\"") {
			Ok(tag) => Ok(tag)
			Err(Missing) => Err(NoStableCompiler)
		}

	## The release named by the `roc` field of a file's header: the braces of
	## an `app` or `package` header, or the `packages` braces of a `platform`
	## header. A file with no such field, or with no header, names none.
	roc_pin : Str -> Try(Str, [NoPin, MalformedPin])
	roc_pin = |source|
		match header_fields(Str.split_on(source, "\n")).keep_if(|field| field.name == "roc") {
			[] => Err(NoPin)
			[field] =>
				match quoted(field.value) {
					Ok(tag) => Ok(tag)
					Err(NotQuoted) => Err(MalformedPin)
				}
			_ => Err(MalformedPin)
		}

	## Whether a repository path is one the floating-nightly model retires:
	## a `.roc-version` file anywhere, or the old pin updater's settings.
	is_retired_pin_file : Str -> Bool
	is_retired_pin_file = |path|
		path == ".roc-version" or path.ends_with("/.roc-version") or path == ".github/roc-nightly.json"

	## Whether a repository path is a script that `roc-stable` runs: a `.roc`
	## file directly inside `scripts/`. Modules under `scripts/src/` are not.
	is_script : Str -> Bool
	is_script = |path|
		if path.starts_with("scripts/") and path.ends_with(".roc") {
			!Str.drop_prefix(path, "scripts/").contains("/")
		} else {
			Bool.False
		}

	## Whether a repository path may carry a `roc` field at all.
	may_pin : Str -> Bool
	may_pin = |path| path.starts_with("scripts/")

	## Whether a script's first line runs it with `roc-stable`.
	has_stable_shebang : Str -> Bool
	has_stable_shebang = |source|
		match Str.split_first(source, "\n") {
			Ok({ before, .. }) => before.trim() == shebang
			Err(_) => source.trim() == shebang
		}
}

shebang : Str
shebang = "#!/usr/bin/env roc-stable"

Field : { name : Str, value : Str }

# The fields inside a header's braces, or none when the file has no header.
header_fields : List(Str) -> List(Field)
header_fields = |lines| {
	body = Str.join_with(lines.drop_if(is_comment), "\n")
	braces = match first_header_word(lines) {
		Ok("platform") =>
			match Str.split_first(body, "packages {") {
				Ok({ after, .. }) => up_to_brace(after)
				Err(_) => ""
			}
		Ok(_) =>
			match Str.split_first(body, "{") {
				Ok({ after, .. }) => up_to_brace(after)
				Err(_) => ""
			}
		Err(_) => ""
	}
	Str.split_on(braces, ",")
		.keep_oks(|field| Str.split_first(field, ":"))
		.map(|{ before, after }| { name: before.trim(), value: after.trim() })
}

# The keyword of the file's header, which is its first line that is neither
# blank nor a comment.
first_header_word : List(Str) -> Try(Str, [NoHeader])
first_header_word = |lines|
	match lines.drop_if(|line| is_comment(line) or line.trim() == "") {
		[line, ..] =>
			if line.starts_with("app ") or line.starts_with("app[") {
				Ok("app")
			} else if line.starts_with("package ") or line.starts_with("package[") {
				Ok("package")
			} else if line.starts_with("platform ") {
				Ok("platform")
			} else {
				Err(NoHeader)
			}
		[] => Err(NoHeader)
	}

is_comment : Str -> Bool
is_comment = |line| line.trim().starts_with("#")

up_to_brace : Str -> Str
up_to_brace = |text|
	match Str.split_first(text, "}") {
		Ok({ before, .. }) => before
		Err(_) => ""
	}

# The text after the only occurrence of `prefix`, up to the next double quote.
quoted_after : Str, Str -> Try(Str, [Missing])
quoted_after = |text, prefix|
	match Str.split_on(text, prefix) {
		[_, after] =>
			match Str.split_first(after, "\"") {
				Ok({ before, .. }) if before != "" => Ok(before)
				_ => Err(Missing)
			}
		_ => Err(Missing)
	}

# The text between a value's only pair of double quotes.
quoted : Str -> Try(Str, [NotQuoted])
quoted = |value|
	match Str.split_on(value.trim(), "\"") {
		["", text, ""] => Ok(text)
		_ => Err(NotQuoted)
	}

script : Str
script = "#!/usr/bin/env roc-stable\napp [main!] {\n\tcli: platform \"https://example.com/cli.tar.zst\",\n\troc: \"nightly-2026-10-23-18478ff\",\n}\n\nmain! = |_| { roc: \"not a header\" }\n"

example : Str
example = "app [Model, program] { rr: platform \"../../platform/main.roc\" }\n\nprogram = { roc: \"not a header\" }\n"

platform_header : Str
platform_header = "## The platform.\n## app [Model, program] { roc: \"nightly-2026-01-01-0000000\" }\nplatform \"\"\n\trequires {\n\t\t[Model : model] for program : App.Program(model)\n\t}\n\texposes [App]\n\tpackages {\n\t\thttp: \"https://example.com/http.tar.zst\",\n\t\troc: \"nightly-2026-10-23-18478ff\",\n\t}\n\tprovides { init!: \"init\" }\n"

expect Pins.stable_tag("\t\tPrograms([Fetch(\"roc-stable\", Recipes.roc_nightly(\"nightly-2026-10-23-18478ff\"))]),\n") == Ok("nightly-2026-10-23-18478ff")
expect Pins.stable_tag("# `roc-stable` is fetched below\n") == Err(NoStableCompiler)
expect Pins.stable_tag("Fetch(\"roc-stable\", Recipes.roc_nightly(\"\"))") == Err(NoStableCompiler)
expect Pins.roc_pin(script) == Ok("nightly-2026-10-23-18478ff")
expect Pins.roc_pin(example) == Err(NoPin)
expect Pins.roc_pin("app [Model, program] { roc: \"nightly-1\", rr: platform \"../../platform/main.roc\" }\n") == Ok("nightly-1")
expect Pins.roc_pin("app [main!] { heroc: \"nightly-1\" }\n") == Err(NoPin)
expect Pins.roc_pin("app [main!] { roc: \"a\", roc: \"b\" }\n") == Err(MalformedPin)
expect Pins.roc_pin("app [main!] { roc: nightly }\n") == Err(MalformedPin)
expect Pins.roc_pin(platform_header) == Ok("nightly-2026-10-23-18478ff")
expect Pins.roc_pin(Str.replace_each(platform_header, "\t\troc: \"nightly-2026-10-23-18478ff\",\n", "")) == Err(NoPin)
expect Pins.roc_pin("package [Pins] {\n\troc: \"nightly-1\",\n}\n") == Ok("nightly-1")
expect Pins.roc_pin("## A module.\nPins := [].{\n\tx = { roc: \"nightly-1\" }\n}\n") == Err(NoPin)
expect Pins.is_retired_pin_file(".roc-version") and Pins.is_retired_pin_file("examples/x/.roc-version")
expect Pins.is_retired_pin_file(".github/roc-nightly.json")
expect !Pins.is_retired_pin_file("docs/roc-version.adoc")
expect Pins.is_script("scripts/check_no_pins.roc")
expect !Pins.is_script("scripts/src/Pins.roc") and !Pins.is_script("platform/main.roc") and !Pins.is_script("scripts/all_tests.py")
expect Pins.may_pin("scripts/check_glue.roc") and !Pins.may_pin("test/asset_store_compile.roc")
expect Pins.has_stable_shebang(script)
expect !Pins.has_stable_shebang("#!/usr/bin/env roc\napp [main!] {}\n")
expect !Pins.has_stable_shebang(example)
