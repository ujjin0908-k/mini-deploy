#!/usr/bin/env bash
# Stage 6 test: the pink glass sites deploy, the app list (dashboard.collect, shown on the
# admin page) reads real data, nothing phones home, and the look stays readable (contrast)
# and safe (no HTML injection). The Wi-Fi dashboard page is retired (2026-10-15); section 7
# checks it stays gone. Needs Docker and Caddy (current Caddyfile) running.
#
# This DEPLOYS two test apps: demo-site (built in Docker) and mini-deploy (the same sample's
# plain folder, no build), plus one hooktest-<pid> app. It never deletes anything; remove them
# afterwards (clean-test-leftovers.py).
set -uo pipefail

REPO=/mnt/c/Users/indra/Code/mini-deploy
SRC=$(mktemp -d /tmp/mini-deploy-sites-test-XXXXXX)
# The command-line deploys below log to a temp file, never the live deploy log. They still go to
# the real Caddy and /sites (this suite checks the live sites), so the smoke check runs against Caddy.
export MINI_DEPLOY_TESTING=1 MINI_DEPLOY_LOG=$SRC/deploy.log MINI_DEPLOY_SMOKE_URL=http://127.0.0.1:8080
fail=0

ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }
get()  { curl -s -m 5 -w ' [%{http_code}]' --resolve "$1.localhost:8080:127.0.0.1" "http://$1.localhost:8080${2:-/}"; }
code() { curl -s -m 5 -o /dev/null -w '%{http_code}' --resolve "$1.localhost:8080:127.0.0.1" "http://$1.localhost:8080${2:-/}"; }

echo "== 1. the theme copies are in step with the source =="
for f in web/logs/style.css web/admin/style.css examples/static-site/src/style.css; do
  if cmp -s "$REPO/web/theme/pink.css" "$REPO/$f"; then ok "$f matches web/theme/pink.css"
  else bad "$f is stale: run scripts/sync-theme.sh"; fi
done
h1_count=$(grep -c '<h1>' "$REPO/examples/static-site/src/index.html")
h1_line=$(grep '<h1>' "$REPO/examples/static-site/src/index.html" | tr -d '\r')   # Windows git may check it out with CRLF
[ "$h1_count" = 1 ] && [ "$h1_line" = '<h1>static-site, built with __BUILT_WITH__</h1>' ] \
  && ok "demo page keeps its one-line <h1> (the webhook test edits it)" || bad "demo <h1> changed shape: $h1_line"

echo
echo "== 2. static checks: nothing phones home, no HTML injection, readable colours =="
REPO=$REPO python3 - <<'PY' || fail=1
import os, re, sys
from pathlib import Path
repo = Path(os.environ["REPO"])
bad = 0
def check(ok, msg):
    global bad
    print(("ok    " if ok else "FAIL  ") + msg)
    bad += not ok

site_files = [p for root in ("web", "examples/static-site/src") for p in (repo / root).rglob("*") if p.is_file()]
check(all(not p.name.startswith(".") for p in site_files), "no dotfiles in the site sources")

leaks = []
for p in site_files:
    if p.suffix not in (".html", ".css", ".js"):
        continue
    text = p.read_text(encoding="utf-8")
    # (the SVG namespace name inside the grain is an identifier, not something fetched)
    for m in re.finditer(r"https?://(?!www\.w3\.org/2000/svg)|(?<![:\w])//[a-z0-9.-]+\.[a-z]{2,}", text):
        leaks.append(f"{p.relative_to(repo)}: {m.group(0)}")
    if re.search(r"@import|<link[^>]+rel=[\"']?(preconnect|dns-prefetch)", text):
        leaks.append(f"{p.relative_to(repo)}: import/preconnect")
check(not leaks, "no external URLs, fonts, imports or preconnects" + (f" ({leaks})" if leaks else ""))

