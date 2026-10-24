#!/usr/bin/env bash
# Stage 3 test: deploy, roll back, deploy again while requests keep flowing, plus
# the failure paths the deploy review found. Needs Caddy running with the current
# caddy/Caddyfile. Creates a few small apps under /sites (names end in the PID) and
# a /tmp folder. It never deletes anything itself; remove the leftovers with direct
# rm -rf commands.
# Pass = every request answered 200 with a complete page, bad input is refused with
# a clear "error:" message, and nothing is left half-done.
set -uo pipefail

REPO=/mnt/c/Users/indra/Code/mini-deploy
DEPLOY="python3 $REPO/scripts/deploy.py"
APP=demo
SRC=$(mktemp -d /tmp/mini-deploy-test-XXXXXX)   # fresh and unpredictable
LOG=$SRC/requests.log
# The command-line runs below log to a temp file, never the live deploy log (its failure lines
# would show on the admin page). They still go to the real Caddy and /sites, which is the point
# of this test, so the smoke check runs against Caddy too.
LOGFILE=$SRC/deploy.log
export MINI_DEPLOY_TESTING=1 MINI_DEPLOY_LOG=$LOGFILE MINI_DEPLOY_SMOKE_URL=http://127.0.0.1:8080
fail=0

ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }
link_of() { readlink "/sites/$1/current"; }
host_get() {  # app path -> body and status
  curl -s -m 3 -o - -w ' [%{http_code}]' --resolve "$1.localhost:8080:127.0.0.1" "http://$1.localhost:8080$2"
}
live_id() { $DEPLOY deploy "$@" | awk '/^live:/{print $2}'; }

# Expect exit code 1 AND a readable "error:" line, so a Python crash cannot pass.
expect_error() {  # label, command...
  local label=$1; shift
  local err rc
  err=$("$@" 2>&1 >/dev/null); rc=$?
  if [ $rc -eq 1 ] && grep -q '^error:' <<<"$err"; then ok "$label refused"
  else bad "$label (exit $rc): $err"; fi
}

# Three tiny "builds". 300 extra files make each copy take a moment, so a
# half-finished release would be visible if the flip were not atomic.
for v in v1 v2 v3; do
  mkdir -p "$SRC/$v"
  printf '<h1>%s</h1>' "$v" > "$SRC/$v/index.html"
  for i in $(seq 1 300); do echo "$i" > "$SRC/$v/f$i.txt"; done
done
mkdir -p "$SRC/tiny"; printf '<h1>tiny</h1>' > "$SRC/tiny/index.html"

echo "== 1. deploy, roll back, roll forward, with requests in a loop =="
id1=$(live_id $APP "$SRC/v1")
# Each answer is captured first and written with ONE printf, so stopping the loop can
# never leave a half-written line behind (that once looked like a broken request).
( while true; do r=$(host_get $APP /); printf '%s\n' "$r" >> "$LOG"; sleep 0.01; done ) &
LOOP=$!

sleep 0.3; id2=$(live_id $APP "$SRC/v2")
[ "$(link_of $APP)" = "releases/$id2" ] && ok "deploy v2 is live" || bad "deploy v2 not live"
sleep 0.3; $DEPLOY rollback $APP >/dev/null
[ "$(link_of $APP)" = "releases/$id1" ] && ok "rollback landed on v1" || bad "rollback did not land on v1"
sleep 0.3; id3=$(live_id $APP "$SRC/v3")
[ "$(link_of $APP)" = "releases/$id3" ] && ok "deploy v3 is live" || bad "deploy v3 not live"
sleep 0.3; $DEPLOY rollback $APP >/dev/null
[ "$(link_of $APP)" = "releases/$id2" ] && ok "rollback from v3 landed on v2" || bad "rollback from v3 wrong"
sleep 0.3; $DEPLOY rollforward $APP >/dev/null
[ "$(link_of $APP)" = "releases/$id3" ] && ok "rollforward landed on v3" || bad "rollforward wrong"
sleep 0.3

kill $LOOP; wait $LOOP 2>/dev/null
total=$(wc -l < "$LOG")
broken=$(grep -vcE '^<h1>v[123]</h1> \[200\]$' "$LOG")
echo "requests: $total   broken or half-built: $broken"
if [ "$broken" -ne 0 ] || [ "$total" -lt 20 ]; then bad "request loop"; else ok "no broken request across 5 flips"; fi

echo
echo "== 2. releases =="
$DEPLOY list $APP

echo
echo "== 3. bad input is refused, with a message, and nothing moves =="
before=$(link_of $APP)
mkdir -p "$SRC/withlink";  echo hi > "$SRC/withlink/index.html"; ln -sfn /etc/passwd "$SRC/withlink/leak"
ln -sfn /etc "$SRC/linkedsrc"                               # the source folder itself is a link
mkdir -p "$SRC/withenv";   echo hi > "$SRC/withenv/index.html"; echo SECRET=1 > "$SRC/withenv/.env"
mkdir -p "$SRC/withgit/.git"; echo hi > "$SRC/withgit/index.html"
mkdir -p "$SRC/withfifo";  echo hi > "$SRC/withfifo/index.html"; mkfifo "$SRC/withfifo/pipe"
mkdir -p "$SRC/toobig";    echo hi > "$SRC/toobig/index.html"; truncate -s 600M "$SRC/toobig/data.bin"  # sparse
mkdir -p "/sites/realfolder-$$/current"                     # a real folder where the link should be

