#!/usr/bin/env python3
"""mini-deploy stage 6: build the dashboard's data and deploy it as the app `dashboard`.

    dashboard.py                    refresh the live dashboard (does nothing if unchanged)
    dashboard.py --force            deploy even if nothing changed, and lift a hold on it
    dashboard.py --out DIR          write the site into DIR instead of deploying (tests)

The page itself is static (web/dashboard). This script only produces data.json from
what is on disk: /sites/<app>/releases, the live link, the deploy log. It deploys the
result through deploy.py like any other app, so the platform hosts its own face.

The page is visible to everyone on the home Wi-Fi, so it publishes only a SHORT REASON
for a failure ("build failed", "timed out") and the short commit id, never the error text:
that can contain paths, git output or the tail of a build log. The full text stays in
/var/log/mini-deploy.log, which only this machine can read. Standard library only.
"""

import argparse
import json
import os
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
import deploy as deploy_mod  # noqa: E402

APP_NAME = "dashboard"
SRC_DIR = REPO_ROOT / "web" / "dashboard"
MAX_EVENTS = 40          # rows shown in "Recent activity"
SHOW_RELEASES = 8
LOG_TAIL_BYTES = 256 * 1024   # only the end of the log is read; it has no rotation yet
REFRESH_LOCK_WAIT = 15   # seconds; another refresh takes about one
WORK_PREFIX = "mini-deploy-dash-"
STALE_AGE = 3600

# One deploy-log line: ts app action release result duration [detail]
LINE_RE = re.compile(
    r"^(?P<ts>\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) (?P<app>[a-z0-9-]{1,40}) (?P<action>[a-z]{1,20}) "
    r"(?P<release>-|\d{8}-\d{6}(?:-\d{1,3})?) (?P<result>[a-z]{1,20}) (?P<duration>\d+\.\ds)"
    r"(?: (?P<detail>.*))?$"
)
SHA7_RE = re.compile(r"^[0-9a-f]{7,40}$")
NOT_APPS = {"webhook", "invalid-name", APP_NAME}   # log "apps" that are not real apps

# What a failure is called on the page. First match wins; checked against the error
# message only (the build-output tail is cut off first), so output cannot pick the label.
REASONS = [
    ("timed out", "timed out"),
    ("still running", "busy"),
    ("build failed", "build failed"),
    ("missing or empty", "no build output"),
    ("symlink", "refused: contains a link"),
    ("must not be published", "refused: unsafe file"),
    ("special file", "refused: special file"),
    ("larger than", "too large"),
    ("not enough free disk", "low disk space"),
    ("bad app name", "bad app name"),
    ("is reserved", "reserved name"),
    ("not a folder", "source not found"),
    ("is empty", "source is empty"),
    ("git", "git failed"),
]


# ---------------------------------------------------------------- what the page may show

def public_detail(action, result, detail):
    """A short, safe summary of a log line for a page the whole Wi-Fi can read.
    Only fixed words, a 7-character commit id and a release id ever come out."""
    detail = detail or ""
    parts = []
    if result in ("fail", "crash"):
        core = detail.split("nothing was deployed:")[0].lower()
        parts.append(next((label for needle, label in REASONS if needle in core), "failed"))
    elif result == "superseded":
        parts.append("replaced by a newer push")
    elif result == "rejected":
        parts.append("bad signature" if "signature" in detail else "request refused")
    # webhook lines start "owner/repo <sha7> ..."; show only the commit id
    m = re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+ ([0-9a-f]{7})\b", detail)
    if m and m.group(1) != "0000000":  # all zeros = a deleted branch, there is no commit
        parts.append(f"commit {m.group(1)}")
    m = re.search(r"\bwas=(\d{8}-\d{6}(?:-\d{1,3})?)\b", detail)
    if m:
        parts.append(f"was {m.group(1)}")
    return ", ".join(parts)


# ---------------------------------------------------------------- collecting

def collect_apps(sites_root):
    apps = []
    for path in sorted(Path(sites_root).iterdir()):
        if not path.is_dir() or not deploy_mod.APP_RE.fullmatch(path.name):
            continue
        if path.name == APP_NAME:
            continue  # listing itself would change the data on every refresh, forever
        releases = path / "releases"
        if not releases.is_dir():
            continue  # a folder without releases is not a deployed app
        try:
            live = deploy_mod.current_id(path / "current")
        except deploy_mod.DeployError:
            live = None
        ids = deploy_mod.release_ids(releases)
        shown = ids[-SHOW_RELEASES:]
        deployed = None
        try:
            meta = json.loads((path / ".deployed").read_text(encoding="utf-8"))
            sha = meta.get("sha", "")
            if isinstance(sha, str) and SHA7_RE.fullmatch(sha):
                deployed = sha[:7]
        except (OSError, ValueError, AttributeError):
            pass
        apps.append({
            "name": path.name,
            "preview_of": deploy_mod.preview_parent(path.name),  # None for a normal app
            "live": live,
            "held": deploy_mod.is_held(path),
            "deployed": deployed,
            "total": len(ids),
            "releases": [{"id": r, "live": r == live} for r in shown],
        })
    # Each app, then its previews right after it.
    apps.sort(key=lambda a: (a["preview_of"] or a["name"], a["preview_of"] is not None, a["name"]))
    return apps


