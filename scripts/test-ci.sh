#!/usr/bin/env bash
# Cheaper Inference forwarder test (scripts/ci_forwarder.py, option A).
# Part 1 runs the forwarder on a test port against a FAKE upstream on loopback: no real key,
# no real address, nothing sent out. The config is a temp file (MINI_DEPLOY_CI_CONFIG).
# Part 2 checks the Caddy route to the real service (which answers without an upstream call).
# It never deletes anything itself. Pass = every check ok.
set -uo pipefail
REPO=/mnt/c/Users/indra/Code/mini-deploy
fail=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }

echo "== 1. the forwarder, against a fake upstream =="
python3 - <<PY || fail=1
import os, sys, threading, json, tempfile, stat, contextlib, io, http.client, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

os.environ["MINI_DEPLOY_TESTING"] = "1"
tmp = Path(tempfile.mkdtemp(prefix="mini-deploy-citest-"))   # removed by hand, like other test folders
os.environ["MINI_DEPLOY_CI_CONFIG"] = str(tmp / "ci.json")
sys.path.insert(0, "$REPO/scripts")
import ci_forwarder as cf

bad_count = 0
def check(ok, msg):
    global bad_count
    print(("ok    " if ok else "FAIL  ") + msg)
    bad_count += not ok

KEY = "sk-test-phone-key-0123456789"    # a fake key: the phone's own key in the test

