#!/usr/bin/env python3
"""mini-deploy: forwards After Sleep's Cheaper Inference calls (option A, the Netlify way).

    ci_forwarder.py serve            run on 127.0.0.1:9200 (the systemd service mini-deploy-ci)
    ci_forwarder.py set-upstream     read the upstream address from stdin and save it
    ci_forwarder.py show             print the saved address (kept off git: it lives on this PC only)

The phone sends its own Cheaper Inference key with each request. This forwarder passes that
key on and stores nothing, so it cannot spend anyone's money by itself. Only the three
inference paths the app uses are passed on; everything else is 404.

The upstream address is read from /etc/mini-deploy/ci.json (root only, 600), never from the
request and never from git. Standard library only.
"""

import argparse
import http.client
import json
import os
import re
import stat
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

LISTEN = ("127.0.0.1", 9200)
CONFIG = Path("/etc/mini-deploy/ci.json")
# Tests point the config at a temp file. The override needs a second switch, like appenv.py.
if os.environ.get("MINI_DEPLOY_CI_CONFIG") and os.environ.get("MINI_DEPLOY_TESTING") == "1":
    CONFIG = Path(os.environ["MINI_DEPLOY_CI_CONFIG"])

# The same allowlist as Netlify's function (netlify/edge-functions/ci.js), after /api/ci is removed.
PATH_RE = re.compile(r"^/v1/(chat/completions|messages|models)$")
# Only these request headers travel upstream. Caddy's X-Forwarded-For, Host and cookies never do.
IN_HEADERS = ("authorization", "content-type", "x-api-key", "anthropic-version",
              "x-ci-prompt-cache", "x-ci-prompt-cache-session")
OUT_HEADERS = ("content-type", "x-ci-request-id", "x-ci-saved-usd", "retry-after")
MAX_BODY = 1024 * 1024    # a chat request is a few KB; anything bigger is refused
DRAIN_LIMIT = 16 * 1024 * 1024   # a refused body is read and dropped up to this size, so the 413 arrives
CONNECT_TIMEOUT = 5       # seconds to reach the service at all
TIMEOUT = 300             # seconds; a long answer can take a while
CHUNK = 64 * 1024
READ_TIMEOUT = 30         # seconds per read or write on the phone's connection (a slow sender gives up)
MAX_HANDLERS = 16         # connections handled at once; more get a 503 at once


class ConfigError(Exception):
    pass


def _check_private(st):
    """Owner only, and not readable by others (the same rule as the app-value store)."""
    if st.st_uid != os.getuid():
        raise ConfigError("the config is not owned by this user; not used")
    if st.st_mode & 0o077:
        raise ConfigError(f"the config can be read by others (mode {stat.S_IMODE(st.st_mode):o})")


def valid_upstream(url):
    """https only (http only in tests), a host, and nothing else: no path, query or login."""
    parts = urllib.parse.urlsplit(url)
    allowed = ("https", "http") if os.environ.get("MINI_DEPLOY_TESTING") == "1" else ("https",)
    if parts.scheme not in allowed or not parts.hostname:
        raise ConfigError("the upstream must be an https address")
    if parts.path not in ("", "/") or parts.query or parts.fragment or parts.username or parts.password:
        raise ConfigError("the upstream must be just the address (no path, query or login)")
    return url.rstrip("/")


