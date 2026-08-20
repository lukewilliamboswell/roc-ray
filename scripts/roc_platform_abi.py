#!/usr/bin/env python3
"""Reproduce roc-ray's generated Zig ABI from its pinned Roc nightly."""

from __future__ import annotations

import argparse
import difflib
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PIN_FILE = ROOT / ".roc-version"
PLATFORM_FILE = ROOT / "platform" / "main.roc"
ABI_FILE = ROOT / "src" / "roc_platform_abi.zig"
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
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise GlueError(f"cannot read Roc pin {path}: {error}") from error

    if len(lines) != 1 or not lines[0]:
        raise GlueError(f"{path} must contain exactly one non-empty nightly tag")

    match = PIN_PATTERN.fullmatch(lines[0])
    if match is None:
        raise GlueError(
            f"unsupported Roc pin {lines[0]!r}; expected a nightly tag ending in a commit hash"
        )

    return RocPin(nightly=lines[0], commit=match.group("commit"))


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
    revision reports its build mode and commit instead -- `release-fast-edec8304`
    for `nightly-2026-08-19-edec830` -- which is the same compiler and should be
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
            "Roc compiler does not match .roc-version\n"
            f"  expected: Roc compiler version {pin.nightly} (or a build of {pin.commit})\n"
            f"  observed: {observed or '<empty output>'}\n"
            f"  binary:   {roc}"
        )
    return roc


def resolve_roc_repo(path: Path) -> Path:
    result = _run_checked(["git", "-C", str(path), "rev-parse", "--show-toplevel"])
    return Path(result.stdout.strip()).resolve()


def _git_try(repo: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            ["git", "-C", str(repo), *args], capture_output=True, text=True
        )
    except OSError as error:
        raise GlueError(f"could not run git: {error}") from error


def resolve_pinned_commit(repo: Path, pin: RocPin) -> str:
    commit_result = _git_try(
        repo, ["rev-parse", "--verify", f"{pin.commit}^{{commit}}"]
    )
    if commit_result.returncode != 0:
        raise GlueError(
            f"Roc repository {repo} does not contain pinned commit {pin.commit}; "
            "fetch that commit before regenerating glue"
        )

    commit = commit_result.stdout.strip()
    if not commit.startswith(pin.commit):
        raise GlueError(
            f"Roc source resolved to {commit}, which does not match pinned hash {pin.commit}"
        )

    tag_result = _git_try(
        repo,
        ["rev-parse", "--verify", "--quiet", f"refs/tags/{pin.nightly}^{{commit}}"],
    )
    if tag_result.returncode == 0 and tag_result.stdout.strip() != commit:
        raise GlueError(
            f"Roc tag {pin.nightly} resolves to {tag_result.stdout.strip()}, "
            f"but its embedded hash resolves to {commit}"
        )

    glue_result = _git_try(
        repo, ["cat-file", "-e", f"{commit}:src/glue/src/ZigGlue.roc"]
    )
    if glue_result.returncode != 0:
        raise GlueError(f"pinned Roc commit {commit} has no src/glue/src/ZigGlue.roc")

    return commit


def extract_glue(repo: Path, commit: str, destination: Path) -> Path:
    archive_path = destination / "roc-glue.tar"
    _run_checked(
        [
            "git",
            "-C",
            str(repo),
            "archive",
            "--format=tar",
            f"--output={archive_path}",
            commit,
            "src/glue",
        ]
    )

    destination_resolved = destination.resolve()
    with tarfile.open(archive_path, mode="r:") as archive:
        extracted_entries: list[tuple[tarfile.TarInfo, Path]] = []
        for member in archive.getmembers():
            if member.name not in {"src", "src/glue"} and not member.name.startswith(
                "src/glue/"
            ):
                raise GlueError(f"unexpected path in Roc glue archive: {member.name}")
            if not (member.isfile() or member.isdir()):
                raise GlueError(f"unsupported entry in Roc glue archive: {member.name}")
            target = (destination / member.name).resolve()
            try:
                target.relative_to(destination_resolved)
            except ValueError as error:
                raise GlueError(f"unsafe path in Roc glue archive: {member.name}") from error
            extracted_entries.append((member, target))

        for member, target in extracted_entries:
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise GlueError(f"could not read Roc glue archive entry: {member.name}")
            with source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            target.chmod(member.mode & 0o777)

    archive_path.unlink()
    glue = destination / "src" / "glue" / "src" / "ZigGlue.roc"
    if not glue.is_file():
        raise GlueError(f"Roc glue extraction did not produce {glue}")
    return glue


