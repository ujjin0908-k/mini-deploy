"""mini-deploy build logs: the full output of every build, kept on this PC only.

    /var/log/mini-deploy/builds/<app>/<UTC id>-<ok|fail>.log    one file per build
    /var/log/mini-deploy/builds/index.json                     list read by the logs page

Each log starts with a few "key: value" header lines, then a blank line, then the
build's own output. Build output is untrusted: escape codes and control characters
are replaced before anything is written, so a build cannot fake lines or styling.
These files are NEVER served to the Wi-Fi: Caddy shows them at logs.localhost only to
requests from 127.0.0.1 (the dashboard, which the Wi-Fi can see, shows reason words only).
Standard library only.
"""

import json
import os
import re
import shutil
import time
from pathlib import Path

LOGS_ROOT = Path(os.environ.get("MINI_DEPLOY_BUILD_LOGS", "/var/log/mini-deploy/builds"))
KEEP = 20                         # logs per app
HEAD_BYTES = 256 * 1024           # a log keeps its first 256 KB ...
TAIL_BYTES = 768 * 1024           # ... and its last 768 KB; the middle is cut (1 MB at most)
APP_RE = re.compile(r"^[a-z0-9-]{1,40}$")
FILE_RE = re.compile(r"^(\d{8}-\d{6}(?:-\d{1,3})?)-(ok|fail)\.log$")
# A preview whose FIRST build failed has no folder in /sites, but its log is exactly what
# you want to read: apps without a folder stay listed while their newest log is this young.
LIST_GONE_FOR = 7 * 24 * 3600
HEADER_KEYS = ("app", "commit", "image", "started", "duration", "result", "release", "error")

_ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[@-_]")      # colour and cursor codes
_CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")                  # everything but tab and newline


def clean(text):
    """One line of untrusted output -> plain text. A lone \\r (progress bars) becomes a
    newline instead of a way to overwrite what came before."""
    text = _ANSI.sub("", text).replace("\r\n", "\n").replace("\r", "\n")
    return _CTRL.sub("?", text)


class Capture:
    """Collects build output with a size limit: the start and the end are kept, because
    that is where the useful parts are (what ran, and how it failed)."""

    def __init__(self):
        self.head, self.head_size = [], 0
        self.tail, self.tail_size = [], 0
        self.cut = 0

    def add(self, line):
        line = clean(line)
        size = len(line.encode("utf-8", "replace"))
        if self.head_size + size <= HEAD_BYTES and not self.tail:
            self.head.append(line)
            self.head_size += size
            return
        self.tail.append(line)
        self.tail_size += size
        while self.tail_size > TAIL_BYTES and self.tail:
            dropped = self.tail.pop(0)
            self.tail_size -= len(dropped.encode("utf-8", "replace"))
            self.cut += len(dropped.encode("utf-8", "replace"))

    def text(self):
        middle = [f"\n[... {self.cut // 1024} KB of output cut here; the log keeps the start and the end ...]\n"] \
            if self.cut else []
        return "".join(self.head + middle + self.tail)


def _key(rid):
    """Sort key: (second, counter), so -2 and -10 compare as numbers."""
    return rid[:15], int(rid[16:]) if len(rid) > 15 else 0


def _new_id(folder):
    """UTC id that sorts after EVERY existing log (never reuse a freed name: after pruning,
    a reused early name would sort as the oldest and be deleted at once)."""
    existing = [m.group(1) for m in (FILE_RE.match(p.name) for p in folder.iterdir()) if m]
    base, n = time.strftime("%Y%m%d-%H%M%S", time.gmtime()), 0
    if existing:
        top = max(_key(r) for r in existing)
        if (base, n) <= top:
            base, n = top[0], top[1] + 1
    if n > 999:
        raise RuntimeError("too many build logs in one second")
    return base if n == 0 else f"{base}-{n}"


def write(app, result, header, output):
    """Save one build log, keep the newest KEEP for the app, refresh the index.
    Never raises: a build log is a convenience, it must not turn a deploy into an error."""
    try:
        if not APP_RE.fullmatch(app) or result not in ("ok", "fail"):
            return None
        folder = LOGS_ROOT / app
        folder.mkdir(parents=True, exist_ok=True)
        os.chmod(LOGS_ROOT, 0o700)  # root only: Caddy (root) reads it, nobody else needs to
        lines = [f"{k}: {clean(str(header[k])).replace(chr(10), ' ')[:300]}"
                 for k in HEADER_KEYS if header.get(k) not in (None, "")]
        path = folder / f"{_new_id(folder)}-{result}.log"
        tmp = folder / f".{path.name}.tmp"
        tmp.write_text("\n".join(lines) + "\n\n" + output, encoding="utf-8", errors="replace")
        os.replace(tmp, path)
        prune(folder)
        write_index()
        return path
    except Exception as e:  # noqa: BLE001
        print(f"warning: could not save the build log ({type(e).__name__}: {e})")
        return None


def logs_of(folder):
    """Build log files of one app folder, newest first."""
    found = [(m.group(1), p) for p in folder.iterdir() if p.is_file() and not p.is_symlink()
             for m in [FILE_RE.match(p.name)] if m]
    return [p for _, p in sorted(found, key=lambda item: _key(item[0]), reverse=True)]


def prune(folder, keep=KEEP):
    for old in logs_of(folder)[keep:]:
        try:
            old.unlink()
        except OSError:
            pass


def read_header(path):
    header = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for _ in range(len(HEADER_KEYS) + 1):
            line = fh.readline().rstrip("\n")
            if not line:
                break
            key, sep, value = line.partition(": ")
            if sep and key in HEADER_KEYS:
                header[key] = value
    return header


def write_index(sites_root=None):
    """index.json for the logs page: every app that still exists, newest build first.
    Only header fields go in; the page fetches a log's text when it is opened."""
    if sites_root is None:
        import deploy  # lazy: deploy.py imports this module
        sites_root = deploy.SITES
    sites_root = Path(sites_root)
    apps = []
    if LOGS_ROOT.is_dir():
        for folder in sorted(LOGS_ROOT.iterdir()):
            if not folder.is_dir() or folder.is_symlink() or not APP_RE.fullmatch(folder.name):
                continue
            newest = logs_of(folder)[:1]
            recent = bool(newest) and time.time() - newest[0].stat().st_mtime < LIST_GONE_FOR
            if not (sites_root / folder.name).is_dir() and not recent:
                continue  # an app that is gone (and quiet for a week) is not listed
            builds = []
            for path in logs_of(folder):
                h = read_header(path)
                builds.append({
                    "file": path.name,
                    "result": FILE_RE.match(path.name).group(2),
                    "started": h.get("started", ""),
                    "duration": h.get("duration", ""),
                    "commit": h.get("commit", "")[:7],
                    "release": h.get("release", ""),
                })
            if builds:
                apps.append({"name": folder.name, "builds": builds})
    data = {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "apps": apps}
    LOGS_ROOT.mkdir(parents=True, exist_ok=True)
    tmp = LOGS_ROOT / ".index.json.tmp"
    tmp.write_text(json.dumps(data, indent=1), encoding="utf-8")
    os.replace(tmp, LOGS_ROOT / "index.json")


def remove_app(app):
    """Drop an app's logs (used when a preview is taken down)."""
    if APP_RE.fullmatch(app):
        shutil.rmtree(LOGS_ROOT / app, ignore_errors=True)
        try:
            write_index()
        except OSError:
            pass
