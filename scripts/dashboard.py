#!/usr/bin/env python3
"""mini-deploy stage 6: build the dashboard's data and deploy it as the app `dashboard`.

    dashboard.py                    refresh the live dashboard (does nothing if unchanged)
    dashboard.py --force            deploy even if nothing changed
    dashboard.py --out DIR          write the site into DIR instead of deploying (tests)

The page itself is static (web/dashboard). This script only produces data.json from
what is on disk: /sites/<app>/releases, the live link, the deploy log. It is read-only
with respect to your apps and deploys the result through deploy.py like any other app,
so the platform hosts its own face. Standard library only.
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
MAX_EVENTS = 40
MAX_DETAIL = 120
SHOW_RELEASES = 8

# One deploy-log line: ts app action release result duration [detail]
LINE_RE = re.compile(
    r"^(?P<ts>\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) (?P<app>[a-z0-9-]{1,40}) (?P<action>[a-z]{1,20}) "
    r"(?P<release>-|\d{8}-\d{6}(?:-\d{1,3})?) (?P<result>[a-z]{1,20}) (?P<duration>\d+\.\ds)"
    r"(?: (?P<detail>.*))?$"
)
SHA7_RE = re.compile(r"^[0-9a-f]{7,40}$")


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
            "live": live,
            "held": deploy_mod.is_held(path),
            "deployed": deployed,
            "total": len(ids),
            "releases": [{"id": r, "live": r == live} for r in shown],
        })
    return apps


def collect_events(log_file, limit=MAX_EVENTS):
    """Last `limit` well-formed lines. Anything that does not match the strict
    format is dropped, and detail is cut down and limited to printable ASCII."""
    try:
        lines = Path(log_file).read_text(encoding="ascii", errors="replace").splitlines()
    except OSError:
        return []
    events = []
    for line in lines[-2000:]:
        m = LINE_RE.match(line)
        if not m or m["app"] == APP_NAME:  # the dashboard's own refreshes are just noise
            continue
        detail = re.sub(r"[^\x20-\x7e]", "?", m["detail"] or "")[:MAX_DETAIL]
        events.append({"ts": m["ts"], "app": m["app"], "action": m["action"], "release": m["release"],
                       "result": m["result"], "duration": m["duration"], "detail": detail})
    return events[-limit:]


def collect(sites_root=None, log_file=None):
    sites_root = sites_root or deploy_mod.SITES
    log_file = log_file or deploy_mod.LOG_FILE
    apps = collect_apps(sites_root)
    events = collect_events(log_file)
    # an app "needs a look" when its most recent real event was a failure
    latest = {}
    for ev in events:
        if ev["action"] in ("rejected",) or ev["result"] == "rejected":
            continue
        latest[ev["app"]] = ev["result"]
    attention = sorted(a for a, r in latest.items() if r in ("fail", "crash"))
    return {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "apps": apps, "events": events, "attention": attention}


def _comparable(data):
    return {k: v for k, v in data.items() if k != "generated_at"}


def write_site(out_dir, data):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    for src in SRC_DIR.iterdir():
        if src.is_file() and not src.name.startswith("."):
            shutil.copy2(src, out_dir / src.name)
    (out_dir / "data.json").write_text(json.dumps(data, indent=1), encoding="utf-8")


def refresh(force=False, sites_root=None, log_file=None):
    """Regenerate and deploy. Returns the release id, or None if nothing changed."""
    data = collect(sites_root, log_file)
    if not force:
        try:
            old = json.loads((deploy_mod.SITES / APP_NAME / "current" / "data.json").read_text(encoding="utf-8"))
            if _comparable(old) == _comparable(data):
                return None
        except (OSError, ValueError):
            pass
    work = Path(tempfile.mkdtemp(prefix="mini-deploy-dash-", dir="/var/tmp"))
    try:
        write_site(work / "site", data)
        return deploy_mod.deploy(APP_NAME, work / "site")
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
    parser.add_argument("--log-file", help=argparse.SUPPRESS)      # tests only
    parser.add_argument("--sites-root", help=argparse.SUPPRESS)    # tests only
    args = parser.parse_args()
    try:
        if args.out:
            write_site(args.out, collect(args.sites_root, args.log_file))
            print(f"wrote the site to {args.out}")
            return 0
        release = refresh(args.force, args.sites_root, args.log_file)
    except deploy_mod.DeployError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    if release is None:
        print("dashboard is up to date (nothing changed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
