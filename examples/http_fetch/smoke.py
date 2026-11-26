"""Run the HTTP example against a fixture owned by this invocation."""

import http.server
import signal
import subprocess
import sys
import threading


BODY = b"RocRay HTTP smoke response"
TIMEOUT_SECONDS = 7
RESPONSE_VERIFIED_EXIT = 42  # Sent by update! when it processes the expected response.


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/fixture":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, _format, *args):
        # The case compares the application's stderr exactly.
        pass


def main(executable, args):
    try:
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
            url = f"http://127.0.0.1:{server.server_port}/fixture"
            worker = threading.Thread(target=server.serve_forever, args=(0.05,))
            worker.start()
            try:
                result = subprocess.run(
                    [executable, *args, "--smoke", "--url", url],
                    timeout=TIMEOUT_SECONDS,
                )
            finally:
                server.shutdown()
                worker.join()
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"http_fetch fixture failed: {error}", file=sys.stderr)
        return 1

    if result.returncode == RESPONSE_VERIFIED_EXIT:
        return 0
    print(
        f"http_fetch exited with status {result.returncode} before confirming the fixture response",
        file=sys.stderr,
    )
    return 1


def terminate(signum, _frame):
    # Unwind subprocess.run so it reaps the child before the fixture closes.
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, terminate)
    sys.exit(main(sys.argv[1], sys.argv[2:]))
