#!/usr/bin/env bash
# Admin page test (scripts/admin.py, P3a).
# Part 1 runs the admin server on test ports with a TEMP database, TEMP /sites and a TEMP
# deploy log: the real ones are never touched. Part 2 checks Caddy's gate in front of the
# real service. It never deletes anything itself. Pass = every check ok.
set -uo pipefail
REPO=/mnt/c/Users/indra/Code/mini-deploy
fail=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }

echo "== 1. the admin server (temp database, temp apps) =="
python3 - <<PY || fail=1
import contextlib, io, json, os, socket, sqlite3, subprocess, sys, tempfile, threading, time, http.client
from pathlib import Path

tmp = Path(tempfile.mkdtemp(prefix="mini-deploy-admintest-"))   # removed by hand, like other test folders
os.environ["MINI_DEPLOY_TESTING"] = "1"
os.environ["MINI_DEPLOY_ADMIN_DB"] = str(tmp / "admin.db")
sys.path.insert(0, "$REPO/scripts")
import deploy, admin
deploy.SITES = tmp / "sites"; deploy.SITES.mkdir()
deploy.LOG_FILE = tmp / "deploy.log"           # never the real deploy log
admin.HOME_FILE = tmp / "home-lan"             # not at home until a test writes it

bad_count = 0
def check(ok, msg):
    global bad_count
    print(("ok    " if ok else "FAIL  ") + msg)
    bad_count += not ok

# A test app with three releases.
srcs = []
for n in (1, 2, 3):
    src = tmp / f"src{n}"; src.mkdir()
    (src / "index.html").write_text(f"<h1>release {n}</h1>")
    srcs.append(src)
    with contextlib.redirect_stdout(io.StringIO()):
        deploy.deploy("adm-one", src)
    time.sleep(1.1)   # release ids are per second
root = deploy.SITES / "adm-one"
ids = deploy.release_ids(root / "releases")
live = lambda: deploy.current_id(root / "current")

class TestServer(admin.Server):
    deadline = 5                                 # short, so the slow-client test is quick
