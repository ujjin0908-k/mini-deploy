#!/usr/bin/env bash
# Stage 5 test: a signed push deploys, a bad signature is rejected, and everything a
# payload, a slow client, a restart or an old redelivery could try is handled.
# Needs Docker and Caddy (current Caddyfile) running.
#
# It starts its OWN webhook server on 127.0.0.1:9101 with a random secret, its own
# state folder and a throw-away local git repo standing in for GitHub, so it never
# touches your real secret, config or queue. Creates the app "hook-test" and a /tmp
# folder; it never deletes anything itself (remove leftovers with direct rm -rf).
set -uo pipefail

REPO=/mnt/c/Users/indra/Code/mini-deploy
DEPLOY="python3 $REPO/scripts/deploy.py"
SRC=$(mktemp -d /tmp/mini-deploy-hook-test-XXXXXX)
ORIGIN=$SRC/origin
STATE=$SRC/state
PORT=9101
APP=hook-test
RUN=$(python3 -c 'import secrets; print(secrets.token_hex(4))')   # makes markers unique per run
LOGFILE=/var/log/mini-deploy.log
URL=http://127.0.0.1:$PORT/webhook
SECRET=$(python3 -c 'import secrets; print(secrets.token_hex(32))')   # never printed, never exported
LOG_BASE=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)
SPID=""
fail=0
trap '[ -n "$SPID" ] && kill $SPID 2>/dev/null' EXIT

ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }

g()      { git -C "$ORIGIN" -c user.name=test -c user.email=test@example.invalid "$@"; }
guid()   { python3 -c 'import uuid; print(uuid.uuid4())'; }
newlog() { tail -n +$((LOG_BASE + 1)) "$LOGFILE"; }       # only lines written during this run
sign()   { printf '%s' "$1" | SECRET="$SECRET" python3 -c 'import sys,os,hmac,hashlib; print("sha256="+hmac.new(os.environ["SECRET"].encode(), sys.stdin.buffer.read(), hashlib.sha256).hexdigest())'; }
body()   { python3 -c 'import json,sys; print(json.dumps({"ref":sys.argv[2],"after":sys.argv[3],"deleted":False,"repository":{"full_name":sys.argv[1]},"clone_url":"file:///etc"}))' "$@"; }
push()   { post push "$(guid)" "$(body test/hook-repo refs/heads/main "$1")"; }   # sha -> response

# post EVENT DELIVERY BODY [SIGNATURE | VALID | NONE]  -> "<text> [<status>]"
post() {
  local sig=${4:-VALID}
  [ "$sig" = VALID ] && sig=$(sign "$3")
  local args=(-s -m 10 -w ' [%{http_code}]' -H "X-GitHub-Event: $1" -H "X-GitHub-Delivery: $2" -H 'Content-Type: application/json')
  [ "$sig" != NONE ] && args+=(-H "X-Hub-Signature-256: $sig")
  curl "${args[@]}" --data-binary "$3" "$URL"
}
code_of() { grep -o '\[[0-9]*\]' <<<"$1" | tr -d '[]'; }
expect() {  # label want result
  local got; got=$(code_of "$3")
  [ "$got" = "$2" ] && ok "$1 -> $2" || bad "$1 -> $got (want $2): $3"
}

page()     { curl -s -m 3 --resolve "$APP.localhost:8080:127.0.0.1" "http://$APP.localhost:8080/"; }
wait_for() { local i; for i in $(seq 1 "${2:-90}"); do page | grep -q -- "$1" && return 0; sleep 1; done; return 1; }
wait_log() { local i; for i in $(seq 1 "${2:-90}"); do newlog | grep -q -- "$1" && return 0; sleep 1; done; return 1; }
n_releases() { ls -A "/sites/$APP/releases" 2>/dev/null | grep -vc '^\.'; }
commit_page() {  # marker -> prints the new commit sha
  sed -i "s|<h1>.*</h1>|<h1>marker-$1, built with __BUILT_WITH__</h1>|" "$ORIGIN/src/index.html"
  g add -A >/dev/null; g commit -q -m "page $1"; g rev-parse HEAD
}
break_build()   { echo 'process.exit(1)' > "$ORIGIN/build.js"; g add -A >/dev/null; g commit -q -m "break the build"; g rev-parse HEAD; }
restore_build() { g checkout -q HEAD~1 -- build.js; g commit -q -m "fix the build"; }

