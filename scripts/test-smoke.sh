#!/usr/bin/env bash
# Smoke test after each deploy (deploy.py smoke_test): a release whose page is empty, or
# whose own files are missing or fail over HTTP, is switched back at once, the app is held
# (like a rollback), and the deploy is logged as a failure. A release that loads is kept.
# Everything happens in a temp folder (/tmp/mini-deploy-smoketest-*): fake /sites, a fake
# deploy log, and a test server on a free port that stands in for Caddy. Nothing live is
# touched and nothing is deleted here. Pass = ALL PASSED.
set -uo pipefail
REPO=/mnt/c/Users/indra/Code/mini-deploy
export REPO
fail=0

echo "== 1. good, broken and blank releases (temp sites, test server) =="
python3 - <<'PY' || fail=1
import contextlib, http.server, io, os, socket, sys, tempfile, threading, time, urllib.parse
from pathlib import Path

tmp = Path(tempfile.mkdtemp(prefix="mini-deploy-smoketest-"))  # removed by hand, like other test folders
os.environ["MINI_DEPLOY_TESTING"] = "1"
sys.path.insert(0, os.environ["REPO"] + "/scripts")
import deploy, dashboard
deploy.SITES = tmp / "sites"; deploy.SITES.mkdir()
deploy.LOG_FILE = tmp / "deploy.log"           # never the real deploy log
deploy.SMOKE_PAUSE = 0                         # retries need not wait in a test

ERRORS = {}   # path -> status the test server answers instead of the file
BLANK = set() # paths the test server answers 200 with an empty body

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def send(self, code, body):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        # Like Caddy: the Host header names the app, and the app's `current` link is served.
        host = (self.headers.get("Host") or "").split(":")[0]
        path = urllib.parse.unquote(self.path.split("?")[0])
        if not host.endswith(".localhost"):
            return self.send(404, b"no")
        app = host[:-len(".localhost")]
        if path in ERRORS:
            return self.send(ERRORS[path], b"error")
        if path in BLANK:
            return self.send(200, b"")
        rel = "index.html" if path == "/" else path.lstrip("/")
        f = deploy.SITES / app / "current" / rel
        if ".." in rel or not f.is_file():
            return self.send(404, b"not found")
        self.send(200, f.read_bytes())

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
TEST_URL = "http://127.0.0.1:%d" % srv.server_address[1]
os.environ["MINI_DEPLOY_SMOKE_URL"] = TEST_URL

bad_count = 0
def check(cond, msg):
    global bad_count
    print(("ok    " if cond else "FAIL  ") + msg); bad_count += not cond

def make_src(name, index_html, files=None):
    src = tmp / name
    src.mkdir()
    (src / "index.html").write_text(index_html)
    for rel, body in (files or {}).items():
        (src / rel).parent.mkdir(parents=True, exist_ok=True)
        (src / rel).write_text(body)
    return src

def deploy_app(app, src):
    """The DeployError text, or None when the release went live."""
    time.sleep(1.1)  # release ids are per second
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            deploy.deploy(app, src)
        return None
    except deploy.DeployError as e:
        return str(e)

def live(app):
    return deploy.current_id(deploy.SITES / app / "current")

def last_log(n=1):
    lines = deploy.LOG_FILE.read_text().splitlines() if deploy.LOG_FILE.exists() else []
    return lines[-n:]

GOOD = '<!doctype html><html><body><h1>Hello</h1><script src="app.js"></script></body></html>'
FILES = {"app.js": "console.log(1)"}
APP = "smk-one"

# A good release goes live and stays.
e = deploy_app(APP, make_src("v1", GOOD, FILES))
v1 = live(APP)
check(e is None and v1 is not None, "a good release goes live and passes the smoke test")
check(not deploy.is_held(deploy.SITES / APP), "a good release does not hold the app")

# An empty page is switched back at once.
e = deploy_app(APP, make_src("v2", "   \n"))
check(e is not None and "smoke test failed: index.html is empty" in e, "an empty page is refused")
check(e is not None and ("rolled back to %s" % v1) in e, "the error names the release it went back to")
check(live(APP) == v1, "the previous release is live again")
check(deploy.is_held(deploy.SITES / APP), "the app is held after the switch back, like a rollback")
parts = last_log()[0].split() if last_log() else []
check(len(parts) > 5 and parts[2] == "deploy" and parts[4] == "fail" and "smoke test failed" in last_log()[0],
      "the deploy is logged as a failure with the reason")

