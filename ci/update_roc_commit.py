#!/usr/bin/env python3
"""Update the Roc dependency in build.zig.zon to a new commit."""

import re
import subprocess
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {sys.argv[0]} <new_commit_sha>")

    new_commit = sys.argv[1]
    if not re.match(r"^[0-9a-fA-F]{40}$", new_commit):
        raise SystemExit(f"Invalid commit SHA: {new_commit}")

    zon_path = Path(__file__).resolve().parent.parent / "build.zig.zon"
    contents = zon_path.read_text()

    # Update the commit in the URL
    new_contents = re.sub(
        r"(git\+https://github\.com/roc-lang/roc#)[0-9a-fA-F]{40}",
        rf"\g<1>{new_commit}",
        contents,
    )

    if new_contents == contents:
        raise SystemExit("Could not find roc commit URL in build.zig.zon")

    # Write with updated commit (hash will be wrong initially)
    zon_path.write_text(new_contents)
    print(f"Updated commit to {new_commit}")

    # Run zig build to get the correct hash - it will fail but tell us the right hash
    print("Fetching new hash from zig...")
    result = subprocess.run(
        ["zig", "build", "--fetch"],
        capture_output=True,
        text=True,
        cwd=zon_path.parent,
    )

    # Look for the expected hash in stderr
    # Format: "expected: roc-0.0.0-XXXX"
    output = result.stdout + result.stderr
    match = re.search(r"expected:\s+(roc-[^\s,]+)", output)

    if match:
        new_hash = match.group(1)
        print(f"Found new hash: {new_hash}")

        # Update the hash
        contents = zon_path.read_text()
        new_contents = re.sub(
            r'\.hash = "roc-[^"]+",',
            f'.hash = "{new_hash}",',
            contents,
        )
        zon_path.write_text(new_contents)
        print("Updated hash in build.zig.zon")
    else:
        # If no hash mismatch, the existing hash might be correct (unlikely) or format changed
        print("Warning: Could not extract new hash from zig output")
        print("Output:", output)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
