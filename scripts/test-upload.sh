#!/usr/bin/env bash
# Upload deploys test (scripts/upload.py and POST /api/upload/<app> in scripts/admin.py, P4).
# Part 1 checks the zip checker with hand-made hostile zips. Part 2 runs the admin server on a
# test port with a TEMP database, TEMP /sites and a TEMP deploy log. Part 3 deploys one upload
# into the real /sites (a test app, left for the cleanup like every suite's) and fetches it
# through Caddy. Part 4 checks the real service behind Caddy. Nothing is deleted here.
# Pass = every check ok.
set -uo pipefail
export MINI_DEPLOY_NO_DASHBOARD=1
fail=0

echo "== 1. the zip checker (upload.py) =="
python3 - <<'PY' || fail=1
import io, os, stat, struct, sys, tempfile, warnings, zipfile
from pathlib import Path
sys.path.insert(0, "/mnt/c/Users/indra/Code/mini-deploy/scripts")
import upload

tmp = Path(tempfile.mkdtemp(prefix="mini-deploy-uploadtest-"))   # removed by hand, like the others
bad_count = 0
def check(ok, msg):
    global bad_count
    print(("ok    " if ok else "FAIL  ") + msg)
    bad_count += not ok

n = 0
def zbuild(items):
    """items: (name, data[, options]). Options: mode (Unix mode, made on Unix), system, attr, method."""
    global n
    n += 1
    p = tmp / f"z{n}.zip"
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")          # duplicate names are made on purpose
        with zipfile.ZipFile(p, "w") as zf:
            for it in items:
                name, data, opts = it[0], it[1], (it[2] if len(it) > 2 else {})
                zi = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
                zi.compress_type = opts.get("method", zipfile.ZIP_DEFLATED)
                if "mode" in opts:
                    zi.create_system, zi.external_attr = 3, opts["mode"] << 16
                if "system" in opts:
                    zi.create_system = opts["system"]
                if "attr" in opts:
                    zi.external_attr = opts["attr"]
                zf.writestr(zi, data)
    return p

def run(p):
    """-> (root or None, error text or None, the destination folder)"""
    dest = tmp / f"d{n}-{p.stem}"
    dest.mkdir()
    try:
        return upload.unpack(p, dest), None, dest
    except upload.UploadError as e:
        return None, str(e), dest

def refused(p, label, words, before_writing=True):
    root, err, dest = run(p)
    ok = root is None and err is not None and words in err
    if before_writing:
        ok = ok and not any(dest.iterdir())
    check(ok, f"refused: {label}" + (" (nothing written)" if before_writing else "") +
          ("" if ok else f"  [got {err!r}]"))

def patch(p, sig, offset, fmt, value, last=False):
    b = bytearray(p.read_bytes())
    i = b.rfind(sig) if last else b.find(sig)
    struct.pack_into(fmt, b, i + offset, value)
    p.write_bytes(bytes(b))

INDEX = ("index.html", b"<h1>ok</h1>")

# --- good zips
p = zbuild([INDEX, ("css/site.css", b"body{}"), ("img/a.txt", b"x" * 1000)])
root, err, dest = run(p)
check(root == dest and (dest / "css" / "site.css").read_bytes() == b"body{}", "a plain site unpacks at its root")
modes = {q.relative_to(dest).as_posix(): stat.S_IMODE(q.stat().st_mode) for q in dest.rglob("*")}
check(modes.get("index.html") == 0o644 and modes.get("css") == 0o755, "files 0644, folders 0755")

p = zbuild([("site/index.html", b"<h1>top</h1>"), ("site/css/a.css", b"a{}")])
root, err, dest = run(p)
check(root == dest / "site", "one top folder (Windows 'Compress'): that folder is the site")

p = zbuild([("site/index.html", b"x"), ("__MACOSX/site/._index.html", b"junk"), ("site/.DS_Store", b"junk")])
root, err, dest = run(p)
check(root == dest / "site" and not (dest / "__MACOSX").exists() and not (dest / "site" / ".DS_Store").exists(),
      "macOS junk (__MACOSX, .DS_Store) is skipped, not written")