check(not (repo / "web/dashboard").exists(), "the retired Wi-Fi dashboard page is gone from web/")
for site in ("logs",):
    js = (repo / f"web/{site}/app.js").read_text(encoding="utf-8")
    danger = [w for w in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function") if w in js]
    check(not danger, f"{site} JS never builds HTML from data" + (f" (found {danger})" if danger else ""))
    html = (repo / f"web/{site}/index.html").read_text(encoding="utf-8")
    csp = re.search(r'http-equiv="Content-Security-Policy" content="([^"]+)"', html)
    check(bool(csp) and "script-src 'self'" in csp.group(1) and "object-src 'none'" in csp.group(1),
          f"{site} has a Content-Security-Policy that only allows its own scripts")
    check(not re.search(r"<script(?![^>]*\bsrc=)", html), f"{site} has no inline script (the CSP would block it)")

css = (repo / "web/theme/pink.css").read_text(encoding="utf-8")
check("prefers-reduced-motion" in css, "animation respects prefers-reduced-motion")
check(":focus-visible" in css, "keyboard focus is visible")

# --- contrast (WCAG 2.x relative luminance)
def tok(name):
    return re.search(r"--%s:\s*(#[0-9A-Fa-f]{6})" % re.escape(name), css).group(1)
def rgb(h):
    h = h.lstrip("#"); return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
def lum(c):
    def f(v):
        v /= 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (f(v) for v in c)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
def ratio(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)
def over(alpha, bg):  # white glass at `alpha` over a background colour
    return tuple(round(alpha * 255 + (1 - alpha) * v) for v in bg)

ink, muted, deep = rgb(tok("ink")), rgb(tok("muted")), rgb(tok("deep"))
cream, blush, petal, rose = rgb(tok("cream")), rgb(tok("blush")), rgb(tok("petal")), rgb(tok("rose"))
on_dark, on_dark_muted = rgb(tok("on-dark")), rgb(tok("on-dark-muted"))
pairs = [
    ("ink on cream", ink, cream), ("ink on blush", ink, blush), ("ink on petal", ink, petal),
    ("muted on cream", muted, cream), ("muted on blush", muted, blush),
    ("muted on glass over petal", muted, over(0.58, petal)),
    ("muted on glass over rose", muted, over(0.58, rose)),
    ("deep on cream", deep, cream), ("deep on glass over blush", deep, over(0.58, blush)),
    ("ink on glass pill", ink, over(0.78, petal)),
    ("light text on dark card", on_dark, ink), ("muted light text on dark card", on_dark_muted, ink),
    ("ok-green on dark card", rgb("#9EE3BE"), ink), ("pink on dark card", rgb("#FFB3C9"), ink),
    ("white number on a deep badge", (255, 255, 255), deep),
    ("ok-green chip text is ink", ink, over(0.8, blush)),
]
# The mist background: text sits either right on it (headings, footers) or on glass
# over it. Check the strongest patch of every mist colour, tinted harder (85%) than
# anything the page actually draws, so the real page can only be better than this.
paper = rgb(tok("paper"))
def mist(name, strength=0.85):
    c = rgb(tok(name))
    return tuple(round(strength * c[i] + (1 - strength) * paper[i]) for i in range(3))
for name in ("mist-pink", "mist-rose", "mist-butter", "mist-sage", "mist-blue", "mist-lilac"):
    bg = mist(name)
    pairs.append((f"ink right on the {name}", ink, bg))
    pairs.append((f"muted right on the {name}", muted, bg))
    # glass is white at 46% where the browser can blur (66% where it cannot): test 46%
    pairs.append((f"muted on glass over the {name}", muted, over(0.46, bg)))
    pairs.append((f"deep on glass over the {name}", deep, over(0.46, bg)))

for name, fg, bg in pairs:
    r = ratio(fg, bg)
    check(r >= 4.5, f"contrast {name}: {r:.1f}:1")
check("prefers-reduced-motion" in css and "mist-drift" in css.split("prefers-reduced-motion")[1],
      "the mist only drifts when the device has not asked for reduced motion")
sys.exit(1 if bad else 0)
PY


echo
echo "== 3. log lines cannot inject anything, and bad lines are dropped =="
cat > "$SRC/evil.log" <<'LOG'
2026-10-12T01:00:00Z demo-site deploy 20261012-010000 ok 1.2s was=20261011-150008
2026-10-12T01:00:05Z demo-site webhook - fail 4.0s <script>alert(1)</script> <img src=x onerror=alert(2)>
2026-10-12T01:00:06Z Bad_App deploy - fail 0.1s uppercase app name must be dropped
not a log line at all
2026-10-12T01:00:07Z demo-site webhook - fail 0.2s xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
LOG
mkdir -p "$SRC/sites/demo-site/releases"   # the fixture's app exists in a temp /sites, not the real one
REPO=$REPO SRC=$SRC python3 - <<'PY' || fail=1
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["REPO"] + "/scripts")
import dashboard   # the admin page shows exactly what collect() returns
src = Path(os.environ["SRC"])
d = dashboard.collect(src / "sites", src / "evil.log")
bad = 0
def check(ok, msg):
    global bad
    print(("ok    " if ok else "FAIL  ") + msg)
    bad += not ok
ev = d["events"]
check(len(ev) == 3, f"3 well-formed lines kept, 2 dropped (kept {len(ev)})")
check(all(e["app"] != "Bad_App" for e in ev), "invalid app name is dropped")
check(all("<" not in e["detail"] and ">" not in e["detail"] for e in ev), "no markup at all reaches the page")
fails = [e["detail"] for e in ev if e["result"] == "fail"]
check(fails == ["failed", "failed"], f"a failure shows only a reason word, never its text (got {fails})")
check(all("/" not in e["detail"] for e in ev), "no paths reach the page")
check(d["attention"] == ["demo-site"], f"failed app is flagged (got {d['attention']})")
sys.exit(1 if bad else 0)
PY

echo
echo "== 3b. previews are listed right after their app, with their parent named =="
REPO=$REPO SRC=$SRC python3 - <<'PY' || fail=1
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["REPO"] + "/scripts")
import dashboard
bad = 0
def check(ok, msg):
    global bad
    print(("ok    " if ok else "FAIL  ") + msg)
    bad += not ok
