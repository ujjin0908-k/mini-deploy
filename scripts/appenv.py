#!/usr/bin/env python3
"""mini-deploy: environment variables per app, for the BUILD only.

    appenv.py set   <app> <KEY> [--public] [--preview]   value from stdin (or a hidden prompt)
    appenv.py unset <app> <KEY> [--preview]
    appenv.py list  <app> [--preview]                     names only; public values are shown

    /etc/mini-deploy/apps/<app>.json           the live app's values   (dir 0700, file 0600, root)
    /etc/mini-deploy/apps/<app>.preview.json   what previews of <app> get (never the live values)

The values go into the Docker build as environment variables and nowhere else: not into
the release, not into the dashboard, not into a log. A secret (the default) is masked in
build output and build logs, and a build whose dist/ contains a secret is refused. A value
marked --public (an API address, a feature flag) may appear in the site and is not masked.

Why previews have their own file: with previews on, any pushed branch is built. If a
branch got the live app's secrets, one push of `console.log(process.env)` could print them.

Only `npm run build` gets the values: `npm ci` runs in a box of its own without them, so
package install steps never see a secret. (Code the build itself loads, your own and your
dependencies', does see them; that is what they are for.)

Masking and the dist/ check look for the value as written and in common encodings (JS/JSON
string, HTML, URL, base64). That is a safety net for mistakes, not a wall: code that wants
to hide a value (reversed, split, encrypted) gets past it. Root on this machine, and
`docker inspect` during a build, can read the values.

The file is JSON parsed by Python, never sourced as shell, so a value cannot run anything.
A value never goes through argv (that would show in `ps` and in shell history).
Standard library only.
"""

import argparse
import contextlib
import fcntl
import getpass
import json
import os
import re
import stat
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deploy as deploy_mod  # app names and previews follow the same rules everywhere

REAL_ROOT = Path("/etc/mini-deploy/apps")
# Tests point the store at a temp folder. The override needs a second, explicit switch, so
# a stray variable in a service's environment cannot move the real store somewhere else.
if os.environ.get("MINI_DEPLOY_APP_ENV") and os.environ.get("MINI_DEPLOY_TESTING") == "1":
    ENV_ROOT = Path(os.environ["MINI_DEPLOY_APP_ENV"])
else:
    ENV_ROOT = REAL_ROOT
KEY_RE = re.compile(r"^[A-Z_][A-Z0-9_]{0,63}$")
# These change how node, npm, the shell, TLS, proxies or the loader behave rather than what
# the app builds, or would override what build.py sets on purpose (HOME, the npm cache).
DENIED = {"PATH", "HOME", "TMPDIR", "TMP", "TEMP", "SHELL", "ENV", "BASH_ENV", "SHELLOPTS",
          "BASHOPTS", "IFS", "PS4", "CDPATH", "GODEBUG", "GCONV_PATH", "LOCPATH"}
DENIED_PREFIXES = ("NODE_", "NPM_CONFIG_", "NPM_", "YARN_", "PNPM_", "COREPACK_", "LD_",
                   "DOCKER_", "SSL_", "OPENSSL_", "CURL_", "GIT_", "XDG_", "PYTHON", "BASH_FUNC_")
DENIED_SUFFIXES = ("_PROXY",)                   # HTTP_PROXY, HTTPS_PROXY, NO_PROXY, ALL_PROXY
ALLOWED = {"NODE_ENV"}                          # the one NODE_ name builds commonly need
MAX_VALUE = 4096          # bytes
MAX_KEYS = 64
MAX_FILE = 1024 * 1024    # comfortably above 64 full values; a bigger file is refused, not cut
MIN_SECRET = 8            # shorter is not a secret; masking 2 letters would wreck the log
LOCK_WAIT = 15


class EnvError(Exception):
    pass


def check_key(key):
    if not isinstance(key, str) or not KEY_RE.fullmatch(key):
        raise EnvError("bad name: use A-Z, 0-9 and _, start with a letter or _, at most 64")
    if key not in ALLOWED and (key in DENIED or key.startswith(DENIED_PREFIXES)
                               or key.endswith(DENIED_SUFFIXES)):
        raise EnvError(f"{key} is not allowed (it changes how node, npm or the system "
                       "behave, not your app)")


def check_value(value, public):
    if not isinstance(value, str) or "\x00" in value or "\n" in value or "\r" in value:
        raise EnvError("value must be one line with no NUL")
    try:
        size = len(value.encode("utf-8"))
    except UnicodeEncodeError:  # a lone surrogate such as "\ud800" from JSON
        raise EnvError("value is not valid text")
    if size > MAX_VALUE:
        raise EnvError(f"value is longer than {MAX_VALUE} bytes")
    if not public and len(value) < MIN_SECRET:
        raise EnvError(f"a secret needs at least {MIN_SECRET} characters "
                       "(add --public if this value is not secret)")


def env_file(app, preview=False):
    """The file for an app (or for its previews). The name is checked before any path is built."""
    deploy_mod.app_paths(app)  # raises on a bad name
    if deploy_mod.PREVIEW_SEP in app:
        raise EnvError("set values on the app, with --preview for its previews")
    return ENV_ROOT / (f"{app}.preview.json" if preview else f"{app}.json")


def file_for_build(app):
    """Which file a build of `app` reads: a preview reads its parent's .preview.json."""
    parent = deploy_mod.preview_parent(app)
    return env_file(parent, preview=True) if parent else env_file(app)


def _check_private(st, what):
    """Like ssh with its keys: a file anyone else could write or read is not trusted."""
    if st.st_uid != os.getuid():
        raise EnvError(f"{what} is not owned by this user; not used")
    if st.st_mode & 0o077:
        raise EnvError(f"{what} can be read by others (mode {stat.S_IMODE(st.st_mode):o}); "
                       f"fix with chmod go= {what}")