p = zbuild([INDEX, ("run.sh", b"#!/bin/sh", {"mode": stat.S_IFREG | 0o4755})])
root, err, dest = run(p)
check(root is not None and stat.S_IMODE((dest / "run.sh").stat().st_mode) == 0o644,
      "a setuid/executable mode in the zip is ignored: written as 0644")

# --- names
refused(zbuild([INDEX, ("../evil-marker.html", b"x")]), "'../' in a name", "outside")
refused(zbuild([INDEX, ("a/../../evil-marker.html", b"x")]), "'..' inside a path", "outside")
refused(zbuild([INDEX, ("/etc/evil-marker", b"x")]), "an absolute path", "absolute")
refused(zbuild([INDEX, ("C:/evil-marker", b"x")]), "a Windows drive path", "absolute")
refused(zbuild([INDEX, ("a\\..\\evil-marker", b"x")]), "a backslash path", "\\")
refused(zbuild([INDEX, ("bad\x01name.html", b"x")]), "a control character in a name", "control")
refused(zbuild([INDEX, ("a//b.html", b"x")]), "an empty path part", "malformed")
refused(zbuild([INDEX, ("x" * 300 + ".html", b"x")]), "a name part over 255 bytes", "too long")
refused(zbuild([INDEX, ("dup.html", b"1"), ("dup.html", b"2")]), "the same name twice", "twice")
refused(zbuild([INDEX, ("Page.html", b"1"), ("page.html", b"2")]), "the same name in other letter case", "twice")
refused(zbuild([INDEX, ("a", b"file"), ("a/b.html", b"x")]), "a name used as file and folder", "both")
for bad in (".env", ".env.local", ".ENV", ".git/config", "sub/.npmrc", ".ssh/id_rsa"):
    refused(zbuild([INDEX, (bad, b"x")]), f"{bad!r} (never published)", "never be published")

# --- entry types
refused(zbuild([INDEX, ("link", b"/etc/passwd", {"mode": stat.S_IFLNK | 0o777})]), "a symlink", "link")
refused(zbuild([INDEX, ("dev", b"", {"mode": stat.S_IFCHR | 0o644})]), "a device file", "special")
refused(zbuild([INDEX, ("fifo", b"", {"mode": stat.S_IFIFO | 0o644})]), "a FIFO", "special")
refused(zbuild([INDEX, ("win-link", b"x", {"system": 0, "attr": 0x400})]), "a Windows link (reparse point)", "link")
# zipfile clears the flags when it writes, so the "encrypted" bit is set in the headers afterwards
# (local header at offset 6, list of files at offset 8), as a real encrypted zip has it.
p = zbuild([("secret.html", b"x")])
patch(p, b"PK\x03\x04", 6, "<H", 0x1)
patch(p, b"PK\x01\x02", 8, "<H", 0x1)
refused(p, "an encrypted entry", "encrypted")
refused(zbuild([INDEX, ("b.html", b"x" * 100, {"method": zipfile.ZIP_BZIP2})]), "an unusual compression method", "compression")

# --- sizes
p = tmp / "bomb.zip"
with zipfile.ZipFile(p, "w", zipfile.ZIP_DEFLATED) as zf:
    zf.writestr(*INDEX)
    with zf.open("zeros.bin", "w") as w:
        for _ in range(60):
            w.write(bytes(1024 * 1024))          # 60 MB of zeros: about 60 KB packed
refused(p, "a zip bomb (60 MB of zeros, ratio about 1000:1)", "zip bomb")

p = zbuild([INDEX, ("big.bin", b"y" * 10)])
patch(p, b"PK\x01\x02", 24, "<I", 250 * 1024 * 1024)   # says 250 MB unpacked
refused(p, "a site over 200 MB unpacked (from the zip's own list)", "200 MB")

