#!/usr/bin/env python3
"""mini-deploy admin page: login, the apps, rollback and unhold, from the browser. PC only.

    admin.py serve            run on 127.0.0.1:9300 (the systemd service mini-deploy-admin)
    admin.py set-password     set the owner's password (hidden prompt; signs every session out)
    admin.py sign-out-all     end every session
    admin.py unlock           clear failed sign-ins (if something on this PC keeps you locked out)

Caddy shows it at http://admin.localhost:8080, and only to this PC (127.0.0.1, no proxy
headers), the same gate as the build logs page. "This PC only" is not "only me": every
program on the PC can reach 127.0.0.1:9300 directly, so the server checks everything itself:
  - a password (scrypt hash) and a session cookie: __Host-, HttpOnly, Secure, SameSite=Strict;
  - every change needs the session, a CSRF token, Origin = http://admin.localhost:8080, JSON;
  - after 5 wrong passwords in an hour, each further try must wait longer (30 s, doubling,
    at most 15 min); `admin.py unlock` (root, in WSL) clears that;
  - every change is written to an audit log (action, app, result; never a value).
The password is only ever set from WSL, never from the web, so nobody can "set it first".
State lives in /var/lib/mini-deploy/admin.db (SQLite, owner-only). Standard library only.
"""

import argparse
import contextlib
import getpass
import hashlib
import hmac
import http.cookies
import json
import os
import re
import secrets
import socket
import sqlite3
import stat
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deploy as deploy_mod        # rollback, rollforward, unhold: the same code as the command line
import dashboard as dashboard_mod  # the app list and recent activity

REPO_ROOT = Path(__file__).resolve().parent.parent
WEB_DIR = REPO_ROOT / "web" / "admin"
LISTEN = ("127.0.0.1", 9300)
HOST = "admin.localhost:8080"
ORIGIN = "http://" + HOST
DB_PATH = Path("/var/lib/mini-deploy/admin.db")
# Tests use a temp database. The override needs a second switch, like the other stores.
if os.environ.get("MINI_DEPLOY_ADMIN_DB") and os.environ.get("MINI_DEPLOY_TESTING") == "1":
    DB_PATH = Path(os.environ["MINI_DEPLOY_ADMIN_DB"])
HOME_FILE = Path("/etc/mini-deploy/home-lan")

# __Host-: the browser only accepts it with Secure, Path=/ and no Domain, so no other name
# (and no other port's service on this name) can plant or share it.
COOKIE = "__Host-md_admin"
IDLE = 12 * 3600            # a session ends after 12 h without you doing anything ...
MAX_AGE = 7 * 24 * 3600     # ... and after 7 days in any case
FREE_TRIES = 5              # wrong passwords per FAIL_WINDOW before waiting starts
FAIL_WINDOW = 3600
BASE_DELAY = 30             # then 30 s, 60 s, 120 s ... per further wrong password
MAX_DELAY = 15 * 60
MIN_PASSWORD = 12
MAX_BODY = 16 * 1024        # every request this page sends is tiny
LENGTH_RE = re.compile(r"^[0-9]{1,6}$")
ACTION_LOCK_WAIT = 15       # a web action waits this long for a busy app, then says "busy"
MAX_HANDLERS = 32           # connections handled at once; more get a 503
REQUEST_DEADLINE = 30       # seconds for a whole request, however slowly it trickles in
SCRYPT = {"n": 2 ** 15, "r": 8, "p": 1, "maxmem": 64 * 1024 * 1024, "dklen": 32}
SCRYPT_SLOTS = threading.BoundedSemaphore(2)   # ~32 MB each: never more than two at once

# The only files the page is made of. Anything else is 404: no paths are built from the URL.
STATIC = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
    "/admin.css": ("admin.css", "text/css; charset=utf-8"),
}
ACTIONS = ("rollback", "rollforward", "unhold")
CSP = ("default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
       "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")