start_server() {  # extra server flags...
  WEBHOOK_SECRET=$SECRET python3 "$REPO/scripts/webhook.py" --config "$SRC/webhook.json" \
    --state-dir "$STATE" --env-file "$SRC/no-such-env" --allow-file-urls "$@" >>"$SRC/server.out" 2>&1 &
  SPID=$!
  local i
  for i in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && return 0; sleep 0.1; done
  return 1
}
stop_server() {  # graceful: waits for the running build
  [ -n "$SPID" ] || return 0
  kill -TERM "$SPID" 2>/dev/null
  local i
  for i in $(seq 1 120); do
    kill -0 "$SPID" 2>/dev/null || { wait "$SPID" 2>/dev/null; SPID=""; return 0; }
    sleep 0.5
  done
  return 1
}

echo "== 0. set up: a local repo standing in for GitHub, and a server of our own =="
mkdir -p "$ORIGIN" "$STATE"; cp -r "$REPO/examples/static-site/." "$ORIGIN"
g init -q -b main
g config uploadpack.allowAnySHA1InWant true
g add -A; g commit -q -m base
BASE=$(g rev-parse HEAD)
cat > "$SRC/webhook.json" <<JSON
{ "listen": "127.0.0.1", "port": $PORT,
  "repos": { "test/hook-repo": { "app": "$APP", "branch": "main", "subdir": "", "url": "file://$ORIGIN" } } }
JSON
start_server && ok "server is up" || { bad "server did not start"; cat "$SRC/server.out"; exit 1; }

echo
echo "== 1. a bad signature is rejected, and nothing is parsed first =="
B=$(body test/hook-repo refs/heads/main "$BASE")
r_none=$(post push "$(guid)" "$B" NONE);                                    expect "no signature header" 401 "$r_none"
r_wrong=$(post push "$(guid)" "$B" "sha256=$(printf '0%.0s' $(seq 1 64))"); expect "wrong signature" 401 "$r_wrong"
good=$(sign "$B")
r_edit=$(post push "$(guid)" "${B/main/mxin}" "$good");                     expect "valid signature, edited body" 401 "$r_edit"
r_pref=$(post push "$(guid)" "$B" "${good#sha256=}");                       expect "signature without sha256= prefix" 401 "$r_pref"
r_asc=$(post push "$(guid)" "$B" $'sha256=\xff\xfe');                       expect "non-ASCII signature" 401 "$r_asc"
r_junk=$(post push "$(guid)" "not json at all" "sha256=deadbeef");          expect "garbage body, bad signature (401, not 400)" 401 "$r_junk"
r_junk2=$(post push "$(guid)" "not json at all");                           expect "garbage body, valid signature (parsed only now)" 400 "$r_junk2"
[ "$r_none" = "$r_wrong" ] && [ "$r_wrong" = "$r_edit" ] && [ "$r_edit" = "$r_asc" ] && ok "every 401 looks the same" || bad "401 answers differ"
big=$(head -c 1100000 /dev/zero | curl -s -o /dev/null -w '%{http_code}' -m 10 -H 'X-Hub-Signature-256: sha256=00' --data-binary @- "$URL")
[ "$big" = 413 ] && ok "body over 1 MB -> 413 before it is read" || bad "body over 1 MB -> $big"
expect "GET /webhook" 405 "$(curl -s -m 5 -w ' [%{http_code}]' "$URL")"
expect "POST /other" 404 "$(curl -s -m 5 -w ' [%{http_code}]' -X POST "http://127.0.0.1:$PORT/other")"
expect "signed ping" 200 "$(post ping "$(guid)" '{"zen":"hi"}')"