p = zbuild([INDEX, ("lie.bin", os.urandom(4000))])
patch(p, b"PK\x01\x02", 24, "<I", 5)                    # says 5 bytes, holds 4000
refused(p, "a zip that lies about a size (more data than it says)", "", before_writing=False)

p = tmp / "many.zip"
with zipfile.ZipFile(p, "w") as zf:
    zf.writestr(*INDEX)
    for i in range(5001):
        zf.writestr(f"f/{i}.txt", b"")
refused(p, "more than 5,000 entries", "5000")

p = zbuild([INDEX])
patch(p, b"PK\x05\x06", 12, "<I", 5 * 1024 * 1024, last=True)
refused(p, "a list of files over 1.5 MB (checked before zipfile parses it)", "list of files")

p = zbuild([INDEX])
patch(p, b"PK\x05\x06", 10, "<H", 0xFFFF, last=True)
refused(p, "the zip64 format", "zip64")

# --- not a site
p = tmp / "noise.zip"; p.write_bytes(os.urandom(5000))
refused(p, "random bytes", "not a zip")
p = tmp / "text.zip"; p.write_bytes(b"just text\n" * 100)
refused(p, "a text file called .zip", "not a zip")
p = tmp / "empty.zip"
zipfile.ZipFile(p, "w").close()
refused(p, "an empty zip", "no files")
refused(zbuild([("about.html", b"x")]), "no index.html", "index.html", before_writing=False)
refused(zbuild([("a/index.html", b"x"), ("b/index.html", b"x")]), "two top folders, no index.html at the top",
        "index.html", before_writing=False)

check(not (tmp / "evil-marker.html").exists() and not (tmp.parent / "evil-marker.html").exists()
      and not Path("/etc/evil-marker").exists(), "nothing was written outside the destination folders")
sys.exit(1 if bad_count else 0)
PY

echo
echo "== 2. POST /api/upload/<app> (temp database, temp apps, test port) =="
python3 - <<'PY' || fail=1
import fcntl, io, json, os, socket, sqlite3, sys, tempfile, threading, time, zipfile, http.client
from pathlib import Path

tmp = Path(tempfile.mkdtemp(prefix="mini-deploy-uploadtest-srv-"))   # removed by hand
os.environ["MINI_DEPLOY_TESTING"] = "1"
os.environ["MINI_DEPLOY_ADMIN_DB"] = str(tmp / "admin.db")
sys.path.insert(0, "/mnt/c/Users/indra/Code/mini-deploy/scripts")
import deploy, admin, repos, upload, admindb
deploy.SITES = tmp / "sites"; deploy.SITES.mkdir()
deploy.LOG_FILE = tmp / "deploy.log"
admin.HOME_FILE = tmp / "home-lan"
upload.TMP_ROOT = str(tmp / "work"); (tmp / "work").mkdir()

PORT = 9312
class TestServer(admin.Server):
    deadline = 5
srv = TestServer(("127.0.0.1", PORT), admin.Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
HOST, ORIGIN = admin.HOST, admin.ORIGIN
journal = io.StringIO()
jlock = threading.Lock()
def capture(*a, **k):
    with jlock:
        journal.write(" ".join(str(x) for x in a) + "\n")
admin.print = capture
deploy.print = lambda *a, **k: None

bad_count = 0
def check(ok, msg):
    global bad_count
    print(("ok    " if ok else "FAIL  ") + msg)
    bad_count += not ok

def jbody(b):
    try: return json.loads(b)
    except ValueError: return {}

def req(method, path, body=None, cookie=None, csrf=None, origin=ORIGIN, ctype="application/json", extra=None):
    h = {"Host": HOST}
    if origin: h["Origin"] = origin
    if body is not None:
        h["Content-Type"] = ctype
    if cookie: h["Cookie"] = f"{admin.COOKIE}={cookie}"
    if csrf: h["X-CSRF-Token"] = csrf
    h.update(extra or {})
    data = body if (body is None or isinstance(body, bytes)) else json.dumps(body).encode()
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=60)
    c.request(method, path, body=data, headers=h)
    r = c.getresponse(); b = r.read(); c.close()
    return r.status, b