SCHEMA = """
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sessions (token_hash TEXT PRIMARY KEY, csrf TEXT NOT NULL,
                                     created REAL NOT NULL, last_seen REAL NOT NULL);
CREATE TABLE IF NOT EXISTS failures (ts REAL NOT NULL);
CREATE TABLE IF NOT EXISTS audit (id INTEGER PRIMARY KEY, ts TEXT NOT NULL, action TEXT NOT NULL,
                                  app TEXT NOT NULL, result TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS logins (id INTEGER PRIMARY KEY, ts TEXT NOT NULL, result TEXT NOT NULL);
"""


# ---------------------------------------------------------------- database

def _private(st, what, folder=False):
    kind = stat.S_ISDIR if folder else stat.S_ISREG
    if not kind(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise RuntimeError(f"{what} is not a private {'folder' if folder else 'file'} of this user; not used")


@contextlib.contextmanager
def db():
    """A connection to the admin database, created owner-only on first use. The folder and
    the file are checked on every use (one someone else owns or can read is never trusted)."""
    DB_PATH.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    _private(os.lstat(DB_PATH.parent), DB_PATH.parent, folder=True)
    with contextlib.suppress(FileExistsError):
        os.close(os.open(DB_PATH, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600))
    _private(os.lstat(DB_PATH), DB_PATH)
    conn = sqlite3.connect(DB_PATH, timeout=10, isolation_level=None)
    try:
        conn.executescript(SCHEMA)
        yield conn
    finally:
        conn.close()


def _sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def audit(conn, action, app, result):
    """One line per change. Never a value: only fixed words and a checked app name.
    Sign-ins go to their own table, so a flood of guesses can never push changes out."""
    conn.execute("INSERT INTO audit (ts, action, app, result) VALUES (?, ?, ?, ?)",
                 (_now_iso(), action, app if deploy_mod.APP_RE.fullmatch(app) else "-", result))
    conn.execute("DELETE FROM audit WHERE id <= (SELECT MAX(id) FROM audit) - 1000")


def log_login(conn, result):
    conn.execute("INSERT INTO logins (ts, result) VALUES (?, ?)", (_now_iso(), result))
    conn.execute("DELETE FROM logins WHERE id <= (SELECT MAX(id) FROM logins) - 500")


# ---------------------------------------------------------------- password and sessions

def hash_password(password):
    salt = secrets.token_bytes(16)
    dk = hashlib.scrypt(password.encode("utf-8"), salt=salt, **SCRYPT)
    return f"scrypt${SCRYPT['n']}${SCRYPT['r']}${SCRYPT['p']}${salt.hex()}${dk.hex()}"


def check_password(password, stored):
    try:
        _, n, r, p, salt, want = stored.split("$")
        dk = hashlib.scrypt(password.encode("utf-8"), salt=bytes.fromhex(salt), n=int(n), r=int(r),
                            p=int(p), maxmem=SCRYPT["maxmem"], dklen=len(want) // 2)
    except (ValueError, TypeError, UnicodeError, MemoryError):
        return False
    return hmac.compare_digest(dk.hex(), want)


def set_password(password):
    if not isinstance(password, str) or len(password) < MIN_PASSWORD:
        raise ValueError(f"the password needs at least {MIN_PASSWORD} characters")
    with db() as conn:
        conn.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('password', ?)",
                     (hash_password(password),))
        conn.execute("DELETE FROM sessions")    # a new password signs every session out
        conn.execute("DELETE FROM failures")
        audit(conn, "set-password", "-", "ok")


def login_wait(conn, now):
    """Seconds to wait before the next try is checked at all (0 = go ahead)."""
    rows = conn.execute("SELECT ts FROM failures WHERE ts > ? ORDER BY ts", (now - FAIL_WINDOW,)).fetchall()
    if len(rows) < FREE_TRIES:
        return 0
    wait = min(BASE_DELAY * 2 ** (len(rows) - FREE_TRIES), MAX_DELAY)
    left = rows[-1][0] + wait - now
    return int(left) + 1 if left > 0 else 0


def new_session(conn):
    token, csrf, now = secrets.token_urlsafe(32), secrets.token_urlsafe(32), time.time()
    conn.execute("INSERT INTO sessions VALUES (?, ?, ?, ?)", (_sha(token), csrf, now, now))
    return token, csrf   # only the token's hash is stored: a copy of the database is no login


def find_session(conn, token, touch=True):
    """touch=False for the page's automatic refresh: an open tab alone must not keep a
    session alive past the 12 h idle limit. Loading the page or acting does count."""
    if not token or len(token) > 100:
        return None
    row = conn.execute("SELECT token_hash, csrf, created, last_seen FROM sessions WHERE token_hash = ?",
                       (_sha(token),)).fetchone()
    if not row:
        return None
    now = time.time()
    if now - row[3] > IDLE or now - row[2] > MAX_AGE:
        conn.execute("DELETE FROM sessions WHERE token_hash = ?", (row[0],))
        return None
    if touch:
        conn.execute("UPDATE sessions SET last_seen = ? WHERE token_hash = ?", (now, row[0]))
    return {"hash": row[0], "csrf": row[1]}


# ---------------------------------------------------------------- the phone address

def phone_base():
    """'192-168-40-241.nip.io:8080' while Caddy listens on the saved home address (so the
    phone on the home Wi-Fi can reach the apps), else None."""
    try:
        text = HOME_FILE.read_text(encoding="ascii")
    except (OSError, UnicodeError):
        return None
    m = re.search(r"^ADDR=([0-9]{1,3}(?:\.[0-9]{1,3}){3})$", text, re.M)
    if not m:
        return None
    try:
        with socket.create_connection((m.group(1), 8080), timeout=0.5):
            pass
    except OSError:
        return None
    return m.group(1).replace(".", "-") + ".nip.io:8080"


def state():
    data = dashboard_mod.collect()
    # Recent deploys: only apps that exist now, plus the webhook's own lines. The test suites
    # write throwaway apps into the deploy log; once those are removed they are only noise.
    present = {a["name"] for a in data["apps"]}
    data["events"] = [e for e in data["events"] if e["app"] in present or e["app"] == "webhook"]
    base = phone_base()
    for app in data["apps"]:
        app["pc_url"] = f"http://{app['name']}.localhost:8080/"
        app["phone_url"] = f"http://{app['name']}.{base}/" if base else None
    with db() as conn:
        rows = conn.execute("SELECT ts, action, app, result FROM audit ORDER BY id DESC LIMIT 50").fetchall()
    data["audit"] = [{"ts": r[0], "action": r[1], "app": r[2], "result": r[3]} for r in rows]
    data["at_home"] = base is not None
    return data


# ---------------------------------------------------------------- the web side

def _clean(text, limit=100):
    """For the journal: printable ASCII only, so a request cannot fake lines or colours."""
    return re.sub(r"[^\x21-\x7e]", "?", text[:limit])


class Handler(BaseHTTPRequestHandler):
    server_version = "mini-deploy-admin"
    sys_version = ""
    timeout = 10   # per read; the server also has an overall deadline per request

    def log_message(self, fmt, *args):
        # Method, path, status. Never the body (it holds the password) or the cookie.
        code = args[1] if len(args) > 1 else ""
        print(f"{_clean(str(self.command or '-'), 10)} {_clean(self.path.split('?')[0])} {_clean(str(code), 5)}",
              flush=True)

    # --- answers
    def _send(self, status, body, ctype, extra=()):
        self.send_response(status)
        for k, v in (("Content-Type", ctype), ("Content-Length", str(len(body))),
                     ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"),
                     ("Referrer-Policy", "no-referrer"), ("X-Frame-Options", "DENY"),
                     ("Content-Security-Policy", CSP), ("Cross-Origin-Opener-Policy", "same-origin"),
                     ("Cross-Origin-Resource-Policy", "same-origin"), *extra):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status, obj, extra=()):
        self._send(status, json.dumps(obj).encode("utf-8"), "application/json; charset=utf-8", extra)

    def _not_found(self):
        self._send(404, b"not found", "text/plain; charset=utf-8")

    # --- checks
    def _host_ok(self):
        # The page answers only to its own name: a page that tricks the browser into using
        # another name for this address (DNS rebinding) gets nothing.
        return self.headers.get("Host") == HOST

    def _path(self):
        try:
            return urllib.parse.urlsplit(self.path).path
        except ValueError:   # e.g. "//[" : not a path this page has
            return None

    def _token(self):
        raw = self.headers.get("Cookie")
        if not raw:
            return None
        try:
            jar = http.cookies.SimpleCookie(raw)
        except http.cookies.CookieError:
            return None
        return jar[COOKIE].value if COOKIE in jar else None

    def _guarded(self, route):
        """Run a route; a database problem or a bug answers 500, never a dropped connection."""
        try:
            route()
        except sqlite3.DatabaseError as e:
            print(f"admin database problem: {type(e).__name__}", flush=True)
            self._json(500, {"error": "the admin database has a problem (see journalctl -u mini-deploy-admin)"})
        except RuntimeError as e:   # an unsafe database file or folder
            print(f"refused: {e}", flush=True)
            self._json(500, {"error": "the admin database is not safe to use (see journalctl -u mini-deploy-admin)"})

    # --- GET
    def do_GET(self):
        self._guarded(self._get)

    def _get(self):
        path = self._path()
        if not self._host_ok() or path is None:
            return self._not_found()
        if path in STATIC:
            name, ctype = STATIC[path]
            try:
                body = (WEB_DIR / name).read_bytes()
            except OSError:
                return self._not_found()
            return self._send(200, body, ctype)
        if path == "/api/session":   # loaded when the page opens: counts as activity
            with db() as conn:
                sess = find_session(conn, self._token())
                has_password = conn.execute("SELECT 1 FROM settings WHERE key = 'password'").fetchone() is not None
            return self._json(200, {"logged_in": sess is not None, "csrf": sess["csrf"] if sess else None,
                                    "password_set": has_password})
        if path == "/api/state":     # the automatic refresh: does not keep the session alive
            with db() as conn:
                sess = find_session(conn, self._token(), touch=False)
            if not sess:
                return self._json(401, {"error": "sign in first"})
            return self._json(200, state())
        return self._not_found()

    # --- POST
    def do_POST(self):
        self._guarded(self._post)

    def _post(self):
        path = self._path()
        if not self._host_ok() or path is None:
            return self._not_found()
        if path not in ("/api/login", "/api/logout", "/api/logout-all", "/api/action"):
            return self._not_found()
        # Only this page may send changes: exactly our Origin, a same-origin fetch, JSON.
        if self.headers.get("Origin") != ORIGIN:
            return self._json(403, {"error": "refused: wrong origin"})
        fetch_site = self.headers.get("Sec-Fetch-Site")
        if fetch_site is not None and fetch_site != "same-origin":
            return self._json(403, {"error": "refused: not from this page"})
        if (self.headers.get("Content-Type") or "").split(";")[0].strip() != "application/json":
            return self._json(415, {"error": "send JSON"})
        if self.headers.get("Transfer-Encoding"):
            return self._json(411, {"error": "send a Content-Length"})
        raw_length = self.headers.get("Content-Length") or "0"
        if not LENGTH_RE.fullmatch(raw_length):   # digits only: no "-1", " 5" or "+5"
            return self._json(400, {"error": "bad Content-Length"})
        if int(raw_length) > MAX_BODY:
            return self._json(413, {"error": "request too large"})
        raw = self.rfile.read(int(raw_length))

        if path == "/api/login":
            return self._login(raw)
        with db() as conn:
            sess = find_session(conn, self._token())
            if not sess:
                return self._json(401, {"error": "sign in first"})
            given = self.headers.get("X-CSRF-Token") or ""
            if not hmac.compare_digest(given.encode("utf-8", "replace"), sess["csrf"].encode("ascii")):
                return self._json(403, {"error": "refused: missing or wrong CSRF token"})
            if path == "/api/logout":
                conn.execute("DELETE FROM sessions WHERE token_hash = ?", (sess["hash"],))
                audit(conn, "logout", "-", "ok")
                return self._json(200, {"ok": True}, [("Set-Cookie", self._cookie("", 0))])
            if path == "/api/logout-all":
                conn.execute("DELETE FROM sessions")
                audit(conn, "logout-all", "-", "ok")
                return self._json(200, {"ok": True}, [("Set-Cookie", self._cookie("", 0))])
        return self._action(raw)

    def _cookie(self, value, max_age):
        return f"{COOKIE}={value}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age={max_age}"

    def _login(self, raw):
        # Count the try BEFORE checking the password, in one transaction: tries sent in
        # parallel each count, so they cannot get more guesses than one after another.
        with db() as conn:
            now = time.time()
            conn.execute("BEGIN IMMEDIATE")
            try:
                conn.execute("DELETE FROM failures WHERE ts < ?", (now - FAIL_WINDOW,))
                wait = login_wait(conn, now)
                row = conn.execute("SELECT value FROM settings WHERE key = 'password'").fetchone()
                if not wait and row:
                    conn.execute("INSERT INTO failures (ts) VALUES (?)", (now,))   # removed on success
                conn.execute("COMMIT")
            except BaseException:
                conn.execute("ROLLBACK")
                raise
            if wait:
                log_login(conn, "wait")
                return self._json(429, {"error": f"too many wrong passwords; try again in {wait} s",
                                        "retry_after": wait}, [("Retry-After", str(wait))])
            if not row:
                return self._json(503, {"error": "no password set yet: in WSL run admin.py set-password"})
        try:
            data = json.loads(raw.decode("utf-8"))
        except (ValueError, RecursionError):
            data = {}
        password = data.get("password") if isinstance(data, dict) else None
        if not isinstance(password, str) or len(password) > 1024:
            password = ""   # still checked, so a bad request takes as long as a wrong password
        if not SCRYPT_SLOTS.acquire(timeout=10):
            return self._json(503, {"error": "busy; try again"})
        try:
            ok = check_password(password, row[0])
        finally:
            SCRYPT_SLOTS.release()
        with db() as conn:
            if not ok:
                log_login(conn, "fail")
                return self._json(401, {"error": "wrong password"})
            conn.execute("DELETE FROM failures")
            token, csrf = new_session(conn)
            log_login(conn, "ok")
        return self._json(200, {"ok": True, "csrf": csrf}, [("Set-Cookie", self._cookie(token, MAX_AGE))])

    def _action(self, raw):
        try:
            data = json.loads(raw.decode("utf-8"))
        except (ValueError, RecursionError):
            return self._json(400, {"error": "bad JSON"})
        if not isinstance(data, dict):
            return self._json(400, {"error": "bad request"})
        action, app, expect = data.get("action"), data.get("app"), data.get("expect")
        if action not in ACTIONS:
            return self._json(400, {"error": "unknown action"})
        if not isinstance(app, str) or not deploy_mod.APP_RE.fullmatch(app) or app in deploy_mod.RESERVED_APPS:
            return self._json(400, {"error": "bad app name"})
        if not (deploy_mod.SITES / app / "releases").is_dir():
            return self._json(404, {"error": "no such app"})
        if action != "unhold" and not (isinstance(expect, str) and deploy_mod.ID_RE.fullmatch(expect)):
            # Rollback is relative ("one step back"): the page must say which release it
            # showed, so a double click or a retry is refused instead of going back twice.
            return self._json(400, {"error": "nothing live to move from, or the page is out of date; reload"})

        status, reply, result = 200, {"ok": True}, "ok"
        try:
            if action == "unhold":
                deploy_mod.unhold(app)
            elif action == "rollback":
                deploy_mod.rollback(app, expect=expect, wait=ACTION_LOCK_WAIT)
            else:
                deploy_mod.rollforward(app, expect=expect, wait=ACTION_LOCK_WAIT)
        except deploy_mod.DeployError as e:
            status, reply, result = 409, {"error": str(e)}, "fail"   # PC-only page: the full reason is fine
        except Exception as e:  # noqa: BLE001  (never a dropped connection without a record)
            print(f"{action} {app}: {type(e).__name__}", flush=True)
            status, result = 500, "error"
            reply = {"error": f"unexpected error ({type(e).__name__}); see journalctl -u mini-deploy-admin"}
        try:
            with db() as conn:
                audit(conn, action, app, result)
        except Exception as e:  # noqa: BLE001  (the action already happened; say so, do not hide it)
            print(f"audit write failed: {type(e).__name__}", flush=True)
            reply["warning"] = "done, but the audit log could not be written"
        deploy_mod._refresh_dashboard(app)   # after failures too, like the command line
        return self._json(status, reply)


