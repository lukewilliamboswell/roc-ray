#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.25.0/CZsY7tYZwR3rj9kYbpaCfxki2yVAaRL8bBwMLvB2xkbA.tar.zst",
}

import cli.OsStr
import cli.Path
import cli.Stderr
import cli.Stdout
import src/Hosts

## Reject release host libraries built with Zig's debug allocator. Run from the
## repository root after `zig build -Doptimize=ReleaseFast`: every target's
## host library must exist and contain none of the debug allocator's symbols.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |_args| {
	var $failures = 0
	for library in Hosts.libraries {
		match Path.read_bytes!(Path.unix(library)) {
			Err(_) => {
				_ = Stderr.line!("ERROR: missing release host: ${library}")
				$failures = $failures + 1
			}
			Ok(bytes) =>
				match Hosts.markers_in(bytes) {
					[] => {
						_ = Stdout.line!("Verified release host: ${library}")
					}
					markers => {
						_ = Stderr.line!("ERROR: ${library} contains debug allocator marker(s): ${Str.join_with(markers, ", ")}")
						$failures = $failures + 1
					}
				}
		}
	}
	if ($failures == 0) Ok({}) else Err(Exit(1))
}