def raw(data, wait=10):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=wait)
    s.sendall(data)
    out = b""
    try:
        while True:
            chunk = s.recv(4096)
            if not chunk: break
            out += chunk
    except (socket.timeout, ConnectionResetError):
        pass
    s.close()
    return out

def zbytes(files):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data in files:
            zf.writestr(name, data)
    return buf.getvalue()

PW = "correct horse battery staple 42"
admin.set_password(PW)
c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
c.request("POST", "/api/login", body=json.dumps({"password": PW}).encode(),
          headers={"Host": HOST, "Origin": ORIGIN, "Content-Type": "application/json"})
r = c.getresponse(); b = r.read(); c.close()
csrf = jbody(b).get("csrf")
sc = r.getheader("Set-Cookie") or ""
cookie = sc.split(";")[0].split("=", 1)[1] if sc.startswith(admin.COOKIE + "=") else None
check(bool(cookie) and bool(csrf), "signed in (session cookie and CSRF token)")

MARK = b"UPLOAD-CONTENT-MARKER-7f3a"
SITE = zbytes([("index.html", b"<h1>uploaded</h1>" + MARK), ("css/a.css", b"a{}")])
def up(app, body=SITE, **kw):
    kw.setdefault("cookie", cookie); kw.setdefault("csrf", csrf); kw.setdefault("ctype", "application/zip")
    return req("POST", "/api/upload/" + app, body, **kw)

# --- gates (each answered, with the body read and dropped, so the browser sees it)
st, b = up("upl-a", cookie=None)
check(st == 401 and "sign in" in jbody(b).get("error", ""), "no session: 401 (answer arrives)")
st, b = up("upl-a", csrf=None)
check(st == 403, "no CSRF token: 403")
st, b = up("upl-a", csrf="wrong")
check(st == 403, "a wrong CSRF token: 403")
st, b = up("upl-a", origin="http://evil.localhost:8080")
check(st == 403, "another page's Origin: 403")
st, b = up("upl-a", extra={"Sec-Fetch-Site": "cross-site"})
check(st == 403, "Sec-Fetch-Site: cross-site: 403")
st, b = up("upl-a", ctype="application/json")
check(st == 415, "not application/zip: 415")
st, b = up("upl-a", ctype="multipart/form-data; boundary=x")
check(st == 415, "a form upload: 415 (the zip is the body itself)")
head = (f"POST /api/upload/upl-a HTTP/1.1\r\nHost: {HOST}\r\nOrigin: {ORIGIN}\r\nCookie: {admin.COOKIE}={cookie}\r\n"
        f"X-CSRF-Token: {csrf}\r\nContent-Type: application/zip\r\n")
t0 = time.monotonic()
out = raw((head + f"Content-Length: {50 * 1024 * 1024 + 1}\r\n\r\n").encode(), wait=4)
check(out.startswith(b"HTTP/1.0 413") and time.monotonic() - t0 < 3, "over 50 MB: 413 at once, nothing read")
out = raw((head + "\r\n").encode(), wait=4)
check(out.startswith(b"HTTP/1.0 411"), "no Content-Length: 411")
out = raw((head + "Transfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n").encode(), wait=4)
check(out.startswith(b"HTTP/1.0 411"), "chunked: 411")
for cl in ("+5", "-1", "0x10", "1e3", "5 5"):
    out = raw((head + f"Content-Length: {cl}\r\n\r\n").encode(), wait=4)
    check(out.startswith(b"HTTP/1.0 400"), f"Content-Length {cl!r}: 400 before reading")
