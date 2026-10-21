#!/usr/bin/env python3
"""mini-deploy: forwards After Sleep's Cheaper Inference calls (option A, the Netlify way).

    ci_forwarder.py serve            run on 127.0.0.1:9200 (the systemd service mini-deploy-ci)
    ci_forwarder.py set-upstream     read the upstream address from stdin and save it
    ci_forwarder.py show             print the saved address (kept off git: it lives on this PC only)
    ci_forwarder.py set-limits       read the per-app limits (JSON) from stdin, check and save them
    ci_forwarder.py usage            requests per app today, against each app's daily limit

The phone sends its own Cheaper Inference key with each request. This forwarder passes that
key on and never stores it. Only the three inference paths the app uses are passed on;
everything else is 404.

Brakes ("A+", 2026-10-21): Caddy names the calling app in X-MD-App (it overwrites anything the
phone sends). Each app needs an entry in /etc/mini-deploy/ci-limits.json (no entry = refused):
which models, the largest max_tokens, how many at once, per minute and per day (days start at
00:00 JST). The body is only READ to check model and max_tokens; it goes on unchanged or not at
all. Requests per app per day are counted in /var/lib/mini-deploy-ci/usage.json (never the key,
the prompt or the answer). A request without max_tokens is allowed (YoomiRead sends none yet).
A request with a duplicate key, a checked field in other letter case, n other than 1, or a thinking
budget over max_tokens is refused (the check and the provider must read the same request). A call
that never really used the provider (unreachable, timed out, the key refused) is given back to the
day. When the phone hangs up, the provider's connection is cut, so the at-once slot comes back.

The upstream address is read from /etc/mini-deploy/ci.json (root only, 600), never from the
request and never from git. Standard library only.
"""

import argparse
import collections
import contextlib
import http.client
import json
import os
import re
import select
import signal
import socket
import stat
import sys
import threading
import time
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
LENGTH_RE = re.compile(r"^[0-9]{1,9}$")
WATCH_EVERY = 0.5         # seconds between checks that the phone is still there

LIMITS = Path("/etc/mini-deploy/ci-limits.json")
USAGE = Path("/var/lib/mini-deploy-ci/usage.json")   # the unit's StateDirectory: its only writable place
if os.environ.get("MINI_DEPLOY_TESTING") == "1":
    LIMITS = Path(os.environ.get("MINI_DEPLOY_CI_LIMITS", LIMITS))
    USAGE = Path(os.environ.get("MINI_DEPLOY_CI_USAGE", USAGE))
APP_RE = re.compile(r"^[a-z0-9-]{1,40}$")   # deploy.py's rule: the header is checked like any input
LIMIT_KEYS = {"models", "max_tokens", "at_once", "per_minute", "per_day"}
TOKEN_FIELDS = ("max_tokens", "max_completion_tokens")   # Anthropic and OpenAI names for the same thing
DAY_OFFSET = 9 * 3600     # days start at 00:00 JST (UTC+9, no summer time)
KEEP_DAYS = 60


class ConfigError(Exception):
    pass


def _check_private(st):
    """Owner only, and not readable by others (the same rule as the app-value store)."""
    if st.st_uid != os.getuid():
        raise ConfigError("the config is not owned by this user; not used")
    if st.st_mode & 0o077:
        raise ConfigError(f"the config can be read by others (mode {stat.S_IMODE(st.st_mode):o})")


