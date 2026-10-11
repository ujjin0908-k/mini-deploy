#!/usr/bin/env bash
# Stage 5 test: a signed push deploys, a bad signature is rejected, and everything
# the payload could try is ignored. Needs Docker and Caddy (current Caddyfile) running.
#
# It starts its OWN webhook server on 127.0.0.1:9101 with a random secret and a
# throw-away local git repo standing in for GitHub, so it never touches your real
# .env or config. Creates the app "hook-test" and a /tmp folder; it never deletes
# anything itself (remove leftovers with direct rm -rf commands).
set -uo pipefail

REPO=/mnt/c/Users/indra/Code/mini-deploy
SRC=$(mktemp -d /tmp/mini-deploy-hook-test-XXXXXX)
ORIGIN=$SRC/origin
PORT=9101
APP=hook-test
LOGFILE=/var/log/mini-deploy.log
URL=http://127.0.0.1:$PORT/webhook
SECRET=$(python3 -c 'import secrets; print(secrets.token_hex(32))')   # never printed
export SECRET
fail=0

ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }

g()    { git -C "$ORIGIN" -c user.name=test -c user.email=test@example.invalid "$@"; }
guid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
sign() { printf '%s' "$1" | python3 -c 'import sys,os,hmac,hashlib; print("sha256="+hmac.new(os.environ["SECRET"].encode(), sys.stdin.buffer.read(), hashlib.sha256).hexdigest())'; }
body() { python3 -c 'import json,sys; print(json.dumps({"ref":sys.argv[2],"after":sys.argv[3],"deleted":False,"repository":{"full_name":sys.argv[1]},"clone_url":"file:///etc"}))' "$@"; }

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
wait_for() { local i; for i in $(seq 1 "${2:-90}"); do page | grep -q "$1" && return 0; sleep 1; done; return 1; }
wait_log() { local i; for i in $(seq 1 "${2:-90}"); do grep -q -- "$1" "$LOGFILE" && return 0; sleep 1; done; return 1; }
commit_page() {  # marker -> prints the new commit sha
  sed -i "s|<h1>.*</h1>|<h1>marker-$1, built with __BUILT_WITH__</h1>|" "$ORIGIN/src/index.html"
  g add -A >/dev/null; g commit -q -m "page $1"; g rev-parse HEAD
}

echo "== 0. set up: a local repo standing in for GitHub, and a server of our own =="
mkdir -p "$ORIGIN"; cp -r "$REPO/examples/static-site/." "$ORIGIN"
g init -q -b main
g config uploadpack.allowAnySHA1InWant true
g add -A; g commit -q -m base
BASE=$(g rev-parse HEAD)
cat > "$SRC/webhook.json" <<JSON
{ "listen": "127.0.0.1", "port": $PORT,
  "repos": { "test/hook-repo": { "app": "$APP", "branch": "main", "subdir": "", "url": "file://$ORIGIN" } } }
JSON
WEBHOOK_SECRET=$SECRET python3 "$REPO/scripts/webhook.py" --config "$SRC/webhook.json" --allow-file-urls >"$SRC/server.out" 2>&1 &
SPID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
curl -s -o /dev/null "http://127.0.0.1:$PORT/" && ok "server is up" || { bad "server did not start"; cat "$SRC/server.out"; exit 1; }

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
r_ping=$(post ping "$(guid)" '{"zen":"hi"}');                               expect "signed ping" 200 "$r_ping"

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
SHA1=$(commit_page one)
D1=$(guid); B1=$(body test/hook-repo refs/heads/main "$SHA1")
expect "signed push" 202 "$(post push "$D1" "$B1")"
if wait_for "marker-one"; then ok "live site shows the pushed commit"; else bad "site never showed marker-one"; fi
page | grep -q 'built with node v' && ok "and it was built in the container" || bad "page was not built"
link1=$(readlink "/sites/$APP/current")
n1=$(ls -A "/sites/$APP/releases" | grep -vc '^\.')
expect "the same delivery again (replay)" 202 "$(post push "$D1" "$B1")"
post push "$D1" "$B1" | grep -q duplicate && ok "replay is answered 'duplicate'" || bad "replay not recognised"
sleep 4
[ "$(readlink /sites/$APP/current)" = "$link1" ] && [ "$(ls -A /sites/$APP/releases | grep -vc '^\.')" = "$n1" ] \
  && ok "replay deployed nothing" || bad "replay changed the site"

