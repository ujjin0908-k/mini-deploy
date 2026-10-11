#!/usr/bin/env bash
# Stage 6 test: the pink glass sites deploy, the dashboard shows real data, nothing
# phones home, and the look stays readable (contrast) and safe (no HTML injection).
# Needs Docker and Caddy (current Caddyfile) running.
#
# This DEPLOYS the three real apps: dashboard, demo-site and mini-deploy (the landing
# page). They are meant to stay. It never deletes anything.
set -uo pipefail

REPO=/mnt/c/Users/indra/Code/mini-deploy
SRC=$(mktemp -d /tmp/mini-deploy-sites-test-XXXXXX)
fail=0

ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }
get()  { curl -s -m 5 -w ' [%{http_code}]' --resolve "$1.localhost:8080:127.0.0.1" "http://$1.localhost:8080${2:-/}"; }
code() { curl -s -m 5 -o /dev/null -w '%{http_code}' --resolve "$1.localhost:8080:127.0.0.1" "http://$1.localhost:8080${2:-/}"; }

echo "== 1. the theme copies are in step with the source =="
for f in web/dashboard/style.css web/landing/style.css examples/static-site/src/style.css; do
  if cmp -s "$REPO/web/theme/pink.css" "$REPO/$f"; then ok "$f matches web/theme/pink.css"
  else bad "$f is stale: run scripts/sync-theme.sh"; fi
done
h1_count=$(grep -c '<h1>' "$REPO/examples/static-site/src/index.html")
h1_line=$(grep '<h1>' "$REPO/examples/static-site/src/index.html")
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