def load_upstream():
    """The saved upstream address. Raises ConfigError if missing or unsafe (the forwarder then
    answers 503, so nothing is ever sent to a guessed address)."""
    try:
        fd = os.open(CONFIG, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except FileNotFoundError:
        raise ConfigError("not configured yet (run: ci_forwarder.py set-upstream)")
    except OSError as e:
        raise ConfigError(f"cannot open the config ({e.strerror})")
    with os.fdopen(fd, "rb") as fh:
        st = os.fstat(fh.fileno())
        if not stat.S_ISREG(st.st_mode):
            raise ConfigError("the config is not a regular file")
        _check_private(st)
        raw = fh.read(64 * 1024)
    try:
        data = json.loads(raw.decode("utf-8"))
    except (ValueError, RecursionError):
        raise ConfigError("the config is not valid JSON")
    if not isinstance(data, dict) or not isinstance(data.get("upstream"), str):
        raise ConfigError("the config has no upstream address")
    return valid_upstream(data["upstream"])


def save_upstream(url):
    """Write the config atomically, owner-only, from a validated address."""
    url = valid_upstream(url)
    CONFIG.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = CONFIG.with_name(CONFIG.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump({"upstream": url}, fh)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, CONFIG)


class Handler(BaseHTTPRequestHandler):
    server_version = "mini-deploy-ci"
    sys_version = ""
    # Without this a connection that sends nothing (or one byte a minute) holds its thread forever.
    # Only the phone's side: the answer from the service has its own TIMEOUT.
    timeout = READ_TIMEOUT

    def log_message(self, fmt, *args):
        # One line per request: method, path and status. Never headers or bodies (they hold the key).
        # A connection that timed out before sending a request line has no command or path yet.
        command, path = getattr(self, "command", None), getattr(self, "path", None)
        if not command or path is None:
            print("connection closed before a request arrived", flush=True)
            return
        print(f"{command} {urllib.parse.urlsplit(path).path} {args[1] if len(args) > 1 else ''}",
              flush=True)

    def do_GET(self):
        self._forward("GET")

    def do_POST(self):
        self._forward("POST")

    def do_PUT(self):
        self._reply(405, b"method not allowed")

    do_DELETE = do_PATCH = do_PUT

    def _reply(self, status, text):
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(text)))
        self.end_headers()
        self.wfile.write(text)

    def _forward(self, method):
        parts = urllib.parse.urlsplit(self.path)
        sub = parts.path[len("/api/ci"):] if parts.path.startswith("/api/ci") else parts.path
        if not PATH_RE.fullmatch(sub):
            return self._reply(404, b"not found")

        try:
            upstream = load_upstream()
        except ConfigError as e:
            return self._reply(503, f"cheaper inference: {e}".encode("utf-8"))

        body = None
        if method == "POST":
            if self.headers.get("Transfer-Encoding"):
                return self._reply(411, b"send a Content-Length")
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                return self._reply(400, b"bad Content-Length")
            if length > MAX_BODY:
                # Read the body and throw it away first: replying while the phone is still
                # sending would drop the connection, and the phone would never see the 413.
                left = min(length, DRAIN_LIMIT)
                while left > 0:
                    got = self.rfile.read(min(CHUNK, left))
                    if not got:
                        break
                    left -= len(got)
                return self._reply(413, b"request too large")
            body = self.rfile.read(length)

        headers = {k: self.headers[k] for k in IN_HEADERS if self.headers.get(k)}
        target = urllib.parse.urlsplit(upstream)
        conn_class = http.client.HTTPSConnection if target.scheme == "https" else http.client.HTTPConnection
        # Two timeouts: connecting must fail fast (an unreachable service should not hold the
        # phone for minutes); the answer itself may take a long time.
        conn = conn_class(target.hostname, target.port, timeout=CONNECT_TIMEOUT)
        try:
            conn.connect()
        except OSError:  # refused, unreachable or too slow to connect: the service is down
            conn.close()
            return self._reply(502, b"could not reach the service")
        try:
            conn.sock.settimeout(TIMEOUT)
            conn.request(method, sub + (f"?{parts.query}" if parts.query else ""), body=body, headers=headers)
            resp = conn.getresponse()
        except TimeoutError:
            conn.close()
            return self._reply(504, b"the service did not answer in time")
        except OSError:
            conn.close()
            return self._reply(502, b"could not reach the service")

        self.send_response(resp.status, resp.reason)
        for k in OUT_HEADERS:
            v = resp.getheader(k)
            if v:
                self.send_header(k, v)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()  # no Content-Length: the answer is streamed and ends when the connection closes
        try:
            while True:
                chunk = resp.read1(CHUNK)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (OSError, TimeoutError):
            pass  # the phone went away mid-answer; nothing more to send
        finally:
            conn.close()


class Server(ThreadingHTTPServer):
    """At most MAX_HANDLERS connections at once: a device on the Wi-Fi or the tailnet that
    opens many connections gets 503s, and the threads it can hold stay bounded."""
    daemon_threads = True
    max_handlers = MAX_HANDLERS

    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(self.max_handlers)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                request.sendall(b"HTTP/1.0 503 Service Unavailable\r\nContent-Length: 0\r\n"
                                b"Connection: close\r\n\r\n")
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:   # no thread was started (so it never releases the slot): give it back
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):  # one quiet line, not a traceback
        print(f"connection error: {sys.exc_info()[0].__name__}", file=sys.stderr, flush=True)


def serve(listen=LISTEN):
    httpd = Server(listen, Handler)
    print(f"listening on {listen[0]}:{listen[1]}", flush=True)
    httpd.serve_forever()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("serve")
    sub.add_parser("set-upstream")
    sub.add_parser("show")
    args = parser.parse_args()
    try:
        if args.cmd == "serve":
            serve()
        elif args.cmd == "set-upstream":
            url = sys.stdin.readline().strip()  # from stdin, never argv: keeps it out of ps and history
            save_upstream(url)
            print("saved (not shown)")
        else:
            print(load_upstream())
    except ConfigError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