def _read_private_json(path, missing):
    """A small JSON file only its owner can read: opened without following links or blocking on a
    FIFO, checked, parsed. ConfigError (with `missing` when it does not exist) on any problem."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except FileNotFoundError:
        raise ConfigError(missing)
    except OSError as e:
        raise ConfigError(f"cannot open {path.name} ({e.strerror})")
    with os.fdopen(fd, "rb") as fh:
        st = os.fstat(fh.fileno())
        if not stat.S_ISREG(st.st_mode):
            raise ConfigError(f"{path.name} is not a regular file")
        _check_private(st)
        raw = fh.read(64 * 1024 + 1)
    if len(raw) > 64 * 1024:
        raise ConfigError(f"{path.name} is larger than 64 KB")
    try:
        return json.loads(raw.decode("utf-8"))
    except (ValueError, RecursionError):
        raise ConfigError(f"{path.name} is not valid JSON")


def _write_private_json(path, data):
    """Atomically, owner-only, never through a link."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1, sort_keys=True)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def valid_limits(data):
    """{app: {"models": [..] or null, "max_tokens", "at_once", "per_minute", "per_day"}}.
    Every field is required (a missing number must never mean "no limit")."""
    if not isinstance(data, dict) or not data:
        raise ConfigError("the limits must name at least one app")
    out = {}
    for app, lim in data.items():
        if not isinstance(app, str) or not APP_RE.fullmatch(app):
            raise ConfigError(f"bad app name in the limits: {str(app)[:40]!r}")
        if not isinstance(lim, dict) or set(lim) != LIMIT_KEYS:
            raise ConfigError(f"{app}: the limits need exactly {sorted(LIMIT_KEYS)}")
        for key in ("max_tokens", "at_once", "per_minute", "per_day"):
            v = lim[key]
            if isinstance(v, bool) or not isinstance(v, int) or not 1 <= v <= 1_000_000:
                raise ConfigError(f"{app}: {key} must be a whole number from 1 to 1000000")
        models = lim["models"]
        if models is not None and (not isinstance(models, list) or not 1 <= len(models) <= 20 or not all(
                isinstance(m, str) and re.fullmatch(r"[\x21-\x7e]{1,100}", m) for m in models)):
            raise ConfigError(f"{app}: models must be null (any) or a list of 1 to 20 model ids")
        out[app] = dict(lim, models=None if models is None else list(models))
    return out


def load_limits():
    """Read on every request, so an edit counts at once. A missing or broken file = every app
    refused (closed, never open)."""
    return valid_limits(_read_private_json(LIMITS, "no AI limits set yet (run: ci_forwarder.py set-limits)"))


def day_key(now=None):
    """Today's date in JST: the day the daily counters belong to."""
    return time.strftime("%Y-%m-%d", time.gmtime((time.time() if now is None else now) + DAY_OFFSET))


def seconds_to_midnight(now=None):
    t = (time.time() if now is None else now) + DAY_OFFSET
    return int(86400 - t % 86400) + 1


ROW_FIELDS = ("requests", "refused", "refunded", "bytes")
DAY_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
SAVE_DELAY = 2.0          # seconds: counters reach the disk at most this often (and on shutdown)


def clean_days(raw):
    """Only well-formed rows survive: {YYYY-MM-DD: {app: {field: int >= 0}}}. Returns (days, dropped)."""
    days, dropped = {}, False
    if not isinstance(raw, dict):
        return days, True
    for day, apps in raw.items():
        if not (isinstance(day, str) and DAY_RE.fullmatch(day) and isinstance(apps, dict)):
            dropped = True
            continue
        for app, row in apps.items():
            if not (isinstance(app, str) and APP_RE.fullmatch(app) and isinstance(row, dict)):
                dropped = True
                continue
            clean = {}
            for f in ROW_FIELDS:
                v = row.get(f, 0)
                ok = isinstance(v, int) and not isinstance(v, bool) and v >= 0
                dropped |= not ok
                clean[f] = v if ok else 0
            days.setdefault(day, {})[app] = clean
    return days, dropped


