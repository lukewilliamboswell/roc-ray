#!/usr/bin/env python3
"""Read the Roc nightly pinned by the platform header and check a compiler against it.

The generated Zig ABI is checked by `scripts/check_glue.roc`.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PIN_FILE = ROOT / "platform" / "main.roc"
PIN_PATTERN = re.compile(
    r"nightly-[0-9]{4}-(?:[A-Za-z]+|[0-9]{2})-[0-9]{2}-(?P<commit>[0-9a-f]{7,40})"
)


class GlueError(RuntimeError):
    """A reproducibility or generation failure with a user-facing message."""


@dataclass(frozen=True)
class RocPin:
    nightly: str
    commit: str


def read_pin(path: Path = PIN_FILE) -> RocPin:
    try:
        source = path.read_text(encoding="utf-8")
    except OSError as error:
        raise GlueError(f"cannot read Roc pin {path}: {error}") from error

    # Ignore module docs, which may contain example app headers with their own pin.
    source = re.sub(r"(?m)^\s*#.*$", "", source)
    packages = re.search(r"\bpackages\s*\{([^}]*)\}", source)
    if packages is None:
        raise GlueError(f"{path} must declare a platform packages block")
    pins = re.findall(r'\broc\s*:\s*"([^"\n]+)"', packages.group(1))
    if len(pins) != 1:
        raise GlueError(f"{path} must declare exactly one roc compiler pin")
    nightly = pins[0]

    match = PIN_PATTERN.fullmatch(nightly)
    if match is None:
        raise GlueError(
            f"unsupported Roc pin {nightly!r}; expected a nightly tag ending in a commit hash"
        )

    return RocPin(nightly=nightly, commit=match.group("commit"))


def _display_command(args: list[str]) -> str:
    return " ".join(args)


def _run_checked(args: list[str], *, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    except OSError as error:
        raise GlueError(f"could not run {_display_command(args)}: {error}") from error

    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "no diagnostic output"
        raise GlueError(
            f"command failed ({result.returncode}): {_display_command(args)}\n{detail}"
        )
    return result


def resolve_program(program: str) -> Path:
    resolved = shutil.which(program)
    if resolved is None:
        raise GlueError(f"required executable not found: {program}")
    return Path(resolved).resolve()


def compiler_matches_pin(observed: str, pin: RocPin) -> bool:
    """Is `observed` (a `roc version` line) the compiler `pin` names?

    The published nightly reports the whole tag. A compiler built from the same
    revision reports its build mode and commit instead -- `release-fast-fb208ba`
    for `nightly-2026-08-23-fb208ba` -- which is the same compiler and should be
    allowed. Match on the commit, taking the shorter of the two hashes so either
    abbreviation is accepted.
    """
    if observed == f"Roc compiler version {pin.nightly}":
        return True
    for token in re.findall(r"[0-9a-f]{7,40}", observed):
        shared = min(len(token), len(pin.commit))
        if token[:shared] == pin.commit[:shared]:
            return True
    return False


def verify_compiler(program: str, pin: RocPin) -> Path:
    roc = resolve_program(program)
    result = _run_checked([str(roc), "version"])
    observed = result.stdout.strip()
    if not compiler_matches_pin(observed, pin):
        raise GlueError(
            "Roc compiler does not match platform/main.roc\n"
            f"  expected: Roc compiler version {pin.nightly} (or a build of {pin.commit})\n"
            f"  observed: {observed or '<empty output>'}\n"
            f"  binary:   {roc}"
        )
    return roc
