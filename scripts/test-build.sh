#!/usr/bin/env bash
# Stage 4 test: a repo with a build step deploys from a container build, and the
# container is locked down. Needs Docker and Caddy running (current Caddyfile).
# Creates the apps demo-site, probe-build, build-<pid>, logtest-<pid>, envtest-<pid> and
# its preview try-env--envtest-<pid> (and build logs for them under
# /var/log/mini-deploy/builds), plus /tmp folders (mini-deploy-btest-*, -envtest-*, -envunit-*).
# It never deletes anything itself; remove the leftovers with direct rm -rf commands.
# Pass = host has no node, the built page is live, a broken or hostile build
# changes nothing, and the build box is non-root, read-only and has no .env.
set -uo pipefail

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
const fs = require("fs"), os = require("os"), net = require("net");
let ro = "no"; try { fs.writeFileSync("/usr/probe", "x"); } catch (e) { ro = "yes"; }
// Network: which interfaces besides loopback, and can it open a connection out?
const ifs = Object.keys(os.networkInterfaces()).filter(n => n !== "lo");
const done = (out) => {
  fs.mkdirSync("dist", { recursive: true });
  fs.writeFileSync("dist/index.html",
    "uid:" + process.getuid() + " rootfs-readonly:" + ro +
    " env-file:" + (fs.existsSync(".env") ? "yes" : "no") +
    " postinstall:" + (fs.existsSync("postinstall-ran") ? "yes" : "no") +
    " interfaces:" + (ifs.length ? ifs.join(",") : "lo-only") + " connect-out:" + out + "\n");
};
const s = net.connect({ host: "1.1.1.1", port: 53, timeout: 4000 });
s.on("connect", () => { s.destroy(); done("yes"); });
s.on("timeout", () => { s.destroy(); done("timeout"); });
s.on("error", () => done("no"));'
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
grep -q 'interfaces:lo-only' <<<"$facts"   && ok "build box has no network interface"   || bad "build box has a network: $facts"
grep -q 'connect-out:no' <<<"$facts"       && ok "build box cannot connect out"         || bad "build box reached the outside: $facts"
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
echo "== 9. every build leaves a log, and build output cannot fake anything in it =="
LOGS=/var/log/mini-deploy/builds
newest() { ls -1t "$LOGS/$1"/*.log 2>/dev/null | head -1; }
okl=$(ls -1t "$LOGS/$APP"/*-ok.log 2>/dev/null | head -1)
[ -n "$okl" ] && grep -q '^result: ok$' "$okl" && grep -q 'built dist/ with node' "$okl" \
  && ok "a good build's log has its header and the build's own output" || bad "no ok log for $APP ($okl)"
failed=$(ls -1t "$LOGS/$APP"/*-fail.log 2>/dev/null | head -1)
[ -n "$failed" ] && grep -q '^result: fail$' "$failed" && grep -q '^error: ' "$failed" \
  && ok "a failed build's log says it failed and why" || bad "no fail log with an error line ($failed)"
LOGAPP=logtest-$$
make_repo "$SRC/hostile-out" '
process.stdout.write("\x1b[31mRED\x1b[0m plain\n");
process.stdout.write("about to be overwritten\rOVERWRITE\n");
process.stdout.write("result: ok\nerror: none\n");
process.stdout.write("nul\x00byte bell\x07\n");
process.exit(1);'
$BUILD $LOGAPP "$SRC/hostile-out" >/dev/null 2>&1
hl=$(newest $LOGAPP)
if [ -n "$hl" ]; then
  ok "a build that fails before deploying still gets a log"
  [ "$(sed -n '/^$/q;/^result: /p' "$hl")" = "result: fail" ] && ok "the header says fail; the fake 'result: ok' in the output stays below the header" || bad "header was fooled: $(head -8 "$hl")"
  grep -qP '\x1b|\x00|\x07' "$hl" && bad "escape or control characters reached the log" || ok "colour codes, NUL and bell were cleaned out"
  grep -q '^OVERWRITE$' "$hl" && grep -q '^about to be overwritten$' "$hl" && ok "a carriage return cannot hide the line before it" || bad "\\r handling: $(grep -a overwrit "$hl")"
else
  bad "no log for the failed build of $LOGAPP"
fi
out=$(python3 "$REPO/scripts/logs.py" $APP); grep -q 'show one:' <<<"$out" && ok "logs.py lists recent builds" || bad "logs.py list: $out"
python3 "$REPO/scripts/logs.py" $APP last | grep -q '^app: ' && ok "logs.py prints the newest log" || bad "logs.py last"
python3 "$REPO/scripts/logs.py" Bad_App >/dev/null 2>&1 && bad "logs.py accepted a bad name" || ok "logs.py refuses a bad app name"
python3 - <<PY || fail=1
import os, sys, tempfile, time, json
from pathlib import Path
sys.path.insert(0, "$REPO/scripts")
import buildlog
bad = 0
def check(ok, msg):
    global bad
    print(("ok    " if ok else "FAIL  ") + msg)
    bad += not ok
tmp = Path(tempfile.mkdtemp(prefix="mini-deploy-logunit-"))
buildlog.LOGS_ROOT = tmp / "builds"   # never the real folder
sites = tmp / "sites"; (sites / "keep-app").mkdir(parents=True)
# size cap: the start and the end stay, the middle is cut
cap = buildlog.Capture()
for i in range(40000):
    cap.add(f"line {i:05d} " + "x" * 40 + "\n")
text = cap.text()
check(len(text.encode()) < buildlog.HEAD_BYTES + buildlog.TAIL_BYTES + 200, f"a huge log is capped ({len(text) // 1024} KB)")
check("line 00000" in text and "line 39999" in text and "cut here" in text, "it keeps the first and the last lines and says what was cut")
# retention
for i in range(25):
    buildlog.write("keep-app", "ok" if i % 2 else "fail", {"app": "keep-app", "result": "ok"}, f"build {i}\n")
logs = buildlog.logs_of(buildlog.LOGS_ROOT / "keep-app")
check(len(logs) == buildlog.KEEP, f"only the newest {buildlog.KEEP} logs are kept (found {len(logs)})")
check(logs[0].read_text().endswith("build 24\n"), "newest first")
# the index lists existing apps (and gone ones only while they are recent)
buildlog.write("gone-app", "fail", {"app": "gone-app"}, "x\n")
old = buildlog.write("old-gone", "fail", {"app": "old-gone"}, "x\n")
past = time.time() - buildlog.LIST_GONE_FOR - 60
os.utime(old, (past, past))
buildlog.write_index(sites)
names = [a["name"] for a in json.loads((buildlog.LOGS_ROOT / "index.json").read_text())["apps"]]
check(names == ["gone-app", "keep-app"], f"index: existing apps, plus recently failed ones without a folder (got {names})")
check(buildlog.write("Bad_App", "ok", {}, "x") is None and buildlog.write("ok-app", "maybe", {}, "x") is None,
      "bad app names and results write nothing")
buildlog.remove_app("gone-app")
check(not (buildlog.LOGS_ROOT / "gone-app").exists(), "remove_app deletes an app's logs")
hdr = buildlog.write("keep-app", "fail", {"app": "keep-app", "error": "two\nlines\x1b[2J"}, "")
check(len(buildlog.read_header(hdr)) == 2 and "\x1b" not in hdr.read_text(), "a header value cannot add a line or an escape code")

# two builds finishing at once (different apps, same moment): the list must never break
import threading
(sites / "par-a").mkdir(); (sites / "par-b").mkdir()
import deploy; deploy.SITES = sites
errors = []
def writer(app):
    for i in range(15):
        if buildlog.write(app, "ok", {"app": app}, f"{app} {i}\n") is None:
            errors.append(app)
ts = [threading.Thread(target=writer, args=(a,)) for a in ("par-a", "par-b", "keep-app")]
[t.start() for t in ts]; [t.join() for t in ts]
idx = json.loads((buildlog.LOGS_ROOT / "index.json").read_text())
counts = {a["name"]: len(a["builds"]) for a in idx["apps"]}
check(not errors and counts.get("par-a") == 15 and counts.get("par-b") == 15,
      f"three writers at once: no write lost, index.json is valid and complete ({counts})")
check(not list(buildlog.LOGS_ROOT.glob(".index.json*.tmp")), "no temp files left behind")

# logs of an app that is gone for a month are deleted, not kept forever
gone = buildlog.write("month-gone", "ok", {"app": "month-gone"}, "x\n")
past = time.time() - buildlog.DELETE_GONE_AFTER - 60
os.utime(gone, (past, past))
buildlog.write_index(sites)
check(not (buildlog.LOGS_ROOT / "month-gone").exists(), "logs of an app gone for a month are deleted")

# a giant line without a newline, and millions of tiny lines: memory and time stay bounded
import resource, subprocess
sys.path.insert(0, "$REPO/scripts")
import build
def pump(cmd):
    cap, tail = buildlog.Capture(), __import__("collections").deque(maxlen=40)
    p = subprocess.Popen(["python3", "-c", cmd], stdout=subprocess.PIPE)
    t0 = time.monotonic()
    build.print = lambda *a, **k: None   # keep the test's own output short
    build.pump_output(p.stdout, cap, tail)
    del build.print
    p.wait()
    return cap, time.monotonic() - t0
before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
cap, took = pump("import sys; sys.stdout.write('x' * 150_000_000)")
grew_mb = (resource.getrusage(resource.RUSAGE_SELF).ru_maxrss - before) / 1024
size_kb = len(cap.text().encode()) // 1024
check(grew_mb < 80 and size_kb <= 1100, f"a 150 MB line with no newline: memory grew {grew_mb:.0f} MB, log {size_kb} KB, {took:.1f}s")
cap, took = pump("import sys; sys.stdout.write('a\\\\n' * 2_000_000)")
check(took < 30 and len(cap.text().encode()) <= buildlog.HEAD_BYTES + buildlog.TAIL_BYTES + 200,
      f"2 million tiny lines: {took:.1f}s, still capped")

# a log step that fails must not turn a finished deploy into an error
build._build_locked = lambda *a, **k: "20260101-000000"
build.sweep_stale = lambda: None
real_write = buildlog.write
buildlog.write = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("disk full"))
pkg = tmp / "pkg"; pkg.mkdir(); (pkg / "package.json").write_text("{}")
deploy.SITES = sites
try:
    got = build.build_and_deploy("keep-app", pkg)
    check(got == "20260101-000000", "a broken log step leaves a good deploy good")
except Exception as e:
    check(False, f"a broken log step turned a good deploy into {type(e).__name__}: {e}")
buildlog.write = real_write
sys.exit(1 if bad else 0)
PY

echo
echo "== 10. env values reach the build only: masked, never in the site, previews kept apart =="
# A temp store, never the real /etc/mini-deploy/apps (the owner's values stay untouched).
# The override needs the second switch, MINI_DEPLOY_TESTING=1.
export MINI_DEPLOY_APP_ENV=$(mktemp -d /tmp/mini-deploy-envtest-XXXXXX) MINI_DEPLOY_TESTING=1
ENVCLI="python3 $REPO/scripts/appenv.py"
ENVAPP=envtest-$$
SECRET="s3cret-$$-$RANDOM-zz"
printf '%s\n' "$SECRET" | $ENVCLI set $ENVAPP API_TOKEN >/dev/null && ok "set a secret from stdin" || bad "set secret"
printf '%s' "https://api.example.test" | $ENVCLI set $ENVAPP PUBLIC_URL --public >/dev/null && ok "set a public value" || bad "set public"
mode=$(stat -c '%a %U' "$MINI_DEPLOY_APP_ENV/$ENVAPP.json")
[ "$mode" = "600 root" ] && ok "the file is 600 and root's" || bad "file mode/owner: $mode"
listed=$($ENVCLI list $ENVAPP)
grep -q "$SECRET" <<<"$listed" && bad "list printed the secret" || ok "list never prints a secret ($(tr '\n' ' ' <<<"$listed"))"
grep -q 'PUBLIC_URL=https://api.example.test' <<<"$listed" && ok "list shows public values" || bad "list: $listed"
expect_error "a secret shorter than 8"   "at least 8"   bash -c "printf short | $ENVCLI set $ENVAPP SHORT"
expect_error "NODE_OPTIONS"              "not allowed"  bash -c "printf 'xxxxxxxxx' | $ENVCLI set $ENVAPP NODE_OPTIONS"
expect_error "an npm setting"            "not allowed"  bash -c "printf 'xxxxxxxxx' | $ENVCLI set $ENVAPP NPM_CONFIG_REGISTRY"
expect_error "a lowercase/odd name"      "bad name"     bash -c "printf 'xxxxxxxxx' | $ENVCLI set $ENVAPP 'a;b'"
expect_error "a preview name"            "--preview"    bash -c "printf 'xxxxxxxxx' | $ENVCLI set x--$ENVAPP KEY"
expect_error "a bad app name"            "bad app name" bash -c "printf 'xxxxxxxxx' | $ENVCLI set ../etc KEY"
expect_error "two lines"                 "one line"     bash -c "printf 'aaaaaaaaa\nbbbbbbbbb\n' | $ENVCLI set $ENVAPP TWO"
for k in HTTPS_PROXY NO_PROXY SSL_CERT_FILE OPENSSL_CONF NODE_TLS_REJECT_UNAUTHORIZED TMPDIR BASH_ENV GIT_SSH_COMMAND; do
  expect_error "$k" "not allowed" bash -c "printf 'xxxxxxxxx' | $ENVCLI set $ENVAPP $k"
done
expect_error "a value that is not UTF-8"  "not valid UTF-8" bash -c "printf 'abc\xff\xfedefgh' | $ENVCLI set $ENVAPP BIN"
printf 'production' | $ENVCLI set $ENVAPP NODE_ENV --public >/dev/null && ok "NODE_ENV is allowed" || bad "NODE_ENV refused"
$ENVCLI unset $ENVAPP NODE_ENV >/dev/null

# A build that uses both values, prints the secret (must be masked) and writes only
# the public one into the page.
make_repo "$SRC/envok" '
const fs = require("fs");
const t = process.env.API_TOKEN || "";
console.log("token is " + t + " and again " + t);
fs.mkdirSync("dist", { recursive: true });
fs.writeFileSync("dist/index.html", "url:" + process.env.PUBLIC_URL +
  " has-secret:" + (t ? "yes" : "no") + " secret-len:" + t.length + "\n");'
out=$($BUILD $ENVAPP "$SRC/envok" 2>&1); rc=$?
[ $rc -eq 0 ] && ok "a build with values deployed" || bad "env build failed: $(tail -3 <<<"$out")"
page=$(get $ENVAPP); echo "page says: $page"
grep -q 'url:https://api.example.test' <<<"$page" && ok "the public value reached the build" || bad "public value missing"
grep -q "has-secret:yes secret-len:${#SECRET}" <<<"$page" && ok "the secret reached the build, whole" || bad "secret missing in the build"
grep -q "$SECRET" <<<"$out" && bad "the secret was printed to the terminal" || ok "terminal output has no secret"
grep -q 'token is \[hidden\] and again \[hidden\]' <<<"$out" && ok "printed secrets show as [hidden]" || bad "no [hidden] in output"
el=$(newest $ENVAPP)
grep -q "$SECRET" "$el" && bad "the secret is in the build log" || ok "build log has no secret"
grep -q '^env: API_TOKEN, PUBLIC_URL$' "$el" && ok "the log header lists the names only" || bad "env header: $(grep '^env' "$el")"
grep -rq "$SECRET" "/sites/$ENVAPP/" && bad "the secret is in /sites" || ok "the secret is nowhere in the release"
grep -q "$SECRET" /var/log/mini-deploy.log && bad "the secret is in the deploy log" || ok "deploy log has no secret"

# A build that puts the secret into the site is refused; the live page stays.
before=$(link_of $ENVAPP)
make_repo "$SRC/envleak" '
const fs = require("fs"); fs.mkdirSync("dist/js", { recursive: true });
fs.writeFileSync("dist/index.html", "<h1>hi</h1>");
fs.writeFileSync("dist/js/app.js", "x".repeat(1048570) + "const k=\"" + process.env.API_TOKEN + "\";");'
expect_error "a secret written into dist (across a 1 MB read boundary)" "secret appears in dist.*API_TOKEN" $BUILD $ENVAPP "$SRC/envleak"
# The same secret, but the way bundlers and auth code write it: base64 inside a longer
# text (a Basic auth header), and a JS string of a secret with quotes and slashes.
make_repo "$SRC/envb64" '
const fs = require("fs"); fs.mkdirSync("dist", { recursive: true });
const h = Buffer.from("user:" + process.env.API_TOKEN).toString("base64");
console.log("auth header " + h);
fs.writeFileSync("dist/index.html", "<script>fetch(\"/x\",{headers:{Authorization:\"Basic " + h + "\"}})</script>");'
out=$($BUILD $ENVAPP "$SRC/envb64" 2>&1)
grep -q '^error:.*secret appears in dist' <<<"$out" && ok "a base64-encoded secret in dist is refused" || bad "base64 leak: $(tail -2 <<<"$out")"
grep -q 'auth header .*\[hidden\]' <<<"$out" && ok "the base64 form is masked in the output too" || bad "base64 not masked: $(grep 'auth header' <<<"$out")"
QUOTED="a\"b/c\\d</x>-$$-q"
printf '%s' "$QUOTED" | $ENVCLI set $ENVAPP QUOTED_TOKEN >/dev/null
make_repo "$SRC/envjson" '
const fs = require("fs"); fs.mkdirSync("dist", { recursive: true });
fs.writeFileSync("dist/index.html", "<h1>x</h1>");
fs.writeFileSync("dist/cfg.js", "window.cfg=" + JSON.stringify({ t: process.env.QUOTED_TOKEN }).replace(/\//g, "\\/") + ";");'
expect_error "a secret with quotes written as a JS string" "secret appears in dist.*QUOTED_TOKEN" $BUILD $ENVAPP "$SRC/envjson"
$ENVCLI unset $ENVAPP QUOTED_TOKEN >/dev/null
[ "$(link_of $ENVAPP)" = "$before" ] && ok "current did not move" || bad "current moved after a leak"

# npm ci runs in its own box WITHOUT the values: an install script cannot see a secret.
make_repo "$SRC/envinstall" '
const fs = require("fs"); fs.mkdirSync("dist", { recursive: true });
fs.writeFileSync("dist/index.html", "install-saw:" + fs.readFileSync("install-saw", "utf8") +
  " build-saw:" + (process.env.API_TOKEN ? "yes" : "no") + "\n");'
cat > "$SRC/envinstall/package.json" <<'JSON'
{ "name": "envinstall", "version": "1.0.0", "private": true,
  "scripts": { "build": "node build.js", "postinstall": "node -e \"require('fs').writeFileSync('install-saw', process.env.API_TOKEN ? 'yes' : 'no')\"" },
  "engines": { "node": ">=22" } }
JSON
$BUILD $ENVAPP "$SRC/envinstall" --install-scripts >/dev/null 2>&1 || bad "install-script build failed"
grep -q 'install-saw:no build-saw:yes' <<<"$(get $ENVAPP)" && ok "npm ci (install scripts) saw no secret; npm run build did" \
  || bad "install step: $(get $ENVAPP)"

# Previews never get the live values; they get their own (--preview) or none.
$BUILD $ENVAPP "$SRC/envok" --preview try-env >/dev/null 2>&1 && ok "preview built" || bad "preview build failed"
grep -q 'has-secret:no' <<<"$(get try-env--$ENVAPP)" && grep -q 'url:undefined' <<<"$(get try-env--$ENVAPP)" \
  && ok "a preview does NOT get the live app's values" || bad "preview got live values: $(get try-env--$ENVAPP)"
printf '%s' "preview-only-value-$$" | $ENVCLI set $ENVAPP API_TOKEN --preview >/dev/null
$BUILD $ENVAPP "$SRC/envok" --preview try-env >/dev/null 2>&1
grep -q "has-secret:yes secret-len:$(printf '%s' "preview-only-value-$$" | wc -c)" <<<"$(get try-env--$ENVAPP)" \
  && ok "a preview gets its own --preview value" || bad "preview value: $(get try-env--$ENVAPP)"

# A store file that others can read, or a link, is not trusted: the build stops.
chmod 644 "$MINI_DEPLOY_APP_ENV/$ENVAPP.json"
expect_error "a world-readable env file" "read by others" $BUILD $ENVAPP "$SRC/envok"
chmod 600 "$MINI_DEPLOY_APP_ENV/$ENVAPP.json"
ln -s "$MINI_DEPLOY_APP_ENV/$ENVAPP.json" "$MINI_DEPLOY_APP_ENV/link-$$.json"
expect_error "an env file that is a link" "env values" $BUILD link-$$ "$SRC/envok"
# Broken files fail the build clearly (and fast: a FIFO must not hang it).
printf '{"A": ' > "$MINI_DEPLOY_APP_ENV/badjson-$$.json"; chmod 600 "$MINI_DEPLOY_APP_ENV/badjson-$$.json"
expect_error "an env file that is not JSON" "not valid JSON" $BUILD badjson-$$ "$SRC/envok"
python3 -c "import sys; sys.stdout.write('{\"A\": {\"value\": \"' + 'x' * 1100000 + '\", \"public\": true}}')" > "$MINI_DEPLOY_APP_ENV/huge-$$.json"
chmod 600 "$MINI_DEPLOY_APP_ENV/huge-$$.json"
expect_error "an env file over 1 MB" "larger than" $BUILD huge-$$ "$SRC/envok"
python3 -c "print('[' * 100000)" > "$MINI_DEPLOY_APP_ENV/deep-$$.json"; chmod 600 "$MINI_DEPLOY_APP_ENV/deep-$$.json"
expect_error "deeply nested JSON" "not valid JSON" $BUILD deep-$$ "$SRC/envok"
mkfifo -m 600 "$MINI_DEPLOY_APP_ENV/fifo-$$.json"
t0=$(date +%s)
expect_error "a FIFO at the env path" "not a regular file" timeout 60 $BUILD fifo-$$ "$SRC/envok"
[ $(( $(date +%s) - t0 )) -lt 30 ] && ok "... and it did not hang" || bad "FIFO took $(( $(date +%s) - t0 ))s"
chmod 755 "$MINI_DEPLOY_APP_ENV"
expect_error "a store folder others can read" "read by others" $BUILD $ENVAPP "$SRC/envok"
chmod 700 "$MINI_DEPLOY_APP_ENV"
real=$(env -u MINI_DEPLOY_TESTING python3 -c "import sys; sys.path.insert(0, '$REPO/scripts'); import appenv; print(appenv.ENV_ROOT)")
[ "$real" = /etc/mini-deploy/apps ] && ok "MINI_DEPLOY_APP_ENV alone does not move the real store" || bad "override without the test switch: $real"
$ENVCLI unset $ENVAPP PUBLIC_URL >/dev/null; listed=$($ENVCLI list $ENVAPP)   # captured first: grep -q + pipefail
grep -q PUBLIC_URL <<<"$listed" && bad "unset left PUBLIC_URL" || ok "unset removes a value"

python3 - <<PY || fail=1
import os, subprocess, sys, tempfile
from pathlib import Path
sys.path.insert(0, "$REPO/scripts")
import build, buildlog, collections
bad = 0
def check(ok, msg):
    global bad
    print(("ok    " if ok else "FAIL  ") + msg)
    bad += not ok
secret = "Zq7-secret-value-1234567890"
# a secret cut in two by the 64 KB read limit is still masked
for pad in (build.CHUNK - 5, build.CHUNK - 1, build.CHUNK, build.CHUNK * 3 - 11):
    cap, tail = buildlog.Capture(), collections.deque(maxlen=40)
    p = subprocess.Popen(["python3", "-c", f"import sys; sys.stdout.write('x' * {pad} + '{secret}' + 'y' * 10 + '\\\\n' + '{secret}')"],
                         stdout=subprocess.PIPE)
    build.print = lambda *a, **k: None
    build.pump_output(p.stdout, cap, tail, list(build.all_forms({"K": secret})))
    del build.print
    p.wait()
    text = cap.text()
    check(secret not in text and text.count("[hidden]") == 2 and text.count("x") == pad,
          f"secret across the read limit (padding {pad}) is masked, nothing lost")
# the docker command lines carry names, never values; npm ci gets none at all
calls = []
class FakeProc:
    stdout = open(os.devnull, "rb")
    def wait(self, timeout=None): return 0
def fake_popen(cmd, **kw):
    calls.append((cmd, kw.get("env", {})))
    return FakeProc()
real_popen, real_run = build.subprocess.Popen, build.subprocess.run
build.subprocess.Popen = fake_popen
build.subprocess.run = lambda *a, **k: None
os.environ["SOME_HOST_SETTING"] = "host-only"
build.docker_build(Path("/nonexistent"), "img", False, None, {"API_TOKEN": secret, "MODE": "x"},
                   list(build.all_forms({"API_TOKEN": secret})))
build.subprocess.Popen, build.subprocess.run = real_popen, real_run
(ci_cmd, ci_env), (cmd, env) = calls
check(len(calls) == 2 and ci_cmd[-1].startswith("npm ci") and cmd[-1] == "npm run build", "two boxes: npm ci, then npm run build")
check(cmd[cmd.index("--network") + 1] == "none" if "--network" in cmd else False, "the build box (with values) has no network")
check("--network" not in ci_cmd, "the npm ci box keeps the network (it downloads packages)")
check("API_TOKEN" not in ci_cmd and "API_TOKEN" not in ci_env, "the npm ci box gets no app values")
check(not any(secret in a for c, _ in calls for a in c), "the secret is not on any docker command line")
check(cmd[cmd.index("API_TOKEN") - 1] == "-e" and "MODE" in cmd, "names are passed as -e KEY")
check(cmd.index("API_TOKEN") < cmd.index("HOME=/tmp"), "our own HOME comes after the app's values (it wins)")
check(env.get("API_TOKEN") == secret, "the value travels in the docker client's environment")
check("SOME_HOST_SETTING" not in env and "PATH" in env, "the docker client gets a small environment, not all of ours")

# encoded forms are found and masked; a short piece is not used (false alarms)
import base64, json as js, html as ht, urllib.parse as up
q = 'p"a/s\\\\s<w>&rd-' + "é" * 3 + "-9"
forms = build.all_forms({"Q": q})
long_b64 = base64.b64encode(b"Basic user:" + q.encode())
for label, text in [("JSON (ascii)", js.dumps(q).encode()), ("JSON (utf-8)", js.dumps(q, ensure_ascii=False).encode()),
                    ("JS with <\\/", js.dumps(q).replace("/", "\\\\/").encode()), ("HTML", ht.escape(q).encode()),
                    ("URL", up.quote(q, safe="").encode()), ("base64 inside a longer text", long_b64),
                    ("URL-safe base64", base64.urlsafe_b64encode(b"xy" + q.encode()))]:
    check(any(f in text for f in forms) and b"[hidden]" in build.mask(text, list(forms)), f"{label} form is caught")
check(all(len(f) >= build.MIN_FORM for f in forms), "no form shorter than 8 bytes")

# find_secret: file names too, a FIFO does not hang it, a huge dist is refused before reading
tmp = Path(tempfile.mkdtemp(prefix="mini-deploy-envunit-"))
(tmp / "a").mkdir(); (tmp / "a" / "ok.txt").write_text("nothing here")
os.mkfifo(tmp / "a" / "pipe")
check(build.find_secret(tmp, build.all_forms({"K": secret})) is None, "clean dist passes, a FIFO is skipped (no hang)")
(tmp / "a" / (secret + ".txt")).write_text("x")
check(build.find_secret(tmp, build.all_forms({"K": secret})) == "K", "a secret in a file NAME is found")
big = tmp / "big"; big.mkdir()
with open(big / "sparse.bin", "wb") as fh:
    fh.truncate(build.deploy_mod.MAX_RELEASE_BYTES + 1)   # sparse: costs no disk
t0 = __import__("time").monotonic()
try:
    build.find_secret(big, build.all_forms({"K": secret}))
    check(False, "a dist over the release cap was scanned")
except build.BuildError as e:
    took = __import__("time").monotonic() - t0
    check("larger than" in str(e) and took < 2, f"a dist over 500 MB is refused before reading ({took:.2f}s)")

# the admin page shows a reason word, never the key name, for the new errors
import dashboard
for detail, word in [("env values could not be used; nothing was deployed: GIT_TOKEN is not allowed", "env problem"),
                     ("o/r abc1234 d (fallback) env values could not be used; nothing was deployed: x", "env problem"),
                     ("a secret appears in dist/; nothing was deployed: GIT_TOKEN (if it is not secret ...)", "refused: secret in output")]:
    got = dashboard.public_detail("build", "fail", detail)
    check(word in got and "GIT_TOKEN" not in got, f"the admin page says {got!r}")

# the webhook does not walk the fallback chain for an env-file problem (it would fail the same)
import deploy, webhook
deploy.LOG_FILE = tmp / "deploy.log"   # never the real deploy log
tried = []
def fake_run_job(j, allow_file, check_tip=True):
    tried.append(j["sha"])
    raise build.EnvBuildError("env values could not be used; nothing was deployed: bad file")
webhook.run_job = fake_run_job
class Seen:
    def remove(self, d): pass
state = type("S", (), {"seen": Seen()})()
old = {"repo": "o/r", "sha": "b" * 40, "delivery": "d2", "app": "envtest-unit"}
new = {"repo": "o/r", "sha": "a" * 40, "delivery": "d1", "app": "envtest-unit", "fallback": old}
webhook.process(state, new, False)
check(tried == ["a" * 40], f"an env error stops the fallback chain (tried {len(tried)} push(es))")
sys.exit(1 if bad else 0)
PY

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOMETHING FAILED"; fi
exit $fail
