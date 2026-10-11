#!/usr/bin/env bash
# Stage 4 test: a repo with a build step deploys from a container build, and the
# container is locked down. Needs Docker and Caddy running (current Caddyfile).
# Creates the apps demo-site, probe-build and build-<pid>, plus a /tmp folder.
# It never deletes anything itself; remove the leftovers with direct rm -rf commands.
# Pass = host has no node, the built page is live, a broken or hostile build
# changes nothing, and the build box is non-root, read-only and has no .env.
set -uo pipefail
export MINI_DEPLOY_NO_DASHBOARD=1   # keep the real dashboard's releases quiet during tests

REPO=/mnt/c/Users/indra/Code/mini-deploy
BUILD="python3 $REPO/scripts/build.py build"
EXAMPLE="$REPO/examples/static-site"
SRC=$(mktemp -d /tmp/mini-deploy-btest-XXXXXX)   # fresh and unpredictable
APP=demo-site
fail=0

ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }
get() { curl -s -m 3 --resolve "$1.localhost:8080:127.0.0.1" "http://$1.localhost:8080/"; }
link_of() { readlink "/sites/$1/current"; }

# Expect exit code 1 AND an "error:" line containing a pattern.
expect_error() {  # label, pattern, command...
  local label=$1 pat=$2; shift 2
  local err rc
  err=$("$@" 2>&1 >/dev/null); rc=$?
  if [ $rc -eq 1 ] && grep -q "^error:.*$pat" <<<"$err"; then ok "$label refused"
  else bad "$label (exit $rc): $(tail -3 <<<"$err")"; fi
}

# A copy of the example with a replaced build.js.
make_repo() {  # dir, build.js content
  mkdir -p "$1"; cp -r "$EXAMPLE/." "$1"; printf '%s\n' "$2" > "$1/build.js"
}

echo "== 1. the host has no Node =="
if command -v node >/dev/null 2>&1; then bad "node is installed on the host"
else ok "node is not installed on the host"; fi

echo
echo "== 2. build in a container and deploy =="
if $BUILD $APP "$EXAMPLE"; then ok "build + deploy finished"; else bad "build failed"; fi
page=$(get $APP)
echo "live page: $page"
grep -q 'built with node v' <<<"$page" && ok "live page was produced by the build" || bad "page is not the built one"
grep -q '__BUILT' <<<"$page" && bad "unreplaced placeholder (source was deployed, not dist)"
image_line=$($BUILD $APP "$EXAMPLE" 2>&1 | grep '^image:')
grep -q '@sha256:' <<<"$image_line" && ok "image is pinned by digest" || bad "image not pinned: $image_line"

echo
echo "== 3. the build box is locked down =="
PROBE=probe-build
make_repo "$SRC/probe" '
const fs = require("fs");
let ro = "no"; try { fs.writeFileSync("/usr/probe", "x"); } catch (e) { ro = "yes"; }
fs.mkdirSync("dist", { recursive: true });
fs.writeFileSync("dist/index.html",
  "uid:" + process.getuid() + " rootfs-readonly:" + ro +
  " env-file:" + (fs.existsSync(".env") ? "yes" : "no") +
  " postinstall:" + (fs.existsSync("postinstall-ran") ? "yes" : "no") + "\n");'
echo "SECRET=do-not-leak" > "$SRC/probe/.env"
# A lifecycle script that would run during npm ci if scripts were allowed.
cat > "$SRC/probe/package.json" <<'JSON'
{ "name": "probe", "version": "1.0.0", "private": true,
  "scripts": { "build": "node build.js", "postinstall": "node -e \"require('fs').writeFileSync('postinstall-ran','1')\"" },
  "engines": { "node": ">=22" } }
JSON
if $BUILD $PROBE "$SRC/probe" >/dev/null 2>&1; then ok "probe build deployed"; else bad "probe build failed"; fi
facts=$(get $PROBE)
echo "probe says: $facts"
grep -q 'uid:1000 ' <<<"$facts"            && ok "build ran as uid 1000, not root"      || bad "build ran as root or unknown"
grep -q 'rootfs-readonly:yes' <<<"$facts"  && ok "container filesystem is read-only"    || bad "container filesystem writable"
grep -q 'env-file:no' <<<"$facts"          && ok ".env was not copied into the box"     || bad ".env reached the container"
grep -q 'postinstall:no' <<<"$facts"       && ok "npm lifecycle scripts did not run"    || echo "note  postinstall ran or unknown: $facts"
[ -e "/sites/$PROBE/current/.env" ] && bad ".env was published" || ok ".env is not in the release"