expect_error "uppercase/underscore name"  $DEPLOY deploy Bad_App "$SRC/tiny"
expect_error "path traversal in name"     $DEPLOY deploy ../etc "$SRC/tiny"
expect_error "41-character name"          $DEPLOY deploy aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$SRC/tiny"
expect_error "missing source folder"      $DEPLOY deploy $APP "$SRC/nope"
expect_error "source is a symlink"        $DEPLOY deploy $APP "$SRC/linkedsrc"
expect_error "symlink inside source"      $DEPLOY deploy $APP "$SRC/withlink"
expect_error ".env in source"             $DEPLOY deploy $APP "$SRC/withenv"
expect_error ".git in source"             $DEPLOY deploy $APP "$SRC/withgit"
expect_error "FIFO in source"             $DEPLOY deploy $APP "$SRC/withfifo"
expect_error "source over 500 MB"         $DEPLOY deploy $APP "$SRC/toobig"
expect_error "current is a real folder"   $DEPLOY deploy realfolder-$$ "$SRC/tiny"
expect_error "unknown release id"         $DEPLOY rollback $APP 19990101-000000
expect_error "release id with a path"     $DEPLOY rollback $APP ../../etc

# One deploy holds the lock; a second one must give up with a clear message.
flock "/sites/$APP/.lock" sleep 4 &
sleep 0.5
expect_error "second deploy while locked" env MINI_DEPLOY_LOCK_WAIT=1 $DEPLOY deploy $APP "$SRC/tiny"
wait

[ "$(link_of $APP)" = "$before" ] && ok "current did not move ($before)" || bad "current moved"
ls -A "/sites/$APP/releases" | grep -q '^\.tmp-' && bad "left a .tmp-* folder behind" || ok "no .tmp-* folder left behind"

echo
echo "== 4. dotfiles, setuid bits =="
DOTS=dots-$$
mkdir -p "$SRC/dots/.hiddendir"
echo '<h1>dots</h1>' > "$SRC/dots/index.html"
echo secret > "$SRC/dots/.hidden-file"
echo secret > "$SRC/dots/.hiddendir/inner.txt"
echo bin > "$SRC/dots/suid.bin"; chmod 4755 "$SRC/dots/suid.bin"
mkdir -p "$SRC/dots/open"; echo x > "$SRC/dots/open/all.txt"   # like a folder copied from C:
chmod 777 "$SRC/dots" "$SRC/dots/open"; chmod 666 "$SRC/dots/open/all.txt"
$DEPLOY deploy $DOTS "$SRC/dots" >/dev/null
for p in /index.html /.hidden-file /.hiddendir/inner.txt /%2ehidden-file; do
  want=404; [ "$p" = /index.html ] && want=200
  got=$(host_get $DOTS $p | grep -o '\[[0-9]*\]')
  [ "$got" = "[$want]" ] && ok "GET $p -> $want" || bad "GET $p -> $got (want $want)"
done
mode=$(stat -c %a "/sites/$DOTS/current/suid.bin")
[ "$mode" = 755 ] && ok "setuid bit stripped (mode $mode)" || bad "mode is $mode"
modes="$(stat -L -c %a "/sites/$DOTS/current") $(stat -c %a "/sites/$DOTS/current/open") $(stat -c %a "/sites/$DOTS/current/open/all.txt")"
[ "$modes" = "755 755 644" ] && ok "nothing in a release is writable by others (got $modes)" || bad "release modes: $modes"

echo
echo "== 5. prune keeps 5 and the live one, ids stay in order =="
PR=prune-$$
for i in $(seq 1 12); do $DEPLOY deploy $PR "$SRC/tiny" >/dev/null; done
count=$(ls -A "/sites/$PR/releases" | grep -vc '^\.')
[ "$count" = 5 ] && ok "12 deploys leave 5 releases" || bad "found $count releases"
$DEPLOY list $PR | tail -1 | grep -q '^\*' && ok "newest release is live and last in order" || bad "order wrong"

echo
echo "== 6. two deploys at the same time =="
PA=par-$$
$DEPLOY deploy $PA "$SRC/v1" >/dev/null
$DEPLOY deploy $PA "$SRC/v2" >/dev/null & p1=$!
$DEPLOY deploy $PA "$SRC/v3" >/dev/null & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
[ $r1 -eq 0 ] && [ $r2 -eq 0 ] && ok "both deploys finished" || bad "exit codes $r1 $r2"
n=$($DEPLOY list $PA | wc -l); live=$($DEPLOY list $PA | grep -c '^\*')
[ "$n" = 3 ] && [ "$live" = 1 ] && ok "3 releases, exactly one live" || bad "$n releases, $live live"

