#!/usr/bin/env python3
"""Extract the pinned Roc compiler commit hash from ci/ROC_COMMIT."""

import re
from pathlib import Path


def main() -> None:
    commit_path = Path(__file__).resolve().parent / "ROC_COMMIT"
    try:
        commit = commit_path.read_text().strip()
    except FileNotFoundError:
        raise SystemExit(f"Missing ROC_COMMIT at {commit_path}")

    if not re.fullmatch(r"[0-9a-fA-F]{40}", commit):
        raise SystemExit(f"Invalid commit hash in ROC_COMMIT: {commit!r}")

    print(commit)


if __name__ == "__main__":
    main()
