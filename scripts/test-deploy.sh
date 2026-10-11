#!/usr/bin/env bash
# Stage 3 test: deploy, roll back, deploy again while requests keep flowing.
# Needs Caddy running (stage 2). Creates /sites/demo and /tmp/mini-deploy-test.
# Pass = every request answered 200 with a complete page, and bad input is refused.
set -uo pipefail

DEPLOY="python3 /mnt/c/Users/indra/Code/mini-deploy/scripts/deploy.py"
APP=demo
SRC=/tmp/mini-deploy-test
LOG=$SRC/requests.log
fail=0

# Three tiny "builds". 300 extra files make each copy take a moment, so a
# half-finished release would be visible if the flip were not atomic.
rm -f "$LOG"
for v in v1 v2 v3; do
  mkdir -p "$SRC/$v"
  printf '<h1>%s</h1>' "$v" > "$SRC/$v/index.html"
  for i in $(seq 1 300); do echo "$i" > "$SRC/$v/f$i.txt"; done
done

get() {  # one request to the demo site; prints "<body> <status>"
  curl -s -m 2 -o - -w ' %{http_code}\n' \
    --resolve "$APP.localhost:8080:127.0.0.1" "http://$APP.localhost:8080/"
}

echo "== 1. deploy, roll back, deploy again, with requests in a loop =="
$DEPLOY deploy $APP "$SRC/v1" || fail=1

( while true; do get >> "$LOG"; sleep 0.01; done ) &
LOOP=$!

sleep 0.3; $DEPLOY deploy $APP "$SRC/v2" || fail=1
sleep 0.3; $DEPLOY rollback $APP          || fail=1   # back to v1
sleep 0.3; $DEPLOY deploy $APP "$SRC/v3" || fail=1
sleep 0.3; $DEPLOY rollback $APP          || fail=1   # back to v2
sleep 0.3

kill $LOOP; wait $LOOP 2>/dev/null

total=$(wc -l < "$LOG")
bad=$(grep -vcE '^<h1>v[123]</h1> 200$' "$LOG")
echo
echo "what visitors saw, in order (count, response):"
uniq -c "$LOG"
echo
echo "requests: $total   broken or half-built: $bad"
if [ "$bad" -ne 0 ] || [ "$total" -lt 20 ]; then echo "FAIL  loop"; fail=1; else echo "ok    no broken request"; fi

echo
echo "== 2. releases =="
$DEPLOY list $APP

echo
echo "== 3. bad input is refused and nothing moves =="
before=$(readlink /sites/$APP/current)
mkdir -p "$SRC/withlink"; echo hi > "$SRC/withlink/index.html"; ln -sfn /etc/passwd "$SRC/withlink/leak"

expect_fail() {  # label, command...
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then echo "FAIL  $label (was accepted)"; fail=1
  else echo "ok    $label refused"; fi
}
expect_fail "uppercase/underscore name"  $DEPLOY deploy Bad_App "$SRC/v1"
expect_fail "path traversal in name"     $DEPLOY deploy ../etc "$SRC/v1"
expect_fail "41-character name"          $DEPLOY deploy aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$SRC/v1"
expect_fail "missing source folder"      $DEPLOY deploy $APP "$SRC/nope"
expect_fail "source with a symlink"      $DEPLOY deploy $APP "$SRC/withlink"
expect_fail "current is a real folder"   $DEPLOY deploy hello "$SRC/v1"
expect_fail "unknown release id"         $DEPLOY rollback $APP 19990101-000000
expect_fail "release id with a path"     $DEPLOY rollback $APP ../../etc

after=$(readlink /sites/$APP/current)
if [ "$before" = "$after" ]; then echo "ok    current did not move ($after)"; else echo "FAIL  current moved: $before -> $after"; fail=1; fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOMETHING FAILED"; fi
exit $fail