js = (repo / "web/dashboard/app.js").read_text(encoding="utf-8")
danger = [w for w in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function") if w in js]
check(not danger, "dashboard JS never builds HTML from data" + (f" (found {danger})" if danger else ""))

dash_html = (repo / "web/dashboard/index.html").read_text(encoding="utf-8")
csp = re.search(r'http-equiv="Content-Security-Policy" content="([^"]+)"', dash_html)
check(bool(csp) and "script-src 'self'" in csp.group(1) and "object-src 'none'" in csp.group(1),
      "dashboard has a Content-Security-Policy that only allows its own scripts")
check(not re.search(r"<script(?![^>]*\bsrc=)", dash_html), "dashboard has no inline script (the CSP would block it)")

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
echo "== 2b. the three *-explained folders are complete, accurate and accessible =="
REPO=$REPO python3 - <<'PY' || fail=1
import html, json, os, re, sys
from pathlib import Path
repo = Path(os.environ["REPO"])
bad = 0
def check(ok, msg):
    global bad
    print(("ok    " if ok else "FAIL  ") + msg)
    bad += not ok

pink = (repo / "web/theme/pink.css").read_bytes()
explain = (repo / "web/theme/explain.css").read_bytes()
real_top = {"generated_at", "apps", "events", "attention"}
real_app = {"name", "live", "held", "deployed", "total", "releases"}
real_event = {"ts", "app", "action", "release", "result", "duration", "detail"}

for name in ("dashboard-explained", "demo-site-explained", "landing-explained"):
    d = repo / name
    files = {p.name for p in d.iterdir()} if d.is_dir() else set()
    check({"index.html", "style.css", "explain.css", "README.md"} <= files, f"{name}: has index.html, style.css, explain.css, README.md")
    if not d.is_dir():
        continue
    check(not any(f.startswith(".") for f in files), f"{name}: no dotfiles")
    check((d / "style.css").read_bytes() == pink, f"{name}: style.css matches web/theme/pink.css")
    check((d / "explain.css").read_bytes() == explain, f"{name}: explain.css matches web/theme/explain.css")

    page = (d / "index.html").read_text(encoding="utf-8")
    css = (d / "style.css").read_text(encoding="utf-8") + (d / "explain.css").read_text(encoding="utf-8")
    outside = [m.group(0) for src in (page, css)
               for m in re.finditer(r"https?://(?!([a-z0-9-]+\.)?localhost|www\.w3\.org/2000/svg)[^\s\"'<)]+", src)]
    check(not outside, f"{name}: nothing is fetched from elsewhere" + (f" ({outside})" if outside else ""))
    check("<script" not in page, f"{name}: no scripts at all")
    check(page.count("<h1") == 1, f"{name}: exactly one <h1>")

    svgs = re.findall(r"<svg\b[^>]*>.*?</svg>", page, flags=re.S)
    ok_svg = all('role="img"' in s and "aria-labelledby=" in s and "<title" in s and "<desc" in s for s in svgs)
    check(len(svgs) >= 2 and ok_svg, f"{name}: {len(svgs)} diagrams, each with a title and a description")

    ids = re.findall(r'\bid="([^"]+)"', page)
    check(len(ids) == len(set(ids)), f"{name}: element ids are unique")
    missing = [h for h in re.findall(r'href="#([^"]+)"', page) if h not in ids]
    check(not missing, f"{name}: every in-page link has a target" + (f" ({missing})" if missing else ""))

    files_named = re.findall(r'<code class="file">([^<]+)</code>', page)
    gone = [f for f in files_named if not (repo / html.unescape(f)).exists()]
    check(files_named and not gone, f"{name}: {len(files_named)} file names mentioned, all exist" + (f" (missing {gone})" if gone else ""))

    for m in re.finditer(r'<pre class="code" data-json>(.*?)</pre>', page, flags=re.S):
        try:
            data = json.loads(html.unescape(re.sub(r"<[^>]+>", "", m.group(1))))
            keys_ok = (set(data) <= real_top
                       and all(set(a) <= real_app for a in data.get("apps", []))
                       and all(set(e) <= real_event for e in data.get("events", [])))
            check(keys_ok, f"{name}: the data.json example parses and uses only real field names")
        except ValueError as e:
            check(False, f"{name}: the data.json example is not valid JSON ({e})")
sys.exit(1 if bad else 0)
PY

if exp=$(python3 "$REPO/scripts/export-diagrams.py" --out "$SRC/svg" 2>&1) \
   && [ "$(ls "$SRC/svg"/*.svg 2>/dev/null | wc -l)" = 9 ]; then
  ok "all 9 drawings export as standalone, well-formed .svg files (the Obsidian pictures)"
else
  bad "diagram export failed: $exp"
fi

echo
echo "== 3. log lines cannot inject anything, and bad lines are dropped =="
cat > "$SRC/evil.log" <<'LOG'
2026-10-12T01:00:00Z demo-site deploy 20261012-010000 ok 1.2s was=20261011-150008
2026-10-12T01:00:05Z demo-site webhook - fail 4.0s <script>alert(1)</script> <img src=x onerror=alert(2)>
2026-10-12T01:00:06Z Bad_App deploy - fail 0.1s uppercase app name must be dropped
not a log line at all
2026-10-12T01:00:07Z demo-site webhook - fail 0.2s xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
LOG
python3 "$REPO/scripts/dashboard.py" --out "$SRC/out" --log-file "$SRC/evil.log" >/dev/null
SRC_OUT="$SRC/out" python3 - <<'PY' || fail=1
import json, os, sys
from pathlib import Path
d = json.loads((Path(os.environ["SRC_OUT"]) / "data.json").read_text())
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
for name in ("zeta", "demo-site", "feat-x--demo-site", "abc--demo-site", "other"):
    (root / name / "releases").mkdir(parents=True)
apps = dashboard.collect_apps(root)
order = [a["name"] for a in apps]
check(order == ["demo-site", "abc--demo-site", "feat-x--demo-site", "other", "zeta"],
      f"each app is followed by its previews (got {order})")
parents = {a["name"]: a["preview_of"] for a in apps}
check(parents["feat-x--demo-site"] == "demo-site" and parents["demo-site"] is None, "previews name their parent, apps do not")
check(dashboard.public_detail("webhook", "removed", "test/repo 0000000 remove 1111") == "",
      "a deleted branch shows no fake all-zero commit")
sys.exit(1 if bad else 0)
PY

echo
echo "== 4. deploy the three sites =="
if python3 "$REPO/scripts/deploy.py" deploy mini-deploy "$REPO/web/landing" >/dev/null; then ok "landing deployed"; else bad "landing deploy failed"; fi
if python3 "$REPO/scripts/build.py" build demo-site "$REPO/examples/static-site" >/dev/null 2>&1; then ok "demo-site built in Docker and deployed"; else bad "demo-site build failed"; fi
if python3 "$REPO/scripts/dashboard.py" --force >/dev/null; then ok "dashboard deployed"; else bad "dashboard deploy failed"; fi

for app in mini-deploy demo-site dashboard; do
  [ "$(code $app /)" = 200 ] && ok "$app.localhost:8080 -> 200" || bad "$app did not answer 200"
  [ "$(code $app /style.css)" = 200 ] && ok "$app serves its stylesheet" || bad "$app has no style.css"
done
get demo-site / | grep -q 'built with node v' && ok "demo page was built (stamp present)" || bad "demo page has no build stamp"
get demo-site / | grep -q '__BUILT' && bad "demo page has an unreplaced placeholder"
get mini-deploy / | grep -q 'Your own small Netlify' && ok "landing page content is there" || bad "landing page content missing"
[ "$(code dashboard /data.json)" = 200 ] && ok "dashboard has data.json" || bad "no data.json"

echo
echo "== 5. the dashboard shows the real state =="
curl -s -m 5 --resolve dashboard.localhost:8080:127.0.0.1 http://dashboard.localhost:8080/data.json > "$SRC/live.json"
SRC_JSON="$SRC/live.json" python3 - <<'PY' || fail=1
import json, os, sys
from pathlib import Path
d = json.loads(Path(os.environ["SRC_JSON"]).read_text())
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
check(all(e["app"] != "dashboard" for e in d["events"]), "the dashboard's own refreshes are left out of the activity")
sys.exit(1 if bad else 0)
PY
before=$(ls -A /sites/dashboard/releases | grep -vc '^\.')
python3 "$REPO/scripts/dashboard.py" | grep -q 'up to date' && ok "refresh with nothing new does not deploy" || bad "refresh deployed an identical dashboard"
after=$(ls -A /sites/dashboard/releases | grep -vc '^\.')
[ "$before" = "$after" ] && ok "no extra release was made" || bad "release count changed $before -> $after"

echo
echo "== 6. the phone address works too (nip.io name, LAN address) =="
phone=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Host: dashboard.192-168-40-241.nip.io:8080' http://192.168.40.241:8080/)
[ "$phone" = 200 ] && ok "dashboard.192-168-40-241.nip.io:8080 -> 200" || bad "phone-style host answered $phone"
dot=$(curl -s -m 5 -o /dev/null -w '%{http_code}' --resolve dashboard.localhost:8080:127.0.0.1 http://dashboard.localhost:8080/.hidden)
[ "$dot" = 404 ] && ok "dotfiles are still 404" || bad "dotfile answered $dot"
for app in dashboard demo-site mini-deploy; do
  for path in / /style.css; do
    curl -s -m 5 -I --resolve "$app.localhost:8080:127.0.0.1" "http://$app.localhost:8080$path" | grep -qi '^cache-control: no-cache' \
      && ok "$app$path is revalidated, so a deploy shows up at once" || bad "$app$path has no Cache-Control: no-cache"
  done
done

curl -s -m 5 -I --resolve demo-site.localhost:8080:127.0.0.1 http://demo-site.localhost:8080/ | grep -qi '^x-content-type-options: nosniff' \
  && ok "apps are served with X-Content-Type-Options: nosniff" || bad "no nosniff header"

echo
echo "== 7. the refresh hooks really run (deploy, failure, rollback of the dashboard) =="
# The other suites switch the hooks off. Here they are on, and nothing calls
# dashboard.py by hand in between, so only the hooks can make these pass.
HK=hooktest-$$
live_json() { curl -s -m 5 --resolve dashboard.localhost:8080:127.0.0.1 http://dashboard.localhost:8080/data.json; }
jq_py() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
mkdir -p "$SRC/hk-good"; echo '<h1>hook test</h1>' > "$SRC/hk-good/index.html"
mkdir -p "$SRC/hk-bad"; echo hi > "$SRC/hk-bad/index.html"; echo 'TOKEN=abc' > "$SRC/hk-bad/.env"

python3 "$REPO/scripts/deploy.py" deploy $HK "$SRC/hk-good" >/dev/null 2>&1
live_json | jq_py "'$HK' in [a['name'] for a in d['apps']]" | grep -q True \
  && ok "a deploy refreshed the dashboard by itself" || bad "new app did not appear after deploy"

python3 "$REPO/scripts/deploy.py" deploy $HK "$SRC/hk-bad" >/dev/null 2>&1 && bad "the .env deploy was accepted"
live_json | jq_py "'$HK' in d['attention']" | grep -q True \
  && ok "a FAILED deploy refreshed it too: the app needs a look" || bad "failure did not reach the dashboard"
reason=$(live_json | jq_py "[e['detail'] for e in d['events'] if e['app']=='$HK' and e['result']=='fail'][-1]")
[ "$reason" = "refused: unsafe file" ] && ok "the LAN sees only the reason: '$reason'" || bad "failure detail was: $reason"

python3 "$REPO/scripts/deploy.py" deploy $HK "$SRC/hk-good" >/dev/null 2>&1
live_json | jq_py "'$HK' in d['attention']" | grep -q False \
  && ok "a later success clears 'needs a look'" || bad "attention did not clear"

# rolling the dashboard back is respected, and --force lifts the hold
python3 "$REPO/scripts/deploy.py" rollback dashboard >/dev/null 2>&1
held_at=$(readlink /sites/dashboard/current)
python3 "$REPO/scripts/deploy.py" deploy $HK "$SRC/hk-good" >/dev/null 2>&1
[ "$(readlink /sites/dashboard/current)" = "$held_at" ] && ok "a rolled-back dashboard stays rolled back" || bad "refresh undid the dashboard rollback"
python3 "$REPO/scripts/dashboard.py" --force >/dev/null
[ ! -e /sites/dashboard/.hold ] && [ "$(readlink /sites/dashboard/current)" != "$held_at" ] \
  && ok "dashboard.py --force lifts the hold and refreshes" || bad "--force did not lift the hold"

# the name is reserved, and test flags can never deploy test data
out=$(python3 "$REPO/scripts/deploy.py" deploy dashboard "$SRC/hk-good" 2>&1); rc=$?
[ $rc = 1 ] && grep -q reserved <<<"$out" && ok "deploying to 'dashboard' by hand is refused" || bad "reserved name accepted: $out"
out=$(python3 "$REPO/scripts/dashboard.py" --log-file "$SRC/evil.log" 2>&1); rc=$?
[ $rc = 1 ] && ok "--log-file without --out is refused (test data never goes live)" || bad "--log-file deployed: $out"

# two refreshes at once: both finish, one after the other
python3 "$REPO/scripts/dashboard.py" --force >/dev/null 2>&1 & r1=$!
python3 "$REPO/scripts/dashboard.py" --force >/dev/null 2>&1 & r2=$!
wait $r1; a=$?; wait $r2; b=$?
[ $a = 0 ] && [ $b = 0 ] && ok "two refreshes at once both finish (they take turns)" || bad "concurrent refresh exit codes $a $b"
echo "      (left behind for you to remove: /sites/$HK and $SRC)"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOMETHING FAILED"; fi
exit $fail