root = Path(os.environ["SRC"]) / "fake-sites"
for name in ("zeta", "demo-site", "feat-x--demo-site", "abc--demo-site", "other", "dashboard"):
    (root / name / "releases").mkdir(parents=True)
apps = dashboard.collect_apps(root)
order = [a["name"] for a in apps]
check(order == ["demo-site", "abc--demo-site", "feat-x--demo-site", "other", "zeta"],
      f"each app is followed by its previews, and the old dashboard folder is not an app (got {order})")
parents = {a["name"]: a["preview_of"] for a in apps}
check(parents["feat-x--demo-site"] == "demo-site" and parents["demo-site"] is None, "previews name their parent, apps do not")
check(dashboard.public_detail("webhook", "removed", "test/repo 0000000 remove 1111") == "",
      "a deleted branch shows no fake all-zero commit")
sys.exit(1 if bad else 0)
PY

echo
echo "== 4. deploy the two sites =="
if python3 "$REPO/scripts/deploy.py" deploy mini-deploy "$REPO/examples/static-site/src" >/dev/null; then ok "a plain folder deployed (no build)"; else bad "plain folder deploy failed"; fi
if python3 "$REPO/scripts/build.py" build demo-site "$REPO/examples/static-site" >/dev/null 2>&1; then ok "demo-site built in Docker and deployed"; else bad "demo-site build failed"; fi

for app in mini-deploy demo-site; do
  [ "$(code $app /)" = 200 ] && ok "$app.localhost:8080 -> 200" || bad "$app did not answer 200"
  [ "$(code $app /style.css)" = 200 ] && ok "$app serves its stylesheet" || bad "$app has no style.css"
done
get demo-site / | grep -q 'built with node v' && ok "demo page was built (stamp present)" || bad "demo page has no build stamp"
get demo-site / | grep -q '__BUILT' && bad "demo page has an unreplaced placeholder"
get mini-deploy / | grep -q 'static-site, built with' && ok "the plain folder's page is served as it is" || bad "plain folder page content missing"

echo
echo "== 5. the app list (what the admin page shows) matches the real state =="
REPO=$REPO python3 - <<'PY' || fail=1
import os, sys
sys.path.insert(0, os.environ["REPO"] + "/scripts")
import dashboard
d = dashboard.collect()          # the real /sites and the real deploy log, read only
bad = 0
def check(ok, msg):
    global bad
    print(("ok    " if ok else "FAIL  ") + msg)
    bad += not ok
names = {a["name"] for a in d["apps"]}
check({"demo-site", "mini-deploy"} <= names, f"apps listed: {sorted(names)}")
for a in d["apps"]:
    live = [r for r in a["releases"] if r["live"]]
    ok_live = (a["live"] is None) or (len(live) == 1 and live[0]["id"] == a["live"])
    if not ok_live:
        check(False, f"{a['name']}: live marker does not match the live link")
        break
else:
    check(True, "every app has exactly one live marker, matching its link")
check(all(e["app"] != "dashboard" for e in d["events"]), "the old dashboard's refresh lines are left out of the activity")
check("dashboard" not in {a["name"] for a in d["apps"]}, "the retired dashboard is not listed as an app")
sys.exit(1 if bad else 0)
PY

echo
echo "== 6. the phone address works too (nip.io name, LAN address) =="
if ip -4 addr | grep -q 'inet 192\.168\.40\.241/'; then
  phone=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Host: mini-deploy.192-168-40-241.nip.io:8080' http://192.168.40.241:8080/)
  [ "$phone" = 200 ] && ok "mini-deploy.192-168-40-241.nip.io:8080 -> 200" || bad "phone-style host answered $phone"
  lanlogs=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Host: logs.localhost:8080' http://192.168.40.241:8080/)
  [ "$lanlogs" = 404 ] && ok "the build logs page is 404 from the Wi-Fi address" || bad "logs page answered $lanlogs on the Wi-Fi address"
else
  echo "skip  phone checks: this PC is not on the home Wi-Fi (no 192.168.40.241), so there is nothing to reach"