class Usage:
    """Counters per app: today's requests (kept on disk, so a restart does not reset the day),
    the last minute's requests and the calls running now (in memory). One lock for all.
    The disk copy is written at most every SAVE_DELAY seconds, and by flush() on shutdown: the
    brake itself always works from memory, so a slow disk never slows a request."""

    def __init__(self, path=None, clock=time.time):
        self.path = Path(path or USAGE)
        self.clock = clock
        self.lock = threading.Lock()
        self.minute = collections.defaultdict(collections.deque)
        self.active = collections.Counter()
        self.days, self.warning = {}, None
        self._timer = None
        try:
            data = _read_private_json(self.path, "none yet")
            self.days, dropped = clean_days(data.get("days") if isinstance(data, dict) else None)
            if dropped:
                self.warning = "some AI counters on the PC were damaged and were dropped"
        except ConfigError as e:
            if str(e) != "none yet":
                # A broken file is kept for a look (never silently overwritten), and the page says
                # so: today's counts start again, which is the one way the daily brake can loosen.
                try:
                    os.replace(self.path, self.path.with_name(self.path.name + ".bad"))
                except OSError:
                    pass
                self.warning = f"the AI counters file was broken ({e}); moved to usage.json.bad, today restarted"
        if self.warning:
            print(self.warning, flush=True)

    def _mark(self):
        """Something changed: save soon (once), never now. Called with the lock held."""
        if self._timer is None:
            self._timer = threading.Timer(SAVE_DELAY, self.flush)
            self._timer.daemon = True
            self._timer.start()

    def flush(self):
        """Write the counters now (the timer, shutdown, tests)."""
        with self.lock:
            self._timer = None
            keep = sorted(self.days)[-KEEP_DAYS:]
            self.days = {d: self.days[d] for d in keep}
            try:
                _write_private_json(self.path, {"days": self.days, "warning": self.warning})
            except OSError as e:   # counting must never stop a request; memory still holds the brake
                print(f"usage counters not saved ({type(e).__name__})", flush=True)

    def _row(self, app, now):
        return self.days.setdefault(day_key(now), {}).setdefault(app, dict.fromkeys(ROW_FIELDS, 0))

    def admit(self, app, lim):
        """None when the call may go ahead (and is counted), else (status, message, retry_after)."""
        with self.lock:
            now = self.clock()
            row = self._row(app, now)
            window = self.minute[app]
            while window and window[0] <= now - 60:
                window.popleft()
            refusal = None
            if row["requests"] >= lim["per_day"]:
                refusal = (429, f"daily AI limit reached for {app} ({lim['per_day']} requests); "
                                "it starts again at 00:00 JST", seconds_to_midnight(now))
            elif len(window) >= lim["per_minute"]:
                refusal = (429, f"too many AI requests from {app} this minute ({lim['per_minute']}); "
                                "wait a moment", max(1, int(window[0] + 60 - now) + 1))
            elif self.active[app] >= lim["at_once"]:
                refusal = (429, f"{app} already has {lim['at_once']} AI requests running; "
                                "wait for one to finish", 2)
            if refusal:
                row["refused"] += 1
            else:
                row["requests"] += 1
                window.append(now)
                self.active[app] += 1
            self._mark()
            return refusal

    def refuse(self, app):
        """A request stopped before admission (bad model, too large): counted as refused."""
        with self.lock:
            self._row(app, self.clock())["refused"] += 1
            self._mark()

    def release(self, app, nbytes, refund=False):
        """The call is over. refund=True: it never really used the provider (unreachable, timed
        out, or the key was refused), so it does not count toward the day: a junk key or a broken
        connection cannot use up an app's allowance."""
        with self.lock:
            self.active[app] = max(0, self.active[app] - 1)
            row = self._row(app, self.clock())
            row["bytes"] += nbytes
            if refund and row["requests"] > 0:
                row["requests"] -= 1
                row["refunded"] += 1
            self._mark()


class BodyError(ValueError):
    pass


CHECKED = ("model", "max_tokens", "max_completion_tokens", "max_output_tokens", "n", "thinking")
BUDGET_FIELDS = TOKEN_FIELDS + ("max_output_tokens",)


def _no_duplicates(pairs):
    """json.loads keeps the LAST of two equal keys; a provider may take the first. Either way the
    check and the provider could read different requests, so a duplicate key is refused (at any depth)."""
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise BodyError("a key appears twice in the request")
    return dict(pairs)


def _count(v, top):
    return not isinstance(v, bool) and isinstance(v, int) and 1 <= v <= top


def check_body(lim, body):
    """Only reads the request (it is forwarded byte-for-byte): the model must be allowed, and every
    field that sets how much may be generated must be within the app's max_tokens. Returns None,
    or (status, message)."""
    try:
        data = json.loads(body.decode("utf-8"), object_pairs_hook=_no_duplicates)
    except BodyError as e:
        return 400, str(e)
    except (ValueError, RecursionError):
        return 400, "send the request as JSON"
    if not isinstance(data, dict):
        return 400, "send the request as a JSON object"
    # A provider that ignores letter case would read "Model" or "MAX_TOKENS" that we never checked.
    for k in data:
        if isinstance(k, str) and k.lower() in CHECKED and k not in CHECKED:
            return 400, f"use the field name {k.lower()!r}, not {k[:30]!r}"
    model = data.get("model")
    if lim["models"] is not None and model not in lim["models"]:
        shown = model[:60] if isinstance(model, str) else "(none)"
        return 400, f"model {shown!r} is not allowed here (allowed: {', '.join(lim['models'])})"
    top = lim["max_tokens"]
    for field in BUDGET_FIELDS:
        if field in data and not _count(data[field], top):
            return 400, f"{field} must be at most {top} here (got {str(data[field])[:20]})"
    if "n" in data and not (type(data["n"]) is int and data["n"] == 1):   # not True, not 1.0
        return 400, "only one answer per request (n must be 1)"
    if "thinking" in data:
        think = data["thinking"]
        if not isinstance(think, dict):
            return 400, "thinking must be an object"
        for k in think:
            if isinstance(k, str) and k.lower() == "budget_tokens" and k != "budget_tokens":
                return 400, "use the field name 'budget_tokens'"
        if "budget_tokens" in think and not _count(think["budget_tokens"], top):
            return 400, f"thinking.budget_tokens must be at most {top} here"
    return None