class Server(ThreadingHTTPServer):
    """At most MAX_HANDLERS connections at once (more get a 503 at once), and each request has
    an overall deadline, so a client dripping one byte at a time cannot hold a thread."""
    daemon_threads = True
    request_queue_size = 64
    max_handlers = MAX_HANDLERS
    deadline = REQUEST_DEADLINE

    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(self.max_handlers)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                request.sendall(b"HTTP/1.0 503 Service Unavailable\r\nContent-Length: 0\r\n"
                                b"Connection: close\r\n\r\n")
                request.shutdown(socket.SHUT_WR)
                request.settimeout(0.5)
                request.recv(4096)
            except OSError:
                pass
            self.shutdown_request(request)
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        def cut():
            with contextlib.suppress(OSError):
                request.shutdown(socket.SHUT_RDWR)
        timer = threading.Timer(self.deadline, cut)
        timer.daemon = True
        timer.start()
        try:
            super().process_request_thread(request, client_address)
        finally:
            timer.cancel()
            self.slots.release()

    def handle_error(self, request, client_address):  # one quiet line, not a traceback
        print(f"connection error: {sys.exc_info()[0].__name__}", file=sys.stderr, flush=True)


def serve(listen=LISTEN):
    os.umask(0o077)   # the database and its journal files: owner-only
    with db():
        pass           # create or check the database before taking requests
    httpd = Server(listen, Handler)
    print(f"listening on {listen[0]}:{listen[1]} (Caddy: {ORIGIN}, this PC only)", flush=True)
    httpd.serve_forever()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("serve", "set-password", "sign-out-all", "unlock"):
        sub.add_parser(name)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.cmd == "serve":
            serve()
        elif args.cmd == "set-password":
            first = getpass.getpass(f"new password (at least {MIN_PASSWORD} characters, not shown): ")
            if getpass.getpass("again: ") != first:
                print("error: the two passwords differ; nothing changed", file=sys.stderr)
                return 1
            set_password(first)
            print("password saved; every session is signed out")
        elif args.cmd == "unlock":
            with db() as conn:
                conn.execute("DELETE FROM failures")
                audit(conn, "unlock", "-", "ok")
            print("failed sign-ins cleared: you can sign in again now")
        else:
            with db() as conn:
                conn.execute("DELETE FROM sessions")
                audit(conn, "logout-all", "-", "ok")
            print("every session is signed out")
    except sqlite3.DatabaseError:
        print(f"error: {DB_PATH} is damaged. Move it aside (mv {DB_PATH} {DB_PATH}.bad), "
              "then run admin.py set-password again.", file=sys.stderr)
        return 1
    except (ValueError, RuntimeError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