echo
echo "== 2. signed, but not something to act on =="
before_ignored=$(readlink "/sites/$APP/current" 2>/dev/null || echo none)   # the app may exist from an earlier run
expect "push to another branch" 202 "$(post push "$(guid)" "$(body test/hook-repo refs/heads/dev "$BASE")")"
expect "push from a repo not in the allowlist" 202 "$(post push "$(guid)" "$(body evil/repo refs/heads/main "$BASE")")"
expect "a non-push event" 202 "$(post issues "$(guid)" '{"action":"opened"}')"
expect "all-zero sha (branch deleted)" 202 "$(post push "$(guid)" "$(body test/hook-repo refs/heads/main 0000000000000000000000000000000000000000)")"
expect "short sha" 400 "$(post push "$(guid)" "$(body test/hook-repo refs/heads/main abc123)")"
expect "uppercase sha" 400 "$(post push "$(guid)" "$(body test/hook-repo refs/heads/main "${BASE^^}")")"
expect "repo name with ../" 400 "$(post push "$(guid)" "$(body ../../etc/passwd refs/heads/main "$BASE")")"
expect "missing delivery id" 400 "$(curl -s -m 5 -w ' [%{http_code}]' -H "X-GitHub-Event: push" -H "X-Hub-Signature-256: $good" --data-binary "$B" "$URL")"
sleep 3
after_ignored=$(readlink "/sites/$APP/current" 2>/dev/null || echo none)
[ "$before_ignored" = "$after_ignored" ] && ok "none of those deployed anything" || bad "something was deployed: $before_ignored -> $after_ignored"

echo
echo "== 3. a signed push to main deploys by itself =="
SHA1=$(commit_page "$RUN-one")
D1=$(guid); B1=$(body test/hook-repo refs/heads/main "$SHA1")
expect "signed push" 202 "$(post push "$D1" "$B1")"
if wait_for "marker-$RUN-one"; then ok "live site shows the pushed commit"; else bad "site never showed marker-$RUN-one"; fi
page | grep -q 'built with node v' && ok "and it was built in the container" || bad "page was not built"
link1=$(readlink "/sites/$APP/current"); n1=$(n_releases)
grep -q "\"sha\": \"$SHA1\"" "/sites/$APP/.deployed" && ok "the deployed commit is recorded" || bad "no .deployed record"
post push "$D1" "$B1" | grep -q duplicate && ok "same delivery again (replay) -> duplicate" || bad "replay not recognised"
expect "same commit, new delivery id" 202 "$(post push "$(guid)" "$B1")"
if wait_log "webhook - same .*${SHA1:0:7}" 30; then ok "commit already live: skipped, not built twice"; else bad "same commit was not skipped"; fi
sleep 2
[ "$(readlink /sites/$APP/current)" = "$link1" ] && [ "$(n_releases)" = "$n1" ] && ok "nothing was deployed twice" || bad "a repeat changed the site"

echo
echo "== 4. an old commit with a fresh delivery id does not roll the site back =="
SHA_X=$(commit_page "$RUN-x"); SHA_Y=$(commit_page "$RUN-y")
push "$SHA_Y" >/dev/null
wait_for "marker-$RUN-y" && ok "newest commit is live" || bad "marker-$RUN-y never appeared"
live_y=$(readlink "/sites/$APP/current"); ny=$(n_releases)
expect "signed push of the OLDER commit, new delivery id" 202 "$(push "$SHA_X")"
if wait_log "webhook - stale .*${SHA_X:0:7}" 40; then ok "old commit refused as stale"; else bad "stale push not detected"; fi
sleep 2
page | grep -q "marker-$RUN-y" && [ "$(readlink /sites/$APP/current)" = "$live_y" ] && [ "$(n_releases)" = "$ny" ] \
  && ok "site still on the newest commit" || bad "old commit changed the site"

