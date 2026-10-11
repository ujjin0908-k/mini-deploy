#!/usr/bin/env bash
# Stage 4 test: a repo with a build step deploys from a container build.
# Needs Docker and Caddy running. Creates the app "demo-site".
# Pass = host has no node, the built page is live, and a broken build changes nothing.
set -uo pipefail

REPO=/mnt/c/Users/indra/Code/mini-deploy
BUILD="python3 $REPO/scripts/build.py build"
APP=demo-site
fail=0

get() {
  curl -s -m 3 --resolve "$APP.localhost:8080:127.0.0.1" "http://$APP.localhost:8080/"
}

echo "== 1. the host has no Node =="
if command -v node >/dev/null 2>&1; then echo "FAIL  node is installed on the host"; fail=1
else echo "ok    node is not installed on the host"; fi

echo
echo "== 2. build in a container and deploy =="
if $BUILD $APP "$REPO/examples/static-site"; then echo "ok    build + deploy finished"; else echo "FAIL  build failed"; fail=1; fi
page=$(get)
echo "live page: $page"
if echo "$page" | grep -q 'built with node v'; then echo "ok    live page was produced by the build"; else echo "FAIL  page is not the built one"; fail=1; fi
if echo "$page" | grep -q '__BUILT'; then echo "FAIL  unreplaced placeholder (source was deployed, not dist)"; fail=1; fi

echo
echo "== 3. a broken build changes nothing =="
before=$(readlink /sites/$APP/current)
BROKEN=$(mktemp -d /tmp/mini-deploy-broken-XXXXXX)   # fresh folder, so no rm -rf needed
cp -r "$REPO/examples/static-site/." "$BROKEN"
echo 'process.exit(1)' > "$BROKEN/build.js"
if $BUILD $APP "$BROKEN" >/dev/null 2>&1; then echo "FAIL  broken build was accepted"; fail=1
else echo "ok    broken build refused"; fi
after=$(readlink /sites/$APP/current)
if [ "$before" = "$after" ]; then echo "ok    current did not move ($after)"; else echo "FAIL  current moved: $before -> $after"; fail=1; fi
if [ "$(get)" = "$page" ]; then echo "ok    live page is unchanged"; else echo "FAIL  live page changed"; fail=1; fi

echo
echo "== 4. bad input =="
expect_fail() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then echo "FAIL  $label (was accepted)"; fail=1
  else echo "ok    $label refused"; fi
}
expect_fail "bad app name"        $BUILD Bad_App "$REPO/examples/static-site"
expect_fail "no package.json"     $BUILD $APP /tmp
expect_fail "missing folder"      $BUILD $APP /tmp/does-not-exist

echo
echo "== 5. Node version is only a number =="
python3 - <<'PY'
import sys, json, tempfile, pathlib
sys.path.insert(0, "/mnt/c/Users/indra/Code/mini-deploy/scripts")
import build
cases = {">=20": 20, "^22.1.0": 22, "": 22, "evil; rm -rf /": 22, "$(touch x)18": 18, "99": 22, ">=4": 22}
bad = 0
for spec, want in cases.items():
    d = pathlib.Path(tempfile.mkdtemp())
    pkg = {"engines": {"node": spec}} if spec != "" else {}
    (d / "package.json").write_text(json.dumps(pkg))
    got = build.node_major(d)
    ok = got == want
    bad += not ok
    print(("ok    " if ok else "FAIL  ") + f"engines.node={spec!r} -> node:{got}-slim")
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || fail=1

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOMETHING FAILED"; fi
exit $fail
