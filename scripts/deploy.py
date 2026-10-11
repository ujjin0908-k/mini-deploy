#!/usr/bin/env python3
"""mini-deploy: release folders, an atomic `current` link, and rollback.

    deploy.py deploy      <app> <dir>        copy <dir> into a new release and go live
    deploy.py rollback    <app> [release-id] point `current` at an older release
    deploy.py rollforward <app>              point `current` at the next newer release
    deploy.py unhold      <app>              let the webhook deploy this app again
    deploy.py list        <app>              show releases, `*` marks the live one

A rollback or rollforward puts the app on hold (webhook pushes are skipped and logged
as "held") so the next push cannot silently undo it. A manual `deploy` or `unhold` lifts it.

Layout (runtime data lives in the WSL filesystem, not on /mnt/c):

    /sites/<app>/releases/<id>/
    /sites/<app>/current -> releases/<id>

Every deploy, rollback and failure appends one line to /var/log/mini-deploy.log.
Standard library only. The same functions are reused by build.py and the webhook.
"""

import argparse
import fcntl
import os
import re
import shutil
import stat
import sys
import time
from pathlib import Path

SITES = Path("/sites")
LOG_FILE = Path("/var/log/mini-deploy.log")

# Same rule the Caddyfile applies to the Host header. App names end up in file
# paths, so they are checked here before any path is built from them.
APP_RE = re.compile(r"^[a-z0-9-]{1,40}$")
# 20261011-163000, with an optional -N when two deploys land in the same second.
# (Older releases used -1 and local time; both still match.)
ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}(-[0-9]{1,3})?$")

KEEP = 5                           # releases kept for rollback (the rule says at least 3)
MAX_RELEASE_BYTES = 500 * 1024 * 1024
LOCK_WAIT = int(os.environ.get("MINI_DEPLOY_LOCK_WAIT", "600"))  # seconds


class DeployError(Exception):
    pass


# ---------------------------------------------------------------- names and ids

def app_paths(app):
    if not APP_RE.fullmatch(app):
        raise DeployError(f"bad app name: use only a-z, 0-9 and '-', 1 to 40 characters")
    root = SITES / app
    return root, root / "releases", root / "current"


def id_key(rid):
    """Sort key: (second, counter). Compares -2 and -10 as numbers, not as text."""
    return rid[:15], int(rid[16:]) if len(rid) > 15 else 0


def release_ids(releases):
    """Real release folders, oldest first. Hidden .tmp-* folders never count."""
    if not releases.is_dir():
        return []
    ids = [p.name for p in releases.iterdir() if ID_RE.fullmatch(p.name) and p.is_dir()]
    return sorted(ids, key=id_key)


def next_release_id(existing, now=None):
    """UTC time id, forced to sort after every existing release.

    Local time jumps at DST changes and when the clock is set back; if the new id
    ever sorted below an old one, "previous release" and prune would pick wrongly.
    """
    candidate = (time.strftime("%Y%m%d-%H%M%S", now or time.gmtime()), 0)
    if existing:
        top = max(id_key(r) for r in existing)
        if candidate <= top:
            candidate = (top[0], top[1] + 1)
    base, n = candidate
    if n > 999:
        raise DeployError("too many releases in one second")
    return base if n == 0 else f"{base}-{n:03d}"


def current_id(current):
    """Id the live link points at, or None. Refuses a real folder named `current`."""
    if current.is_symlink():
        name = os.path.basename(os.readlink(current))
        return name if ID_RE.fullmatch(name) else None
    if current.exists():
        raise DeployError(
            f"{current} is a real folder, not a link. Refusing to touch it "
            "(deploy that content under a release first)."
        )
    return None


# ---------------------------------------------------------------- hold (after a rollback)

HOLD_NAME = ".hold"


def is_held(root):
    """A rollback means "something was wrong". While `.hold` exists the webhook skips
    this app, so the next push cannot silently undo the rollback."""
    return (root / HOLD_NAME).exists()


def set_hold(root):
    (root / HOLD_NAME).write_text(time.strftime("%Y-%m-%dT%H:%M:%SZ\n", time.gmtime()), encoding="ascii")


def clear_hold(root):
    try:
        (root / HOLD_NAME).unlink()
        return True
    except FileNotFoundError:
        return False


# ---------------------------------------------------------------- logging

def log_event(app, action, release, result, started, detail=""):
    """One line per event: time, app, action, release, result, duration, detail."""
    safe_app = app if APP_RE.fullmatch(app) else "invalid-name"
    line = " ".join([
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), safe_app, action,
        release or "-", result, f"{time.monotonic() - started:.1f}s",
    ])
    if detail:  # printable ASCII only, so a message can never forge a second log line
        line += " " + re.sub(r"[^\x20-\x7e]", "?", detail)[:300]
    try:
        with open(LOG_FILE, "a", encoding="ascii") as fh:
            fh.write(line + "\n")
    except OSError as e:
        print(f"warning: could not write {LOG_FILE}: {e}", file=sys.stderr)