# --- fake upstream: records every request and streams a two-part answer
seen = []
class Up(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a): pass
    def _answer(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        seen.append({"method": self.command, "path": self.path, "body": body,
                     "headers": {k.lower(): v for k, v in self.headers.items()}})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("x-ci-request-id", "req-123")
        self.send_header("set-cookie", "upstream=1")          # must NOT reach the phone
        self.end_headers()
        self.wfile.write(b"part one "); self.wfile.flush()
        self.wfile.write(b"part two")
    do_GET = do_POST = do_PUT = do_DELETE = _answer
up = ThreadingHTTPServer(("127.0.0.1", 9301), Up)
threading.Thread(target=up.serve_forever, daemon=True).start()

fw = cf.Server(("127.0.0.1", 9302), cf.Handler)
threading.Thread(target=fw.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:9302"

log = io.StringIO()
def call(method, path, body=None, headers=None):
    req = urllib.request.Request(BASE + path, data=body, method=method, headers=headers or {})
    try:
        with contextlib.redirect_stdout(log):
            with urllib.request.urlopen(req, timeout=15) as r:
                return r.status, r.read(), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers

# 1. no config yet: 503, nothing sent anywhere
st, txt, _ = call("GET", "/api/ci/v1/models")
check(st == 503 and b"not configured" in txt, f"no address saved: 503 'not configured' (got {st})")

# 2. the address rules
for bad_addr in ["https://api.example.test/path", "https://api.example.test?x=1",
                 "https://user:pw@api.example.test", "ftp://api.example.test", "api.example.test", ""]:
    try:
        cf.valid_upstream(bad_addr)
        check(False, f"refused address {bad_addr!r}")
    except cf.ConfigError:
        check(True, f"refused address {bad_addr!r}")
check(cf.valid_upstream("https://api.example.test/") == "https://api.example.test", "a plain address is accepted")

# 3. save: owner-only file, and the address is read back from it
cf.save_upstream("http://127.0.0.1:9301")
mode = stat.S_IMODE(os.stat(cf.CONFIG).st_mode)
check(mode == 0o600, f"config saved owner-only (mode {mode:o})")
check(cf.load_upstream() == "http://127.0.0.1:9301", "the saved address is read back")

# 4. a readable-by-others config is refused
os.chmod(cf.CONFIG, 0o644)
st, txt, _ = call("GET", "/api/ci/v1/models")
check(st == 503 and b"can be read by others" in txt, f"a 644 config is refused (got {st})")
os.chmod(cf.CONFIG, 0o600)

# 5. a good inference call: the path, the phone's key and the body go up; the answer comes back
upstream_before = len(seen)
payload = json.dumps({"model": "mimo", "messages": [{"role": "user", "content": "hi"}]}).encode()
st, txt, hdr = call("POST", "/api/ci/v1/chat/completions", body=payload,
                    headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json",
                             "X-Forwarded-For": "10.9.9.9", "Cookie": "session=abc", "Host": "evil.example"})
check(st == 200 and txt == b"part one part two", f"answer streamed back in full (status {st}, body {txt!r})")
check(len(seen) == upstream_before + 1, "the upstream was called once")
up_req = seen[-1]
check(up_req["path"] == "/v1/chat/completions", f"path passed as /v1/... (got {up_req['path']})")
check(up_req["headers"].get("authorization") == "Bearer " + KEY, "the phone's key is passed on unchanged")
check(up_req["body"] == payload, "the request body is passed on unchanged")
check("x-forwarded-for" not in up_req["headers"] and "cookie" not in up_req["headers"]
      and up_req["headers"].get("host") == "127.0.0.1:9301",
      "X-Forwarded-For, Cookie and the client's Host are NOT passed upstream")
check(hdr.get("x-ci-request-id") == "req-123", "the request id comes back")
check(hdr.get("set-cookie") is None, "the upstream's Set-Cookie never reaches the phone")
check(hdr.get("Cache-Control") == "no-store", "answers are no-store")

# 6. the allowlist: other paths are 404 and never reach the upstream
n = len(seen)
for p in ["/api/ci/v1/admin", "/api/ci/v2/models", "/api/ci/v1/models/../../x", "/", "/api/ci/v1/chat/completions/extra"]:
    st, _, _ = call("GET", p)
    check(st == 404 and len(seen) == n, f"{p} is 404 and not sent upstream (got {st})")

# 7. methods: only GET and POST
for m in ["PUT", "DELETE"]:
    st, _, _ = call(m, "/api/ci/v1/models")
    check(st == 405 and len(seen) == n, f"{m} is refused with 405 (got {st})")

# 8. body size cap: over 1 MB is refused before anything is sent
st, _, _ = call("POST", "/api/ci/v1/chat/completions", body=b"x" * (cf.MAX_BODY + 1),
                headers={"Content-Type": "application/json"})
check(st == 413 and len(seen) == n, f"a body over 1 MB is 413 and not sent (got {st})")

# 9. chunked uploads are refused (the size could not be checked)
conn = http.client.HTTPConnection("127.0.0.1", 9302, timeout=10)
conn.putrequest("POST", "/api/ci/v1/chat/completions")
conn.putheader("Transfer-Encoding", "chunked"); conn.endheaders()
conn.send(b"5\r\nhello\r\n0\r\n\r\n")
r = conn.getresponse(); r.read(); conn.close()
check(r.status == 411 and len(seen) == n, f"a chunked upload is 411 (got {r.status})")

# 10. the upstream is down: 502, not a crash
cf.save_upstream("http://127.0.0.1:9399")   # nothing listens there
st, txt, _ = call("GET", "/api/ci/v1/models")
check(st == 502, f"upstream down: 502 (got {st})")
cf.save_upstream("http://127.0.0.1:9301")

# 11. slow or silent connections: bounded in time and in number (a second server with
# small limits, so the test is quick: 2 s per read, 2 connections at once)
import socket, time
class QuickHandler(cf.Handler):
    timeout = 2
small = cf.Server(("127.0.0.1", 9303), QuickHandler)
small.slots = threading.BoundedSemaphore(2)
threading.Thread(target=small.serve_forever, daemon=True).start()
quiet = [socket.create_connection(("127.0.0.1", 9303), timeout=10) for _ in range(2)]   # send nothing
time.sleep(0.3)
extra = socket.create_connection(("127.0.0.1", 9303), timeout=10)
extra.sendall(b"GET /api/ci/v1/models HTTP/1.0\r\n\r\n")
got = extra.recv(200); extra.close()
check(got.startswith(b"HTTP/1.0 503"), f"a connection over the cap gets 503 at once (got {got[:30]!r})")
started = time.monotonic()
closed = all(s.recv(10) == b"" for s in quiet)   # the server closes a silent connection
took = time.monotonic() - started
check(closed and took < 6, f"silent connections are closed after the read timeout ({took:.1f}s)")
for s in quiet: s.close()
# a thread that cannot start must give its slot back (16 such failures would 503 forever)
import socketserver
real_pr = socketserver.ThreadingMixIn.process_request
def no_thread(self, request, client_address):
    raise RuntimeError("can't start new thread")
socketserver.ThreadingMixIn.process_request = no_thread
before = small.slots._value
try:
    small.process_request(socket.socket(), ("127.0.0.1", 0))
except RuntimeError:
    pass
socketserver.ThreadingMixIn.process_request = real_pr
check(small.slots._value == before, f"a thread that cannot start gives its slot back ({before} -> {small.slots._value})")
try:   # what a timed-out connection logs: it has no request line yet
    with contextlib.redirect_stdout(io.StringIO()):
        cf.Handler.__new__(cf.Handler).log_message("Request timed out: %r", "x")
    check(True, "a timed-out connection logs one line, no crash")
except Exception as e:
    check(False, f"a timed-out connection crashes the log line ({type(e).__name__})")
time.sleep(0.3)
c2 = socket.create_connection(("127.0.0.1", 9303), timeout=10)
c2.sendall(b"GET /api/ci/v1/models HTTP/1.0\r\n\r\n")
got = c2.recv(200); c2.close()
check(got.startswith(b"HTTP/1.0 200"), f"after they are gone, a normal call works again (got {got[:30]!r})")

# 12. the key never reaches the log
check(KEY not in log.getvalue(), "the key is not in the forwarder's log")
print("log sample:", log.getvalue().strip().splitlines()[:2])
sys.exit(1 if bad_count else 0)
PY

echo
echo "== 2. the Caddy route reaches the real service =="
systemctl is-active --quiet mini-deploy-ci && ok "mini-deploy-ci is running" || bad "mini-deploy-ci is not running"
body=$(curl -s -m 5 -H "Host: aftersleep.localhost:8080" "http://127.0.0.1:8080/api/ci/v1/evil")
code=$(curl -s -o /dev/null -w "%{http_code}" -m 5 -H "Host: aftersleep.localhost:8080" "http://127.0.0.1:8080/api/ci/v1/evil")
[ "$code" = 404 ] && [ "$body" = "not found" ] && ok "/api/ci/v1/evil reaches the forwarder (its own 404)" \
  || bad "route check: $code '$body'"
[ "$(curl -s -o /dev/null -w "%{http_code}" -H "Host: aftersleep.localhost:8080" http://127.0.0.1:8080/index.html)" = 200 ] \
  && ok "the site itself still answers 200" || bad "the site no longer answers"
[ "$(curl -s -o /dev/null -w "%{http_code}" -H "Host: aftersleep.localhost:8080" http://127.0.0.1:8080/.env)" = 404 ] \
  && ok "dotfiles are still 404" || bad "dotfile check"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOMETHING FAILED"; fi
exit $fail