echo
echo "== 5. a restart does not forget delivery ids =="
stop_server && ok "server stopped cleanly" || bad "server did not stop"
start_server && ok "server restarted" || bad "server did not restart"
post push "$D1" "$B1" | grep -q duplicate && ok "old delivery id is still known after a restart" || bad "restart forgot the delivery id"

echo
echo "== 6. a broken build leaves the live site up, and the log says why =="
SHA_B=$(break_build)
expect "push of a broken build" 202 "$(push "$SHA_B")"
if wait_log "webhook - fail .*${SHA_B:0:7}" 120; then ok "failure was logged"; else bad "no failure in the log"; fi
newlog | grep "webhook - fail .*${SHA_B:0:7}" | grep -q 'nothing was deployed: .' && ok "the log line carries the build's own output" || bad "no reason in the log"
page | grep -q "marker-$RUN-y" && [ "$(readlink /sites/$APP/current)" = "$live_y" ] && ok "live site still serves marker-$RUN-y" || bad "live site changed after a failed build"
restore_build

echo
echo "== 7. a newer push breaks while an older one waited: the older one is built =="
# Hold the build lock so the worker is busy and later pushes have to queue.
flock "/sites/$APP/.build.lock" sleep 12 &
FL=$!; sleep 0.5
SHA_X0=$(commit_page "$RUN-x0"); push "$SHA_X0" >/dev/null
sleep 3                                              # the worker has fetched X0 and now waits for the lock
SHA_P=$(commit_page "$RUN-p"); SHA_Q=$(break_build)
push "$SHA_P" >/dev/null; push "$SHA_Q" >/dev/null   # P waits, then Q replaces it (P kept as a fallback)
wait $FL 2>/dev/null
if wait_for "marker-$RUN-p" 150; then ok "site ended on P: the good push that Q had superseded"; else bad "fallback build never went live"; fi
newlog | grep -q "webhook - superseded .*${SHA_P:0:7}" && ok "the supersede was logged" || bad "no supersede line"
newlog | grep -q "webhook - fail .*${SHA_Q:0:7}" && ok "the broken newer push was logged as a failure" || bad "no failure line for Q"
newlog | grep -q "${SHA_P:0:7} .*(fallback)" && ok "the fallback build was logged" || bad "no fallback line"
restore_build

echo
echo "== 8. a rollback is not silently undone by the next push =="
$DEPLOY rollback $APP | tee "$SRC/rb.out" >/dev/null
grep -q '^held:' "$SRC/rb.out" && ok "rollback says the app is on hold" || bad "rollback did not mention the hold"
$DEPLOY list $APP | grep -q 'held' && ok "list shows the hold" || bad "list does not show the hold"
rolled=$(readlink "/sites/$APP/current")
SHA_H=$(commit_page "$RUN-held"); D_H=$(guid); B_H=$(body test/hook-repo refs/heads/main "$SHA_H")
expect "push while on hold" 202 "$(post push "$D_H" "$B_H")"
if wait_log "webhook - held .*${SHA_H:0:7}" 30; then ok "push was skipped and logged as held"; else bad "hold not applied"; fi
sleep 1
[ "$(readlink /sites/$APP/current)" = "$rolled" ] && ok "the rollback stayed in force" || bad "a push undid the rollback"
$DEPLOY unhold $APP | grep -q resumed && ok "unhold resumed webhook deploys" || bad "unhold failed"
expect "same delivery again after unhold (redeliver)" 202 "$(post push "$D_H" "$B_H")"
if wait_for "marker-$RUN-held" 90; then ok "after unhold the push deploys"; else bad "push did not deploy after unhold"; fi