# ---------------------------------------------------------------- locking

class locked:
    """One deploy or rollback per app at a time. Gives up after LOCK_WAIT seconds,
    so one hung deploy cannot block every later webhook forever."""

    def __init__(self, root, name=".lock"):
        self.path = root / name

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fh = open(self.path, "w")
        deadline = time.monotonic() + LOCK_WAIT
        while True:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    fh.close()
                    err = DeployError(f"another deploy of this app is still running (waited {LOCK_WAIT}s)")
                    err.busy = True  # lets the webhook worker retry this one once
                    raise err
                time.sleep(0.2)
        self.fh = fh

    def __exit__(self, *exc):
        self.fh.close()


# ---------------------------------------------------------------- safety checks

def _forbidden(name):
    return name in (".git", ".npmrc", ".ssh", ".aws", ".env") or name.startswith(".env.")


def check_tree(path, label):
    """Walk a folder without following links. Refuse anything that must not be served.

    Run on the source before copying AND on the private copy afterwards. The copy is
    what gets published, so it is the one that has to be clean.
    """
    total = 0
    for dirpath, dirnames, filenames in os.walk(path):  # does not descend into links
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            if _forbidden(name):
                raise DeployError(f"{label} contains {name!r}, which must not be published: {full}")
            st = os.lstat(full)
            if stat.S_ISLNK(st.st_mode):
                raise DeployError(f"{label} contains a symlink, refusing: {full}")
            if stat.S_ISDIR(st.st_mode):
                continue
            if not stat.S_ISREG(st.st_mode):  # a FIFO would also hang the copy forever
                raise DeployError(f"{label} contains a special file, refusing: {full}")
            total += st.st_size
            if total > MAX_RELEASE_BYTES:
                raise DeployError(f"{label} is larger than {MAX_RELEASE_BYTES // 2**20} MB, refusing")
    return total


def strip_special_modes(path):
    """Drop setuid, setgid and sticky bits from the copy. copytree keeps modes, and a
    build must not be able to plant a setuid file under /sites."""
    for dirpath, dirnames, filenames in os.walk(path):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            mode = stat.S_IMODE(os.lstat(full).st_mode)
            if mode & 0o7000:
                os.chmod(full, mode & 0o0777)


# ---------------------------------------------------------------- release handling

def flip(root, current, release_id):
    """Point `current` at a release atomically: new link next to it, then rename over it.

    The rename is one step, so a request sees either the old release or the new one,
    never a missing link. The link is relative so the app folder can be moved.
    """
    tmp_link = root / f".current.tmp-{os.getpid()}"
    if tmp_link.is_symlink() or tmp_link.exists():
        tmp_link.unlink()
    os.symlink(f"releases/{release_id}", tmp_link)
    os.replace(tmp_link, current)


def cleanup_stale(root, releases):
    """Called under the lock, so anything still named .tmp-* is left over from a
    crashed run. Removing it first also frees disk space before a new copy."""
    for p in list(releases.glob(".tmp-*")) + list(root.glob(".current.tmp-*")):
        try:
            if p.is_symlink() or p.is_file():
                p.unlink()
            else:
                shutil.rmtree(p)
        except OSError as e:
            print(f"warning: could not remove {p}: {e}", file=sys.stderr)


def prune(releases, live, keep=KEEP):
    """Delete old releases, never the live one. Warns instead of failing: by the time
    this runs the new release is already live, so a cleanup error is not a failed deploy.

    Each release is renamed to .tmp-del-<id> first (one step, so a half-deleted folder
    can never match a release id and be rolled back to), then removed.
    """
    ids = release_ids(releases)
    keep_set = set(ids[-keep:]) if keep > 0 else set()
    if live:
        keep_set.add(live)
    for rid in ids:
        if rid in keep_set:
            continue
        gone = releases / f".tmp-del-{rid}"
        try:
            os.rename(releases / rid, gone)
            shutil.rmtree(gone)
        except OSError as e:
            print(f"warning: could not prune {rid}: {e}", file=sys.stderr)


