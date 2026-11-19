"""Documented exceptions to ordinary cached Roc compilation."""

from functools import lru_cache
from pathlib import Path
import subprocess

# These are confined to the compiler on which they were reproduced. The
# commands still compile/check/test the complete source; none skips coverage.
# PR #285 records the local reproductions and failed cross-platform CI runs.
CACHE_EXCEPTIONS = {
    ("test", "Devices"): "cached imported receiver methods stall the value tests",
    ("test", "roc-doom-e1m1"): "cached test compilation segfaults",
    ("check", "top_down"): "loading checked imports segfaults in the compiler",
}
AFFECTED_NIGHTLY = "nightly-2026-11-18-a520eed"


@lru_cache(maxsize=4)
def compiler_version(roc: str) -> str:
    return subprocess.check_output([roc, "version"], text=True, timeout=30).strip()


def compiler_args(roc: str, command: str, source: Path) -> list[str]:
    """Scope compiler-defect workarounds to the affected command and nightly."""
    source = Path(source)
    name = source.parent.name if source.name == "main.roc" else source.stem
    if (command, name) not in CACHE_EXCEPTIONS and not (command in ("build", "test") and name == "top_down"):
        return []
    if compiler_version(roc) != f"Roc compiler version {AFFECTED_NIGHTLY}":
        return []
    # The unspecialized dev lowering crashes intermittently on Linux/macOS/Windows,
    # including fresh builds. Specialization avoids that path and retains the
    # dev backend and its cache; repeated Intel builds reproduce the difference.
    if command in ("build", "test") and name == "top_down":
        return ["--specialize=yes"]
    return ["--no-cache"]
