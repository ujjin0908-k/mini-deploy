#!/usr/bin/env bash
# Stage 5 test: a signed push deploys, a bad signature is rejected, and everything a
# payload, a slow client, a restart or an old redelivery could try is handled.
# Needs Docker and Caddy (current Caddyfile) running.
#
# It starts its OWN webhook server on 127.0.0.1:9101 with a random secret, its own
# state folder and a throw-away local git repo standing in for GitHub, so it never
# touches your real secret, config or queue. Creates the app "hook-test" and a /tmp
# folder; it never deletes anything itself (remove leftovers with direct rm -rf).
# Section 14 makes previews of hook-test and takes them down again through the
# product's own remove (that removal is what is being tested).
set -uo pipefail
export MINI_DEPLOY_NO_DASHBOARD=1   # keep the real dashboard's releases quiet during tests

REPO=/mnt/c/Users/indra/Code/mini-deploy
DEPLOY="python3 $REPO/scripts/deploy.py"
SRC=$(mktemp -d /tmp/mini-deploy-hook-test-XXXXXX)
touch "$SRC/.started"   # "left behind" counts only what THIS run made (a kill -9 test of an earlier run leaves one on purpose)
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

CONFIG=$SRC/webhook.json   # section 14 switches to a config with previews on
start_server() {  # extra server flags...
  WEBHOOK_SECRET=$SECRET python3 "$REPO/scripts/webhook.py" --config "$CONFIG" \
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
newlog | grep -q " $APP webhook - ignored .*is not a push to main" && ok "previews are off for this repo: the dev push was ignored" || bad "dev push not logged as ignored"
ls -d /sites/*--$APP 2>/dev/null | grep -q '^/sites/dev--' && bad "a dev preview was made with previews off" || ok "no preview was made with previews off"

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
import os, sys, stat, shutil, tempfile, threading, time, json
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
d.LOG_FILE = tmp / "unit.log"   # the unit tests must never write fake apps into the real deploy log
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

# --- previews: site names made from branch names
def fine(fn):
    try:
        fn(); return True
    except Exception:
        return False
pn = d.preview_name
branches = ["feature-x", "feature/x", "Feature-X", "x", "a" * 80, "fix-ab12cd34", "dev", "feature/x-" + "b" * 60]
names = {b: pn("demo-site", b) for b in branches}
check(all(d.APP_RE.fullmatch(n) and d.preview_parent(n) == "demo-site" for n in names.values()),
      f"every preview name is a valid site name with the right parent ({sorted(names.values())})")
check(names["feature-x"] == "feature-x--demo-site", "a plain branch keeps its own name")
import re as _re
check(all(_re.search(r"-?[0-9a-f]{8}--demo-site$", n) for b, n in names.items() if b not in ("feature-x", "dev")),
      "a changed name carries 8 hex characters of the branch hash (not 4: too easy to collide on purpose)")
check(len(set(names.values())) == len(names), "different branches never share a preview (feature/x vs feature-x, Feature-X)")
check(pn("demo-site", "feature/x") == names["feature/x"], "the same branch always gets the same name")
check(raises(d.DeployError, lambda: pn("a" * 35, "x")), "an app name too long for previews is refused")
check(raises(d.DeployError, lambda: pn("x--y", "z")), "a preview of a preview is refused")
check(d.preview_parent("demo-site") is None and d.preview_parent("--x") is None and d.preview_parent("a--b--c") is None,
      "normal and malformed names are not previews")
good_b = ["main", "feature/x", "release-1.2", "a_b", "Feature-X"]
bad_b = ["../x", "a/../b", "-x", "a.lock", "a//b", ".hidden", "a/.b", "x/", "x.", "a b", "a;b", "$(id)", "", "a" * 101, None]
check(all(w.safe_branch(b) for b in good_b), "ordinary branch names are accepted")
rejected = [b for b in bad_b if not w.safe_branch(b)]
check(rejected == bad_b, f"hostile branch names are refused (let through: {[b for b in bad_b if b not in rejected]})")

# --- previews: at most MAX_PREVIEWS per app, removal only for previews
d.SITES = tmp / "sites"; d.SITES.mkdir()
for i in range(d.MAX_PREVIEWS - 1):
    (d.SITES / pn("demo-site", f"b{i:02d}x") / "releases").mkdir(parents=True)
for i in range(3):  # shells left by failed first builds: no releases, must not count
    (d.SITES / pn("demo-site", f"failed{i}")).mkdir()
check(fine(lambda: d.check_preview(pn("demo-site", "ten"), "ten")), "empty folders from failed builds do not count against the limit")
(d.SITES / pn("demo-site", "ten") / "releases").mkdir(parents=True)
check(raises(d.DeployError, lambda: d.check_preview(pn("demo-site", "one-more"), "one-more")), f"preview number {d.MAX_PREVIEWS + 1} is refused")
check(fine(lambda: d.check_preview(pn("demo-site", "b00x"), "b00x")), "an existing preview can still be updated")
check(fine(lambda: d.check_preview(pn("other-app", "b00x"), "b00x")), "another app has its own count")
shell = d.SITES / pn("demo-site", "failed0"); (shell / ".build.lock").write_text(""); (shell / ".branch").write_text("x\n")
d.drop_if_empty(shell.name)
check(not (shell / ".branch").exists() and (shell / ".build.lock").exists(),
      "drop_if_empty clears a failed first build's leftovers but keeps its lock (a waiting build may hold it)")
check(not d._is_preview_dir(shell), "and that shell does not count as a preview (no releases)")
d.drop_if_empty(pn("demo-site", "b01x"))
check((d.SITES / pn("demo-site", "b01x")).is_dir(), "drop_if_empty never touches a preview with releases")
(d.SITES / "plain").mkdir(); d.drop_if_empty("plain")
check((d.SITES / "plain").is_dir(), "drop_if_empty never touches a normal app")

# --- previews: a name belongs to one branch (collision guard)
own = pn("demo-site", "b02x")
d.record_preview_branch(own, "b02x")
check(raises(d.DeployError, lambda: d.check_preview(own, "someone-else")), "a branch that maps to another branch's name cannot overwrite it")
check(fine(lambda: d.check_preview(own, "b02x")), "the owning branch can update it")
check(raises(d.DeployError, lambda: d.remove_preview(own, "someone-else")) and (d.SITES / own).is_dir(),
      "a delete for another branch cannot remove it")

pv = d.SITES / pn("demo-site", "b00x")
(pv / "releases" / "20260101-000000").mkdir(parents=True, exist_ok=True)
os.symlink("releases/20260101-000000", pv / "current")
(d.SITES / ".tmp-del-old-leftover").mkdir()
d.remove_preview(pv.name)
check(not pv.exists() and not list(d.SITES.glob(".tmp-del-*")), "remove takes a preview away completely, and old leftovers too")

# --- previews: a lock waiter must not bring a removed preview back
lr = d.SITES / pn("demo-site", "lockrace"); (lr / "releases").mkdir(parents=True)
res = {}
def waiter():
    try:
        with d.locked(lr):
            res["b"] = "ran"
    except d.DeployError:
        res["b"] = "refused"
with d.locked(lr):
    t = threading.Thread(target=waiter); t.start(); time.sleep(0.5)
    os.rename(lr, d.SITES / ".tmp-del-race")      # what remove_preview does under the lock
t.join(10)
check(res.get("b") == "refused" and not lr.exists(), f"a deploy waiting on the lock gives up instead of recreating the removed preview ({res})")
shutil.rmtree(d.SITES / ".tmp-del-race")

# --- previews: removal and build take the locks in the same order (no 10-minute deadlock)
d.LOCK_WAIT = 5
lo = d.SITES / pn("demo-site", "lockorder"); (lo / "releases").mkdir(parents=True)
order = []
def fake_build():  # a build: build lock, a moment later the deploy lock
    try:
        with d.locked(lo, ".build.lock"):
            time.sleep(1)
            with d.locked(lo):
                order.append("build")
    except d.DeployError as e:
        order.append(f"build failed: {e}")
t = threading.Thread(target=fake_build); t.start(); time.sleep(0.3)
t0 = time.time()
removed = fine(lambda: d.remove_preview(lo.name))
t.join(10)
check(order == ["build"] and removed and time.time() - t0 < 4 and not lo.exists(),
      f"a removal during a build waits for it, then removes (no deadlock) ({order}, {time.time() - t0:.1f}s)")
d.LOCK_WAIT = 600

# --- previews: a rollback on a preview, then pruning to 2, never deletes the live release
src = tmp / "site"; src.mkdir(); (src / "index.html").write_text("v")
rp = pn("demo-site", "rollprune")
for _ in range(3):
    d.deploy(rp, src)
root, rels, cur = d.app_paths(rp)
d.rollback(rp)
live = d.current_id(cur)
check(live in d.release_ids(rels) and len(d.release_ids(rels)) == 2, "after a rollback the older live release is still there")
d.deploy(rp, src)
ids = d.release_ids(rels)
check(d.current_id(cur) in ids and len(ids) == 2, f"the next deploy keeps 2, including the live one ({ids})")

# --- git ls-remote: only the exact ref counts
real_git = w.git
w.git = lambda args, cwd=None, allow_file=False, token=None: ("a" * 40 + "\trefs/heads/x/refs/heads/foo\n" + "b" * 40 + "\trefs/heads/foo\n")
check(w.remote_tip({"url": "u", "branch": "foo"}, False) == "b" * 40, "the tip is read from exactly refs/heads/<branch>")
w.git = lambda args, cwd=None, allow_file=False, token=None: "a" * 40 + "\trefs/heads/x/refs/heads/foo\n"
check(w.remote_tip({"url": "u", "branch": "foo"}, False) == "", "a ref that only ENDS like the branch does not count")
w.git = real_git
(d.SITES / "demo-site").mkdir()
check(raises(d.DeployError, lambda: d.remove_preview("demo-site")) and (d.SITES / "demo-site").is_dir(),
      "remove refuses a normal app and leaves it alone")
check(raises(d.DeployError, lambda: d.remove_preview("../etc--x")), "remove refuses a path")

# --- previews: queue rules
jobs = w.Jobs()
mkp = lambda sha, action: {"app": "p", "sha": sha, "fallback": None, "action": action}
jobs.submit(mkp("a" * 40, "build")); jobs.submit(mkp("0" * 40, "remove"))
j = jobs.take(threading.Event())
check(j["action"] == "remove" and j["fallback"] is None, "a removal replaces a waiting build and never falls back to it")
jobs.submit(mkp("0" * 40, "remove")); jobs.submit(mkp("b" * 40, "build"))
j = jobs.take(threading.Event())
check(j["action"] == "build" and j["fallback"] is None, "a build never falls back to a removal")
jobs = w.Jobs(max_previews=3)
pjob = lambda b: {"app": pn("demo-site", b), "sha": "c" * 40, "fallback": None, "action": "build"}
for b in ("p1x", "p2x", "p3x"):
    jobs.submit(pjob(b))
check(raises(w.QueueFull, lambda: jobs.submit(pjob("p4x"))), "a flood of branches is capped: the 4th waiting preview is refused")
check(fine(lambda: jobs.submit(pjob("p1x"))), "a newer push to a preview that is already waiting is still accepted")
check(fine(lambda: jobs.submit({"app": "demo-site", "sha": "d" * 40, "fallback": None, "action": "build"})),
      "the live app is never capped")
check(jobs.take(threading.Event())["app"] == "demo-site", "the live app is taken first, ahead of waiting previews")
newer = pjob("p2x"); newer["sha"] = "e" * 40
jobs.submit(newer)
check(not jobs.requeue(pjob("p2x")) and jobs.pending[pn("demo-site", "p2x")]["sha"] == "e" * 40,
      "a busy job put back never replaces a newer waiting one")

# --- previews: config and restored queue
check(raises(w.ConfigError, cfg({"repos": {"a/b": {"app": "a" * 35, "previews": True}}})), "previews on an app name that is too long refused")
check(raises(w.ConfigError, cfg({"repos": {"a/b": {"app": "demo-site", "previews": "yes"}}})), "previews must be true or false")
check(raises(w.ConfigError, cfg({"repos": {"a/b": {"app": "x--demo"}}})), "an app name with '--' is refused (kept for previews)")
cfgp = cfg({"repos": {"a/b": {"app": "demo-site", "previews": True}}})()
sd = tmp / "st"; sd.mkdir()
st = w.State(b"s" * 32, cfgp, sd)
(sd / "pending.json").write_text(json.dumps([
    {"repo": "a/b", "sha": "b" * 40, "branch": "feature/x", "action": "build"},
    {"repo": "a/b", "sha": "0" * 40, "branch": "old", "action": "remove"},
    {"repo": "a/b", "sha": "c" * 40, "branch": "../x", "action": "build"},
    {"repo": "a/b", "sha": "c" * 40, "branch": "main", "action": "rm -rf"},
]))
restored = w.load_pending(st)
apps = sorted(j["app"] for j in st.jobs.drain())
check(restored == 2 and apps == sorted([pn("demo-site", "feature/x"), pn("demo-site", "old")]),
      f"a restored queue keeps valid preview jobs and drops junk (got {restored}: {apps})")
(sd / "pending.json").write_text(json.dumps([
    {"repo": "a/b", "sha": "b" * 40, "branch": "feature/x", "action": "build",
     "fallback": {"repo": "a/b", "sha": "f" * 40, "branch": "main", "action": "build"}},
]))
w.load_pending(st)
j = st.jobs.drain()[0]
check(j["fallback"] is None, "a restored fallback for ANOTHER branch is dropped (it would skip the tip check)")
deep = "[" * 100000 + "]" * 100000
(sd / "pending.json").write_text(deep)
check(fine(lambda: w.load_pending(st)) and (sd / "pending.bad").exists() and not (sd / "pending.json").exists(),
      "an unreadable pending.json is moved aside instead of crashing every start")

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
dirs=$(find /var/tmp -maxdepth 1 \( -name 'mini-deploy-hook-*' -o -name 'mini-deploy-build-*' \) -newer "$SRC/.started" | wc -l)
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
printf '{ "port": %s, "repos": {"a/b": {"app": "x--y"}} }' $((PORT+1)) > "$SRC/sepapp.json"
printf '{ "port": %s, "repos": {"a/b": {"app": "ok-app", "previews": 1}} }' $((PORT+1)) > "$SRC/badprev.json"
start_fail "app name with '--'"                "may not contain"    "$SECRET"  "$SRC/sepapp.json"
start_fail "previews that are not true/false"  "true or false"      "$SECRET"  "$SRC/badprev.json"

echo
echo "== 14. preview deploys: a branch gets its own site, the live app is untouched =="
cat > "$SRC/webhook-prev.json" <<JSON
{ "listen": "127.0.0.1", "port": $PORT,
  "repos": { "test/hook-repo": { "app": "$APP", "branch": "main", "subdir": "", "url": "file://$ORIGIN", "previews": true } } }
JSON
CONFIG=$SRC/webhook-prev.json
start_server && ok "server up with previews on" || bad "server did not start"
pname() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import deploy; print(deploy.preview_name(sys.argv[2], sys.argv[3]))' "$REPO/scripts" "$APP" "$1"; }
ppage() { curl -s -m 3 --resolve "$1.localhost:8080:127.0.0.1" "http://$1.localhost:8080/"; }
pcode() { curl -s -m 3 -o /dev/null -w '%{http_code}' --resolve "$1.localhost:8080:127.0.0.1" "http://$1.localhost:8080/"; }
pwait() { local i; for i in $(seq 1 90); do ppage "$1" | grep -q -- "$2" && return 0; sleep 1; done; return 1; }
bpush() { post push "$(guid)" "$(body test/hook-repo "refs/heads/$1" "$2")"; }
delbody() { python3 -c 'import json,sys; print(json.dumps({"ref":sys.argv[1],"after":"0"*40,"deleted":True,"repository":{"full_name":"test/hook-repo"}}))' "$1"; }
npreviews() { ls -d /sites/*--$APP 2>/dev/null | wc -l; }

PB="feature/Prev-$RUN"                 # has a slash and capitals: the site name is cleaned up
PNAME=$(pname "$PB")
echo "      branch $PB -> site $PNAME"
live_before=$(readlink "/sites/$APP/current")
g checkout -q -b "$PB"
SHA_P1=$(commit_page "$RUN-prev1")
expect "signed push to a feature branch" 202 "$(bpush "$PB" "$SHA_P1")"
if pwait "$PNAME" "marker-$RUN-prev1"; then ok "the preview at $PNAME.localhost shows the branch"; else bad "preview never showed marker-$RUN-prev1"; fi
ppage "$PNAME" | grep -q 'built with node v' && ok "and it was built in the container" || bad "preview was not built"
[ "$(readlink "/sites/$APP/current")" = "$live_before" ] && page | grep -q "marker-$RUN-s2" \
  && ok "the live app did not change" || bad "a branch push changed the live app"
newlog | grep -qE " $PNAME webhook [0-9]{8}-[0-9]{6}(-[0-9]+)? ok " && ok "the preview deploy is logged under its own name" || bad "no ok line for $PNAME"
newlog | grep -q "Prev-$RUN" && bad "the raw branch name reached the log" || ok "the raw branch name never reaches the log"
SHA_P2=$(commit_page "$RUN-prev2"); bpush "$PB" "$SHA_P2" >/dev/null
pwait "$PNAME" "marker-$RUN-prev2" && ok "a second push updates the preview" || bad "preview did not update"
SHA_P3=$(commit_page "$RUN-prev3"); bpush "$PB" "$SHA_P3" >/dev/null
pwait "$PNAME" "marker-$RUN-prev3" && ok "a third push updates it again" || bad "preview did not update again"
n=$(ls -A "/sites/$PNAME/releases" | grep -vc '^\.')
[ "$n" = 2 ] && ok "a preview keeps only 2 releases" || bad "preview has $n releases (want 2)"

$DEPLOY rollback "$PNAME" >/dev/null
[ -f "/sites/$PNAME/.hold" ] && [ ! -f "/sites/$APP/.hold" ] && ok "a rollback holds the preview, not the live app" || bad "hold landed on the wrong app"
$DEPLOY unhold "$PNAME" >/dev/null

np=$(npreviews)
for b in '../x' 'a/../b' '-x' 'a.lock' 'a//b' '.hidden' 'a/.b'; do
  expect "branch '$b' is not built" 202 "$(bpush "$b" "$SHA_P3")"
done
sleep 2
[ "$(npreviews)" = "$np" ] && ok "no preview was made for any of them" || bad "a hostile branch made a preview"
newlog | grep -q "push to a branch name we do not build" && ok "they are logged as ignored" || bad "hostile branches not logged"

BB="broken-$RUN"; BNAME=$(pname "$BB")
g checkout -q -b "$BB"; SHA_BB=$(break_build)
expect "push of a branch whose first build fails" 202 "$(bpush "$BB" "$SHA_BB")"
if wait_log " $BNAME webhook - fail " 120; then ok "the failed preview build was logged"; else bad "no failure line for $BNAME"; fi
[ ! -d "/sites/$BNAME/releases" ] && [ ! -e "/sites/$BNAME/.branch" ] \
  && ok "a failed FIRST build leaves no half-made app (no releases, so not counted or shown)" || bad "/sites/$BNAME looks like a real app"
g checkout -q "$PB"; g branch -q -D "$BB"

expect "'branch deleted' while the branch still exists (replay)" 202 "$(post push "$(guid)" "$(delbody "refs/heads/$PB")")"
if wait_log " $PNAME webhook - stale " 30; then ok "refused as stale"; else bad "replayed delete was not refused"; fi
[ -d "/sites/$PNAME" ] && [ "$(pcode "$PNAME")" = 200 ] && ok "the preview is still up" || bad "a replayed delete took the preview down"

g checkout -q main; g branch -q -D "$PB"
expect "branch really deleted" 202 "$(post push "$(guid)" "$(delbody "refs/heads/$PB")")"
if wait_log " $PNAME webhook - removed " 30; then ok "removal logged"; else bad "no removal line"; fi
[ ! -e "/sites/$PNAME" ] && [ "$(pcode "$PNAME")" = 404 ] && ok "the preview is gone: its address answers 404" || bad "preview still there"
page | grep -q "marker-$RUN-s2" && [ "$(readlink "/sites/$APP/current")" = "$live_before" ] && ok "the live app is still untouched" || bad "live app changed"
stop_server

mkdir -p "$SRC/pv"; echo "<h1>cli-preview-$RUN</h1>" > "$SRC/pv/index.html"
CNAME=$(pname "cli-$RUN")
$DEPLOY preview "$APP" "cli-$RUN" "$SRC/pv" | grep -q "address: http://$CNAME.localhost" && ok "deploy.py preview prints the address" || bad "deploy.py preview failed"
ppage "$CNAME" | grep -q "cli-preview-$RUN" && ok "a hand-made preview is served" || bad "hand-made preview not served"
$DEPLOY deploy "x--$APP" "$SRC/pv" >/dev/null 2>&1 && bad "deploy accepted a name with '--'" || ok "deploy refuses a name with '--' (previews only)"
$DEPLOY remove "$APP" >/dev/null 2>&1 && bad "remove accepted a normal app" || ok "remove refuses a normal app"
[ -L "/sites/$APP/current" ] && ok "and the normal app is still there" || bad "the normal app was touched"
$DEPLOY remove "$CNAME" | grep -q removed && [ ! -e "/sites/$CNAME" ] && ok "deploy.py remove takes a preview down" || bad "remove failed"
ls -d /sites/.tmp-del-* >/dev/null 2>&1 && bad "a removal left a .tmp-del folder" || ok "no removal leftovers in /sites"

echo
echo "== 15. a hard kill (power off, wsl --shutdown) does not lose queued pushes =="
CONFIG=$SRC/webhook.json
start_server && ok "server up" || bad "server did not start"
flock "/sites/$APP/.build.lock" sleep 12 & FL=$!; sleep 0.5
SHA_K1=$(commit_page "$RUN-k1"); push "$SHA_K1" >/dev/null
sleep 3                                              # the worker took K1 and waits for the lock
SHA_K2=$(commit_page "$RUN-k2"); push "$SHA_K2" >/dev/null
sleep 1
grep -q "$SHA_K1" "$STATE/pending.json" 2>/dev/null && grep -q "$SHA_K2" "$STATE/pending.json" \
  && ok "the push being built and the one waiting are both on disk before anything stops" \
  || bad "pending.json does not hold both: $(head -c 200 "$STATE/pending.json" 2>/dev/null)"
kill -9 "$SPID"; wait "$SPID" 2>/dev/null; SPID=""
ok "server killed with SIGKILL (no chance to save anything at the end)"
wait $FL 2>/dev/null
start_server && ok "server restarted" || bad "server did not restart"
if wait_for "marker-$RUN-k2" 150; then ok "after the restart the newest push went live: nothing was lost"; else bad "the queued push was lost in the hard kill"; fi
stop_server
installed=/etc/systemd/system/mini-deploy-webhook.service
if [ -f "$installed" ]; then
  grep -q '^RestartPreventExitStatus=1' "$installed" && ok "the real service does not restart-loop on a config error (exit 1)" || bad "service would loop on a bad config"
  grep -q '^ProtectSystem=strict' "$installed" && ok "the real service runs in a read-only sandbox" || bad "service has no sandbox"
fi

echo
echo
echo "== 16. repos connected from the admin page: own address and secret, static sites, token never logged =="
# The admin database and token file are the test's own (two switches, as in the other tests).
export MINI_DEPLOY_TESTING=1 MINI_DEPLOY_ADMIN_DB=$SRC/admin.db MINI_DEPLOY_TOKEN_FILE=$SRC/github-token
export MINI_DEPLOY_TEST_REPO_URL="file://$ORIGIN"
touch "$SRC/github-token" && chmod 600 "$SRC/github-token"
cat > "$SRC/conn.py" <<'PY'
# Test helper: the same functions the admin page calls. Secrets go to stdout only inside
# the test's own variables; the token comes from the environment, never argv.
import json, os, sys
sys.path.insert(0, "/mnt/c/Users/indra/Code/mini-deploy/scripts")
import admindb, repos
op, args = sys.argv[1], sys.argv[2:]
with admindb.db() as conn:
    if op == "connect":
        out = repos.connect(conn, args[0], args[1], subdir=args[2], kind=args[3])
    elif op == "rotate":
        out = repos.rotate(conn, args[0])
    elif op == "disconnect":
        repos.disconnect(conn, args[0]); out = {}
    elif op == "token":
        repos.set_token(os.environ["NEW_TOKEN"]); out = {"token": repos.token_status()}
    else:
        out = {"repos": repos.list_repos(conn)}
print(json.dumps(out))
PY
field()     { python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$1" <<<"$2"; }
sign_key()  { printf '%s' "$2" | KEY="$1" python3 -c 'import sys,os,hmac,hashlib; print("sha256="+hmac.new(os.environ["KEY"].encode(), sys.stdin.buffer.read(), hashlib.sha256).hexdigest())'; }
post_hook() { # hook_id event delivery body signature -> status code only
  curl -s -m 10 -o /dev/null -w '%{http_code}' -H "X-GitHub-Event: $2" -H "X-GitHub-Delivery: $3" \
    -H 'Content-Type: application/json' -H "X-Hub-Signature-256: $5" --data-binary "$4" "http://127.0.0.1:$PORT/webhook/$1"
}
check_code() { [ "$3" = "$2" ] && ok "$1 -> $2" || bad "$1 -> $3 (want $2)"; }
static_commit() {  # marker -> the new commit: the static site lives in site/
  mkdir -p "$ORIGIN/site"; echo "<h1>static-$1</h1>" > "$ORIGIN/site/index.html"
  g add -A >/dev/null; g commit -q -m "static $1"; g rev-parse HEAD
}
spage() { curl -s -m 3 --resolve "$1.localhost:8080:127.0.0.1" "http://$1.localhost:8080/"; }
swait() { # app marker seconds
  local i; for i in $(seq 1 "$3"); do spage "$1" | grep -q -- "$2" && return 0; sleep 1; done; return 1
}

stop_server
start_server && ok "server restarted with the admin database as its repo list" || { bad "server did not restart"; cat "$SRC/server.out"; }
CONN=$(python3 "$SRC/conn.py" connect test/db-repo hook-static site static)
HOOK=$(field hook_id "$CONN"); SEC=$(field secret "$CONN")
[[ "$HOOK" =~ ^[0-9a-f]{32}$ ]] && ok "connect makes an address: /webhook/<32 hex>" || bad "connect made a bad address"
[ "${#SEC}" -eq 64 ] && ok "connect makes a 64-character secret" || bad "connect made a secret of the wrong length"

S1=$(static_commit one); B=$(body test/db-repo refs/heads/main "$S1")
check_code "a signed push to its own address (static, subfolder site/)" 202 "$(post_hook "$HOOK" push "$(guid)" "$B" "$(sign_key "$SEC" "$B")")"
swait hook-static "static-one" 90 && ok "a static repo goes live with no build step" || bad "static repo did not go live"
check_code "the global secret does not open a repo's address" 401 "$(post_hook "$HOOK" push "$(guid)" "$B" "$(sign_key "$SECRET" "$B")")"
check_code "an unknown address" 401 "$(post_hook 00000000000000000000000000000000 push "$(guid)" "$B" "$(sign_key "$SEC" "$B")")"
check_code "a malformed address" 404 "$(post_hook nothex push "$(guid)" "$B" "$(sign_key "$SEC" "$B")")"
OTHER=$(body test/other-repo refs/heads/main "$S1")
check_code "a validly signed push for another repo, sent to this address" 400 "$(post_hook "$HOOK" push "$(guid)" "$OTHER" "$(sign_key "$SEC" "$OTHER")")"

TOKEN_VALUE=github_pat_TESTONLY$(python3 -c 'import secrets; print(secrets.token_hex(12))')   # test value only
NEW_TOKEN=$TOKEN_VALUE python3 "$SRC/conn.py" token >/dev/null && ok "token saved from the admin side" || bad "token was not saved"
r=$(python3 - "$TOKEN_VALUE" <<'PY'
# The token reaches git only through its environment, base64 encoded, never in argv.
import sys
sys.path.insert(0, "/mnt/c/Users/indra/Code/mini-deploy/scripts")
import webhook as w
tok = sys.argv[1]
seen = {}
class Proc:
    pid = 0
    returncode = 0
    def communicate(self, timeout=None):
        return "", ""
def fake(cmd, **kw):
    seen["cmd"], seen["env"] = cmd, kw.get("env", {})
    return Proc()
real = w.subprocess.Popen
w.subprocess.Popen = fake
try:
    w.git(["ls-remote", "--", "x", "refs/heads/main"], token=tok)
finally:
    w.subprocess.Popen = real
header = seen["env"].get("GIT_CONFIG_VALUE_0", "")
clean_argv = not any(tok in part for part in seen["cmd"])
in_env = header.startswith("Authorization: basic ") and tok not in header
no_redirects = "http.followRedirects=false" in seen["cmd"]
print("PASS" if clean_argv and in_env and no_redirects else "FAIL")
PY
)
[ "$r" = PASS ] && ok "the token is in the environment only (base64), never in argv; redirects are not followed" || bad "token position check: $r"

S2=$(static_commit two); B2=$(body test/db-repo refs/heads/main "$S2")
check_code "a push with a token on file" 202 "$(post_hook "$HOOK" push "$(guid)" "$B2" "$(sign_key "$SEC" "$B2")")"
swait hook-static "static-two" 90 && ok "the new commit is live" || bad "the new commit did not go live"
if newlog | grep -q -- "$TOKEN_VALUE" || grep -q -- "$TOKEN_VALUE" "$SRC/server.out"; then
  bad "the token appears in the log or the server output"
else ok "the token is in no log line and no server output"; fi

echo "SECRET=x" > "$ORIGIN/site/.env"; g add -A >/dev/null; g commit -q -m "hostile: env file"; S3=$(g rev-parse HEAD)
B3=$(body test/db-repo refs/heads/main "$S3")
check_code "a push with a .env inside the static site" 202 "$(post_hook "$HOOK" push "$(guid)" "$B3" "$(sign_key "$SEC" "$B3")")"
for i in $(seq 1 90); do newlog | grep "hook-static" | grep -q fail && break; sleep 1; done
newlog | grep "hook-static" | grep -q fail && ok "the hostile static checkout was refused and logged" || bad "no failure logged for the .env"
spage hook-static | grep -q "static-two" && ok "the last good static site is still live" || bad "the hostile push changed the live site"
rm -f "$ORIGIN/site/.env"; g add -A >/dev/null; g commit -q -m "remove the hostile file"

g mv site/index.html site/home.html; g commit -q -m "index.html renamed"; S3b=$(g rev-parse HEAD)
B3b=$(body test/db-repo refs/heads/main "$S3b")
check_code "a push whose static folder has no index.html" 202 "$(post_hook "$HOOK" push "$(guid)" "$B3b" "$(sign_key "$SEC" "$B3b")")"
wait_log "no index.html" 90 && ok "refused and logged: no index.html" || bad "a static folder without index.html was not refused"
spage hook-static | grep -q "static-two" && ok "the working site stays live" || bad "the site without index.html went live"

ROT=$(python3 "$SRC/conn.py" rotate test/db-repo); SEC2=$(field secret "$ROT")
S4=$(static_commit three); B4=$(body test/db-repo refs/heads/main "$S4")
check_code "the old secret stops working after a rotate" 401 "$(post_hook "$HOOK" push "$(guid)" "$B4" "$(sign_key "$SEC" "$B4")")"
check_code "the new secret works" 202 "$(post_hook "$HOOK" push "$(guid)" "$B4" "$(sign_key "$SEC2" "$B4")")"
swait hook-static "static-three" 90 && ok "the push signed with the new secret went live" || bad "new secret push did not go live"

chmod 644 "$SRC/admin.db"   # an unsafe database: the webhook must answer, not drop the connection
check_code "repo database unusable -> an answer (503), not a dropped connection" 503 "$(post_hook "$HOOK" push "$(guid)" "$B4" "$(sign_key "$SEC2" "$B4")")"
chmod 600 "$SRC/admin.db"
wait_log "repo database unavailable" 10 && ok "and the reason is logged" || bad "no log line for the database problem"

python3 "$SRC/conn.py" disconnect test/db-repo >/dev/null && ok "repo disconnected" || bad "disconnect failed"
S5=$(static_commit four); B5=$(body test/db-repo refs/heads/main "$S5")
check_code "a disconnected repo's address is refused" 401 "$(post_hook "$HOOK" push "$(guid)" "$B5" "$(sign_key "$SEC2" "$B5")")"
spage hook-static | grep -q "static-three" && ok "nothing was deployed after the disconnect" || bad "a disconnected repo deployed"

chmod 644 "$SRC/github-token"
units=$(python3 - "$SRC" <<'PY'
# Units for the review fixes: a queued job of a disconnected repo, an unusable token file,
# and queued pushes the database cannot check at startup.
import json, sqlite3, sys, tempfile
from pathlib import Path
sys.path.insert(0, "/mnt/c/Users/indra/Code/mini-deploy/scripts")
import webhook as w
src = Path(sys.argv[1])
tmp = Path(tempfile.mkdtemp(prefix="mini-deploy-hook-units-", dir=str(src)))
w.deploy_mod.LOG_FILE = tmp / "deploy.log"          # never the real deploy log
def check(ok, msg): print(("ok    " if ok else "FAIL  ") + msg)

st = w.State(b"x" * 32, {"listen": "127.0.0.1", "port": 9, "repos": {}})
job = {"app": "never-here", "repo": "test/never-connected", "sha": "a" * 40, "url": "", "branch": "main",
       "subdir": "site", "delivery": w.NO_DELIVERY, "fallback": None, "retried": False,
       "action": "build", "kind": "static", "private": True}
w.process(st, job, allow_file=True)
log = (tmp / "deploy.log").read_text() if (tmp / "deploy.log").exists() else ""
check("disconnected" in log, "a queued job of a repo that is no longer connected does nothing (logged 'disconnected')")

try:
    w.job_token({"private": True})
    check(False, "an unsafe token file raises GitError")
except w.GitError:
    check(True, "an unsafe token file is a GitError (a failed push, Redeliver still works)")

sd = tmp / "state"; sd.mkdir()
(sd / "pending.json").write_text(json.dumps([dict(job, repo="test/db-x", app="db-x")]))
real = w.repos_mod.repo_by_name
def busy(_name):
    raise sqlite3.OperationalError("database is locked")
w.repos_mod.repo_by_name = busy
try:
    n = w.load_pending(w.State(b"x" * 32, {"listen": "127.0.0.1", "port": 9, "repos": {}}, sd))
finally:
    w.repos_mod.repo_by_name = real
check(n == 0 and (sd / "pending.json").exists() and (sd / "pending.bad").exists(),
      "queued pushes the database cannot check are kept (pending.json stays, copy in pending.bad)")
PY
)
chmod 600 "$SRC/github-token"
echo "$units"
grep -q '^FAIL' <<<"$units" && fail=1
[ -n "$units" ] || bad "the unit checks did not run"
stop_server
unset MINI_DEPLOY_TEST_REPO_URL MINI_DEPLOY_TOKEN_FILE MINI_DEPLOY_ADMIN_DB MINI_DEPLOY_TESTING

if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOMETHING FAILED"; fi
exit $fail
