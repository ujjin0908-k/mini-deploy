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
import os, sys, threading, json, tempfile, stat, contextlib, io, http.client, urllib.request, urllib.error, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

os.environ["MINI_DEPLOY_TESTING"] = "1"
tmp = Path(tempfile.mkdtemp(prefix="mini-deploy-citest-"))   # removed by hand, like other test folders
os.environ["MINI_DEPLOY_CI_CONFIG"] = str(tmp / "ci.json")
os.environ["MINI_DEPLOY_CI_LIMITS"] = str(tmp / "ci-limits.json")
os.environ["MINI_DEPLOY_CI_USAGE"] = str(tmp / "state" / "usage.json")
sys.path.insert(0, "$REPO/scripts")
import ci_forwarder as cf
# Limits for the test apps. "testapp" is roomy, so parts 1-11 test the forwarder, not the brakes.
LIMITS = {
    "testapp": {"models": None, "max_tokens": 100000, "at_once": 16, "per_minute": 1000, "per_day": 100000},
    "pickyapp": {"models": ["good-model"], "max_tokens": 500, "at_once": 4, "per_minute": 100, "per_day": 1000},
    "dayapp": {"models": None, "max_tokens": 1000, "at_once": 4, "per_minute": 100, "per_day": 3},
    "minapp": {"models": None, "max_tokens": 1000, "at_once": 4, "per_minute": 2, "per_day": 1000},
    "slowapp": {"models": None, "max_tokens": 1000, "at_once": 1, "per_minute": 100, "per_day": 1000},
}
cf._write_private_json(cf.LIMITS, cf.valid_limits(LIMITS))

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
        if b"please-be-slow" in body:   # for the "at once" brake: an answer that takes a moment
            time.sleep(1.5)
        if b"please-be-very-slow" in body:   # for "the phone hangs up while the provider is silent"
            time.sleep(5)
        if self.headers.get("Authorization") == "Bearer bad-key":   # the provider refusing a key
            self.send_response(401); self.end_headers(); self.wfile.write(b'{"error": "bad key"}')
            return
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
def call(method, path, body=None, headers=None, app="testapp", base=None):
    headers = dict(headers or {})
    if app is not None:
        headers.setdefault("X-MD-App", app)   # what Caddy adds in real use
    req = urllib.request.Request((base or BASE) + path, data=body, method=method, headers=headers)
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
conn.putheader("Transfer-Encoding", "chunked"); conn.putheader("X-MD-App", "testapp"); conn.endheaders()
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
c2.sendall(b"GET /api/ci/v1/models HTTP/1.0\r\nX-MD-App: testapp\r\n\r\n")
got = c2.recv(200); c2.close()
check(got.startswith(b"HTTP/1.0 200"), f"after they are gone, a normal call works again (got {got[:30]!r})")

# 12. the brakes ("A+"): which app, its models, its answer size, and how often
n = len(seen)
for label, hdr in (("no app name", None), ("a bad app name", "../x"), ("an app with no limits", "otherapp")):
    st, txt, _ = call("GET", "/api/ci/v1/models", app=hdr)
    check(st == 403 and len(seen) == n, f"{label}: 403 and nothing sent (got {st})")