def check_root():
    """The store folder itself must be a real folder, ours, closed to others. Otherwise
    someone could swap files in it even when each file looks fine."""
    try:
        st = os.lstat(ENV_ROOT)
    except FileNotFoundError:
        return False
    if not stat.S_ISDIR(st.st_mode):
        raise EnvError(f"{ENV_ROOT} is not a folder (or is a link); nothing was used")
    _check_private(st, str(ENV_ROOT))
    return True


def load(path):
    """{KEY: {"value": str, "public": bool}}. A missing file = no values.
    Opened without following links and without blocking (a FIFO placed there would hang the
    open forever), then checked: folder, owner, mode, size, and every entry again."""
    if not check_root():
        return {}
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except FileNotFoundError:
        return {}
    except OSError as e:
        raise EnvError(f"cannot open {path.name} ({e.strerror})")
    with os.fdopen(fd, "rb") as fh:
        st = os.fstat(fh.fileno())
        if not stat.S_ISREG(st.st_mode):
            raise EnvError(f"{path.name} is not a regular file")
        _check_private(st, str(path))
        raw = fh.read(MAX_FILE + 1)
    if len(raw) > MAX_FILE:
        raise EnvError(f"{path.name} is larger than {MAX_FILE // 1024} KB; nothing was used")
    try:
        data = json.loads(raw.decode("utf-8"))
    except (ValueError, RecursionError):   # UnicodeDecodeError is a ValueError
        raise EnvError(f"{path.name} is not valid JSON; nothing was used")
    if not isinstance(data, dict) or len(data) > MAX_KEYS:
        raise EnvError(f"{path.name} has the wrong shape")
    out = {}
    for key, entry in data.items():
        if not isinstance(entry, dict):
            raise EnvError(f"{path.name}: entry {key!r} has the wrong shape")
        public = entry.get("public") is True
        check_key(key)
        check_value(entry.get("value"), public)
        out[key] = {"value": entry["value"], "public": public}
    return out


def for_build(app):
    """(all values for the container, {KEY: value} of the secrets to mask and to forbid in
    dist). Raises EnvError if the file exists but cannot be trusted: a build must not
    quietly run without its values."""
    entries = load(file_for_build(app))
    values = {k: e["value"] for k, e in entries.items()}
    secrets = {k: e["value"] for k, e in entries.items() if not e["public"]}
    return values, secrets


@contextlib.contextmanager
def _locked():
    """One writer at a time, so two quick `set`s cannot lose one of them."""
    if not ENV_ROOT.exists() and not ENV_ROOT.is_symlink():
        ENV_ROOT.mkdir(mode=0o700, parents=True)
    check_root()
    fd = os.open(ENV_ROOT / ".lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    with os.fdopen(fd, "w") as fh:
        deadline = time.monotonic() + LOCK_WAIT
        while True:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise EnvError("the env files are locked by another command")
                time.sleep(0.1)
        yield


def _save(path, entries):
    """Write to a 0600 temp file next to `path`, then rename over it (never half-written)."""
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(entries, fh, indent=1, sort_keys=True, ensure_ascii=False)  # same size as read
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def set_value(app, key, value, public=False, preview=False):
    check_key(key)
    check_value(value, public)
    path = env_file(app, preview)
    with _locked():
        entries = load(path)
        if key not in entries and len(entries) >= MAX_KEYS:
            raise EnvError(f"at most {MAX_KEYS} values per app")
        entries[key] = {"value": value, "public": public}
        _save(path, entries)


def unset_value(app, key, preview=False):
    check_key(key)
    path = env_file(app, preview)
    with _locked():
        entries = load(path)
        if key not in entries:
            return False
        del entries[key]
        if entries:
            _save(path, entries)
        else:
            path.unlink()
        return True


def read_value_from_user():
    """stdin if it is piped (one trailing newline dropped), else a prompt that does not echo."""
    try:
        if sys.stdin.isatty():
            return getpass.getpass("value (not shown): ")
        value = sys.stdin.buffer.read(MAX_VALUE + 2).decode("utf-8")
    except UnicodeDecodeError:
        raise EnvError("value is not valid UTF-8 text")
    return value[:-1] if value.endswith("\n") else value


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("set")
    p.add_argument("app"); p.add_argument("key")
    p.add_argument("--public", action="store_true", help="not secret: not masked, may appear in the site")
    p.add_argument("--preview", action="store_true", help="the value previews of this app get")
    p = sub.add_parser("unset")
    p.add_argument("app"); p.add_argument("key")
    p.add_argument("--preview", action="store_true")
    p = sub.add_parser("list")
    p.add_argument("app")
    p.add_argument("--preview", action="store_true")
    args = parser.parse_args()
    where = "previews of " + args.app if args.preview else args.app
    try:
        if args.cmd == "set":
            check_key(args.key)  # fail before asking for a value
            env_file(args.app, args.preview)
            set_value(args.app, args.key, read_value_from_user(), args.public, args.preview)
            print(f"set {args.key} for {where} ({'public' if args.public else 'secret'}); "
                  "used from the next build")
        elif args.cmd == "unset":
            print(f"removed {args.key} from {where}" if unset_value(args.app, args.key, args.preview)
                  else f"{args.key} was not set for {where}")
        else:
            entries = load(env_file(args.app, args.preview))
            if not entries:
                print(f"no values for {where}")
            for key, e in sorted(entries.items()):
                # A secret is never printed, not even its length.
                print(f"{key}={e['value']}  (public)" if e["public"] else f"{key}=********")
    except (EnvError, deploy_mod.DeployError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