# Unhold, then a release whose own file is missing from the folder.
deploy.unhold(APP) if deploy.is_held(deploy.SITES / APP) else None
e = deploy_app(APP, make_src("v3", '<script src="missing.js"></script><p>x</p>'))
check(e is not None and "missing.js is missing from the new release" in e, "a page that loads a missing file is refused")
check(live(APP) == v1, "the previous release is live after a missing file")

# A file that is on disk but answers 500 over HTTP (the server, not the folder, is wrong).
ERRORS["/broken.css"] = 500
e = deploy_app(APP, make_src("v4", '<link rel="stylesheet" href="/broken.css"><p>x</p>', {"broken.css": "p{}"}))
check(e is not None and "/broken.css answered 500" in e, "a file that answers 500 over HTTP is refused")
check(live(APP) == v1, "the previous release is live after a 500 file")
ERRORS.clear()

# An empty front page over HTTP (200 with no body), though the folder has a page.
BLANK.add("/")
e = deploy_app(APP, make_src("v5", GOOD, FILES))
check(e is not None and "answered 200 with an empty body" in e, "a 200 with an empty body is refused")
check(live(APP) == v1, "the previous release is live after a blank HTTP page")
BLANK.clear()

# A release that loads over HTTP is kept (after the earlier holds, a deploy still goes live).
deploy.unhold(APP) if deploy.is_held(deploy.SITES / APP) else None
e = deploy_app(APP, make_src("v6", GOOD, FILES))
v6 = live(APP)
check(e is None and v6 != v1, "a release that loads over HTTP goes live")

# Caddy not answering: the disk checks still count, the release is kept, and a warning says so.
s = socket.socket(); s.bind(("127.0.0.1", 0)); closed = s.getsockname()[1]; s.close()
os.environ["MINI_DEPLOY_SMOKE_URL"] = "http://127.0.0.1:%d" % closed
err = io.StringIO()
time.sleep(1.1)
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
    deploy.deploy(APP, make_src("v7", GOOD, FILES))
v7 = live(APP)
check(v7 is not None and v7 != v6, "with Caddy not answering, the release is kept")
check("HTTP part skipped" in err.getvalue(), "and the log says the HTTP part was skipped")
os.environ["MINI_DEPLOY_SMOKE_URL"] = TEST_URL

# A first release that is blank: nothing to switch back to, so it stays up and the app is held.
APP2 = "smk-two"
e = deploy_app(APP2, make_src("w1", "   \n"))
check(e is not None and "no earlier release to go back to" in e, "a blank first release says there is nothing to go back to")
check(live(APP2) is not None, "the blank first release stays live (nothing to switch to)")
check(deploy.is_held(deploy.SITES / APP2), "and the app is held until it is fixed")

# Without MINI_DEPLOY_SMOKE_URL (the normal test setting) the HTTP part is off, so a test
# run never checks the real Caddy with made-up names.
del os.environ["MINI_DEPLOY_SMOKE_URL"]
ERRORS["/broken.css"] = 500
e = deploy_app("smk-three", make_src("x1", '<link rel="stylesheet" href="/broken.css"><p>x</p>', {"broken.css": "p{}"}))
check(e is None, "with no test URL, only the disk checks run (a 500 file is not seen)")
ERRORS.clear()

# Outside the test setting, a folder other than /sites is not checked over HTTP either (Caddy
# serves only /sites): the webhook tests deploy into temp folders this way.
os.environ.pop("MINI_DEPLOY_TESTING")
check(deploy._smoke_target() is None, "a sites folder other than /sites is not checked over HTTP")
ERRORS["/broken.css"] = 500
e = deploy_app("smk-four", make_src("y1", '<link rel="stylesheet" href="/broken.css"><p>x</p>', {"broken.css": "p{}"}))
check(e is None, "and a 500 file there goes live (only the disk checks ran)")
ERRORS.clear()
os.environ["MINI_DEPLOY_TESTING"] = "1"

# What the admin page shows: fixed words, never the error text.
for detail, want in [
    ("smoke test failed: index.html is empty; rolled back to 20261024-100000; held: deploy.py unhold x", "smoke test failed, switched back"),
    ("smoke test failed: index.html is empty; no earlier release to go back to, so it stays live; held: x", "smoke test failed, nothing to switch to"),
    ("smoke test failed: /x answered 500", "smoke test failed"),
]:
    shown = dashboard.public_detail("deploy", "fail", detail)
    check(want in shown and "/" not in shown and "index" not in shown, "the page shows %r" % want)

print("test folder: %s" % tmp)
print("ALL PASSED" if bad_count == 0 else "SOMETHING FAILED")
sys.exit(1 if bad_count else 0)
PY

if [ $fail -eq 0 ]; then echo "ALL PASSED"; else echo "SOMETHING FAILED"; fi
exit $fail