PORT = 9310
srv = TestServer(("127.0.0.1", PORT), admin.Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
HOST, ORIGIN = admin.HOST, admin.ORIGIN
# Capture everything the server prints (its journal lines) without swapping sys.stdout,
# which is not safe with several threads: the module's own print is replaced instead.
log = io.StringIO()
log_lock = threading.Lock()
def capture(*a, **k):
    with log_lock:
        log.write(" ".join(str(x) for x in a) + "\n")
admin.print = capture
deploy.print = lambda *a, **k: None   # "live: ..." lines from the actions: not needed here

def req(method, path, body=None, host=HOST, origin=ORIGIN, cookie=None, csrf=None,
        ctype="application/json", extra=None, port=PORT):
    h = {"Host": host}
    if origin: h["Origin"] = origin
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        h["Content-Type"] = ctype
    if cookie: h["Cookie"] = f"{admin.COOKIE}={cookie}"
    if csrf: h["X-CSRF-Token"] = csrf
    h.update(extra or {})
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    c.request(method, path, body=data, headers=h)
    r = c.getresponse(); b = r.read()
    c.close()
    try: j = json.loads(b)
    except ValueError: j = None
    return r.status, j if j is not None else b, r

def login(pw):
    st, j, r = req("POST", "/api/login", {"password": pw})
    cookie = None
    sc = r.getheader("Set-Cookie") or ""
    if sc.startswith(admin.COOKIE + "="):
        cookie = sc.split(";")[0].split("=", 1)[1]
    return st, j, sc, cookie

def raw_request(data, port=PORT, wait=5):
    s = socket.create_connection(("127.0.0.1", port), timeout=wait)
    s.sendall(data)
    out = b""
    try:
        while True:
            chunk = s.recv(4096)
            if not chunk: break
            out += chunk
    except socket.timeout:
        pass
    s.close()
    return out

db = lambda: sqlite3.connect(admin.DB_PATH)
PW = "correct horse battery staple 42"

# --- the page and its headers
st, body, r = req("GET", "/", origin=None)
csp = r.getheader("Content-Security-Policy") or ""
check(st == 200 and b"mini-deploy admin" in body, "the page loads with the right Host")
check("frame-ancestors 'none'" in csp and "script-src 'self'" in csp and "unsafe-inline" not in csp,
      "strict CSP: own scripts only, no inline, never in a frame")
check(r.getheader("X-Content-Type-Options") == "nosniff" and r.getheader("Cache-Control") == "no-store"
      and r.getheader("Referrer-Policy") == "no-referrer", "nosniff, no-store, no-referrer")
for h in ["127.0.0.1:9310", "evil.localhost:8080", "admin.localhost", "admin.localhost:8080.evil.test"]:
    st, _, _ = req("GET", "/", host=h, origin=None)
    check(st == 404, f"wrong Host {h!r} gets 404 (DNS-rebinding guard)")
for p in ["/../scripts/admin.py", "/web/admin/app.js", "/app.js/..", "/.env", "/api/nothing", "//["]:
    st, _, _ = req("GET", p, origin=None)
    check(st == 404, f"{p} is 404 (only the page's own files are served; odd paths do not crash)")

# --- before a password exists
st, j, _ = req("GET", "/api/session", origin=None)
check(st == 200 and j["logged_in"] is False and j["password_set"] is False, "no session, no password yet")
st, j, _, _ = login("anything")
check(st == 503, f"login before a password is set: 503 (got {st})")
try:
    admin.set_password("short"); check(False, "a short password was accepted")
except ValueError:
    check(True, f"a password under {admin.MIN_PASSWORD} characters is refused")
admin.set_password(PW)
raw = Path(admin.DB_PATH).read_bytes()
check(PW.encode() not in raw and b"scrypt$" in raw, "the database holds an scrypt hash, never the password")
check(oct(os.stat(admin.DB_PATH).st_mode & 0o777) == "0o600", "the database is owner-only (600)")

# --- signing in
st, j, sc, _ = login("wrong password!!")
check(st == 401, "a wrong password: 401")
st, j, sc, cookie = login(PW)
check(st == 200 and cookie and isinstance(j.get("csrf"), str), "the right password: 200, a session and a CSRF token")
csrf = j["csrf"]
check(sc.startswith("__Host-"), "the cookie has the __Host- prefix (no other name or port can share it)")
for attr in ("HttpOnly", "Secure", "SameSite=Strict", "Path=/"):
    check(attr in sc, f"the session cookie is {attr}")
check("Domain=" not in sc, "the cookie has no Domain (it stays on admin.localhost)")
check(cookie.encode() not in Path(admin.DB_PATH).read_bytes(), "only the session's hash is stored, not the token")

# --- reading
st, j, _ = req("GET", "/api/state", origin=None)
check(st == 401, "state without a session: 401")
st, j, _ = req("GET", "/api/state", origin=None, cookie=cookie)
app = next((a for a in (j or {}).get("apps", []) if a["name"] == "adm-one"), None)
check(st == 200 and app is not None, "state with a session lists the app")
check(app and app["pc_url"] == "http://adm-one.localhost:8080/" and app["phone_url"] is None and j["at_home"] is False,
      "this-PC address shown; no phone address when not at home")
with open(deploy.LOG_FILE, "a") as fh:   # a removed test app in the log is not shown
    fh.write("2026-01-01T00:00:00Z gone-app deploy 20260101-000000 ok 0.0s\n")
st, j, _ = req("GET", "/api/state", origin=None, cookie=cookie)
check(all(e["app"] != "gone-app" for e in j["events"]) and any(e["app"] == "adm-one" for e in j["events"]),
      "recent deploys list only apps that exist now")

# --- the automatic refresh does not keep a session alive; opening the page does
seen = lambda: db().execute("SELECT last_seen FROM sessions").fetchall()
db_ = db(); db_.execute("UPDATE sessions SET last_seen = last_seen - 100"); db_.commit()
before = seen()
req("GET", "/api/state", origin=None, cookie=cookie)
check(seen() == before, "polling /api/state does not count as activity (the 12 h idle limit holds)")
req("GET", "/api/session", origin=None, cookie=cookie)
check(seen() != before, "opening the page does count as activity")

# --- every change is refused without each of its guards
good = {"action": "unhold", "app": "adm-one"}
cases = [
    ("no session", dict(csrf=csrf), 401),
    ("no CSRF token", dict(cookie=cookie), 403),
    ("a wrong CSRF token", dict(cookie=cookie, csrf="x" * 43), 403),
    ("another app's Origin", dict(cookie=cookie, csrf=csrf, origin="http://adm-one.localhost:8080"), 403),
    ("no Origin", dict(cookie=cookie, csrf=csrf, origin=None), 403),
    ("Sec-Fetch-Site: cross-site", dict(cookie=cookie, csrf=csrf, extra={"Sec-Fetch-Site": "cross-site"}), 403),
    ("a form post", dict(cookie=cookie, csrf=csrf, ctype="application/x-www-form-urlencoded"), 415),
    ("text/plain", dict(cookie=cookie, csrf=csrf, ctype="text/plain"), 415),
    ("the wrong Host", dict(cookie=cookie, csrf=csrf, host="adm-one.localhost:8080"), 404),
]
audit_count = lambda: db().execute("SELECT COUNT(*) FROM audit").fetchone()[0]
audit_before = audit_count()
for label, kw, want in cases:
    st, _, _ = req("POST", "/api/action", good, **kw)
    check(st == want, f"{label}: {want} (got {st})")
st, _, _ = req("POST", "/api/action", b"x" * (admin.MAX_BODY + 1), cookie=cookie, csrf=csrf)
check(st == 413, f"a body over 16 KB: 413 (got {st})")
# (" 5" is not here: the header parser strips the space, so it arrives as a valid 5.)
for bad_len in ["-1", "+5", "1e3", "0x10", "9999999"]:
    out = raw_request((f"POST /api/action HTTP/1.1\r\nHost: {HOST}\r\nOrigin: {ORIGIN}\r\n"
                       f"Content-Type: application/json\r\nContent-Length: {bad_len}\r\n\r\n").encode())
    check(out.startswith(b"HTTP/1.0 400") or out.startswith(b"HTTP/1.0 413"),
          f"Content-Length {bad_len!r} is refused before reading ({out[:12]!r})")
check(audit_count() == audit_before, "none of the refused requests changed anything")

# --- bad input
for label, body, want in [("an unknown action", {"action": "remove", "app": "adm-one"}, 400),
                          ("a bad app name", {"action": "rollback", "app": "../etc", "expect": ids[-1]}, 400),
                          ("a reserved app", {"action": "rollback", "app": "admin", "expect": ids[-1]}, 400),
                          ("the dashboard", {"action": "rollback", "app": "dashboard", "expect": ids[-1]}, 400),
                          ("an app that does not exist", {"action": "rollback", "app": "nope", "expect": ids[-1]}, 404),
                          ("rollback without the live release", {"action": "rollback", "app": "adm-one"}, 400),
                          ("not an object", ["rollback"], 400)]:
    st, _, _ = req("POST", "/api/action", body, cookie=cookie, csrf=csrf)
    check(st == want, f"{label}: {want} (got {st})")

# --- the real actions
def act(action, expect="live"):
    body = {"action": action, "app": "adm-one"}
    if expect is not None:
        body["expect"] = live() if expect == "live" else expect
    return req("POST", "/api/action", body, cookie=cookie, csrf=csrf)
check(live() == ids[-1], "starts on the newest release")
seen_live = live()
check(act("rollback", seen_live)[0] == 200 and live() == ids[-2] and deploy.is_held(root),
      "rollback: the older release is live, the app is held")
st, j, _ = act("rollback", seen_live)   # the same click again (a double click or a retry)
check(st == 409 and live() == ids[-2] and "changed" in j["error"],
      "the same rollback sent twice: 409, it does NOT go back a second step")
check(act("unhold")[0] == 200 and not deploy.is_held(root), "unhold: the hold is lifted")
check(act("rollforward")[0] == 200 and live() == ids[-1] and deploy.is_held(root), "roll forward: newest again, held")
act("unhold")
st, j, _ = act("rollforward")
check(st == 409 and live() == ids[-1], "roll forward with nothing newer: 409, nothing moves")

# A busy app: the web waits a short time, then says so (no thread parked for 10 minutes).
admin.ACTION_LOCK_WAIT = 1
holder_ready, release_holder = threading.Event(), threading.Event()
def hold_lock():
    with deploy.locked(root):
        holder_ready.set(); release_holder.wait(10)
threading.Thread(target=hold_lock, daemon=True).start(); holder_ready.wait(5)
t0 = time.monotonic(); st, j, _ = act("rollback")
took = time.monotonic() - t0
release_holder.set()
check(st == 409 and "still running" in j["error"] and took < 5, f"a busy app: 409 after the short wait ({took:.1f}s)")
admin.ACTION_LOCK_WAIT = 15

# The hold is set BEFORE the flip: if setting it fails, nothing moves.
real_set_hold = deploy.set_hold
deploy.set_hold = lambda r: (_ for _ in ()).throw(OSError("disk full"))
st, j, _ = act("rollback")
deploy.set_hold = real_set_hold
check(st == 500 and live() == ids[-1] and not deploy.is_held(root),
      "if the hold cannot be written: 500, nothing moved, no silent half-rollback")
# If the flip fails, a hold the rollback added is taken back.
real_flip = deploy.flip
deploy.flip = lambda *a: (_ for _ in ()).throw(deploy.DeployError("flip failed"))
st, j, _ = act("rollback")
deploy.flip = real_flip
check(st == 409 and live() == ids[-1] and not deploy.is_held(root), "if the flip fails: 409, and no hold is left behind")
rows = db().execute("SELECT action, app, result FROM audit").fetchall()
check(("rollback", "adm-one", "ok") in rows and ("rollback", "adm-one", "fail") in rows
      and ("rollback", "adm-one", "error") in rows and ("rollforward", "adm-one", "ok") in rows
      and ("unhold", "adm-one", "ok") in rows, "every change, failure and error is in the audit log")
deploy_log = deploy.LOG_FILE.read_text()
check(" rollback " in deploy_log and " rollforward " in deploy_log, "the actions are in the (temp) deploy log too")

# --- a deploy prepared while a rollback held the app does not go live (the webhook's case)
deploy.set_hold(root)
before = live()
try:
    with contextlib.redirect_stdout(io.StringIO()):
        deploy.deploy("adm-one", srcs[0], refuse_if_held=True)
    check(False, "a held app was deployed by the webhook path")
except deploy.HeldError:
    check(live() == before, "refuse_if_held: a held app is not deployed (checked under the deploy lock)")
with contextlib.redirect_stdout(io.StringIO()):
    deploy.deploy("adm-one", srcs[0])   # a manual deploy still works (the owner's decision)
check(live() != before, "a manual deploy of a held app still works")
deploy.clear_hold(root)

# --- phone address while at home (the saved home address is this PC's loopback here)
admin.HOME_FILE.write_text("ADDR=127.0.0.1\nGATEWAY_MAC=00:00:00:00:00:00\n")
st, j, _ = req("GET", "/api/state", origin=None, cookie=cookie)
app = next(a for a in j["apps"] if a["name"] == "adm-one")
check(j["at_home"] is True and app["phone_url"] == "http://adm-one.127-0-0-1.nip.io:8080/",
      f"at home: the phone address is shown ({app['phone_url']})")
admin.HOME_FILE.unlink()

# --- sessions end
st, j2, _, cookie2 = login(PW)
req("POST", "/api/logout", {}, cookie=cookie2, csrf=j2["csrf"])
check(req("GET", "/api/state", origin=None, cookie=cookie2)[0] == 401, "sign out: that session is gone")
st, j3, _, cookie3 = login(PW)
req("POST", "/api/logout-all", {}, cookie=cookie3, csrf=j3["csrf"])
check(req("GET", "/api/state", origin=None, cookie=cookie)[0] == 401, "sign out everywhere: other sessions are gone too")
st, j4, _, cookie4 = login(PW)
con = db()
con.execute("UPDATE sessions SET last_seen = last_seen - ?", (admin.IDLE + 10,)); con.commit()
check(req("GET", "/api/state", origin=None, cookie=cookie4)[0] == 401, "a session unused for 12 h ends")
st, j5, _, cookie5 = login(PW)
con.execute("UPDATE sessions SET created = created - ?", (admin.MAX_AGE + 10,)); con.commit()
check(req("GET", "/api/state", origin=None, cookie=cookie5)[0] == 401, "a session older than 7 days ends")
st, j6, _, cookie6 = login(PW)
admin.set_password(PW + "!")
check(req("GET", "/api/state", origin=None, cookie=cookie6)[0] == 401, "a new password signs every session out")
PW = PW + "!"

# --- wrong passwords: free tries, then growing waits
con.execute("DELETE FROM failures"); con.commit()
for i in range(admin.FREE_TRIES):
    login("not it " + str(i))
st, j, _, _ = login(PW)
check(st == 429 and j.get("retry_after", 0) > 0, f"after {admin.FREE_TRIES} wrong passwords even the right one must wait (got {st})")
con.execute("UPDATE failures SET ts = ts - ?", (admin.BASE_DELAY + 2,)); con.commit()
st, _, _, _ = login("one more wrong")
check(st == 401, "after the wait, one more try is checked")
st, j, _, _ = login(PW)
check(st == 429 and j["retry_after"] > admin.BASE_DELAY, f"the next wait is longer ({j.get('retry_after')} s)")
check(db().execute("SELECT COUNT(*) FROM logins WHERE result = 'wait'").fetchone()[0] >= 1
      and db().execute("SELECT COUNT(*) FROM audit WHERE action = 'login'").fetchone()[0] == 0,
      "sign-ins are logged on their own, never in the audit of changes")
out = subprocess.run(["python3", "$REPO/scripts/admin.py", "unlock"], capture_output=True, text=True,
                     env={**os.environ})
check(out.returncode == 0, "admin.py unlock runs")
st, _, _, _ = login(PW)
check(st == 200, "after admin.py unlock the right password works at once")

# Tries sent in parallel all count: no more checked guesses than one after another.
con.execute("DELETE FROM failures"); con.commit()
results = []
def try_one(i):
    results.append(login("parallel guess " + str(i))[0])
threads = [threading.Thread(target=try_one, args=(i,)) for i in range(12)]
[t.start() for t in threads]; [t.join() for t in threads]
checked = results.count(401)
check(checked <= admin.FREE_TRIES and results.count(429) == 12 - checked,
      f"12 guesses at once: only {checked} checked (at most {admin.FREE_TRIES}), the rest told to wait")
con.execute("DELETE FROM failures"); con.commit()

# --- a slow client cannot hold a thread past the deadline
s = socket.create_connection(("127.0.0.1", PORT), timeout=15)
s.sendall(b"GET / HTTP/1.1\r\nHost: " + HOST.encode() + b"\r\n")
t0 = time.monotonic(); closed = False
try:
    while time.monotonic() - t0 < 12:
        s.sendall(b"X-Drip: 1\r\n"); time.sleep(1)
        s.settimeout(0.01)
        try:
            if s.recv(1) == b"": closed = True; break
        except socket.timeout:
            pass
        except OSError:
            closed = True; break
except OSError:
    closed = True
s.close()
check(closed and time.monotonic() - t0 < 10, f"a client dripping one header a second is cut off ({time.monotonic() - t0:.0f}s)")

# --- a cap on connections: past it, an immediate 503
class Tiny(admin.Server):
    max_handlers = 2
tiny = Tiny(("127.0.0.1", 9311), admin.Handler)
threading.Thread(target=tiny.serve_forever, daemon=True).start()
idle = [socket.create_connection(("127.0.0.1", 9311)) for _ in range(2)]
time.sleep(0.3)
out = raw_request(f"GET / HTTP/1.1\r\nHost: {HOST}\r\n\r\n".encode(), port=9311)
check(out.startswith(b"HTTP/1.0 503"), f"past the connection cap: 503 at once ({out[:12]!r})")
for s in idle: s.close()

# --- nothing secret anywhere it should not be
everything = log.getvalue() + json.dumps(db().execute("SELECT * FROM audit").fetchall()) \
             + json.dumps(db().execute("SELECT * FROM logins").fetchall())
check("correct horse" not in everything, "the password is in no log line, audit row or sign-in row")
check(cookie not in everything and csrf not in everything, "no session token or CSRF token in the logs")

# --- an unsafe database or folder is refused, a damaged one explained
os.chmod(admin.DB_PATH, 0o644)
try:
    with admin.db(): pass
    check(False, "a 644 database was used")
except RuntimeError:
    check(True, "a database readable by others is refused")
os.chmod(admin.DB_PATH, 0o600)
os.chmod(admin.DB_PATH.parent, 0o755)
try:
    with admin.db(): pass
    check(False, "a database in an open folder was used")
except RuntimeError:
    check(True, "a database in a folder others can read is refused")
os.chmod(admin.DB_PATH.parent, 0o700)
st, j, _ = req("GET", "/api/session", origin=None)
check(st == 200, "the server still answers after those checks")
bad_db = tmp / "damaged"; bad_db.mkdir(mode=0o700)
(bad_db / "admin.db").write_bytes(b"this is not a database" * 100); os.chmod(bad_db / "admin.db", 0o600)
out = subprocess.run(["python3", "$REPO/scripts/admin.py", "unlock"], capture_output=True, text=True,
                     env={**os.environ, "MINI_DEPLOY_ADMIN_DB": str(bad_db / "admin.db")})
check(out.returncode == 1 and "damaged" in out.stderr and "Traceback" not in out.stderr,
      "a damaged database: a clear message, no traceback")
sys.exit(1 if bad_count else 0)
PY

echo
echo "== 1b. GitHub repos from the admin page (temp database and token file) =="
python3 - <<'PY' || fail=1
import io, json, os, re, sqlite3, sys, tempfile, threading, http.client
from pathlib import Path

tmp = Path(tempfile.mkdtemp(prefix="mini-deploy-admintest-repos-"))   # removed by hand, like the others
os.environ["MINI_DEPLOY_TESTING"] = "1"
os.environ["MINI_DEPLOY_ADMIN_DB"] = str(tmp / "admin.db")
os.environ["MINI_DEPLOY_TOKEN_FILE"] = str(tmp / "github-token")
sys.path.insert(0, "/mnt/c/Users/indra/Code/mini-deploy/scripts")
import deploy, admin, repos
deploy.SITES = tmp / "sites"; deploy.SITES.mkdir()
deploy.LOG_FILE = tmp / "deploy.log"
admin.HOME_FILE = tmp / "home-lan"

PORT = 9311
class TestServer(admin.Server):
    deadline = 5
srv = TestServer(("127.0.0.1", PORT), admin.Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
HOST, ORIGIN = admin.HOST, admin.ORIGIN
journal = io.StringIO()
admin.print = lambda *a, **k: journal.write(" ".join(str(x) for x in a) + "\n")
deploy.print = lambda *a, **k: None

bad_count = 0
def check(ok, msg):
    global bad_count
    print(("ok    " if ok else "FAIL  ") + msg)
    bad_count += not ok

def req(method, path, body=None, cookie=None, csrf=None, origin=ORIGIN, ctype="application/json"):
    h = {"Host": HOST}
    if origin: h["Origin"] = origin
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        h["Content-Type"] = ctype
    if cookie: h["Cookie"] = f"{admin.COOKIE}={cookie}"
    if csrf: h["X-CSRF-Token"] = csrf
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=60)
    c.request(method, path, body=data, headers=h)
    r = c.getresponse(); b = r.read(); c.close()
    return r.status, b, r

def jbody(b):
    try: return json.loads(b)
    except ValueError: return {}

PW = "correct horse battery staple 42"
admin.set_password(PW)
st, b, r = req("POST", "/api/login", {"password": PW})
csrf = jbody(b).get("csrf")
sc = r.getheader("Set-Cookie") or ""
cookie = sc.split(";")[0].split("=", 1)[1] if sc.startswith(admin.COOKIE + "=") else None
check(st == 200 and bool(cookie) and bool(csrf), "signed in (session cookie and CSRF token)")

CONNECT = "/api/repos/connect"
SITE = {"repo": "owner/site", "app": "adm-repo", "kind": "static", "subdir": "site"}
st, b, _ = req("POST", CONNECT, SITE)
check(st == 401, "connect without a session: 401")
st, b, _ = req("POST", CONNECT, SITE, cookie=cookie)
check(st == 403, "connect without the CSRF token: 403")
st, b, _ = req("POST", CONNECT, SITE, cookie=cookie, csrf=csrf, origin="http://evil.localhost:8080")
check(st == 403, "connect from another app's page (wrong Origin): 403")
st, b, _ = req("POST", CONNECT, b"repo=owner%2Fsite", cookie=cookie, csrf=csrf, ctype="application/x-www-form-urlencoded")
check(st == 415, "a form post is refused (JSON only)")

st, b, _ = req("POST", CONNECT, SITE, cookie=cookie, csrf=csrf)
made = jbody(b)
secret, hook_id = made.get("secret", ""), made.get("hook_id", "")
check(st == 200 and re.fullmatch(r"[0-9a-f]{32}", hook_id) is not None and re.fullmatch(r"[0-9a-f]{64}", secret) is not None,
      "connect: an address and a 64-hex secret, in the answer to this request")
st, b, _ = req("POST", CONNECT, {"repo": "owner/site", "app": "adm-other", "kind": "static", "subdir": "site"}, cookie=cookie, csrf=csrf)
check(st == 400 and "already" in jbody(b).get("error", ""), "the same repo twice: refused")
st, b, _ = req("POST", CONNECT, {"repo": "OWNER/Site", "app": "adm-other", "kind": "static", "subdir": "site"}, cookie=cookie, csrf=csrf)
check(st == 400 and "already" in jbody(b).get("error", ""), "the same repo in other letter case: refused")
st, b, _ = req("POST", CONNECT, {"repo": "owner/whole", "app": "adm-whole", "kind": "static"}, cookie=cookie, csrf=csrf)
check(st == 400 and "sub-folder" in jbody(b).get("error", ""), "static without a sub-folder (would publish the whole repo): refused")
(deploy.SITES / "adm-taken" / "releases").mkdir(parents=True)
st, b, _ = req("POST", CONNECT, {"repo": "owner/taken", "app": "adm-taken", "kind": "static", "subdir": "s"}, cookie=cookie, csrf=csrf)
check(st == 200 and jbody(b).get("replaces_existing") is True, "an app that already exists: connected, and the answer says the first push replaces it")
req("POST", "/api/repos/disconnect", {"repo": "owner/taken"}, cookie=cookie, csrf=csrf)
BAD = [("reserved app name", {"repo": "owner/x", "app": "admin", "kind": "static"}),
       ("bad repo name", {"repo": "../etc", "app": "adm-x", "kind": "static"}),
       ("unknown kind", {"repo": "owner/y", "app": "adm-y", "kind": "exec"}),
       ("bad branch", {"repo": "owner/z", "app": "adm-z", "kind": "static", "branch": "a..b"}),
       ("sub-folder with ..", {"repo": "owner/w", "app": "adm-w", "kind": "static", "subdir": "../x"}),
       ("previews on a name too long for them", {"repo": "owner/v", "app": "a" * 40, "kind": "build", "previews": True})]
for label, payload in BAD:
    st, b, _ = req("POST", CONNECT, payload, cookie=cookie, csrf=csrf)
    check(st == 400, f"refused: {label}")

st, b, _ = req("GET", "/api/state", cookie=cookie)
check(st == 200 and secret.encode() not in b and hook_id.encode() in b,
      "the page state lists the repo with its address, never the secret")

st, b, _ = req("POST", "/api/repos/rotate", {"repo": "owner/site"}, cookie=cookie, csrf=csrf)
rot = jbody(b)
check(st == 200 and re.fullmatch(r"[0-9a-f]{64}", rot.get("secret", "")) is not None
      and rot["secret"] != secret and rot.get("hook_id") == hook_id,
      "rotate: a new secret, the same address, only in this answer")
st, b, _ = req("POST", "/api/repos/disconnect", {"repo": "owner/site"}, cookie=cookie, csrf=csrf)
check(st == 200, "disconnect")
st, b, _ = req("POST", "/api/repos/disconnect", {"repo": "owner/site"}, cookie=cookie, csrf=csrf)
check(st == 400, "disconnect twice: refused")

TOKEN = "github_pat_TESTONLY" + "x" * 24     # test value only
st, b, _ = req("POST", "/api/token", {"token": "not-a-token"}, cookie=cookie, csrf=csrf)
check(st == 400 and b"not-a-token" not in b, "a bad token is refused and not echoed")
st, b, _ = req("POST", "/api/token", {"token": TOKEN}, cookie=cookie, csrf=csrf)
check(st == 500 and TOKEN.encode() not in b, "no token file yet: a clear error, the token not echoed")
os.mkfifo(tmp / "github-token")
st, b, _ = req("POST", "/api/token", {"token": TOKEN}, cookie=cookie, csrf=csrf)
check(st == 500, "a FIFO at the token path: refused at once, the request does not hang")
os.unlink(tmp / "github-token")
(tmp / "github-token").write_text("")
os.chmod(tmp / "github-token", 0o644)
(tmp / "github-token").write_text("github_pat_OLDVALUE" + "y" * 24 + "\n")
st, b, _ = req("POST", "/api/token", {"token": TOKEN}, cookie=cookie, csrf=csrf)
check(st == 500 and "OLDVALUE" in (tmp / "github-token").read_text(),
      "a token file others can read: refused, and the old content is not emptied first")
(tmp / "github-token").write_text("")
os.chmod(tmp / "github-token", 0o600)
st, b, _ = req("POST", "/api/token", {"token": TOKEN}, cookie=cookie, csrf=csrf)
check(st == 200 and TOKEN.encode() not in b and jbody(b).get("token") == "set",
      "token saved; the answer says 'set' and never shows it")
check((tmp / "github-token").read_text().strip() == TOKEN, "the token is in its own file")
st, b, _ = req("GET", "/api/state", cookie=cookie)
check(jbody(b).get("token") == "set" and TOKEN.encode() not in b, "state says the token is set, without the value")

# Redeploy: the page only asks (a request file); the webhook does the work
ACTION = "/api/action"
req("POST", CONNECT, {"repo": "owner/redo", "app": "adm-redo", "kind": "static", "subdir": "site"}, cookie=cookie, csrf=csrf)
st, b, _ = req("POST", ACTION, {"action": "redeploy", "app": "adm-redo"}, cookie=cookie)
check(st == 403, "redeploy without the CSRF token: 403")
spool = tmp / "redeploy" / "adm-redo.json"
st, b, _ = req("POST", ACTION, {"action": "redeploy", "app": "adm-redo"}, cookie=cookie, csrf=csrf)
check(st == 200 and jbody(b).get("repo") == "owner/redo", f"redeploy of a connected app that never went live: asked for ({st})")
check(spool.is_file() and json.loads(spool.read_text()) == {"app": "adm-redo"}
      and oct(spool.stat().st_mode & 0o777) == "0o600" and oct((tmp / "redeploy").stat().st_mode & 0o777) == "0o700",
      "the request is a 600 file holding only the app name, in a 700 folder")
st, b, _ = req("POST", ACTION, {"action": "redeploy", "app": "adm-redo"}, cookie=cookie, csrf=csrf)
check(st == 409 and "already waiting" in jbody(b).get("error", ""), "a second redeploy while one waits: 409")
(deploy.SITES / "adm-zip" / "releases").mkdir(parents=True)
for label, app, want in (("an app not deployed from GitHub (an upload)", "adm-zip", 409),
                         ("a preview name", "feature--adm-redo", 409), ("a reserved name", "admin", 400),
                         ("a bad name", "../x", 400)):
    st, b, _ = req("POST", ACTION, {"action": "redeploy", "app": app}, cookie=cookie, csrf=csrf)
    check(st == want and not (tmp / "redeploy" / f"{app}.json").exists(), f"redeploy refused: {label} ({st})")
st, b, _ = req("GET", "/api/state", cookie=cookie)
check(any(r.get("app") == "adm-redo" for r in jbody(b).get("repos", [])), "the page sees which apps a repo deploys (for the button)")

con = sqlite3.connect(admin.DB_PATH)
audit_text = " ".join(str(x) for row in con.execute("SELECT action, app, result FROM audit") for x in row)
con.close()
check("redeploy adm-redo ok" in audit_text and "redeploy adm-zip refused" in audit_text, "redeploys are audited, refusals too")
check(all(a in audit_text for a in ("connect", "rotate-secret", "disconnect", "set-token")),
      "every change is in the audit log")
seen = audit_text + journal.getvalue()
check(secret not in seen and rot["secret"] not in seen and TOKEN not in seen,
      "no secret or token in the audit log or the server's journal lines")

srv.shutdown()
sys.exit(1 if bad_count else 0)
PY

echo
echo "== 1c. the phone-anywhere addresses come from the Caddyfile (P5) =="
python3 - <<'PY' || fail=1
import sys, tempfile
from pathlib import Path
sys.path.insert(0, "/mnt/c/Users/indra/Code/mini-deploy/scripts")
import admin
bad = 0
def check(ok, msg):
    global bad
    print(("ok    " if ok else "FAIL  ") + msg)
    bad += not ok
real = admin.tailnet_urls()
check(real.get("aftersleep") == "https://mini-deploy.tail206989.ts.net:8443/",
      f"the real Caddyfile gives After Sleep its address ({real})")
tmp = Path(tempfile.mkdtemp(prefix="mini-deploy-admintest-caddy-"))   # removed by hand
(tmp / "Caddyfile").write_text(
    "https://box.tail1.ts.net:8443 {\r\n    import phone_app one\r\n}\r\n"     # CRLF (a Windows checkout)
    "https://box.tail1.ts.net:8444 {\n    import phone_app Two\n}\n"          # bad app name
    "http://box.tail1.ts.net:8445 {\n    import phone_app three\n}\n"         # not https
    "https://box.example.com:8446 {\n    import phone_app four\n}\n"          # not a ts.net name
    "https://box.tail1.ts.net:8447 {\n    respond hi\n    import phone_app five\n}\n"   # not the two-line shape
    "https://box.tail1.ts.net:8448 {\n    import phone_app six\n}\n")
admin.CADDYFILE = tmp / "Caddyfile"
got = admin.tailnet_urls()
check(got == {"one": "https://box.tail1.ts.net:8443/", "six": "https://box.tail1.ts.net:8448/"},
      f"only well-formed https *.ts.net lines with a valid app name count ({got})")
admin.CADDYFILE = tmp / "missing"
check(admin.tailnet_urls() == {}, "no Caddyfile: no addresses, no error")
sys.exit(1 if bad else 0)
PY

echo
echo "== 2. Caddy's gate in front of the real service =="
systemctl is-active --quiet mini-deploy-admin && ok "mini-deploy-admin is running" || bad "mini-deploy-admin is not running"
code() { curl -s -o /dev/null -w "%{http_code}" -m 5 "$@"; }
[ "$(code -H 'Host: admin.localhost:8080' http://127.0.0.1:8080/)" = 200 ] && ok "admin.localhost from this PC: 200" || bad "admin page from this PC"
[ "$(code -H 'Host: admin.localhost:8080' -H 'X-Forwarded-For: 1.2.3.4' http://127.0.0.1:8080/)" = 404 ] \
  && ok "with a proxy header: 404" || bad "proxy header was let through"
[ "$(code -H 'Host: admin.localhost:8080' -H 'Tailscale-User-Login: x' http://127.0.0.1:8080/)" = 404 ] \
  && ok "with a Tailscale header: 404" || bad "Tailscale header was let through"
[ "$(code -H 'Host: ADMIN.localhost:8080' http://127.0.0.1:8080/)" = 404 ] && ok "another spelling of the name: 404" || bad "mixed-case host"
[ "$(code -H 'Host: admin.localhost:8080' http://127.0.0.1:8080/api/state)" = 401 ] && ok "state without a session: 401" || bad "state was open"
[ "$(code -X POST -H 'Host: admin.localhost:8080' -H 'Origin: http://aftersleep.localhost:8080' -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:8080/api/action)" = 403 ] \
  && ok "a change from another app's page: 403" || bad "cross-app post"
mkdir -p /tmp/mini-deploy-admintest-src && echo hi > /tmp/mini-deploy-admintest-src/index.html
out=$(python3 "$REPO/scripts/deploy.py" deploy admin /tmp/mini-deploy-admintest-src 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q reserved <<<"$out" && ok "nobody can deploy an app called admin" || bad "deploy to 'admin': $out"
for p in /etc/mini-deploy/env /etc/mini-deploy/apps /run/docker.sock; do
  grep -q "$p" /etc/systemd/system/mini-deploy-admin.service && ok "the service cannot see $p" || bad "$p is not blocked in the unit"
done

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOMETHING FAILED"; fi
exit $fail
