#!/usr/bin/env python3
"""Check the HTTP client against a server this script owns.

`test/http_fetch` GETs a URL on a task and exits 0 only when the response it
received in *Roc* is the one that was served: a 200 whose body contains the
expected text and whose headers survived the boundary. Everything is checked
inside the app, so a host that truncates a body, drops the status, or loses the
header list fails this test rather than passing it quietly.

Three runs, because the client's two limits are the parts most likely to be
wrong and most expensive to get wrong:

* a plain fetch, which must succeed;
* the same fetch under `max_response_bytes` smaller than the body, which must
  fail rather than hand the app a truncated body;
* a fetch of a deliberately slow route under a short `timeout_ms`, which must
  fail as a timeout rather than as some other transport error.

Each run also asserts on `ROC_RAY_TRACE_TASKS` output, so a pass means both the
host and the app saw the same thing.

Nothing here touches the public internet: the server is a `http.server` handler
bound to a free port on the loopback interface, started and stopped by this
script.
"""

from __future__ import annotations

import http.server
import os
import socket
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import local_bundles  # noqa: E402


ROOT = Path(__file__).resolve().parent.parent

# Distinctive enough that finding it in the output cannot be a coincidence.
SERVED_BODY = b"roc-ray-http-token-9f3a\nsecond line of the served file\n"

# Long enough that a 200 ms deadline cannot be met, short enough not to slow the
# suite down: the client gives up well before the handler replies.
SLOW_ROUTE_SECONDS = 3.0
SLOW_ROUTE_TIMEOUT_MS = 200

# The probe polls its task every frame; these are generous at the headless pace.
FRAMES = 600


class _Handler(http.server.BaseHTTPRequestHandler):
    """Serve one known file, and one route that answers too late."""

    def do_GET(self) -> None:  # noqa: N802 - name fixed by BaseHTTPRequestHandler
        if self.path == "/slow":
            time.sleep(SLOW_ROUTE_SECONDS)
        elif self.path != "/data.txt":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(SERVED_BODY)))
        self.end_headers()
        try:
            self.wfile.write(SERVED_BODY)
        except (BrokenPipeError, ConnectionResetError):
            # Expected on the timeout case: the client hung up while waiting.
            pass

    def log_message(self, *args) -> None:
        """Silence the default per-request logging to stderr."""


@contextmanager
def serve():
    """Run the handler on a free loopback port for the duration of the block."""
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host, port = server.server_address[0], server.server_address[1]
        yield f"http://{host}:{port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def _free_port_is_available() -> bool:
    """Whether a loopback listener can be opened at all."""
    try:
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
        return True
    except OSError:
        return False


def _run_case(
    executable: Path, name: str, args: list[str], expected_trace: str, verbose: bool
) -> str | None:
    """Run one probe invocation; return a failure description or None."""
    command = [
        str(executable),
        "--host-headless",
        f"--host-headless-frames={FRAMES}",
        *args,
    ]
    if verbose:
        print(f"  Running: {' '.join(command)}")
    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
        cwd=ROOT,
        env={**os.environ, "ROC_RAY_TRACE_TASKS": "1"},
        timeout=120,
    )
    output = result.stdout + result.stderr
    if result.returncode != 0:
        print(output, file=sys.stderr)
        return f"http client {name} (exit {result.returncode})"
    if expected_trace not in output:
        print(output, file=sys.stderr)
        return f"http client {name} (no {expected_trace!r} in the task trace)"
    return None


def run_http_client_test(
    packages: local_bundles.ServedPackages, verbose: bool = False
) -> list[str]:
    """Build `test/http_fetch` against the served platform and exercise it."""
    fixture = ROOT / "test" / "http_fetch" / "main.roc"
    if not fixture.is_file():
        return []

    if not _free_port_is_available():
        print("\nSkipping the HTTP client test: no loopback port available")
        return []

    print("\nRunning HTTP client localhost test...", end=" ", flush=True)
    staged = local_bundles.stage_app(fixture, packages, packages.scratch_dir / "http_fetch")
    build = subprocess.run(
        ["roc", "build", staged.name, *local_bundles.PACKAGE_LIMIT_ARGS],
        capture_output=not verbose,
        text=True,
        cwd=staged.parent,
    )
    if build.returncode != 0:
        print("FAILED")
        if not verbose:
            print((build.stdout or "") + (build.stderr or ""), file=sys.stderr)
        return ["build the HTTP client probe"]

    executable = staged.with_name(staged.stem + (".exe" if sys.platform == "win32" else ""))
    token = SERVED_BODY.split(b"\n")[0].decode()

    failures: list[str] = []
    with serve() as base_url:
        cases = (
            (
                "fetch",
                [
                    "--http-url",
                    f"{base_url}/data.txt",
                    "--http-expect",
                    token,
                ],
                # The host echoes the body it read; the probe's exit code says
                # the app received the same bytes.
                f"http body: {token}",
            ),
            (
                "response size cap",
                [
                    "--http-url",
                    f"{base_url}/data.txt",
                    "--http-max-bytes",
                    "8",
                    "--http-expect-error",
                    "larger than max_response_bytes",
                ],
                "http GET failed: ResponseTooLarge",
            ),
            (
                "timeout",
                [
                    "--http-url",
                    f"{base_url}/slow",
                    "--http-timeout-ms",
                    str(SLOW_ROUTE_TIMEOUT_MS),
                    "--http-expect-error",
                    "timed out",
                ],
                "http GET failed: Timeout",
            ),
        )
        for name, args, expected_trace in cases:
            failure = _run_case(executable, name, args, expected_trace, verbose)
            if failure is not None:
                failures.append(failure)

    print("ok" if not failures else "FAILED")
    return failures


def main() -> int:
    """Serve the packages this test needs and run it on its own."""
    try:
        with local_bundles.serve_packages(ROOT) as packages:
            failures = run_http_client_test(packages, verbose=True)
    except local_bundles.LocalBundleError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    for failure in failures:
        print(f"FAILED: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