echo
echo "== 4. a broken or hostile build changes nothing =="
before=$(link_of $APP); page=$(get $APP)

make_repo "$SRC/broken" 'process.exit(1)'
expect_error "build that exits 1" "build failed" $BUILD $APP "$SRC/broken"

make_repo "$SRC/linkdist" 'require("fs").symlinkSync("/etc", "dist");'
expect_error "dist that is a symlink to /etc" "symlink" $BUILD $APP "$SRC/linkdist"

make_repo "$SRC/linkfile" '
const fs = require("fs"); fs.mkdirSync("dist");
fs.writeFileSync("dist/index.html", "<h1>x</h1>");
fs.symlinkSync("/etc/passwd", "dist/leak");'
expect_error "symlink inside dist" "symlink" $BUILD $APP "$SRC/linkfile"

make_repo "$SRC/emptydist" 'require("fs").mkdirSync("dist");'
expect_error "empty dist" "missing or empty" $BUILD $APP "$SRC/emptydist"

make_repo "$SRC/missing" 'process.exit(0)'
expect_error "no dist at all" "missing or empty" $BUILD $APP "$SRC/missing"

[ "$(link_of $APP)" = "$before" ] && ok "current did not move ($before)" || bad "current moved"
[ "$(get $APP)" = "$page" ] && ok "live page is unchanged" || bad "live page changed"

echo
echo "== 5. two builds of the same app at the same time =="
CC=build-$$
$BUILD $CC "$EXAMPLE" >/dev/null 2>&1 & b1=$!
$BUILD $CC "$EXAMPLE" >/dev/null 2>&1 & b2=$!
wait $b1; r1=$?; wait $b2; r2=$?
[ $r1 -eq 0 ] && [ $r2 -eq 0 ] && ok "both builds finished (run one after the other)" || bad "exit codes $r1 $r2"
n=$(ls -A "/sites/$CC/releases" | grep -vc '^\.')
[ "$n" = 2 ] && ok "2 releases, none lost" || bad "found $n releases"

echo
echo "== 6. bad input =="
mkdir -p "$SRC/nopkg"
expect_error "bad app name"       "bad app name"  $BUILD Bad_App "$EXAMPLE"
expect_error "no package.json"    "package.json"  $BUILD $APP "$SRC/nopkg"
expect_error "missing folder"     "package.json"  $BUILD $APP "$SRC/does-not-exist"

echo
echo "== 7. nothing left behind =="
left=$(docker ps -aq --filter "name=mini-deploy-build-" | wc -l)
[ "$left" = 0 ] && ok "no build containers left" || bad "$left containers left"
dirs=$(ls -d /var/tmp/mini-deploy-build-* 2>/dev/null | wc -l)
[ "$dirs" = 0 ] && ok "no work folders left" || bad "$dirs work folders left"

echo
echo "== 8. Node version is only a number =="
python3 - <<PY || fail=1
import sys, json, tempfile, pathlib
sys.path.insert(0, "$REPO/scripts")
import build
cases = {">=20": 20, "^22.1.0": 22, "": 22, "evil; rm -rf /": 22, "\$(touch x)18": 18, "99": 22, ">=4": 22}
bad = 0
for spec, want in cases.items():
    with tempfile.TemporaryDirectory() as tmp:  # removed again when the block ends
        d = pathlib.Path(tmp)
        pkg = {"engines": {"node": spec}} if spec != "" else {}
        (d / "package.json").write_text(json.dumps(pkg))
        got = build.node_major(d)
    ok = got == want
    bad += not ok
    print(("ok    " if ok else "FAIL  ") + f"engines.node={spec!r} -> node:{got}-slim")
sys.exit(1 if bad else 0)
PY

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOMETHING FAILED"; fi
exit $fail
