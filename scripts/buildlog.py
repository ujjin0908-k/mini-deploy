"""mini-deploy build logs: the full output of every build, kept on this PC only.

    /var/log/mini-deploy/builds/<app>/<UTC id>-<ok|fail>.log    one file per build
    /var/log/mini-deploy/builds/index.json                     list read by the logs page

Each log starts with a few "key: value" header lines, then a blank line, then the
build's own output. Build output is untrusted: escape codes and control characters
are replaced before anything is written, so a build cannot fake lines or styling.
These files are NEVER served to the Wi-Fi: Caddy shows them at logs.localhost only to
requests from 127.0.0.1 (the admin page, also this PC only, shows reason words only).
Standard library only.
"""

import collections
import contextlib
import fcntl
import json
import os
import re
import shutil
import tempfile
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
DELETE_GONE_AFTER = 30 * 24 * 3600   # ... and their logs are deleted once they are this old
LOCK_WAIT = 30                       # seconds; a log write is a small, quick step
HEADER_KEYS = ("app", "commit", "image", "env", "started", "duration", "result", "release", "error")  # env: names only

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
        # a deque: dropping from the front is O(1). A list's pop(0) copies the whole list,
        # and millions of tiny lines would turn that into minutes of work.
        self.tail, self.tail_size = collections.deque(), 0
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
            dropped = len(self.tail.popleft().encode("utf-8", "replace"))
            self.tail_size -= dropped
            self.cut += dropped

    def text(self):
        middle = [f"\n[... {self.cut // 1024} KB of output cut here; the log keeps the start and the end ...]\n"] \
            if self.cut else []
        return "".join(self.head + middle + list(self.tail))


@contextlib.contextmanager
def _locked():
    """One writer at a time (logs, ids, index, removal). Builds of different apps run in
    parallel, and a webhook removal can meet a build finishing: without this they would
    share temp names, pick the same id, or recreate a folder that was just removed."""
    LOGS_ROOT.mkdir(parents=True, exist_ok=True)
    os.chmod(LOGS_ROOT, 0o700)  # root only: Caddy (root) reads it, nobody else needs to
    with open(LOGS_ROOT / ".lock", "w") as fh:
        deadline = time.monotonic() + LOCK_WAIT
        while True:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("build logs are locked by another writer")
                time.sleep(0.1)
        yield


def _replace_atomically(path, text):
    """Write to a unique hidden temp file next to `path`, then rename over it."""
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="replace") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


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
        if callable(output):
            output = output()  # built here, so even building the text cannot break a deploy
        lines = [f"{k}: {clean(str(header[k])).replace(chr(10), ' ')[:300]}"
                 for k in HEADER_KEYS if header.get(k) not in (None, "")]
        with _locked():
            folder = LOGS_ROOT / app
            folder.mkdir(parents=True, exist_ok=True)
            path = folder / f"{_new_id(folder)}-{result}.log"
            _replace_atomically(path, "\n".join(lines) + "\n\n" + output)
            prune(folder)
            _write_index()
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
    """index.json for the logs page (takes the lock; see _write_index)."""
    with _locked():
        _write_index(sites_root)


def _write_index(sites_root=None):
    """Every app that still exists, newest build first. Only header fields go in; the page
    fetches a log's text when it is opened. Apps without a /sites folder stay listed for
    LIST_GONE_FOR, and their logs are deleted after DELETE_GONE_AFTER (no endless pile-up).
    Caller holds the lock."""
    if sites_root is None:
        import deploy  # lazy: deploy.py imports this module
        sites_root = deploy.SITES
    sites_root = Path(sites_root)
    apps = []
    now = time.time()
    for folder in sorted(LOGS_ROOT.iterdir()):
        if not folder.is_dir() or folder.is_symlink() or not APP_RE.fullmatch(folder.name):
            continue
        builds = []
        for path in logs_of(folder):
            try:  # a file can vanish between listing and reading (pruned, app removed)
                h = read_header(path)
                age = now - path.stat().st_mtime
            except FileNotFoundError:
                continue
            builds.append({
                "file": path.name,
                "result": FILE_RE.match(path.name).group(2),
                "started": h.get("started", ""),
                "duration": h.get("duration", ""),
                "commit": h.get("commit", "")[:7],
                "release": h.get("release", ""),
                "_age": age,
            })
        exists = (sites_root / folder.name).is_dir()
        newest_age = builds[0]["_age"] if builds else float("inf")
        if not exists and newest_age >= DELETE_GONE_AFTER:
            shutil.rmtree(folder, ignore_errors=True)  # gone for a month: drop its logs
            continue
        for b in builds:
            del b["_age"]
        if builds and (exists or newest_age < LIST_GONE_FOR):
            apps.append({"name": folder.name, "builds": builds})
    data = {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "apps": apps}
    _replace_atomically(LOGS_ROOT / "index.json", json.dumps(data, indent=1))


def remove_app(app):
    """Drop an app's logs (used when a preview is taken down). Never raises."""
    if not APP_RE.fullmatch(app):
        return
    try:
        with _locked():
            shutil.rmtree(LOGS_ROOT / app, ignore_errors=True)
            _write_index()
    except Exception as e:  # noqa: BLE001
        print(f"warning: could not remove the build logs of {app} ({type(e).__name__})")