echo
echo "== 7. a deploy killed in the middle of the copy =="
KL=kill-$$
$DEPLOY deploy $KL "$SRC/tiny" >/dev/null
before=$(link_of $KL)
mkdir -p "$SRC/bigcopy"; echo hi > "$SRC/bigcopy/index.html"; truncate -s 300M "$SRC/bigcopy/data.bin"
$DEPLOY deploy $KL "$SRC/bigcopy" >/dev/null 2>&1 &
pid=$!
sleep 0.3; kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null; rc=$?
if [ $rc -eq 137 ]; then
  [ "$(link_of $KL)" = "$before" ] && ok "killed mid-copy: current did not move" || bad "current moved after kill"
  left=$(ls -A "/sites/$KL/releases" | grep -c '^\.tmp-')
  echo "      leftover .tmp-* folders after the kill: $left"
  $DEPLOY deploy $KL "$SRC/tiny" >/dev/null
  ls -A "/sites/$KL/releases" | grep -q '^\.tmp-' && bad "stale .tmp-* not cleaned" || ok "next deploy cleaned up the leftover"
else
  echo "skip  deploy finished before the kill (timing); exit $rc"
fi

echo
echo "== 8. release ids =="
python3 - <<PY || fail=1
import sys, time
sys.path.insert(0, "$REPO/scripts")
import deploy as d
t = time.gmtime(0)
cases = [
    ("later local-time ids exist", d.next_release_id(["20261011-232150", "20261011-232150-1"], t), "20261011-232150-002"),
    ("empty", d.next_release_id([], t), "19700101-000000"),
    ("same second", d.next_release_id(["19700101-000000"], t), "19700101-000000-001"),
]
order = sorted(["20260101-000000-10", "20260101-000000-2", "20260101-000000"], key=d.id_key)
cases.append(("-2 sorts before -10", order, ["20260101-000000", "20260101-000000-2", "20260101-000000-10"]))
bad = 0
for label, got, want in cases:
    ok = got == want
    bad += not ok
    print(("ok    " if ok else "FAIL  ") + f"{label}: {got}")
sys.exit(1 if bad else 0)
PY

echo
echo "== 9. the deploy log =="
grep -q " $APP deploy $id2 ok " "$LOGFILE" && ok "successful deploy is logged" || bad "no log line for deploy"
grep -q " invalid-name deploy - fail " "$LOGFILE" && ok "failed deploy is logged (name shown as invalid-name)" || bad "no log line for failure"
grep -q " $APP deploy - fail .*symlink" "$LOGFILE" && ok "failure reason is logged" || bad "no failure reason in log"
[ "$(stat -c %a "$LOGFILE")" = 640 ] && ok "the deploy log is 640 (root only)" || bad "deploy log mode $(stat -c %a "$LOGFILE")"

echo
echo "== 10. private state files: created narrow, old wide ones narrowed, links refused =="
python3 - "$SRC" <<PY || fail=1
import os, sys, stat
sys.path.insert(0, "$REPO/scripts")
import deploy, webhook
tmp = sys.argv[1]
bad = 0
def check(cond, msg):
    global bad
    print(("ok    " if cond else "FAIL  ") + msg); bad += not cond
mode = lambda p: stat.S_IMODE(os.lstat(p).st_mode)
deploy.LOG_FILE = __import__("pathlib").Path(tmp, "deploy.log")          # never the real log
deploy.log_event("demo", "deploy", None, "ok", 0)
check(mode(deploy.LOG_FILE) == 0o640, f"a new deploy log is 640 (got {mode(deploy.LOG_FILE):o})")
os.chmod(deploy.LOG_FILE, 0o644)
deploy.log_event("demo", "deploy", None, "ok", 0)
check(mode(deploy.LOG_FILE) == 0o640, "an old 644 deploy log is narrowed to 640")
target = os.path.join(tmp, "elsewhere.txt"); open(target, "w").close()
link = os.path.join(tmp, "linked.log"); os.symlink(target, link)
deploy.LOG_FILE = __import__("pathlib").Path(link)
deploy.log_event("demo", "deploy", None, "ok", 0)       # warns, never follows the link
check(os.path.getsize(target) == 0, "a link in place of the log is not followed")
seen_path = os.path.join(tmp, "deliveries")
open(seen_path, "w").close(); os.chmod(seen_path, 0o644)
s = webhook.Seen(seen_path)
check(mode(seen_path) == 0o600, f"an old 644 deliveries file is narrowed at start (got {mode(seen_path):o})")
os.remove(seen_path)
webhook.Seen(seen_path).add("12345678-1234-1234-1234-123456789abc")
check(mode(seen_path) == 0o600, "a new deliveries file is 600")
sys.exit(1 if bad else 0)
PY

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOMETHING FAILED"; fi
exit $fail
