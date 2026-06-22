#!/usr/bin/env python3
"""Build examples against a downloaded platform bundle artifact."""

from __future__ import annotations

import argparse
import functools
import http.server
import os
import platform
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path


IS_WINDOWS = platform.system() == "Windows"
LOCAL_PLATFORM_REF = '"../platform/main-default.roc"'
RELEASE_PLATFORM_REF_RE = re.compile(
    r'"https://github\.com/lukewilliamboswell/roc-ray/releases/download/[^"]+\.tar\.zst"'
)


def rewrite_platform_ref(source: str, replacement: str) -> tuple[str, bool]:
    if LOCAL_PLATFORM_REF in source:
        return source.replace(LOCAL_PLATFORM_REF, replacement), True

    rewritten, count = RELEASE_PLATFORM_REF_RE.subn(replacement, source)
    return rewritten, count > 0


def serve_dir(directory: Path) -> tuple[http.server.ThreadingHTTPServer, int]:
    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):  # keep workflow logs focused
            pass

    handler = functools.partial(Handler, directory=str(directory))
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, port


def check_bundle_url(url: str) -> None:
    last_error: Exception | None = None
    request = urllib.request.Request(url, method="HEAD")
    for _ in range(10):
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                if response.status == 200:
                    return
                raise RuntimeError(f"Bundle URL returned HTTP {response.status}: {url}")
        except Exception as err:
            last_error = err
            time.sleep(0.5)

    raise RuntimeError(f"Bundle URL was not accessible: {url}") from last_error


def find_roc(root: Path) -> str | None:
    exe_name = "roc.exe" if IS_WINDOWS else "roc"
    path_roc = shutil.which("roc")
    if os.environ.get("ROC_SKIP_BUILD") == "1":
        return path_roc

    built_roc = root / "roc-src" / "zig-out" / "bin" / exe_name
    if built_roc.is_file():
        return str(built_roc)

    return path_roc


def build_example(roc: str, examples_dir: Path, example: Path) -> bool:
    print(f"Building: {example}", flush=True)
    result = subprocess.run(
        [roc, "build", example.name],
        cwd=examples_dir,
    )
    return result.returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle_file", help="Downloaded bundle artifact filename")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    bundle_path = root / args.bundle_file
    examples_dir = root / "examples"

    if not bundle_path.is_file():
        print(f"Missing bundle artifact: {bundle_path}", file=sys.stderr)
        return 1

    examples = sorted(examples_dir.glob("*.roc"))
    if not examples:
        print("No .roc examples found", file=sys.stderr)
        return 1

    roc = find_roc(root)
    if roc is None:
        expected = root / "roc-src" / "zig-out" / "bin" / ("roc.exe" if IS_WINDOWS else "roc")
        print(f"Could not find Roc executable at {expected} or on PATH", file=sys.stderr)
        return 1
    print(f"Using Roc executable: {roc}")

    httpd, port = serve_dir(root)
    bundle_url = f"http://127.0.0.1:{port}/{bundle_path.name}"
    print(f"Bundle URL: {bundle_url}")
    check_bundle_url(bundle_url)

    originals: dict[Path, str] = {}
    failures: list[str] = []
    try:
        for example in examples:
            original = example.read_text()
            originals[example] = original

            rewritten, did_rewrite = rewrite_platform_ref(original, f'"{bundle_url}"')
            if not did_rewrite:
                print(f"Skipping rewrite for {example}: no platform reference")
                continue

            example.write_text(rewritten)

        for example in examples:
            if not build_example(roc, examples_dir, example):
                failures.append(example.name)
    finally:
        for example, original in originals.items():
            example.write_text(original)
        httpd.shutdown()

    if failures:
        print("Bundle test failed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("Bundle test passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
