"""Stands in for Healthchecks.io.

Records the path of every request it receives to a file the test suite reads.
The tests assert on what arrived here — and, more importantly, on what did
not.
"""

import http.server

LOG_PATH = "/requests/log"


class Handler(http.server.BaseHTTPRequestHandler):
    def _record(self):
        with open(LOG_PATH, "a") as f:
            f.write(self.path + "\n")
            f.flush()
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"OK")

    do_GET = _record
    do_POST = _record

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    open(LOG_PATH, "a").close()
    http.server.ThreadingHTTPServer(("", 8080), Handler).serve_forever()
