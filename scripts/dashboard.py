#!/usr/bin/env python3
"""mini-deploy: the app list and recent activity, read from disk, for the admin page.

collect() reads what is on disk: /sites/<app>/releases, the live link, holds, the deploy
log. scripts/admin.py shows it (this PC only). Until 2026-10-15 this module also published
it as the app `dashboard` for the home Wi-Fi; that page is retired (the phone only opens
apps, and the admin page has everything the dashboard had).

public_detail() still turns a log line into a SHORT REASON ("build failed", "timed out")
and the short commit id, never the error text: that can contain paths, git output or the
tail of a build log. The full text stays in /var/log/mini-deploy.log. Standard library only.
"""

import json
import os
import re
import sys
import time
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import deploy as deploy_mod  # noqa: E402

OLD_PAGE = "dashboard"   # the retired Wi-Fi page: its folder and old log lines are not an app
MAX_EVENTS = 40          # rows shown in "Recent deploys"
SHOW_RELEASES = 8
LOG_TAIL_BYTES = 256 * 1024   # only the end of the log is read; it has no rotation yet

# One deploy-log line: ts app action release result duration [detail]
LINE_RE = re.compile(
    r"^(?P<ts>\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) (?P<app>[a-z0-9-]{1,40}) (?P<action>[a-z]{1,20}) "
    r"(?P<release>-|\d{8}-\d{6}(?:-\d{1,3})?) (?P<result>[a-z]{1,20}) (?P<duration>\d+\.\ds)"
    r"(?: (?P<detail>.*))?$"
)
SHA7_RE = re.compile(r"^[0-9a-f]{7,40}$")
NOT_APPS = {"webhook", "invalid-name", OLD_PAGE}   # log "apps" that are not real apps

# What a failure is called on the page. First match wins; checked against the error
# message only (the build-output tail is cut off first), so output cannot pick the label.
REASONS = [
    ("env values", "env problem"),                       # before "git": a key may say GIT
    ("secret appears in dist", "refused: secret in output"),
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
    """A short, safe summary of a log line. Only fixed words, a 7-character commit id and
    a release id ever come out."""
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
        if path.name == OLD_PAGE:
            continue  # the retired Wi-Fi page, if its folder is still there
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
        for ev in parsed if ev["app"] != OLD_PAGE  # the old page's own refreshes are noise
    ][-MAX_EVENTS:]

    apps = collect_apps(sites_root)
    present = {a["name"] for a in apps}  # an app that no longer exists cannot need a look
    return {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "apps": apps, "events": events,
            "attention": sorted(a for a, bad in broken.items() if bad and a in present)}
