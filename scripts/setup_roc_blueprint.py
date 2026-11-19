#!/usr/bin/env python3
"""Provision CI's resolved nightly through Blueprint's verified binary store."""

import argparse
import os
from pathlib import Path
import re
import subprocess

SYSTEMS = ["x86_64-linux", "aarch64-darwin", "x86_64-darwin", "x86_64-windows"]
ROOT = Path(__file__).resolve().parents[1]


def manifest(nightly: str, project: str) -> str:
    if not re.fullmatch(r"nightly-\d{4}-\d{2}-\d{2}-[0-9a-f]+", nightly):
        raise ValueError("expected the nightly tag resolved by this workflow")
    platform = re.search(r'platform "(https://github.com/lukewilliamboswell/roc-blueprint/releases/download/[^"\s]+)"', project)
    if not platform:
        raise ValueError("Blueprint.roc does not select a Blueprint platform release")
    # This isolated manifest leaves the repository's automation pin intact.
    # All jobs still fetch the one nightly the workflow resolved, through the
    # same verified Blueprint download store cached by setup-blueprint.
    systems = ", ".join(f'"{system}"' for system in SYSTEMS)
    return f'''app [config] {{ bp: platform "{platform[1]}" }}
import bp.Recipes
config = [
    Name("roc-ray-ci-compiler"),
    Systems([{systems}]),
    Environment("compiler", [Programs([Fetch("roc", Recipes.roc_nightly("{nightly}"))])]),
    Shell("default", [Use("compiler")]),
]
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nightly", required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--github-path", type=Path)
    parser.add_argument("--prepare", action="store_true")
    args = parser.parse_args()
    source = manifest(args.nightly, (ROOT / "Blueprint.roc").read_text())
    env = {**os.environ, "BLUEPRINT_ROOT": str(args.directory.resolve())}
    if args.prepare:
        args.directory.mkdir(parents=True, exist_ok=True)
        (args.directory / "Blueprint.roc").write_text(source, encoding="utf-8")
        subprocess.run(["blueprint", "update"], env=env, check=True)
        return
    if not args.github_path:
        parser.error("--github-path is required when activating the compiler")
    if (args.directory / "Blueprint.roc").read_text(encoding="utf-8") != source:
        raise ValueError("compiler manifest differs from the workflow's resolved nightly")
    paths = subprocess.check_output(["blueprint", "env", "default", "--github-path"], env=env)
    with args.github_path.open("ab") as output:
        output.write(paths)


if __name__ == "__main__":
    main()
