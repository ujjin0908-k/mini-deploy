#!/usr/bin/env python3
"""Remove what the test suites leave behind on purpose (they never delete anything themselves).

    clean-test-leftovers.py          list what would be removed (nothing is touched)
    clean-test-leftovers.py --yes    remove it, then rebuild the build-log index

Removed: test apps in /sites and their build logs, /tmp/mini-deploy-* and the suites' folders in
/var/tmp. A test app is recognised by its NAME only, never "everything except my apps": a name
ending in a process id (`dots-161413`), one of the suites' fixed names, or a preview of one of
those. An app connected on the admin page is never removed, whatever its name. Run as root.
"""

import argparse
import glob
import os
import re
import shutil
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deploy as deploy_mod   # noqa: E402  (SITES, APP_RE, PREVIEW_SEP)
import admindb                # noqa: E402  (DB_PATH)

# The suites' fixed app names (everything else they create ends in the shell's $$).
FIXED = {"demo", "demo-site", "hook-static", "hook-test", "mini-deploy", "probe-build"}
PID_RE = re.compile(r"-[0-9]{3,7}$")
LOGS = Path("/var/log/mini-deploy/builds")
TEMP = ("/tmp/mini-deploy-*", "/var/tmp/mini-deploy-hook-*", "/var/tmp/mini-deploy-build-*",
        "/var/tmp/mini-deploy-restoretest-*", "/var/tmp/mini-deploy-backup-*")
KEEP_TEMP = "/tmp/mini-deploy-suites"


def is_test_name(name):
    if not deploy_mod.APP_RE.fullmatch(name):
        return False
    parent = name.rsplit(deploy_mod.PREVIEW_SEP, 1)[-1]   # a preview counts as its app
    return any(n in FIXED or PID_RE.search(n) for n in (name, parent))


def connected_apps():
    """Apps connected on the admin page: never removed (an unreadable database = remove nothing)."""
    if not admindb.DB_PATH.exists():
        return set()
    con = sqlite3.connect(f"file:{admindb.DB_PATH}?mode=ro", uri=True, timeout=10)
    try:
        return {r[0] for r in con.execute("SELECT app FROM repos")}
    finally:
        con.close()


def plan():
    keep = connected_apps()
    sites = [p for p in sorted(deploy_mod.SITES.iterdir())
             if is_test_name(p.name) and p.name not in keep and not p.is_symlink()]
    logs = [p for p in sorted(LOGS.iterdir())
            if p.is_dir() and is_test_name(p.name) and p.name not in keep] if LOGS.is_dir() else []
    # test-all.sh's own outputs stay: they are what you read after a failed run
    temp = sorted(p for pattern in TEMP for p in glob.glob(pattern) if p != KEEP_TEMP)
    return sites, logs, temp


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--yes", action="store_true", help="really remove (default: only list)")
    args = parser.parse_args()
    try:
        sites, logs, temp = plan()
    except sqlite3.Error as e:
        print(f"error: cannot read the admin database ({e}); nothing removed", file=sys.stderr)
        return 1
    print(f"test apps in /sites: {len(sites)}  build-log folders: {len(logs)}  temp entries: {len(temp)}")
    for p in sites:
        print(f"  {p.name}")
    if not args.yes:
        print("nothing removed (run with --yes)")
        return 0
    for p in [*sites, *logs, *map(Path, temp)]:
        if p.is_dir() and not p.is_symlink():
            shutil.rmtree(p, ignore_errors=True)
        else:
            p.unlink(missing_ok=True)
    import buildlog   # only now: the index lists what is left
    buildlog.write_index()
    left = sorted(p.name for p in deploy_mod.SITES.iterdir())
    print("removed; /sites now: " + (", ".join(left) or "(empty)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