out = raw((head + "Content-Length: 0\r\n\r\n").encode(), wait=4)
check(out.startswith(b"HTTP/1.0 400"), "an empty upload: 400")
t0 = time.monotonic()
slow = (f"POST /api/upload/upl-a HTTP/1.1\r\nHost: {HOST}\r\nOrigin: {ORIGIN}\r\n"
        f"Content-Type: application/zip\r\nContent-Length: 1000\r\n\r\n").encode()
raw(slow, wait=15)
check(time.monotonic() - t0 < 9, "a stalled upload without a session is cut at the normal deadline")

# --- app names
for app, words in (("admin", "reserved"), ("dashboard", "reserved"), ("logs", "reserved"), ("a--b", "--"),
                   ("Bad", "only a-z"), ("..%2Fetc", "only a-z"), ("a" * 41, "only a-z")):
    st, b = up(app)
    check(st == 400 and words in jbody(b).get("error", ""), f"app name {app[:20]!r}: 400")
st, b = req("POST", "/api/upload/", SITE, cookie=cookie, csrf=csrf, ctype="application/zip")
check(st == 400, "no app name: 400")
with admindb.db() as conn:
    repos.connect(conn, "owner/linked", "upl-linked", kind="static", subdir="site")
st, b = up("upl-linked")
check(st == 409 and "GitHub" in jbody(b).get("error", ""), "an app deployed from GitHub: 409, refused")
check(not (deploy.SITES / "upl-linked").exists(), "  ... and nothing was created for it")
big = os.urandom(5 * 1024 * 1024)
st, b = up("Bad", body=big)
check(st == 400 and jbody(b).get("error"), "a refusal after a 5 MB body still arrives as a clear answer")

# --- a good upload
st, b = up("upl-new")
rel = jbody(b).get("release", "")
root = deploy.SITES / "upl-new"
live = deploy.current_id(root / "current")
check(st == 200 and deploy.ID_RE.fullmatch(rel or "") is not None and live == rel, "a good upload: 200, live at once")
check(MARK in (root / "current" / "index.html").read_bytes() and (root / "current" / "css" / "a.css").is_file(),
      "  ... the live release holds the zip's files")
log = (tmp / "deploy.log").read_text()
check(" upl-new deploy " in log and " ok " in log, "  ... the deploy is in the deploy log")
with sqlite3.connect(admin.DB_PATH) as conn:
    rows = conn.execute("SELECT action, app, result FROM audit WHERE action = 'upload'").fetchall()
check(("upload", "upl-new", "ok") in rows, "  ... and in the audit log")

time.sleep(1.1)   # release ids are per second
st, b = up("upl-new", body=zbytes([("site/index.html", b"<h1>v2</h1>")]))
check(st == 200 and (root / "current" / "index.html").read_bytes() == b"<h1>v2</h1>",
      "a zip with one top folder: that folder's files go live")

deploy.set_hold(root)
time.sleep(1.1)
st, b = up("upl-new")
check(st == 200 and not deploy.is_held(root), "an upload to a held app deploys and lifts the hold (owner's decision)")
before = deploy.current_id(root / "current")

# --- refused zips leave the live site alone
for label, body in (("'../' in a name", zbytes([("index.html", b"x"), ("../evil.html", b"x")])),
                    ("a .env file", zbytes([("index.html", b"x"), (".env", b"KEY=1")])),
                    ("not a zip", b"this is not a zip" * 100),
                    ("no index.html", zbytes([("about.html", b"x")]))):
    st, b = up("upl-new", body=body)
    check(st == 400 and deploy.current_id(root / "current") == before, f"refused: {label}; the live release did not change")
log = (tmp / "deploy.log").read_text()
check(" upl-new upload " in log and " fail " in log, "refused uploads are in the deploy log")

admin.UPLOAD_LOCK.acquire()
try:
    st, b = up("upl-new")
finally:
    admin.UPLOAD_LOCK.release()
check(st == 409 and "another upload" in jbody(b).get("error", ""), "a second upload while one runs: 409")
with sqlite3.connect(admin.DB_PATH) as conn:
    rows = conn.execute("SELECT app, result FROM audit WHERE action = 'upload'").fetchall()