echo
echo "== 9. a stop in the middle of a build keeps the queue =="
flock "/sites/$APP/.build.lock" sleep 8 &
FL=$!; sleep 0.5
SHA_S1=$(commit_page "$RUN-s1"); push "$SHA_S1" >/dev/null
sleep 3
SHA_S2=$(commit_page "$RUN-s2"); push "$SHA_S2" >/dev/null     # waits behind S1
sleep 1
stop_server && ok "server finished the running build and stopped" || bad "server did not stop"
wait $FL 2>/dev/null
[ -f "$STATE/pending.json" ] && grep -q "$SHA_S2" "$STATE/pending.json" && ok "the waiting push was saved to disk" || bad "queued job was not saved"
start_server && ok "server restarted" || bad "server did not restart"
grep -q 'queued job(s) restored' "$SRC/server.out" && ok "server restored the queued job" || bad "queue was not restored"
if wait_for "marker-$RUN-s2" 150; then ok "the saved push was built after the restart"; else bad "restored job never deployed"; fi

echo
echo "== 10. slow and many clients =="
stop_server; start_server --deadline 4 --max-handlers 3 && ok "server up with a 4 s deadline and 3 handlers" || bad "server did not start"
PORT=$PORT python3 - <<'PY' || fail=1
import os, socket, time, http.client
port = int(os.environ["PORT"])
bad = 0
def check(ok, msg):
    global bad
    print(("ok    " if ok else "FAIL  ") + msg)
    bad += not ok

# a) a client dripping one byte every 1.2 s would hold a thread ~60 s without a deadline
s = socket.create_connection(("127.0.0.1", port))
s.sendall(b"POST /webhook HTTP/1.0\r\nContent-Length: 50\r\n\r\n")
t0 = time.time(); closed = False
try:
    for _ in range(40):
        time.sleep(1.2)
        s.sendall(b"x")
except OSError:
    closed = True
elapsed = time.time() - t0
check(closed and elapsed < 10, f"slow drip was cut off after {elapsed:.1f} s (deadline 4 s)")
s.close()

# b) more concurrent connections than handlers -> 503, then recovery
idle = [socket.create_connection(("127.0.0.1", port)) for _ in range(3)]
time.sleep(0.5)
c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
c.request("POST", "/webhook", b"{}")
check(c.getresponse().status == 503, "4th connection while 3 are busy -> 503")
for i in idle:
    i.close()
time.sleep(5)
c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
c.request("POST", "/webhook", b"{}")
check(c.getresponse().status == 401, "after they are gone the server answers again (401 unsigned)")

# c) a non-ASCII 'digit' in Content-Length is a 400, not a dropped connection
s = socket.create_connection(("127.0.0.1", port))
s.sendall(b"POST /webhook HTTP/1.0\r\nContent-Length: \xc2\xb2\r\n\r\n")
check(b" 400 " in s.recv(200), "Content-Length '²' -> 400")
s.close()
raise SystemExit(1 if bad else 0)
PY
stop_server

echo
echo "== 11. units: secret file, config, retry, worker, caps, persistence =="
REPO=$REPO python3 - <<'PY' || fail=1
import os, sys, stat, tempfile, threading, time, json
from pathlib import Path
sys.path.insert(0, os.environ["REPO"] + "/scripts")
import webhook as w
import deploy as d
bad = 0
def check(ok, msg):
    global bad
    print(("ok    " if ok else "FAIL  ") + msg)
    bad += not ok
def raises(exc, fn):
    try:
        fn()
    except exc:
        return True
    except Exception:
        return False
    return False

tmp = Path(tempfile.mkdtemp())
# --- the secret file is parsed, never sourced
envf = tmp / "env"
def write(text, mode=0o600):
    envf.write_text(text, encoding="utf-8"); os.chmod(envf, mode)