fi
dot=$(curl -s -m 5 -o /dev/null -w '%{http_code}' --resolve mini-deploy.localhost:8080:127.0.0.1 http://mini-deploy.localhost:8080/.hidden)
[ "$dot" = 404 ] && ok "dotfiles are still 404" || bad "dotfile answered $dot"
for app in demo-site mini-deploy; do
  for path in / /style.css; do
    curl -s -m 5 -I --resolve "$app.localhost:8080:127.0.0.1" "http://$app.localhost:8080$path" | grep -qi '^cache-control: no-cache' \
      && ok "$app$path is revalidated, so a deploy shows up at once" || bad "$app$path has no Cache-Control: no-cache"
  done
done

curl -s -m 5 -I --resolve demo-site.localhost:8080:127.0.0.1 http://demo-site.localhost:8080/ | grep -qi '^x-content-type-options: nosniff' \
  && ok "apps are served with X-Content-Type-Options: nosniff" || bad "no nosniff header"

echo
echo "== 7. the Wi-Fi dashboard stays retired; 'needs a look' still works for the admin page =="
HK=hooktest-$$
listed() { REPO=$REPO python3 -c "import os,sys; sys.path.insert(0, os.environ['REPO'] + '/scripts'); import dashboard; d = dashboard.collect(); print($1)"; }
mkdir -p "$SRC/hk-good"; echo '<h1>hook test</h1>' > "$SRC/hk-good/index.html"
mkdir -p "$SRC/hk-bad"; echo hi > "$SRC/hk-bad/index.html"; echo 'TOKEN=abc' > "$SRC/hk-bad/.env"

python3 "$REPO/scripts/deploy.py" deploy $HK "$SRC/hk-good" >/dev/null 2>&1
[ "$(listed "'$HK' in [a['name'] for a in d['apps']]")" = True ] && ok "a deployed app is in the app list" || bad "new app not listed"
[ ! -e /sites/dashboard ] && ok "no deploy brings the Wi-Fi dashboard back (/sites/dashboard does not exist)" \
  || bad "/sites/dashboard exists: something still publishes the retired page"
[ "$(code dashboard /)" = 404 ] && ok "dashboard.localhost:8080 answers 404" || bad "dashboard.localhost:8080 answered $(code dashboard /)"

python3 "$REPO/scripts/deploy.py" deploy $HK "$SRC/hk-bad" >/dev/null 2>&1 && bad "the .env deploy was accepted"
[ "$(listed "'$HK' in d['attention']")" = True ] && ok "a FAILED deploy: the app needs a look" || bad "failure not flagged"
reason=$(listed "[e['detail'] for e in d['events'] if e['app']=='$HK' and e['result']=='fail'][-1]")
[ "$reason" = "refused: unsafe file" ] && ok "the page shows only the reason: '$reason'" || bad "failure detail was: $reason"

python3 "$REPO/scripts/deploy.py" deploy $HK "$SRC/hk-good" >/dev/null 2>&1
[ "$(listed "'$HK' in d['attention']")" = False ] && ok "a later success clears 'needs a look'" || bad "attention did not clear"

# the name stays reserved, so an old bookmark can never open another app
out=$(python3 "$REPO/scripts/deploy.py" deploy dashboard "$SRC/hk-good" 2>&1); rc=$?
[ $rc = 1 ] && grep -q reserved <<<"$out" && ok "deploying to 'dashboard' by hand is refused" || bad "reserved name accepted: $out"
out=$(python3 "$REPO/scripts/deploy.py" deploy dashboard "$SRC/hk-good" --force 2>&1); rc=$?
[ $rc = 1 ] && grep -q 'does not change' <<<"$out" && [ ! -e /sites/dashboard/releases ] \
  && ok "--force cannot bring the dashboard back either" || bad "--force deployed to 'dashboard': $out"
echo "      (left behind for you to remove: /sites/$HK and $SRC)"

echo
echo "== 8. the build logs page: this PC only =="
lcode() { curl -s -m 5 -o /dev/null -w '%{http_code}' --resolve logs.localhost:8080:127.0.0.1 "http://logs.localhost:8080$1"; }
python3 -c "import sys; sys.path.insert(0, '$REPO/scripts'); import buildlog; buildlog.write_index()"
[ "$(lcode /)" = 200 ] && ok "logs.localhost answers this PC" || bad "logs page answered $(lcode /)"
[ "$(lcode /data/index.json)" = 200 ] && ok "and serves its list" || bad "index.json answered $(lcode /data/index.json)"
curl -s -m 5 --resolve logs.localhost:8080:127.0.0.1 http://logs.localhost:8080/ | grep -q 'Build logs' && ok "it is the logs page, not an app" || bad "wrong page on logs.localhost"
touch /var/log/mini-deploy/builds/.probe-hidden
for p in /data/.probe-hidden /data/.index.json.tmp /.hidden /data/../../etc/passwd; do
  c=$(lcode "$p"); [ "$c" = 404 ] && ok "logs.localhost$p -> 404" || bad "logs.localhost$p answered $c"
done
# Caddy decodes %2e%2e and tidies the path, so this lands on the page itself: never outside.
esc=$(curl -s -m 5 --resolve logs.localhost:8080:127.0.0.1 'http://logs.localhost:8080/data/%2e%2e/%2e%2e/etc/passwd')
grep -q 'root:' <<<"$esc" && bad "an encoded ../ escaped the logs folder" || ok "an encoded ../ never leaves the logs site"
rm -f /var/log/mini-deploy/builds/.probe-hidden
curl -s -m 5 -I --resolve logs.localhost:8080:127.0.0.1 http://logs.localhost:8080/data/index.json | grep -qi '^x-content-type-options: nosniff' \
  && ok "logs are served with nosniff (a log is never run as a page)" || bad "no nosniff on logs"
for h in 'X-Forwarded-For: 203.0.113.9' 'Forwarded: for=203.0.113.9' 'X-Real-IP: 203.0.113.9' 'Tailscale-User-Login: someone@example.com'; do
  c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "$h" --resolve logs.localhost:8080:127.0.0.1 http://logs.localhost:8080/)
  [ "$c" = 404 ] && ok "a proxied request (${h%%:*}) gets 404 even from 127.0.0.1" || bad "logs page answered $c with ${h%%:*}"
done
lastlog=$(ls -1t /var/log/mini-deploy/builds/demo-site/*.log 2>/dev/null | head -1)
if [ -n "$lastlog" ]; then
  curl -s -m 5 -I --resolve logs.localhost:8080:127.0.0.1 "http://logs.localhost:8080/data/demo-site/$(basename "$lastlog")" | grep -qi '^content-type: text/plain' \
    && ok "a log file is always served as text/plain" || bad "log served with another Content-Type"
fi
# The real check: a connection that does NOT come from 127.0.0.1. Run a second, temporary
# Caddy with the same config on Docker's bridge address (only this PC and its containers
# can reach that), and ask it for the logs page from there.
BR=$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
if [ -n "$BR" ]; then
  sed -E -e "s/^(\s*)bind .*/\1bind $BR/" -e 's/^:8080 \{/:8099 {/' -e 's|admin unix//run/caddy-admin.sock|admin off|' \
      "$REPO/caddy/Caddyfile" > "$SRC/Caddyfile.bridge"
  caddy run --adapter caddyfile --config "$SRC/Caddyfile.bridge" >"$SRC/caddy-bridge.out" 2>&1 & CB=$!
  for i in $(seq 1 50); do curl -s -o /dev/null "http://$BR:8099/" && break; sleep 0.1; done
  far=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Host: logs.localhost:8099' "http://$BR:8099/")
  farapp=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Host: demo-site.localhost:8099' "http://$BR:8099/")
  kill $CB 2>/dev/null; wait $CB 2>/dev/null
  [ "$farapp" = 200 ] && ok "(control: the same server does serve apps from $BR)" || bad "control app answered $farapp: $(tail -3 "$SRC/caddy-bridge.out")"
  [ "$far" = 404 ] && ok "a connection from another address gets 404 for the logs page" || bad "logs page answered $far to $BR"
else
  echo "skip  no docker0 address to test a non-local connection from"
fi

echo
echo "== 9. Caddy listens on the Wi-Fi only at home, and follows a network change =="
RC="bash $REPO/scripts/run-caddy.sh"
lan_of() { ss -ltnH 'sport = :8080' | awk '{print $4}' | sed 's/:8080$//' | grep -v '^127\.0\.0\.1$' | head -1; }
systemctl is-active -q mini-deploy-caddy && ok "Caddy runs as the service mini-deploy-caddy" || bad "the Caddy service is not running"
systemctl is-active -q mini-deploy-caddy-sync.timer && ok "the 30 s network check is scheduled" || bad "the sync timer is not active"
HL=/etc/mini-deploy/home-lan
# (not `$RC status | grep -q`: under pipefail, grep -q stopping early cuts status off and
#  the pipe "fails" even on a match; the same trap as in run-caddy.sh)
at_home() { local s; s=$($RC status); grep -q '^at home right now:   yes' <<<"$s"; }
if [ -f "$HL" ] && { at_home || at_home; }; then   # asked twice, like the sync itself
  [ -n "$(lan_of)" ] && ok "at home: listening on the Wi-Fi address too ($(lan_of))" || bad "at home but not on the Wi-Fi"
  # Pretend to be on another network that hands out the same address: same address,
  # different router. Restored by the trap even if this section breaks half-way.
  cp -p "$HL" "$SRC/home-lan.real"
  trap 'cp -p "$SRC/home-lan.real" "$HL"; $RC sync >/dev/null 2>&1' EXIT
  sed -i 's/^GATEWAY_MAC=.*/GATEWAY_MAC=02:00:00:00:00:01/' "$HL"
  $RC sync >/dev/null; sleep 1
  [ -z "$(lan_of)" ] && ok "same address but another router: Caddy drops the Wi-Fi by itself (this PC only)" || bad "still listening on $(lan_of) on a 'foreign' network"
  [ "$(code demo-site /)" = 200 ] && ok "and this PC is still served meanwhile" || bad "this PC lost the sites"
  cp -p "$SRC/home-lan.real" "$HL"; trap - EXIT
  $RC sync >/dev/null; sleep 1
  [ -n "$(lan_of)" ] && ok "back home: the Wi-Fi address comes back by itself" || bad "did not return to the Wi-Fi"
else
  [ -z "$(lan_of)" ] && ok "not at home (or home not saved): listening on this PC only" || bad "listening on $(lan_of) while not at home"
fi
# A reload that fails (a broken Caddyfile) must leave Caddy serving its old config, and the
# 30 s check must back off instead of retrying every time. A broken COPY is used; the real
# Caddyfile is never touched.
printf 'this is { not a valid\n' > "$SRC/Caddyfile.broken"
MINI_DEPLOY_CADDYFILE="$SRC/Caddyfile.broken" $RC reload >/dev/null 2>&1 && bad "a broken Caddyfile was accepted" \
  || ok "a broken Caddyfile is refused"
[ "$(code demo-site /)" = 200 ] && ok "and Caddy keeps serving with its old config" || bad "sites went down after a failed reload"
if [ -f "$HL" ]; then
  cp -p "$HL" "$SRC/home-lan.real2"
  # the real timer would clear the mark meanwhile; a run already going would hold the sync lock
  systemctl stop mini-deploy-caddy-sync.timer mini-deploy-caddy-sync.service
  trap 'cp -p "$SRC/home-lan.real2" "$HL"; rm -f /run/mini-deploy-caddy-sync.failed; $RC sync >/dev/null 2>&1; systemctl start mini-deploy-caddy-sync.timer' EXIT
  sed -i 's/^GATEWAY_MAC=.*/GATEWAY_MAC=02:00:00:00:00:01/' "$HL"       # forces "needs a reload"
  MINI_DEPLOY_CADDYFILE="$SRC/Caddyfile.broken" $RC sync >/dev/null 2>&1
  [ -f /run/mini-deploy-caddy-sync.failed ] && ok "a failed network reload is remembered" || bad "no failure mark"
  t0=$(date +%s); out=$(MINI_DEPLOY_CADDYFILE="$SRC/Caddyfile.broken" $RC sync 2>&1); t1=$(date +%s)
  [ -z "$out" ] && ok "the next check backs off (no new attempt, no log spam)" || bad "sync retried at once: $out"
  cp -p "$SRC/home-lan.real2" "$HL"; rm -f /run/mini-deploy-caddy-sync.failed; trap - EXIT
  $RC sync >/dev/null 2>&1; systemctl start mini-deploy-caddy-sync.timer; sleep 1
  [ -n "$(lan_of)" ] && ok "with the real config back, the home Wi-Fi side is restored" || bad "Wi-Fi side not restored"
fi
noenv=$(MINI_DEPLOY_LAN_BIND= MINI_DEPLOY_TAILNET_BIND= caddy adapt --adapter caddyfile --config "$REPO/caddy/Caddyfile" 2>/dev/null | python3 -c 'import json,sys; s=json.load(sys.stdin)["apps"]["http"]["servers"]; print(sorted({l for v in s.values() for l in v["listen"]}))')
# expected: 8080 plus every phone port the Caddyfile has (8443 After Sleep, 8444 YoomiRead, ...), loopback only
want=$(sed -n 's/^https:\/\/[^ ]*\.ts\.net:\([0-9]*\) {$/\1/p' "$REPO/caddy/Caddyfile" \
  | python3 -c 'import sys; print(sorted({"127.0.0.1:8080"} | {"127.0.0.1:" + p.strip() for p in sys.stdin if p.strip()}))')
[ "$noenv" = "$want" ] && ok "with no home and no Tailscale address the config is loopback only: $noenv" || bad "empty addresses give listeners $noenv (want $want)"

echo
echo "== 10. phone from anywhere (P5): HTTPS on the Tailscale address, After Sleep only =="
TN=mini-deploy.tail206989.ts.net
TA=$(ip -4 -o addr show dev tailscale0 2>/dev/null | sed -n 's/.* inet \([0-9.]*\)\/32 .*/\1/p' | head -1)
tget() { curl -sS -m 5 --resolve "$TN:8443:$TA" "$@"; }
if [ -z "$TA" ]; then
  echo "skip  Tailscale is not up on this PC: nothing to reach"
else
  both=$(printf '%s\n' "127.0.0.1:8443" "$TA:8443" | sort | tr '\n' ' ')
  have=$(ss -ltnH 'sport = :8443' | awk '{print $4}' | sort | tr '\n' ' ')
  [ "$have" = "$both" ] && ok "8443 listens only on this PC and the Tailscale address ($have)" || bad "8443 listens on: $have"
  st=$(tget -o "$SRC/tn-root" -w '%{http_code} %{ssl_verify_result}' "https://$TN:8443/")
  [ "$st" = "200 0" ] && ok "After Sleep over Tailscale: 200 with a valid certificate (checked by curl)" || bad "root answered '$st'"
  head -c 300 /sites/aftersleep/current/index.html > "$SRC/tn-want"; head -c 300 "$SRC/tn-root" > "$SRC/tn-got"
  cmp -s "$SRC/tn-want" "$SRC/tn-got" && ok "it is the live After Sleep release" || bad "the page is not After Sleep's live index.html"
  issuer=$(echo | openssl s_client -connect "$TA:8443" -servername "$TN" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)
  grep -q "Let's Encrypt" <<<"$issuer" && ok "the certificate is Let's Encrypt's, via Tailscale ($issuer)" || bad "certificate issuer: $issuer"
  for h in admin.localhost:8080 logs.localhost:8080 aftersleep.localhost:8080; do
    body=$(tget -H "Host: $h" "https://$TN:8443/")
    [ -z "$body" ] && ok "Host $h on this listener gets nothing (admin and logs are never served here)" || bad "Host $h got a page"
  done
  out=$(curl -sS -m 5 -k --resolve "other.tail206989.ts.net:8443:$TA" https://other.tail206989.ts.net:8443/ 2>&1)
  grep -q 'alert' <<<"$out" && ok "another certificate name is refused in the handshake" || bad "another name was served: $out"
  for p in /.env /.git/config /.hidden/x; do
    c=$(tget -o /dev/null -w '%{http_code}' "https://$TN:8443$p")
    [ "$c" = 404 ] && ok "$p is 404" || bad "$p answered $c"
  done
  [ "$(tget "https://$TN:8443/api/ci/v1/evil")" = "not found" ] && ok "/api/ci reaches the forwarder (its own 404 text)" || bad "/api/ci did not reach the forwarder"
  [ "$(tget -o /dev/null -w '%{http_code}' "https://$TN:8443/no-such-file")" = 404 ] && ok "a missing file is 404" || bad "missing file not 404"
  tget -sI "https://$TN:8443/" | grep -qi '^cache-control: no-cache' && ok "no-cache, so a deploy shows at once" || bad "no Cache-Control: no-cache"
  c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$TA:8080/"); [ "$c" = 000 ] && ok "port 8080 is closed on the Tailscale address" || bad "8080 answered $c on Tailscale"
  c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$TA:80/"); [ "$c" = 000 ] && ok "port 80 is closed on the Tailscale address (no http->https redirect server)" || bad "80 answered $c on Tailscale"

  # Tailscale goes away -> the listener closes by itself; comes back -> it reopens. Simulated with
  # an interface name that does not exist; the real timer is stopped meanwhile (it would undo it).
  RC="bash $REPO/scripts/run-caddy.sh"
  MARK=/run/mini-deploy-caddy-sync.failed
  # The timer AND a run of it that may already be going: either could undo what is simulated here.
  systemctl stop mini-deploy-caddy-sync.timer mini-deploy-caddy-sync.service
  trap 'rm -f $MARK; $RC sync >/dev/null 2>&1; systemctl start mini-deploy-caddy-sync.timer' EXIT
  MINI_DEPLOY_TAILNET_DEV=no-such-dev $RC sync >/dev/null 2>&1; sleep 1
  have=$(ss -ltnH 'sport = :8443' | awk '{print $4}' | tr '\n' ' ')
  [ "$have" = "127.0.0.1:8443 " ] && ok "Tailscale gone: the phone listener closes by itself (this PC only)" || bad "still listening on: $have"
  [ "$(code aftersleep /)" = 200 ] && ok "and the sites on this PC keep working meanwhile" || bad "sites broke while Tailscale was gone"
  $RC sync >/dev/null 2>&1; sleep 1
  have=$(ss -ltnH 'sport = :8443' | awk '{print $4}' | sort | tr '\n' ' ')
  [ "$have" = "$both" ] && ok "Tailscale back: the phone listener reopens by itself" || bad "not reopened: $have"

  # A phone site taken out of the Caddyfile: its port is simply not checked, so no endless reloads.
  grep -v '^https://.*\.ts\.net:8443 {' "$REPO/caddy/Caddyfile" | grep -v 'import phone_app aftersleep' > "$SRC/Caddyfile.nophone"
  out=$(MINI_DEPLOY_CADDYFILE="$SRC/Caddyfile.nophone" $RC sync 2>&1); rc=$?
  [ $rc = 0 ] && [ -z "$out" ] && ok "no phone site in the Caddyfile: the sync finds nothing to do (no reload loop)" || bad "sync with no phone site: rc $rc, '$out'"

  # A reload that "works" but leaves the wrong listeners must back off, not reload every 30 s.
  # (A copy whose phone site has no Tailscale bind: Caddy reloads fine and still is not there.)
  sed 's/bind 127\.0\.0\.1 {\$MINI_DEPLOY_TAILNET_BIND}/bind 127.0.0.1/' "$REPO/caddy/Caddyfile" > "$SRC/Caddyfile.notail"
  MINI_DEPLOY_TAILNET_DEV=no-such-dev $RC sync >/dev/null 2>&1; sleep 1   # first: closed, so a reload is due
  rm -f $MARK
  out=$(MINI_DEPLOY_CADDYFILE="$SRC/Caddyfile.notail" $RC sync 2>&1); rc=$?
  [ $rc = 1 ] && [ -f $MARK ] && grep -q 'reloaded, but' <<<"$out" && ok "a reload that leaves the wrong listeners is caught and marked" || bad "not caught: rc $rc, '$out'"
  out=$(MINI_DEPLOY_CADDYFILE="$SRC/Caddyfile.notail" $RC sync 2>&1); rc=$?
  [ $rc = 0 ] && [ -z "$out" ] && ok "and the next check backs off instead of reloading again" || bad "no back-off: rc $rc, '$out'"
  rm -f $MARK; $RC sync >/dev/null 2>&1; sleep 1
  have=$(ss -ltnH 'sport = :8443' | awk '{print $4}' | sort | tr '\n' ' ')
  [ "$have" = "$both" ] && ok "with the real Caddyfile the phone listener is back" || bad "not restored: $have"
  systemctl start mini-deploy-caddy-sync.timer; trap - EXIT

  # A phone port another program holds: Caddy would start without that site, never without this PC's
  # sites. Checked on a copy where EVERY phone port is moved up by 10000 (8443 -> 18443, 8444 ->
  # 18444): the live Caddy holds the real ones, so a copy keeping any of them would see it "taken".
  # (`check-start` starts nothing.)
  sed -E 's/^(https:\/\/[^ ]*\.ts\.net:)(8[0-9]{3}) \{$/\11\2 {/' "$REPO/caddy/Caddyfile" > "$SRC/Caddyfile.port"
  out=$(MINI_DEPLOY_CADDYFILE="$SRC/Caddyfile.port" $RC check-start 2>&1)
  grep -q '^taken phone ports: none$' <<<"$out" && ok "a free phone port is seen as free" || bad "free port check: $out"
  python3 -c 'import socket, time; s = socket.socket(); s.bind(("127.0.0.1", 18443)); s.listen(); time.sleep(6)' & holder=$!
  sleep 1
  out=$(MINI_DEPLOY_CADDYFILE="$SRC/Caddyfile.port" $RC check-start 2>&1)
  kill $holder 2>/dev/null; wait $holder 2>/dev/null
  grep -q '^taken phone ports: 18443$' <<<"$out" && ok "a phone port another program holds is seen before Caddy starts" || bad "taken port not seen: $out"
  fb=$(sed -n 's/^fallback listens on: //p' <<<"$out")
  grep -q '127.0.0.1:8080' <<<"$fb" && ! grep -q ':18443' <<<"$fb" \
    && ok "then Caddy starts without that site and keeps this PC's sites ($fb)" || bad "fallback listens on: $fb"
fi

echo
echo "== 11. the admin page's café colours are readable, by day and by night =="
python3 - "$REPO/web/admin/admin.css" <<'PY' || fail=1
import re, sys
css = open(sys.argv[1], encoding="utf-8").read()
light = css[css.index(":root {"):css.index("@media (prefers-color-scheme: dark)")]
dark = css[css.index('@media (prefers-color-scheme: dark)'):css.index(':root[data-theme="dark"]')]
dark_toggle = css[css.index(':root[data-theme="dark"]'):]
dark_toggle = dark_toggle[:dark_toggle.index("}") + 1]
def toks(block):
    return {m.group(1): m.group(2) for m in re.finditer(r"--([a-z0-9-]+-c):\s*(#[0-9A-Fa-f]{6})", block)}
def rgb(h): h = h.lstrip("#"); return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
def lum(c):
    f = lambda v: v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (f(v / 255) for v in c); return 0.2126 * r + 0.7152 * g + 0.0722 * b
def ratio(a, b):
    la, lb = lum(rgb(a)), lum(rgb(b)); return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
L = toks(light); bad = 0
D = dict(L); D.update(toks(dark))
DT = dict(L); DT.update(toks(dark_toggle))
if {k: v for k, v in D.items()} != {k: v for k, v in DT.items()}:
    print("FAIL  the dark colours differ between the system setting and the dark toggle"); bad += 1
else:
    print("ok    the dark colours are the same for the system setting and the dark toggle")
PAIRS = [("ink-c", "oat-c"), ("ink-c", "surface-c"), ("ink-c", "surface2-c"), ("ink-c", "foam-c"),
         ("muted-c", "oat-c"), ("muted-c", "surface-c"), ("muted-c", "surface2-c"),
         ("pinkink-c", "surface-c"), ("pinkink-c", "foam-c"), ("pinkink-c", "oat-c"),
         ("on-coffee-c", "coffee-c"), ("ok-c", "okbg-c"), ("warn-c", "warnbg-c"), ("bad-c", "badbg-c"),
         ("ok-c", "surface-c"), ("bad-c", "surface-c"), ("pinkink-c", "surface2-c")]
for theme, t in (("day", L), ("night", D)):
    for fg, bg in PAIRS:
        r = ratio(t[fg], t[bg])
        ok = r >= 4.5; bad += not ok
        print(("ok    " if ok else "FAIL  ") + f"{theme}: {fg} on {bg}: {r:.1f}:1")
# the espresso card stays dark in both themes (fixed colours in admin.css)
for fg in ("#F5E8E2", "#E9D9CF", "#9EE3BE", "#FFB3C9"):
    r = ratio(fg, "#2B1E1A"); ok = r >= 4.5; bad += not ok
    print(("ok    " if ok else "FAIL  ") + f"espresso card: {fg} on #2B1E1A: {r:.1f}:1")
print(("ok    " if "prefers-reduced-motion: reduce" in css else "FAIL  ") + "all admin motion stops when the device asks for less")
bad += "prefers-reduced-motion: reduce" not in css
sys.exit(1 if bad else 0)
PY

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOMETHING FAILED"; fi
exit $fail