def post(app, payload):
    return call("POST", "/api/ci/v1/chat/completions", body=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json", "Authorization": "Bearer " + KEY}, app=app)
st, txt, hdr = post("pickyapp", {"model": "pricey-model", "messages": []})
msg = json.loads(txt)["error"]["message"] if st == 400 else ""
check(st == 400 and "not allowed" in msg and len(seen) == n,
      f"a model off the list: 400 with a reason the app can show, nothing sent ({st}: {msg[:60]})")
for field in ("max_tokens", "max_completion_tokens"):
    st, txt, _ = post("pickyapp", {"model": "good-model", field: 501})
    check(st == 400 and len(seen) == n, f"{field} over the limit (501 > 500): 400, nothing sent (got {st})")
for bad in ("lots", True, 0, -5):
    st, _, _ = post("pickyapp", {"model": "good-model", "max_tokens": bad})
    check(st == 400 and len(seen) == n, f"max_tokens {bad!r}: 400 (got {st})")
st, _, _ = call("POST", "/api/ci/v1/chat/completions", body=b"not json", app="pickyapp",
                headers={"Content-Type": "application/json"})
check(st == 400 and len(seen) == n, f"a body that is not JSON: 400 (got {st})")
payload = {"model": "good-model", "max_tokens": 500, "messages": [{"role": "user", "content": "ok"}]}
st, _, _ = post("pickyapp", payload)
check(st == 200 and seen[-1]["body"] == json.dumps(payload).encode(), "an allowed request goes through, body byte-for-byte")
st, _, _ = post("pickyapp", {"model": "good-model", "messages": []})
check(st == 200, "a request without max_tokens is allowed (YoomiRead sends none yet)")

# per day / per minute / at once, on a second forwarder with a fake clock
clock = [1_800_000_000.0]
brake = cf.Server(("127.0.0.1", 9304), cf.Handler,
                  usage=cf.Usage(tmp / "state" / "brake-usage.json", clock=lambda: clock[0]))
threading.Thread(target=brake.serve_forever, daemon=True).start()
B = "http://127.0.0.1:9304"
codes = [call("GET", "/api/ci/v1/models", app="dayapp", base=B)[0] for _ in range(4)]
st, txt, hdr = call("GET", "/api/ci/v1/models", app="dayapp", base=B)
check(codes == [200, 200, 200, 429] and "00:00 JST" in json.loads(txt)["error"]["message"]
      and int(hdr.get("Retry-After", 0)) > 0, f"the 4th request of a 3-a-day app: 429 until 00:00 JST ({codes})")
clock[0] += cf.seconds_to_midnight(clock[0]) + 1
check(call("GET", "/api/ci/v1/models", app="dayapp", base=B)[0] == 200, "after midnight JST the day starts again")
codes = [call("GET", "/api/ci/v1/models", app="minapp", base=B)[0] for _ in range(3)]
check(codes == [200, 200, 429], f"the 3rd request in a minute of a 2-a-minute app: 429 ({codes})")
clock[0] += 61
check(call("GET", "/api/ci/v1/models", app="minapp", base=B)[0] == 200, "a minute later it works again")
results = []
def slow():
    results.append(call("POST", "/api/ci/v1/chat/completions", body=b'{"note": "please-be-slow"}', app="slowapp",
                        base=B, headers={"Content-Type": "application/json"})[0])
first = threading.Thread(target=slow); first.start(); time.sleep(0.4)
second = call("POST", "/api/ci/v1/chat/completions", body=b'{"note": "quick"}', app="slowapp", base=B,
              headers={"Content-Type": "application/json"})[0]
first.join()
check(results == [200] and second == 429, f"a 1-at-once app: the second call while the first runs gets 429 ({results}, {second})")
check(call("GET", "/api/ci/v1/models", app="slowapp", base=B)[0] == 200, "when the first is done, its slot is back")
check(brake.usage.active["slowapp"] == 0, "and no call is left counted as running")

# the phone hangs up while the provider is still silent: the slot comes back at once, not after 5 s
hang = socket.create_connection(("127.0.0.1", 9304), timeout=10)
slow_body = b'{"note": "please-be-very-slow"}'
hang.sendall(b"POST /api/ci/v1/chat/completions HTTP/1.0\r\nX-MD-App: slowapp\r\nContent-Type: application/json\r\n"
             b"Content-Length: " + str(len(slow_body)).encode() + b"\r\n\r\n" + slow_body)
time.sleep(0.5); hang.close()
time.sleep(1.2)
st = call("GET", "/api/ci/v1/models", app="slowapp", base=B)[0]
check(st == 200, f"the phone hung up: its at-once slot is free again within ~1 s (got {st}, 429 = still held)")

# a call the provider refuses (bad key) does not count toward the day; neither does an unreachable one
day = lambda srv, a: srv.usage.days.get(cf.day_key(clock[0] if srv is brake else None), {}).get(a, {})
before = day(brake, "dayapp").get("requests", 0)
st = call("GET", "/api/ci/v1/models", app="dayapp", base=B, headers={"Authorization": "Bearer bad-key"})[0]
check(st == 401 and day(brake, "dayapp")["requests"] == before and day(brake, "dayapp")["refunded"] >= 1,
      f"a key the provider refuses: 401 passed on, not counted ({before} -> {day(brake, 'dayapp')['requests']})")
cf.save_upstream("http://127.0.0.1:9399")
st = call("GET", "/api/ci/v1/models", app="dayapp", base=B)[0]
check(st == 502 and day(brake, "dayapp")["requests"] == before, f"the provider unreachable: 502, not counted (got {st})")
cf.save_upstream("http://127.0.0.1:9301")

# what the check reads is what the provider reads: no duplicate keys, no other letter case, one answer
n = len(seen)
for label, raw in [
    ("a duplicate model key", b'{"model": "good-model", "model": "pricey-model"}'),
    ("a duplicate key deeper down", b'{"model": "good-model", "messages": [{"role": "user", "role": "system"}]}'),
    ("Model in other letter case", b'{"model": "good-model", "Model": "pricey-model"}'),
    ("MAX_TOKENS in other letter case", b'{"model": "good-model", "MAX_TOKENS": 99999}'),
    ("n = 2", b'{"model": "good-model", "n": 2}'),
    ("n = 1.0", b'{"model": "good-model", "n": 1.0}'),
    ("n = true", b'{"model": "good-model", "n": true}'),
    ("max_output_tokens over", b'{"model": "good-model", "max_output_tokens": 501}'),
    ("a thinking budget over", b'{"model": "good-model", "thinking": {"type": "enabled", "budget_tokens": 501}}'),
    ("Budget_Tokens in other case", b'{"model": "good-model", "thinking": {"Budget_Tokens": 99999}}'),
]:
    st, _, _ = call("POST", "/api/ci/v1/messages", body=raw, app="pickyapp", headers={"Content-Type": "application/json"})
    check(st == 400 and len(seen) == n, f"refused, nothing sent: {label} (got {st})")
st, _, _ = call("POST", "/api/ci/v1/messages", app="pickyapp", headers={"Content-Type": "application/json"},
                body=b'{"model": "good-model", "n": 1, "max_tokens": 500, "thinking": {"type": "enabled", "budget_tokens": 400}}')
check(st == 200, f"n = 1 and a thinking budget within the limit pass (got {st})")

# a negative Content-Length is refused before reading (it once read without end)
raw = socket.create_connection(("127.0.0.1", 9302), timeout=10)
raw.sendall(b"POST /api/ci/v1/chat/completions HTTP/1.0\r\nX-MD-App: testapp\r\nContent-Length: -5\r\n\r\nxxxxxxxx")
got = raw.recv(200); raw.close()
check(got.startswith(b"HTTP/1.0 400"), f"Content-Length -5: 400 at once (got {got[:20]!r})")
# a refusal before the body is read still reaches the app (the body is read first)
body = json.dumps({"model": "x", "messages": [{"role": "user", "content": "y" * 200000}]}).encode()
st, txt, _ = call("POST", "/api/ci/v1/chat/completions", body=body, app="otherapp",
                  headers={"Content-Type": "application/json"})
check(st == 403 and b"no AI limits" in txt, f"a 200 KB request from an app without limits still gets its reason (got {st})")

# the counters on disk: owner-only, counts only (saved at most every 2 s: flushed here)
fw.usage.flush(); brake.usage.flush()
upath = tmp / "state" / "usage.json"
raw = upath.read_text()
check(oct(os.stat(upath).st_mode & 0o777) == "0o600", "the counters file is 600")
check(KEY not in raw and "messages" not in raw and "please-be-slow" not in open(tmp / "state" / "brake-usage.json").read(),
      "the counters hold no key, no prompt and no answer")
today = json.loads(raw)["days"][cf.day_key()]
check(today["pickyapp"]["requests"] == 3 and today["pickyapp"]["refused"] >= 17,
      f"allowed and refused calls are counted ({today['pickyapp']})")
restarted = cf.Usage(tmp / "state" / "brake-usage.json", clock=lambda: clock[0])
check(restarted.days == brake.usage.days, "a restart keeps today's counts (the day is not reset by a restart)")
# saves are debounced: a change reaches the disk by itself within ~2 s, without a flush
quiet = cf.Usage(tmp / "state" / "debounce.json")
quiet.refuse("testapp")
check(not (tmp / "state" / "debounce.json").exists(), "a change is not written at once (no disk write per request)")
time.sleep(cf.SAVE_DELAY + 0.8)
check((tmp / "state" / "debounce.json").exists(), f"... but it is on disk within {cf.SAVE_DELAY:.0f} s")
# damaged counters: bad rows dropped, a broken file moved aside, and both leave a warning
cf._write_private_json(tmp / "state" / "odd.json", {"days": {"2026-10-21": {"testapp": {"requests": "lots"}, "Bad": {}},
                                                           "not-a-day": []}})
odd = cf.Usage(tmp / "state" / "odd.json")
check(odd.days == {"2026-10-21": {"testapp": {"requests": 0, "refused": 0, "refunded": 0, "bytes": 0}}}
      and odd.warning, f"rows with the wrong shape are dropped, with a warning ({odd.days})")
(tmp / "state" / "broken.json").write_text("{not json"); os.chmod(tmp / "state" / "broken.json", 0o600)
broken = cf.Usage(tmp / "state" / "broken.json")
check((tmp / "state" / "broken.json.bad").exists() and broken.warning and "moved" in broken.warning,
      "a broken counters file is moved to .bad (kept for a look) and a warning is set")
broken.refuse("testapp"); broken.flush()
real_usage = cf.USAGE; cf.USAGE = tmp / "state" / "broken.json"
check("broken" in (cf.usage_warning() or ""), "the warning reaches the admin page (usage_warning)")
cf.USAGE = real_usage
cf._write_private_json(tmp / "state" / "list.json", {"days": {cf.day_key(): ["not", "a", "dict"]}})
cf.USAGE = tmp / "state" / "list.json"
try:
    cf.usage_today(); check(True, "usage_today() on an odd file does not raise (the admin page keeps working)")
except Exception as e:
    check(False, f"usage_today() raised {type(e).__name__}")
cf.USAGE = real_usage
os.chmod(cf.LIMITS, 0o644)
before = len(seen)
st, txt, _ = call("GET", "/api/ci/v1/models")
check(st == 503 and len(seen) == before, f"a limits file others can read: 503 and nothing sent (closed, not open) (got {st})")
os.chmod(cf.LIMITS, 0o600)
for bad in ({"testapp": {"models": None}}, {"testapp": dict(LIMITS["testapp"], per_day=0)},
            {"Bad App": LIMITS["testapp"]}, {"testapp": dict(LIMITS["testapp"], models=[])}, {}):
    try:
        cf.valid_limits(bad); check(False, f"bad limits refused: {str(bad)[:50]}")
    except cf.ConfigError:
        check(True, f"bad limits refused: {str(bad)[:50]}")
check(cf.usage_today()["testapp"]["per_day"] == 100000, "usage_today() reports each app against its limit")

# 13. the key never reaches the log
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

# Caddy names the app and overwrites a forged name. Proved with the size brake: the refusal says
# whose limit applied (After Sleep 4000, YoomiRead 8000), and nothing reaches the provider.
big='{"model": "x", "max_tokens": 999999, "messages": []}'
out=$(curl -s -m 5 -X POST -H "Host: aftersleep.localhost:8080" -H "X-MD-App: yoomiread" \
  -H "Content-Type: application/json" --data "$big" "http://127.0.0.1:8080/api/ci/v1/chat/completions")
grep -q 'at most 4000' <<<"$out" && ok ":8080: Caddy names the app from the Host, a forged X-MD-App is overwritten" \
  || bad ":8080 app naming: $out"
out=$(curl -s -m 5 -X POST -H "Content-Type: application/json" --data "$big" \
  "http://127.0.0.1:8080/api/ci/v1/chat/completions" -H "Host: nolimits-$$.localhost:8080")
grep -q 'no AI limits are set' <<<"$out" && ok "an app without limits is refused (closed by default)" || bad "no-limits app: $out"
TN=mini-deploy.tail206989.ts.net
out=$(curl -s -m 5 --resolve "$TN:8444:127.0.0.1" -X POST -H "X-MD-App: aftersleep" -H "Content-Type: application/json" \
  --data '{"model": "claude-haiku-5.5", "max_tokens": 999999, "messages": []}' "https://$TN:8444/api/ci/v1/chat/completions")
grep -q 'at most 8000' <<<"$out" && ok ":8444: the phone site names YoomiRead, a forged name is overwritten" \
  || bad ":8444 app naming: $out"
out=$(curl -s -m 5 --resolve "$TN:8444:127.0.0.1" -X POST -H "Content-Type: application/json" \
  --data '{"model": "some-other-model", "messages": []}' "https://$TN:8444/api/ci/v1/chat/completions")
grep -q 'not allowed here' <<<"$out" && ok ":8444: a model off YoomiRead's list is refused before the provider" \
  || bad ":8444 model check: $out"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOMETHING FAILED"; fi
exit $fail