os.environ.pop("WEBHOOK_SECRET", None)
write("WEBHOOK_SECRET=ab$(touch /tmp/should-not-exist)cd;&`id`\n")
check(w.read_secret(envf) == "ab$(touch /tmp/should-not-exist)cd;&`id`", "shell characters in the secret stay literal")
check(not Path("/tmp/should-not-exist").exists(), "nothing in the secret file was executed")
write("OTHER=1\r\nWEBHOOK_SECRET=\"quoted-value-1234567890abcdef12345678\"\r\n")
check(w.read_secret(envf) == "quoted-value-1234567890abcdef12345678", "CRLF and quotes handled")
write("WEBHOOK_SECRET=x" * 1 + "y" * 40 + "\n", 0o644)
check(raises(w.ConfigError, lambda: w.read_secret(envf)), "a group/world-readable secret file is refused")
os.environ["WEBHOOK_SECRET"] = "from-environment"
check(w.read_secret(envf) == "from-environment" and "WEBHOOK_SECRET" not in os.environ, "env var wins and is removed from the environment")

# --- config validation
def cfg(obj):
    p = tmp / "c.json"; p.write_text(json.dumps(obj)); return lambda: w.load_config(p)
good = {"a/b": {"app": "one"}, "c/d": {"app": "two"}}
check(not raises(w.ConfigError, cfg({"repos": good})), "a valid config loads")
check(raises(w.ConfigError, cfg({"repos": {"a/b": {"app": "one"}, "c/d": {"app": "one"}}})), "two repos on one app refused")
check(raises(w.ConfigError, cfg({"repos": {"a/b": "oops"}})), "non-object entry -> ConfigError, not a traceback")
check(raises(w.ConfigError, cfg({"repos": {"a/b": {"app": 5}}})), "non-string app -> ConfigError")
check(raises(w.ConfigError, cfg({"listen": "::1", "repos": {}})), "listen ::1 refused (server is IPv4)")
check(raises(w.ConfigError, cfg({"listen": "0.0.0.0", "repos": {}})), "listen 0.0.0.0 refused")
check(raises(w.ConfigError, cfg([1, 2])), "top level must be an object")

# --- retry
w.RETRY_DELAYS = (0, 0)
calls = {"n": 0}
def flaky():
    calls["n"] += 1
    if calls["n"] < 3:
        raise w.GitError("blip")
    return "ok"
check(w.with_retry(flaky) == "ok" and calls["n"] == 3, "git step succeeds on the third try")
check(raises(w.GitError, lambda: w.with_retry(lambda: (_ for _ in ()).throw(w.GitError("down")))), "persistent failure is still raised")

# --- size and disk caps
t = tmp / "tree"; t.mkdir(); (t / "f").write_bytes(b"x" * 5000)
w.MAX_CHECKOUT_BYTES = 1000
(t / ".git").mkdir()
check(raises(w.GitError, lambda: w.check_checkout_size(t)), "oversized checkout refused")
w.MIN_FREE_BYTES = 10**18
check(raises(w.GitError, w.check_disk), "too little free disk refused")

# --- queue: fallback chain and replacement
jobs = w.Jobs()
mk = lambda sha: {"app": "qa", "sha": sha, "fallback": None}
for s in "abcd":
    jobs.submit(mk(s * 40))
head = jobs.take(threading.Event())
chain = []
while head: chain.append(head["sha"][0]); head = head["fallback"]
check(chain == ["d", "c", "b"], f"newest first with a short fallback chain (got {chain})")

# --- delivery ids persist, removal persists
sp = tmp / "deliveries"
s1 = w.Seen(sp)
a, b = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
s1.add(a); s1.add(b); s1.remove(b)
s2 = w.Seen(sp)
check(s2.has(a) and not s2.has(b), "delivery ids survive a restart; removed ones stay removed")

# --- the worker survives SystemExit and keeps working
done = []
def fake_run_job(job, allow_file, check_tip=True):
    if job["sha"].startswith("0"):
        raise SystemExit(3)
    done.append(job["sha"][0])
    return "ok", "rel"
