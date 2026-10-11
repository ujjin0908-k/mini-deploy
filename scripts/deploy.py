#!/usr/bin/env python3
"""mini-deploy: release folders, an atomic `current` link, and rollback.

    deploy.py deploy   <app> <dir>        copy <dir> into a new release and go live
    deploy.py rollback <app> [release-id] point `current` at an older release
    deploy.py list     <app>              show releases, `*` marks the live one

Layout (runtime data lives in the WSL filesystem, not on /mnt/c):

    /sites/<app>/releases/<id>/
    /sites/<app>/current -> releases/<id>

Standard library only. The same functions are reused by the webhook in stage 5.
"""

import argparse
import fcntl
import os
import re
import shutil
import sys
import time
from pathlib import Path

SITES = Path("/sites")

# Same rule the Caddyfile applies to the Host header. App names end up in file
# paths, so they are checked here before any path is built from them.
APP_RE = re.compile(r"^[a-z0-9-]{1,40}$")
# 20261011-163000, with an optional -N when two deploys land in the same second.
ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}(-[0-9]+)?$")

KEEP = 5          # releases kept for rollback (the rule says at least 3)
STALE_TMP = 3600  # seconds before a leftover .tmp-* folder is cleaned up


class DeployError(Exception):
    pass


def app_paths(app):
    if not APP_RE.fullmatch(app):
        raise DeployError(f"bad app name {app!r}: use only a-z, 0-9 and '-', 1 to 40 characters")
    root = SITES / app
    return root, root / "releases", root / "current"


def release_ids(releases):
    """Real release folders, oldest first. Hidden .tmp-* folders never count."""
    if not releases.is_dir():
        return []
    return sorted(p.name for p in releases.iterdir() if ID_RE.fullmatch(p.name) and p.is_dir())


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


def reject_symlinks(src):
    """A link inside the source could pull in files from outside it (and Caddy would serve them)."""
    for dirpath, dirnames, filenames in os.walk(src):
        for name in dirnames + filenames:
            if os.path.islink(os.path.join(dirpath, name)):
                raise DeployError(f"source contains a symlink, refusing: {os.path.join(dirpath, name)}")


def prune(releases, current_release):
    ids = release_ids(releases)
    keep = set(ids[-KEEP:])
    if current_release:
        keep.add(current_release)  # never delete what is live
    for rid in ids:
        if rid not in keep:
            shutil.rmtree(releases / rid)
    for p in releases.glob(".tmp-*"):
        if time.time() - p.stat().st_mtime > STALE_TMP:
            shutil.rmtree(p, ignore_errors=True)


class locked:
    """One deploy or rollback per app at a time."""

    def __init__(self, root):
        self.path = root / ".lock"

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.fh = open(self.path, "w")
        fcntl.flock(self.fh, fcntl.LOCK_EX)

    def __exit__(self, *exc):
        self.fh.close()


def deploy(app, src):
    root, releases, current = app_paths(app)
    src = Path(src)
    if not src.is_dir():
        raise DeployError(f"source {src} is not a folder")
    reject_symlinks(src)
    if not any(src.iterdir()):
        raise DeployError(f"source {src} is empty")

    with locked(root):
        current_release = current_id(current)  # raises early if `current` is a real folder
        releases.mkdir(parents=True, exist_ok=True)

        release_id = time.strftime("%Y%m%d-%H%M%S")
        n = 0
        while (releases / (release_id if n == 0 else f"{release_id}-{n}")).exists():
            n += 1
        if n:
            release_id = f"{release_id}-{n}"

        # Fill a hidden folder first, rename it when complete. If the copy fails,
        # nothing visible changed and `current` never moved.
        tmp = releases / f".tmp-{release_id}"
        try:
            shutil.copytree(src, tmp)
            os.rename(tmp, releases / release_id)
        except BaseException:
            shutil.rmtree(tmp, ignore_errors=True)
            raise

        flip(root, current, release_id)
        prune(releases, release_id)
    print(f"live: {release_id}  (was: {current_release or 'nothing'})")


def rollback(app, release_id=None):
    root, releases, current = app_paths(app)
    with locked(root):
        live = current_id(current)
        ids = release_ids(releases)
        if release_id is None:
            older = [r for r in ids if live is None or r < live]
            if not older:
                raise DeployError("no older release to roll back to")
            release_id = older[-1]
        elif not ID_RE.fullmatch(release_id) or release_id not in ids:
            raise DeployError(f"unknown release {release_id!r} (try: list {app})")
        flip(root, current, release_id)
    print(f"live: {release_id}  (was: {live or 'nothing'})")


def list_releases(app):
    root, releases, current = app_paths(app)
    live = current_id(current)
    ids = release_ids(releases)
    if not ids:
        print(f"{app}: no releases")
    for rid in ids:
        print(f"{'*' if rid == live else ' '} {rid}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("deploy")
    p.add_argument("app")
    p.add_argument("dir")
    p = sub.add_parser("rollback")
    p.add_argument("app")
    p.add_argument("release", nargs="?")
    p = sub.add_parser("list")
    p.add_argument("app")
    args = parser.parse_args()

    try:
        if args.cmd == "deploy":
            deploy(args.app, args.dir)
        elif args.cmd == "rollback":
            rollback(args.app, args.release)
        else:
            list_releases(args.app)
    except DeployError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