check(("upl-linked", "refused") in rows and ("-", "refused") in rows,
      "refusals after sign-in are audited ('refused'; an invalid name is stored as '-')")

# --- the hold is lifted INSIDE the deploy lock: a rollback right after an upload keeps its hold.
# The rollback starts while the upload's deploy still holds the lock, so it runs exactly in
# the gap that used to exist between "lock released" and "hold cleared".
orig_locked = deploy._deploy_locked
rb = {}
def deploy_then_rollback(src, root_, releases, current):
    out = orig_locked(src, root_, releases, current)
    def roll():
        try:
            deploy.rollback(root_.name, wait=30)
            rb["ok"] = True
        except Exception as e:  # noqa: BLE001
            rb["err"] = repr(e)
    rb["t"] = threading.Thread(target=roll)
    rb["t"].start()
    time.sleep(0.5)          # the rollback is now waiting for the lock this deploy holds
    return out
# And directly: while the hold is lifted, the app's deploy lock must still be held (a second
# flock on it fails).
real_clear = deploy.clear_hold
under_lock = []
def spy_clear(root_):
    fh = open(root_ / ".lock", "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        under_lock.append(False)
        fcntl.flock(fh, fcntl.LOCK_UN)
    except BlockingIOError:
        under_lock.append(True)
    finally:
        fh.close()
    return real_clear(root_)
deploy._deploy_locked = deploy_then_rollback
deploy.clear_hold = spy_clear
try:
    time.sleep(1.1)
    st, b = up("upl-new")
finally:
    deploy._deploy_locked = orig_locked
    deploy.clear_hold = real_clear
rb["t"].join(30)
check(under_lock == [True], "the upload lifts the hold while it still holds the app's deploy lock")
check(st == 200 and rb.get("ok") is True and deploy.is_held(root),
      "a rollback in the moment after an upload keeps its hold" +
      ("" if rb.get("ok") else f"  [{rb.get('err')}]"))

# --- once the new release is live, a failure to lift the hold is only a warning
orig_clear = deploy.clear_hold
def broken_clear(root_):
    raise PermissionError("simulated")
deploy.clear_hold = broken_clear
try:
    time.sleep(1.1)
    st, b = up("upl-new")
finally:
    deploy.clear_hold = orig_clear
check(st == 200 and deploy.current_id(root / "current") == jbody(b).get("release"),
      "a hold that cannot be lifted after going live: still 200 with the new release (not 'error')")
deploy.clear_hold(root)

# --- disk space, a body that arrives too slowly, a failed FIRST upload
before = deploy.current_id(root / "current")
real_du = admin.shutil.disk_usage
admin.shutil.disk_usage = lambda p: real_du(p)._replace(free=10 * 1024 * 1024)
try:
    st, b = up("upl-new")
finally:
    admin.shutil.disk_usage = real_du
check(st == 507 and deploy.current_id(root / "current") == before, "not enough disk space: 507, nothing changed")
real_body_time = admin.UPLOAD_BODY_TIME
admin.UPLOAD_BODY_TIME = -1
try:
    st, b = up("upl-new")
finally:
    admin.UPLOAD_BODY_TIME = real_body_time
check(st == 400 and "too long" in jbody(b).get("error", "") and deploy.current_id(root / "current") == before,
      "a body that arrived too late is refused before deploying (the answer could be cut otherwise)")
orig_check = deploy.check_tree
def failing_copy(path, label):
    if label == "release":
        raise deploy.DeployError("simulated copy failure")
    return orig_check(path, label)
deploy.check_tree = failing_copy
try:
    st, b = up("upl-fresh")
finally:
    deploy.check_tree = orig_check
check(st == 409 and not (deploy.SITES / "upl-fresh" / "releases").exists(),
      "a failed FIRST upload leaves no empty app behind (no releases/ for the dashboard to list)")

# The command line uses the same in-lock lift (deploy.py deploy <app> <dir>).
src = tmp / "cli-src"; src.mkdir()
(src / "index.html").write_text("<h1>cli</h1>")
deploy.set_hold(root)
real_argv = sys.argv
sys.argv = ["deploy.py", "deploy", "upl-new", str(src)]
try:
    rc = deploy.main()
finally:
    sys.argv = real_argv
check(rc == 0 and not deploy.is_held(root), "deploy.py deploy (command line) still lifts a hold")

time.sleep(0.5)
check(not any((tmp / "work").iterdir()), "no temp files are left after uploads (ok or refused)")
with jlock:
    jtext = journal.getvalue()
check(MARK.decode() not in jtext and "KEY=1" not in jtext, "no file content in the server's journal lines")
st, b = req("GET", "/api/state", cookie=cookie)
check(st == 200 and b"upl-new" in b, "the page's state lists the uploaded app")
sys.exit(1 if bad_count else 0)
PY

echo
echo "== 3. an upload goes live through Caddy (real /sites, temp deploy log) =="
python3 - <<'PY' || fail=1
import contextlib, io, os, sys, tempfile, zipfile, http.client
from pathlib import Path
sys.path.insert(0, "/mnt/c/Users/indra/Code/mini-deploy/scripts")
import deploy, upload
tmp = Path(tempfile.mkdtemp(prefix="mini-deploy-uploadtest-live-"))
deploy.LOG_FILE = tmp / "deploy.log"         # never the real deploy log
app = f"upl-live-{os.getpid()}"
mark = f"live upload {os.getpid()}".encode()
z = tmp / "site.zip"
with zipfile.ZipFile(z, "w", zipfile.ZIP_DEFLATED) as zf:
    zf.writestr("site/index.html", b"<h1>" + mark + b"</h1>")
    zf.writestr("site/.hidden-but-fine", b"x")
dest = tmp / "unpacked"; dest.mkdir()
root = upload.unpack(z, dest)
with contextlib.redirect_stdout(io.StringIO()):
    deploy.deploy(app, root)
def get(path):
    c = http.client.HTTPConnection("127.0.0.1", 8080, timeout=10)
    c.request("GET", path, headers={"Host": f"{app}.localhost:8080"})
    r = c.getresponse(); b = r.read(); c.close()
    return r.status, b
st, b = get("/")
ok1 = st == 200 and mark in b
print(("ok    " if ok1 else "FAIL  ") + f"Caddy serves the uploaded site at {app}.localhost:8080")
st, b = get("/.hidden-but-fine")
ok2 = st == 404
print(("ok    " if ok2 else "FAIL  ") + "a dotfile from the zip is not served (Caddy's rule)")
sys.exit(0 if ok1 and ok2 else 1)
PY

echo
echo "== 4. the real service behind Caddy =="
if systemctl is-active --quiet mini-deploy-admin; then echo "ok    mini-deploy-admin is running"; else echo "FAIL  mini-deploy-admin is not running"; fail=1; fi
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Host: admin.localhost:8080' \
  -H 'Origin: http://admin.localhost:8080' -H 'Content-Type: application/zip' \
  --data-binary 'PK' http://127.0.0.1:8080/api/upload/upl-x)
if [ "$code" = "401" ]; then echo "ok    upload without a session through Caddy: 401"; else echo "FAIL  upload without a session through Caddy: $code"; fail=1; fi
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Host: admin.localhost:8080' -H 'X-Forwarded-For: 1.2.3.4' \
  -H 'Origin: http://admin.localhost:8080' -H 'Content-Type: application/zip' \
  --data-binary 'PK' http://127.0.0.1:8080/api/upload/upl-x)
if [ "$code" = "404" ]; then echo "ok    with a proxy header: 404 (Caddy's gate)"; else echo "FAIL  with a proxy header: $code"; fail=1; fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOME CHECKS FAILED"; exit 1; fi