def read_log_tail(log_file):
    """The last LOG_TAIL_BYTES of the log, as whole lines."""
    try:
        with open(log_file, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - LOG_TAIL_BYTES))
            data = fh.read()
    except OSError:
        return []
    lines = data.decode("ascii", errors="replace").splitlines()
    return lines[1:] if size > LOG_TAIL_BYTES else lines  # the first one may be cut


def parse_log(log_file):
    """Every well-formed line in the tail, oldest first. Anything that does not match
    the strict format is dropped."""
    events = []
    for line in read_log_tail(log_file):
        m = LINE_RE.match(line)
        if m:
            events.append(m.groupdict())
    return events


def collect(sites_root=None, log_file=None):
    sites_root = sites_root or deploy_mod.SITES
    log_file = log_file or deploy_mod.LOG_FILE
    parsed = parse_log(log_file)

    # An app "needs a look" from a failure until a later success. Skips, holds and
    # stale pushes do not count as fixed. Uses the whole tail, not only the last 40.
    broken = {}
    for ev in parsed:
        if ev["app"] in NOT_APPS:
            continue
        if ev["result"] in ("fail", "crash"):
            broken[ev["app"]] = True
        elif ev["result"] == "ok" and ev["action"] in ("deploy", "build", "webhook", "rollback", "rollforward"):
            broken[ev["app"]] = False

    events = [
        {"ts": ev["ts"], "app": ev["app"], "action": ev["action"], "release": ev["release"],
         "result": ev["result"], "duration": ev["duration"],
         "detail": public_detail(ev["action"], ev["result"], ev["detail"])}
        for ev in parsed if ev["app"] != APP_NAME  # its own refreshes are just noise
    ][-MAX_EVENTS:]

    apps = collect_apps(sites_root)
    present = {a["name"] for a in apps}  # an app that no longer exists cannot need a look
    return {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "apps": apps, "events": events,
            "attention": sorted(a for a, bad in broken.items() if bad and a in present)}


def _comparable(data):
    return {k: v for k, v in data.items() if k != "generated_at"}


def write_site(out_dir, data):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    for src in SRC_DIR.iterdir():
        if src.is_file() and not src.is_symlink() and not src.name.startswith("."):
            shutil.copy2(src, out_dir / src.name)
    (out_dir / "data.json").write_text(json.dumps(data, indent=1), encoding="utf-8")


# ---------------------------------------------------------------- refreshing

def sweep_stale():
    """A kill skips `finally`; remove clearly old work folders of ours."""
    now = time.time()
    for p in Path("/var/tmp").glob(WORK_PREFIX + "*"):
        try:
            if p.is_dir() and now - p.stat().st_mtime > STALE_AGE:
                shutil.rmtree(p, ignore_errors=True)
        except OSError:
            pass


def refresh(force=False):
    """Regenerate and deploy. Returns the release id, or None if nothing changed or the
    dashboard is on hold. Collect, compare and deploy all happen under the dashboard's
    lock, so an older snapshot can never be deployed over a newer one."""
    root = deploy_mod.SITES / APP_NAME
    sweep_stale()
    with deploy_mod.locked(root, wait=REFRESH_LOCK_WAIT):
        if force:
            deploy_mod.clear_hold(root)       # a forced refresh is a manual decision
        elif deploy_mod.is_held(root):
            return None                       # someone rolled the dashboard back on purpose
        data = collect()
        if not force:
            try:
                old = json.loads((root / "current" / "data.json").read_text(encoding="utf-8"))
                if _comparable(old) == _comparable(data):
                    return None
            except (OSError, ValueError):
                pass
        work = Path(tempfile.mkdtemp(prefix=WORK_PREFIX, dir="/var/tmp"))
        try:
            write_site(work / "site", data)
            return deploy_mod.deploy_holding_lock(APP_NAME, work / "site")
        finally:
            shutil.rmtree(work, ignore_errors=True)


def maybe_refresh():
    """Called after a deploy, rollback or webhook job. Never raises: a broken dashboard
    must not break a deploy. Tests set MINI_DEPLOY_NO_DASHBOARD to keep releases quiet."""
    if os.environ.get("MINI_DEPLOY_NO_DASHBOARD"):
        return
    try:
        refresh()
    except Exception as e:  # noqa: BLE001
        print(f"warning: dashboard refresh failed: {type(e).__name__}: {e}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--out", help="write the site here instead of deploying")
    parser.add_argument("--log-file", help=argparse.SUPPRESS)      # tests only, with --out
    parser.add_argument("--sites-root", help=argparse.SUPPRESS)    # tests only, with --out
    args = parser.parse_args()
    if (args.log_file or args.sites_root) and not args.out:
        # test data must never be deployed as the real dashboard
        print("error: --log-file and --sites-root only work together with --out", file=sys.stderr)
        return 1
    try:
        if args.out:
            write_site(args.out, collect(args.sites_root, args.log_file))
            print(f"wrote the site to {args.out}")
            return 0
        release = refresh(args.force)
    except deploy_mod.DeployError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    if release is None:
        held = deploy_mod.is_held(deploy_mod.SITES / APP_NAME)
        print("dashboard is on hold (rolled back); use --force to refresh it anyway" if held
              else "dashboard is up to date (nothing changed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
