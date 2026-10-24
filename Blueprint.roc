# Development environment and tasks for RocRay, realised by roc-blueprint.
#
#     blueprint run check        # pins, the scripts and the lints: what runs once, on one machine
#     blueprint run pins         # no compiler pin outside scripts/
#     blueprint run glue         # compare the committed host ABI with what `roc` generates
#     blueprint run glue-update  # regenerate the committed host ABI
#     blueprint run test         # build every host, then check, test, build and run every example
#     blueprint run docs         # render the manual (HTML, PDF, Markdown) into .docs-out/
#     blueprint shell            # the development environment
#     blueprint update           # refresh Blueprint.lock
#
# Two compilers are in play and are not interchangeable. `roc-stable` is the
# nightly named below; it runs the scripts under scripts/. Bare `roc` is the
# latest nightly, which the machine provides: the platform, its examples and
# its tests name no compiler.
app [config] { pf: platform "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.8.0/FbJymjYdCxx9vqMcau7r4tQfeAbnVGqqJoYrLGqPCqKu.tar.zst" }

import pf.Recipes

config = [
	Name("roc-ray"),
	Systems(["x86_64-linux", "aarch64-darwin"]),
	Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))),
	Environment(
		"scripts",
		[
			Programs([Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-10-23-18478ff"))]),
			# Every bundle the scripts depend on, including dependencies of
			# dependencies: `roc-stable deps scripts/check_glue.roc` lists them.
			RocPackages([
				"https://github.com/roc-lang/basic-cli/releases/download/0.25.0/CZsY7tYZwR3rj9kYbpaCfxki2yVAaRL8bBwMLvB2xkbA.tar.zst",
			]),
			Expect(["roc", "git", "gh"]),
		],
	),
	Environment(
		"dev",
		[
			Extend("scripts"),
			# The exact Zig release that builds the host and its linker inputs;
			# build.zig.zon names the same version.
			Tools(["nix#zig_0_17", "nix#python3", "nix#zstd", "nix#curl", "nix#binutils"]),
		],
	),
	# The shared documentation renderer from roc-automation. Blueprint.lock
	# records each system's digest, and the bytes are checked before every use.
	Environment(
		"docs",
		[
			Programs([Fetch("roc-docs", Recipes.file("https://github.com/lukewilliamboswell/roc-automation/releases/download/tools-0.4.0/roc-docs-{system}"))]),
			Expect(["sh", "realpath"]),
		],
	),
	Shell("default", [Use("dev")]),
	# The pin check, the scripts' tests, checks and formatting, and `zig build lint`.
	Task("check", [Use("dev"), Run(["scripts/check_all.roc"])]),
	Task("pins", [Use("scripts"), Run(["scripts/check_no_pins.roc"])]),
	Task("glue", [Use("dev"), Run(["scripts/check_glue.roc"])]),
	Task("glue-update", [Use("dev"), Run(["scripts/check_glue.roc", "--update"])]),
	Task("test", [Use("dev"), Run(["zig", "build", "test"])]),
	# The manual, as the docs workflow builds it, for previewing locally.
	Task("docs", [Use("docs"), Run(["roc-docs", "build", "--workspace", ".", "--pdf-filename", "roc-ray.pdf", "--site-url", "https://lukewilliamboswell.github.io/roc-ray/"])]),
	# The verified renderer's path, which CI hands to actions/build-docs.
	Task("docs-renderer", [Use("docs"), Run(["sh", "-c", "realpath \"$(command -v roc-docs)\""])]),
	# The tooling compiler, as release notes record it.
	Task("compiler-version", [Use("scripts"), Run(["roc-stable", "version"])]),
]
