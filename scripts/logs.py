#!/usr/bin/env python3
"""mini-deploy build logs in the terminal (the same logs as logs.localhost:8080).

    logs.py                     apps that have build logs
    logs.py <app>               that app's recent builds, newest first
    logs.py <app> last          print the newest build log
    logs.py <app> <n>           print build number n from the list (1 = newest)

Standard library only.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import buildlog  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app", nargs="?")
    parser.add_argument("which", nargs="?", help="'last' or a number from the list")
    args = parser.parse_args()

    root = buildlog.LOGS_ROOT
    if args.app is None:
        apps = sorted(p.name for p in root.iterdir() if p.is_dir() and buildlog.APP_RE.fullmatch(p.name)) \
            if root.is_dir() else []
        print("\n".join(apps) if apps else "no build logs yet")
        return 0
    if not buildlog.APP_RE.fullmatch(args.app):
        print("error: bad app name", file=sys.stderr)
        return 1
    folder = root / args.app
    logs = buildlog.logs_of(folder) if folder.is_dir() else []
    if not logs:
        print(f"{args.app}: no build logs")
        return 0

    if args.which is None:
        for n, path in enumerate(logs, 1):
            h = buildlog.read_header(path)
            print(f"{n:>2}  {h.get('started', '?'):20}  {h.get('result', '?'):4}  "
                  f"{h.get('duration', ''):>7}  {h.get('commit', '')[:7]:7}  {h.get('release', '')}")
        print(f"\nshow one: logs.py {args.app} last   (or a number)")
        return 0
    if args.which == "last":
        n = 1
    elif args.which.isdigit() and 1 <= int(args.which) <= len(logs):
        n = int(args.which)
    else:
        print(f"error: pick 'last' or a number from 1 to {len(logs)}", file=sys.stderr)
        return 1
    sys.stdout.write(logs[n - 1].read_text(encoding="utf-8", errors="replace"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