echo
echo "== 4. a broken build leaves the live site up =="
echo 'process.exit(1)' > "$ORIGIN/build.js"
g add -A >/dev/null; g commit -q -m "break the build"
SHA2=$(g rev-parse HEAD)
expect "push of a broken build" 202 "$(post push "$(guid)" "$(body test/hook-repo refs/heads/main "$SHA2")")"
if wait_log " $APP webhook - fail .*${SHA2:0:7}" 120; then ok "failure was logged"; else bad "no failure in the log"; fi
[ "$(readlink /sites/$APP/current)" = "$link1" ] && page | grep -q 'marker-one' \
  && ok "live site still serves marker-one" || bad "live site changed after a failed build"
g checkout -q HEAD~1 -- build.js; g commit -q -m "fix the build"   # put the working build.js back

echo
echo "== 5. two quick pushes: the newest wins =="
SHA3=$(commit_page three); SHA4=$(commit_page four)
post push "$(guid)" "$(body test/hook-repo refs/heads/main "$SHA3")" >/dev/null
post push "$(guid)" "$(body test/hook-repo refs/heads/main "$SHA4")" >/dev/null
if wait_for "marker-four" 150; then ok "site ended on the newest commit"; else bad "site never showed marker-four"; fi
sleep 2; page | grep -q marker-four && ok "and stayed there" || bad "an older build overwrote it"

echo
echo "== 6. secret, binding, log =="
if grep -q -- "$SECRET" "$SRC/server.out" "$LOGFILE" 2>/dev/null; then bad "the secret appears in the output or log"; else ok "secret is not in server output or the deploy log"; fi
# Look at the LOCAL address column only (the peer column always says 0.0.0.0:*).
listen=$(ss -ltn | awk -v want=":$PORT" '$4 ~ want "$" {print $4}')
echo "      listening on: $listen"
[ "$listen" = "127.0.0.1:$PORT" ] && ok "listens on 127.0.0.1 only" || bad "not loopback only: $listen"
grep -q " webhook webhook - rejected .*signature" "$LOGFILE" && ok "rejections are logged" || bad "no rejection log line"
grep -q " $APP webhook - ok " "$LOGFILE" && ok "successful webhook deploy is logged" || bad "no ok line"
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null

echo
echo "== 7. the server refuses to start in an unsafe setup =="
start_fail() {  # label, pattern, secret, config, extra args...
  local label=$1 pat=$2 sec=$3 cfg=$4; shift 4
  local out; out=$(WEBHOOK_SECRET=$sec timeout 10 python3 "$REPO/scripts/webhook.py" --config "$cfg" "$@" 2>&1); local rc=$?
  [ $rc -eq 1 ] && grep -q "^error:.*$pat" <<<"$out" && ok "$label refused" || bad "$label (exit $rc): $out"
}
printf '{ "listen": "0.0.0.0", "port": %s, "repos": {} }' $((PORT+1)) > "$SRC/exposed.json"
printf '{ "listen": "127.0.0.1", "port": %s, "repos": {"a/b": {"app": "Bad_App"}} }' $((PORT+1)) > "$SRC/badapp.json"
start_fail "no secret"                 "WEBHOOK_SECRET"  ""            "$SRC/webhook.json" --allow-file-urls
start_fail "short secret"              "WEBHOOK_SECRET"  "tooshort"    "$SRC/webhook.json" --allow-file-urls
start_fail "listening on 0.0.0.0"      "listen must be"  "$SECRET"     "$SRC/exposed.json"
start_fail "bad app name in config"    "bad app name"    "$SECRET"     "$SRC/badapp.json"
start_fail "file:// URL without the test flag" "https://github.com" "$SECRET" "$SRC/webhook.json"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOMETHING FAILED"; fi
exit $fail