def usage_today(now=None):
    """For the admin page and `usage`: {app: {"requests", "refused", "per_day"}} for every app
    with limits or with use today. Never raises."""
    try:
        limits = load_limits()
    except ConfigError:
        limits = {}
    try:
        data = _read_private_json(USAGE, "none")
        days, _ = clean_days(data.get("days") if isinstance(data, dict) else None)
    except ConfigError:
        days = {}
    today = days.get(day_key(now), {})
    out = {}
    for app in sorted(set(limits) | set(today)):
        row = today.get(app, {})
        out[app] = {"requests": row.get("requests", 0), "refused": row.get("refused", 0),
                    "per_day": limits.get(app, {}).get("per_day")}
    return out


def usage_warning():
    """A warning the forwarder left about its counters (damaged file), or None. Never raises."""
    try:
        data = _read_private_json(USAGE, "none")
    except ConfigError as e:
        return None if str(e) == "none" else f"the AI counters file cannot be read ({e})"
    w = data.get("warning") if isinstance(data, dict) else None
    return w[:200] if isinstance(w, str) else None


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
    data = _read_private_json(CONFIG, "not configured yet (run: ci_forwarder.py set-upstream)")
    if not isinstance(data, dict) or not isinstance(data.get("upstream"), str):
        raise ConfigError("the config has no upstream address")
    return valid_upstream(data["upstream"])


def save_upstream(url):
    """Write the config atomically, owner-only, from a validated address."""
    _write_private_json(CONFIG, {"upstream": valid_upstream(url)})


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

    def _limit_reply(self, status, message, retry_after=None):
        """A brake's answer, shaped like the provider's own errors ({"error": {"message"}}), so the
        apps show the reason instead of a bare failure."""
        body = json.dumps({"error": {"message": message, "type": "mini_deploy_limit"}}).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if retry_after is not None:
            self.send_header("Retry-After", str(retry_after))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _forward(self, method):
        parts = urllib.parse.urlsplit(self.path)
        sub = parts.path[len("/api/ci"):] if parts.path.startswith("/api/ci") else parts.path
        if not PATH_RE.fullmatch(sub):
            return self._reply(404, b"not found")

        # The body comes first: every answer below (a refusal too) must reach the app, and an
        # answer sent while the phone is still sending would reset the connection and lose it.
        body = None
        if method == "POST":
            if self.headers.get("Transfer-Encoding"):
                return self._reply(411, b"send a Content-Length")
            raw_length = self.headers.get("Content-Length") or "0"
            if not LENGTH_RE.fullmatch(raw_length):   # digits only: "-5" would read without end
                return self._reply(400, b"bad Content-Length")
            length = int(raw_length)
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

        try:
            upstream = load_upstream()
        except ConfigError as e:
            return self._reply(503, f"cheaper inference: {e}".encode("utf-8"))

        # Which app: Caddy sets this from its own config and overwrites what the phone sent.
        app = self.headers.get("X-MD-App") or ""
        if not APP_RE.fullmatch(app):
            return self._limit_reply(403, "this address may not use the AI route")
        try:
            lim = load_limits().get(app)
        except ConfigError as e:
            print(f"limits: {e}", flush=True)
            return self._limit_reply(503, "the AI limits on the PC are missing or broken; nothing was sent")
        if lim is None:   # closed by default: a new app gets nothing until it has limits
            return self._limit_reply(403, f"no AI limits are set for {app}; nothing was sent")
        if body is not None:
            problem = check_body(lim, body)
            if problem:
                self.server.usage.refuse(app)
                return self._limit_reply(*problem)

        refusal = self.server.usage.admit(app, lim)
        if refusal:
            return self._limit_reply(*refusal)
        sent, refund = 0, True   # an exception before an answer = the provider was never really used
        try:
            sent, refund = self._upstream(method, upstream, sub, parts, body)
        finally:
            self.server.usage.release(app, sent, refund)   # always: a running slot must never be lost

    def _watch_phone(self, conn, done):
        """While the provider is working, notice the phone (through Caddy) hanging up, and then cut
        the provider's connection: the at-once slot must not stay taken for minutes for nobody."""
        client = self.connection
        while not done.is_set():
            try:
                ready, _, _ = select.select([client], [], [], WATCH_EVERY)
                if not ready:
                    continue
                if client.recv(1, socket.MSG_PEEK) == b"":   # end of stream: the phone is gone
                    if conn.sock is not None:
                        conn.sock.shutdown(socket.SHUT_RDWR)
                    return
                return   # unexpected bytes from the phone: stop watching (never spin on them)
            except (OSError, ValueError):
                return

    def _upstream(self, method, upstream, sub, parts, body):
        """Send the (unchanged) request on and stream the answer back. Returns (bytes sent, refund):
        refund is True when the provider was not really used (unreachable, timed out, or it refused
        the key), so the call does not count toward the app's day."""
        sent = 0
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
            self._reply(502, b"could not reach the service")
            return sent, True
        done = threading.Event()
        threading.Thread(target=self._watch_phone, args=(conn, done), daemon=True).start()
        try:
            try:
                conn.sock.settimeout(TIMEOUT)
                conn.request(method, sub + (f"?{parts.query}" if parts.query else ""), body=body, headers=headers)
                resp = conn.getresponse()
            except TimeoutError:
                self._reply(504, b"the service did not answer in time")
                return sent, True
            except (OSError, http.client.HTTPException):   # unreachable, or the phone left (watcher cut it)
                with contextlib.suppress(OSError):
                    self._reply(502, b"could not reach the service")
                return sent, True

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
                    sent += len(chunk)
            except (OSError, TimeoutError, http.client.HTTPException):
                pass  # the phone went away mid-answer (or the watcher cut a silent provider)
            # The provider refused the key: nothing was generated, so it does not count (a junk key
            # cannot use up the app's allowance).
            return sent, resp.status in (401, 403)
        finally:
            done.set()
            conn.close()


