"""Documented exceptions to ordinary cached Roc compilation."""

from functools import lru_cache
from pathlib import Path
import platform
import subprocess

# These are confined to the compiler on which they were reproduced. The
# commands still compile/check/test the complete source; none skips coverage.
# PR #285 records the local reproductions and failed cross-platform CI runs.
CACHE_EXCEPTIONS = {
    ("test", "Devices"): "cached imported receiver methods stall the value tests",
    ("test", "roc-doom-e1m1"): "cached test compilation segfaults",
    ("check", "top_down"): "loading checked imports segfaults in the compiler",
}
# These cached test graphs fail with OutOfMemory in CI on the named hosts.
# Restrict the exception to their source, command, OS, and compiler version.
INTEL_MAC_TESTS = {"pong", "snake", "sqlite_scores"}
WINDOWS_TUTORIAL_TESTS = {"primer", "smallest", *(f"step{i}" for i in range(1, 7))}
AFFECTED_NIGHTLY = "nightly-2026-11-18-a520eed"


@lru_cache(maxsize=4)
def compiler_version(roc: str) -> str:
    return subprocess.check_output([roc, "version"], text=True, timeout=30).strip()


def compiler_args(roc: str, command: str, source: Path) -> list[str]:
    """Scope compiler-defect workarounds to the affected command and nightly."""
    source = Path(source)
    name = source.parent.name if source.name == "main.roc" else source.stem
    cached_test_oom = command == "test" and (
        (platform.system() == "Darwin" and platform.machine() == "x86_64" and name in INTEL_MAC_TESTS)
        or (platform.system() == "Windows" and source.parent.name == "tutorial" and name in WINDOWS_TUTORIAL_TESTS)
    )
    if not cached_test_oom and (command, name) not in CACHE_EXCEPTIONS and not (command in ("build", "test") and name == "top_down"):
        return []
    version = compiler_version(roc)
    # The warm-cache top_down check also crashes on the November 23 nightly.
    if (command, name) == ("check", "top_down") and version == "Roc compiler version nightly-2026-11-23-b5c77fc":
        return ["--no-cache"]
    if version != f"Roc compiler version {AFFECTED_NIGHTLY}":
        return []
    # The unspecialized dev lowering crashes intermittently on Linux/macOS/Windows,
    # including fresh builds. Specialization avoids that path and retains the
    # dev backend and its cache; repeated Intel builds reproduce the difference.
    if command in ("build", "test") and name == "top_down":
        return ["--specialize=yes"]
    return ["--no-cache"]