w.run_job = fake_run_job
state = w.State(b"s" * 32, {"repos": {}}, None)
mkjob = lambda app, sha: {"app": app, "repo": "x/y", "sha": sha, "url": "", "branch": "main",
                          "subdir": "", "delivery": "33333333-3333-3333-3333-333333333333",
                          "fallback": None, "retried": False}
state.worker = threading.Thread(target=w.worker, args=(state, False)); state.worker.start()
state.jobs.submit(mkjob("wa", "0" * 40))      # raises SystemExit inside the worker
state.jobs.submit(mkjob("wb", "9" * 40))
for _ in range(100):
    if done: break
    time.sleep(0.1)
check(done == ["9"] and state.worker_ok(), "after SystemExit the worker is alive and handled the next job")
state.stop.set(); state.worker.join(timeout=5)
check(not state.worker.is_alive(), "worker stops when asked and the queue is empty")
sys.exit(1 if bad else 0)
PY

echo
echo "== 12. nothing left behind, secret not leaked =="
dirs=$(ls -d /var/tmp/mini-deploy-hook-* /var/tmp/mini-deploy-build-* 2>/dev/null | wc -l)
[ "$dirs" = 0 ] && ok "no work folders left in /var/tmp" || bad "$dirs work folders left"
left=$(docker ps -aq --filter "name=mini-deploy-build-" | wc -l)
[ "$left" = 0 ] && ok "no build containers left" || bad "$left containers left"
if grep -q -- "$SECRET" "$SRC/server.out" "$LOGFILE" 2>/dev/null; then bad "the secret appears in the output or log"; else ok "secret is not in server output or the deploy log"; fi
grep -q " webhook webhook - rejected .*signature" <(newlog) && ok "rejections are logged" || bad "no rejection log line"
newlog | grep -qE " $APP webhook [0-9]{8}-[0-9]{6}(-[0-9]+)? ok " \
  && ok "successful webhook deploys are logged with the release id" || bad "no ok line with a release id"

echo
echo "== 13. the server refuses to start in an unsafe setup =="
start_fail() {  # label, pattern, secret, config, extra args...
  local label=$1 pat=$2 sec=$3 cfg=$4; shift 4
  local out; out=$(WEBHOOK_SECRET=$sec timeout 10 python3 "$REPO/scripts/webhook.py" --config "$cfg" \
      --state-dir "$SRC/state2" --env-file "$SRC/no-such-env" "$@" 2>&1); local rc=$?
  [ $rc -eq 1 ] && grep -q "^error:.*$pat" <<<"$out" && ok "$label refused" || bad "$label (exit $rc): $out"
}
printf '{ "listen": "0.0.0.0", "port": %s, "repos": {} }' $((PORT+1)) > "$SRC/exposed.json"
printf '{ "listen": "127.0.0.1", "port": %s, "repos": {"a/b": {"app": "Bad_App"}} }' $((PORT+1)) > "$SRC/badapp.json"
printf '{ "port": %s, "repos": {"a/b": {"app": "same"}, "c/d": {"app": "same"}} }' $((PORT+1)) > "$SRC/dupapp.json"
start_fail "no secret"                         "WEBHOOK_SECRET"     ""         "$SRC/webhook.json" --allow-file-urls
start_fail "short secret"                      "WEBHOOK_SECRET"     "tooshort" "$SRC/webhook.json" --allow-file-urls
start_fail "listening on 0.0.0.0"              "listen must be"     "$SECRET"  "$SRC/exposed.json"
start_fail "bad app name in config"            "bad app name"       "$SECRET"  "$SRC/badapp.json"
start_fail "two repos on one app"              "already used"       "$SECRET"  "$SRC/dupapp.json"
start_fail "file:// URL without the test flag" "https://github.com" "$SECRET"  "$SRC/webhook.json"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOMETHING FAILED"; fi
exit $fail