class Server(ThreadingHTTPServer):
    """At most MAX_HANDLERS connections at once: a device on the Wi-Fi or the tailnet that
    opens many connections gets 503s, and the threads it can hold stay bounded."""
    daemon_threads = True
    max_handlers = MAX_HANDLERS

    def __init__(self, *args, usage=None, **kwargs):
        self.slots = threading.BoundedSemaphore(self.max_handlers)
        self.usage = usage or Usage()   # the per-app brakes and counters, shared by every connection
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

    def stop(*_):   # systemd's SIGTERM: stop taking requests, then write the counters one last time
        threading.Thread(target=httpd.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(f"listening on {listen[0]}:{listen[1]}", flush=True)
    try:
        httpd.serve_forever()
    finally:
        httpd.usage.flush()
        print("stopped; counters saved", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("serve")
    sub.add_parser("set-upstream")
    sub.add_parser("show")
    sub.add_parser("set-limits")
    sub.add_parser("usage")
    args = parser.parse_args()
    try:
        if args.cmd == "serve":
            serve()
        elif args.cmd == "set-upstream":
            url = sys.stdin.readline().strip()  # from stdin, never argv: keeps it out of ps and history
            save_upstream(url)
            print("saved (not shown)")
        elif args.cmd == "set-limits":
            try:
                data = json.loads(sys.stdin.read(64 * 1024))
            except (ValueError, RecursionError):
                raise ConfigError("the limits are not valid JSON")
            limits = valid_limits(data)   # checked whole before anything is written
            _write_private_json(LIMITS, limits)
            for app, lim in sorted(limits.items()):
                print(f"{app}: models {lim['models'] or 'any'}, max_tokens {lim['max_tokens']}, "
                      f"{lim['at_once']} at once, {lim['per_minute']}/min, {lim['per_day']}/day")
            print("saved; the forwarder uses them from the next request")
        elif args.cmd == "usage":
            rows = usage_today()
            print(f"AI use on {day_key()} (JST):" if rows else "no AI limits or use yet")
            for app, r in rows.items():
                print(f"  {app}: {r['requests']} / {r['per_day'] or 'no limits: refused'} requests, {r['refused']} refused")
        else:
            print(load_upstream())
    except ConfigError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