def generate_abi(roc: Path, zig: Path, glue: Path, temporary: Path) -> Path:
    output = temporary / "generated"
    output.mkdir()
    _run_checked(
        [str(roc), "glue", str(glue), str(output), str(PLATFORM_FILE)], cwd=ROOT
    )

    generated = output / ABI_FILE.name
    if not generated.is_file():
        raise GlueError(f"roc glue did not generate {generated}")
    _run_checked([str(zig), "fmt", str(generated)], cwd=ROOT)
    return generated


def _display_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def _unified_diff(checked_in: Path, generated: Path) -> str:
    old = checked_in.read_text(encoding="utf-8").splitlines(keepends=True)
    new = generated.read_text(encoding="utf-8").splitlines(keepends=True)
    return "".join(
        difflib.unified_diff(
            old,
            new,
            fromfile=_display_path(checked_in),
            tofile=f"generated/{generated.name}",
        )
    )


def install_or_check(generated: Path, checked_in: Path, *, check: bool) -> bool:
    if checked_in.is_file() and checked_in.read_bytes() == generated.read_bytes():
        return False

    if check:
        if checked_in.is_file():
            print(_unified_diff(checked_in, generated), file=sys.stderr, end="")
        raise GlueError(
            f"{_display_path(checked_in)} is not reproducible from the pinned Roc source; "
            "run this command with --update"
        )

    checked_in.parent.mkdir(parents=True, exist_ok=True)
    mode = checked_in.stat().st_mode & 0o777 if checked_in.exists() else 0o644
    file_descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{checked_in.name}.", dir=checked_in.parent
    )
    try:
        with os.fdopen(file_descriptor, "wb") as output:
            output.write(generated.read_bytes())
        os.chmod(temporary_name, mode)
        os.replace(temporary_name, checked_in)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)
    return True


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Regenerate roc-ray's Zig ABI from the compiler and Roc source pinned by .roc-version."
    )
    parser.add_argument(
        "--roc-repo",
        required=True,
        type=Path,
        help="local Roc git repository containing the pinned commit",
    )
    parser.add_argument(
        "--roc", default="roc", help="Roc compiler binary to validate and run"
    )
    parser.add_argument("--zig", default="zig", help="Zig binary used to format output")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--check", action="store_true", help="compare without modifying the checked-in ABI"
    )
    mode.add_argument(
        "--update", action="store_true", help="atomically update the checked-in ABI"
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        pin = read_pin()
        roc = verify_compiler(args.roc, pin)
        zig = resolve_program(args.zig)
        repo = resolve_roc_repo(args.roc_repo)
        commit = resolve_pinned_commit(repo, pin)

        print(f"Verified compiler: {roc} ({pin.nightly})")
        print(f"Using immutable Roc glue source: {repo} @ {commit}")

        # Roc's glue command currently misreports specs under a path component
        # containing '-' as missing, so keep this generated path identifier-safe.
        with tempfile.TemporaryDirectory(prefix="rocray_glue_") as temporary_name:
            temporary = Path(temporary_name)
            glue = extract_glue(repo, commit, temporary)
            generated = generate_abi(roc, zig, glue, temporary)
            changed = install_or_check(generated, ABI_FILE, check=args.check)

        if args.check:
            print(f"Verified generated ABI: {ABI_FILE.relative_to(ROOT)}")
        elif changed:
            print(f"Updated generated ABI: {ABI_FILE.relative_to(ROOT)}")
        else:
            print(f"Generated ABI already up to date: {ABI_FILE.relative_to(ROOT)}")
        return 0
    except GlueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