def _deploy_locked(src, root, releases, current):
    src = Path(src)
    if src.is_symlink():  # a link to /root would pass every check below
        raise DeployError(f"source {src} is a symlink, refusing")
    if not src.is_dir():
        raise DeployError(f"source {src} is not a folder")
    if not any(src.iterdir()):
        raise DeployError(f"source {src} is empty")
    check_tree(src, "source")

    cleanup_stale(root, releases)
    live = current_id(current)  # raises early if `current` is a real folder
    releases.mkdir(parents=True, exist_ok=True)
    prune(releases, live, keep=KEEP - 1)  # make room before copying, not after

    release_id = next_release_id(release_ids(releases))
    # Fill a hidden folder first, rename it when complete. If anything fails here,
    # nothing visible changed and `current` never moved.
    tmp = releases / f".tmp-{release_id}"
    try:
        shutil.copytree(src, tmp, symlinks=True)  # links stay links; they are rejected next
        check_tree(tmp, "release")                # re-check the copy that will be served
        strip_special_modes(tmp)
        if not (tmp / "index.html").is_file():
            print("warning: no index.html at the top of the release; the site root will 404",
                  file=sys.stderr)
        os.rename(tmp, releases / release_id)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise

    os.sync()  # file data reaches disk before `current` points at it
    flip(root, current, release_id)
    prune(releases, release_id)
    return release_id, live


def _logged(app, action, fn):
    """Run fn() -> (release, previous), print and log the result, log failures too."""
    started = time.monotonic()
    try:
        release_id, previous = fn()
    except DeployError as e:
        log_event(app, action, None, "fail", started, str(e))
        raise
    except Exception as e:
        log_event(app, action, None, "crash", started, f"{type(e).__name__}: {e}")
        raise
    log_event(app, action, release_id, "ok", started, f"was={previous or '-'}")
    print(f"live: {release_id}  (was: {previous or 'nothing'})")
    return release_id


def deploy(app, src):
    def run():
        root, releases, current = app_paths(app)  # inside run(): a bad name is logged too
        with locked(root):
            return _deploy_locked(src, root, releases, current)
    return _logged(app, "deploy", run)


def rollback(app, release_id=None):
    def run():
        root, releases, current = app_paths(app)
        with locked(root):
            live = current_id(current)
            ids = release_ids(releases)
            target = release_id
            if target is None:
                older = [r for r in ids if live is None or id_key(r) < id_key(live)]
                if not older:
                    raise DeployError("no older release to roll back to")
                target = older[-1]
            elif not ID_RE.fullmatch(target) or target not in ids:
                raise DeployError(f"unknown release {target!r} (try: list {app})")
            flip(root, current, target)
            set_hold(root)
            return target, live
    result = _logged(app, "rollback", run)
    print(f"held: webhook deploys for {app} are paused. Resume with: deploy.py unhold {app}")
    return result


def rollforward(app):
    def run():
        root, releases, current = app_paths(app)
        with locked(root):
            live = current_id(current)
            if live is None:
                raise DeployError("nothing is live, so there is nothing to roll forward from")
            newer = [r for r in release_ids(releases) if id_key(r) > id_key(live)]
            if not newer:
                raise DeployError("already on the newest release")
            flip(root, current, newer[0])
            set_hold(root)
            return newer[0], live
    result = _logged(app, "rollforward", run)
    print(f"held: webhook deploys for {app} are paused. Resume with: deploy.py unhold {app}")
    return result


def unhold(app):
    started = time.monotonic()
    root, _, _ = app_paths(app)
    cleared = clear_hold(root)
    log_event(app, "unhold", None, "ok" if cleared else "noop", started)
    print(f"{app}: webhook deploys resumed" if cleared else f"{app}: was not held")


def clear_hold_after_manual_deploy(app):
    """A deploy the owner starts by hand is a clear decision: lift the hold."""
    root, _, _ = app_paths(app)
    if clear_hold(root):
        print(f"{app}: hold cleared (manual deploy)")


def list_releases(app):
    root, releases, current = app_paths(app)
    live = current_id(current)
    ids = release_ids(releases)
    if not ids:
        print(f"{app}: no releases")
    for rid in ids:
        print(f"{'*' if rid == live else ' '} {rid}")
    if is_held(root):
        print(f"(held: webhook deploys paused; resume with: deploy.py unhold {app})")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("deploy")
    p.add_argument("app")
    p.add_argument("dir")
    p = sub.add_parser("rollback")
    p.add_argument("app")
    p.add_argument("release", nargs="?")
    p = sub.add_parser("rollforward")
    p.add_argument("app")
    p = sub.add_parser("unhold")
    p.add_argument("app")
    p = sub.add_parser("list")
    p.add_argument("app")
    args = parser.parse_args()

    try:
        if args.cmd == "deploy":
            deploy(args.app, args.dir)
            clear_hold_after_manual_deploy(args.app)
        elif args.cmd == "unhold":
            unhold(args.app)
        elif args.cmd == "rollback":
            rollback(args.app, args.release)
        elif args.cmd == "rollforward":
            rollforward(args.app)
        else:
            list_releases(args.app)
    except DeployError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    if args.cmd != "list" and args.app != "dashboard":
        import dashboard  # lazy: dashboard.py imports this module
        dashboard.maybe_refresh()  # keeps the dashboard in step; never raises
    return 0


if __name__ == "__main__":
    sys.exit(main())
