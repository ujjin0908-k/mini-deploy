#!/usr/bin/env python3
"""mini-deploy backup: a weekly copy of what cannot be rebuilt, WITHOUT any secret.

    backup.py make [--dest DIR] [--keep N]     write mini-deploy-<UTC id>.tar.gz into DIR
    backup.py restore ARCHIVE --into DIR       unpack and check it in DIR (nothing live is touched)
    backup.py apply DIR                        put a restored copy in place, only where nothing exists

What is in it:
  - /sites: every app's releases, its `current` link and its .hold/.deployed/.branch notes
    (uploaded sites exist nowhere else);
  - admin.db with the secrets taken out: connected repos keep their settings but get an
    EMPTY webhook secret (pushes are refused until "New secret"), and the password hash,
    sessions and sign-ins are removed. The audit log stays;
  - the NAMES of each app's env values (never the values);
  - RESTORE.txt: what to make again by hand after a restore.

What is never in it: /etc/mini-deploy (webhook secret, GitHub token, Cheaper Inference
address, home network), env values, build logs. A restore means making new secrets, which is
also what you would do after losing the PC. Because nothing secret is inside, the archive may
sit in a synced folder (default: OneDrive, so a copy leaves this PC).

Run weekly by mini-deploy-backup.timer. Standard library only.
"""

import argparse
import calendar
import contextlib
import fcntl
import json
import os
import re
import shutil
import sqlite3
import sys
import tarfile
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deploy as deploy_mod   # noqa: E402  (APP_RE, ID_RE, check_tree, SITES)
import admindb                # noqa: E402  (DB_PATH)
import appenv                 # noqa: E402  (env value names: ENV_ROOT, load)
import ci_forwarder as ci_mod # noqa: E402  (the AI limits: not secret, so they are backed up)

DEST = Path("/mnt/c/Users/indra/OneDrive/mini-deploy-backups")
KEEP = 8                                  # weekly: about two months of history
FORMAT = 1
NAME_RE = re.compile(r"^mini-deploy-[0-9]{8}-[0-9]{6}\.tar\.gz$")
NOTES = (".hold", ".deployed", ".branch")  # small notes kept with an app (never its locks)
MAX_SITES_BYTES = 2 * 2**30               # a sanity cap: /sites is a few MB today
MAX_MEMBERS = 200_000                     # entries a restore accepts (a hostile archive is refused)
MAX_RESTORE_BYTES = MAX_SITES_BYTES + 256 * 2**20
LOCK_WAIT = 120                           # seconds to wait for an app's running deploy
STALE_DAYS = 8                            # weekly + a day: older than this, the admin page warns
SCAN_CHUNK = 1024 * 1024
WORK_ROOT = Path("/var/tmp")
TOP_ENTRIES = {"manifest.json", "RESTORE.txt", "admin.db", "sites", "ci-limits.json"}


def status_path():
    """Next to admin.db (so tests that move the database move this too). The admin page reads it."""
    return admindb.DB_PATH.parent / "backup.json"

RESTORE_TXT = """mini-deploy restore: what to make again by hand
=================================================
This archive holds no secrets. After `backup.py restore` and `backup.py apply`:

1. Admin password:      python3 scripts/admin.py set-password
2. GitHub token:        admin page -> GitHub token -> paste a new read-only token
3. Each connected repo: admin page -> New secret, then paste the new secret into the
                        repo's webhook on GitHub (until then every push is refused: 401)
4. Old shared secret:   python3 scripts/webhook.py --init-env   (only if config/webhook.json lists repos)
5. Cheaper Inference:   echo 'https://...' | python3 scripts/ci_forwarder.py set-upstream
   AI limits:           `backup.py apply` puts ci-limits.json back (if none exists); check it with
                        `python3 scripts/ci_forwarder.py usage`. Without it every AI call is refused.
6. Home network:        bash scripts/run-caddy.sh remember-home   (at home)
7. Env values:          python3 scripts/appenv.py set <app> <KEY>   (names are in manifest.json)
8. Services:            install the units from systemd/ and start them (see CLAUDE.md)
"""


class BackupError(Exception):
    pass


def _now_id():
    return time.strftime("%Y%m%d-%H%M%S", time.gmtime())


# ---------------------------------------------------------------- make

def _apps(sites):
    """App folders under /sites (previews are app names too). Anything else is skipped."""
    out = []
    for entry in sorted(os.listdir(sites)):
        full = sites / entry
        if deploy_mod.APP_RE.fullmatch(entry) and full.is_dir() and not full.is_symlink() \
                and (full / "releases").is_dir():
            out.append(entry)
    return out


def _tree_bytes(path):
    total = 0
    for dirpath, _, files in os.walk(path):
        for f in files:
            try:
                total += os.lstat(os.path.join(dirpath, f)).st_size
            except OSError:
                pass
    return total


def scrubbed_db(src, out):
    """A copy of the admin database with every secret taken out, then VACUUMed so the old
    values do not linger in free pages. Returns {"repos": n, "audit": n}."""
    if not src.exists():
        return None
    con = sqlite3.connect(f"file:{src}?mode=ro", uri=True, timeout=10)
    dst = sqlite3.connect(out)
    try:
        con.backup(dst)              # a consistent copy, even while the admin page writes
    finally:
        con.close()
    try:
        dst.executescript(admindb.SCHEMA)   # an older file may lack a table
        dst.execute("UPDATE repos SET secret = ''")
        dst.execute("DELETE FROM sessions")
        dst.execute("DELETE FROM failures")
        dst.execute("DELETE FROM logins")
        # Every setting goes, not just the password: a setting added later can never slip
        # into a backup unnoticed (today the only one IS the password hash).
        dst.execute("DELETE FROM settings")
        dst.commit()
        dst.execute("VACUUM")
        counts = {"repos": dst.execute("SELECT COUNT(*) FROM repos").fetchone()[0],
                  "audit": dst.execute("SELECT COUNT(*) FROM audit").fetchone()[0]}
    finally:
        dst.close()
    return counts


def live_secrets(db_path):
    """The values that must never be in a backup: repo secrets, the password hash and session
    hashes from the live database. Used to check the finished copy byte by byte."""
    found = []
    if not db_path.exists():
        return found
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=10)
    try:
        for sql in ("SELECT secret FROM repos", "SELECT value FROM settings WHERE key = 'password'",
                    "SELECT token_hash FROM sessions", "SELECT csrf FROM sessions"):
            try:
                found += [r[0] for r in con.execute(sql) if isinstance(r[0], str) and len(r[0]) >= 8]
            except sqlite3.OperationalError:
                pass
    finally:
        con.close()
    return found


def env_names(apps_dir):
    """{app: [{"name": KEY, "public": bool}]} for every env file: names only, never values."""
    out = {}
    if not apps_dir.is_dir():
        return out
    for f in sorted(apps_dir.glob("*.json")):
        try:
            entries = appenv.load(f)
        except appenv.EnvError as e:
            out[f.stem] = {"error": str(e)}
            continue
        out[f.stem] = [{"name": k, "public": e["public"]} for k, e in sorted(entries.items())]
    return out


@contextlib.contextmanager
def app_lock(root, wait=None):
    """The same lock deploy.py takes (flock on <app>/.lock), opened READ-ONLY: the backup service
    sees /sites read-only, and flock works on a read-only handle. No lock file yet = no deploy
    has ever run under it, so there is nothing to wait for."""
    try:
        fd = os.open(root / ".lock", os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except FileNotFoundError:
        yield
        return
    wait = LOCK_WAIT if wait is None else wait
    try:
        deadline = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise BackupError(f"{root.name}: a deploy is still running after {wait}s; try again later")
                time.sleep(0.2)
        yield
    finally:
        os.close(fd)


def check_archive(path, manifest, secrets_to_avoid):
    """Before a backup counts: every app's live release is inside it, and no live secret is in
    any entry's name or content. Read entry by entry in chunks, never the whole archive at once."""
    needles = [s.encode() for s in secrets_to_avoid]
    overlap = max((len(n) for n in needles), default=1) - 1
    with tarfile.open(path, "r:gz") as tar:
        names = set()
        for m in tar:
            names.add(m.name)
            if any(n in m.name.encode("utf-8", "replace") for n in needles):
                raise BackupError("a secret was found in the archive; nothing was kept")
            if not m.isfile():
                continue
            fh, tail = tar.extractfile(m), b""
            while True:
                chunk = fh.read(SCAN_CHUNK)
                if not chunk:
                    break
                window = tail + chunk
                if any(n in window for n in needles):
                    raise BackupError("a secret was found in the archive; nothing was kept")
                tail = window[-overlap:] if overlap else b""
    for app, info in manifest["apps"].items():
        if info["current"] is not None and f"sites/{app}/{info['current']}" not in names:
            raise BackupError(f"{app}: its live release is missing from the archive; nothing was kept")


def write_status(ok, detail):
    """One small file the admin page reads: when the last backup ran, and when one last worked.
    Never fails the caller (a backup that worked stays worked)."""
    path = status_path()
    try:
        old = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    except (OSError, ValueError):
        old = {}
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    data = {"last_run": now, "last_result": "ok" if ok else "fail",
            "last_ok": now if ok else old.get("last_ok"),
            "archive": detail if ok else old.get("archive"),
            "error": None if ok else re.sub(r"[^\x20-\x7e]", "?", detail)[:200]}
    try:
        tmp = path.with_name(path.name + ".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        os.replace(tmp, path)
    except OSError as e:
        print(f"warning: could not write {path}: {e}", file=sys.stderr)


def read_status(now=None):
    """For the admin page: {"last_ok", "last_run", "last_result", "error", "age_days", "stale"}.
    No file, or no good backup within STALE_DAYS, is stale: a timer that never ran says so too."""
    try:
        data = json.loads(status_path().read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            data = {}
    except (OSError, ValueError):
        data = {}
    out = {k: data.get(k) if isinstance(data.get(k), str) else None
           for k in ("last_ok", "last_run", "last_result", "error")}
    age = None
    if out["last_ok"]:
        try:
            ok_at = calendar.timegm(time.strptime(out["last_ok"], "%Y-%m-%dT%H:%M:%SZ"))   # UTC
            age = max(0.0, ((now or time.time()) - ok_at) / 86400)
        except ValueError:
            age = None
    out["age_days"] = None if age is None else round(age, 1)
    out["stale"] = age is None or age > STALE_DAYS or out["last_result"] == "fail"
    return out


def _filter(info):
    """No locks and no half-made folders in the archive; plain owner and modes."""
    base = info.name.rsplit("/", 1)[-1]
    if base in (".lock", ".build.lock") or base.startswith(".tmp-"):
        return None
    if not (info.isfile() or info.isdir() or info.issym()):
        return None
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    info.mode &= 0o755
    return info


def make(dest=DEST, keep=KEEP, sites=None, db_path=None, apps_dir=None):
    """Write one archive into `dest` and keep the newest `keep`. Returns its path."""
    sites = Path(sites or deploy_mod.SITES)
    db_path = Path(db_path or admindb.DB_PATH)
    apps_dir = Path(apps_dir or appenv.ENV_ROOT)
    dest = Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    if dest.is_symlink() or not dest.is_dir():
        raise BackupError(f"{dest} is not a folder")

    apps = _apps(sites)
    size = sum(_tree_bytes(sites / a) for a in apps)
    if size > MAX_SITES_BYTES:
        raise BackupError(f"/sites holds {size // 2**20} MB, more than the {MAX_SITES_BYTES // 2**20} MB cap")
    if shutil.disk_usage(dest).free < 2 * size + 50 * 2**20:
        raise BackupError(f"not enough free space in {dest}")

    secrets_to_avoid = live_secrets(db_path)
    created = False
    work = Path(tempfile.mkdtemp(prefix="mini-deploy-backup-", dir=WORK_ROOT))
    backup_id = _now_id()
    final = dest / f"mini-deploy-{backup_id}.tar.gz"
    part = dest / f".mini-deploy-{backup_id}.tar.gz.part"
    try:
        db_counts = scrubbed_db(db_path, work / "admin.db")
        try:   # the AI limits (no secret inside): saved checked, so a restore gets usable ones
            (work / "ci-limits.json").write_text(json.dumps(ci_mod.load_limits(), indent=1) + "\n", encoding="utf-8")
            has_limits = True
        except ci_mod.ConfigError:
            has_limits = False
        manifest = {
            "format": FORMAT, "created": backup_id, "apps": {},   # apps: filled in under each lock
            "admin_db": db_counts, "env_names": env_names(apps_dir), "ci_limits": has_limits,
            "not_included": ["/etc/mini-deploy (secrets, token, CI address, home network)",
                             "env values", "build logs", "password hash and sessions"],
        }
        (work / "RESTORE.txt").write_text(RESTORE_TXT, encoding="utf-8")

        # The folder can be written from Windows: never follow a link planted under our name.
        fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        created = True   # from here on the .part file is ours to remove on failure
        with os.fdopen(fd, "wb") as fh:
            with tarfile.open(fileobj=fh, mode="w:gz") as tar:
                tar.add(work / "RESTORE.txt", "RESTORE.txt", filter=_filter)
                if db_counts is not None:
                    tar.add(work / "admin.db", "admin.db", filter=_filter)
                if has_limits:
                    tar.add(work / "ci-limits.json", "ci-limits.json", filter=_filter)
                for app in apps:
                    root = sites / app
                    # The app's own deploy lock: a deploy or prune cannot flip `current` or remove
                    # a release while it is read, so the live link and its release always match.
                    with app_lock(root):
                        link = root / "current"
                        target = os.readlink(link) if link.is_symlink() else None
                        manifest["apps"][app] = {
                            "current": target,
                            "releases": sorted(p.name for p in (root / "releases").iterdir()
                                               if deploy_mod.ID_RE.fullmatch(p.name)),
                        }
                        tar.add(root / "releases", f"sites/{app}/releases", filter=_filter)
                        if target is not None:
                            tar.add(link, f"sites/{app}/current", filter=_filter)
                        for note in NOTES:
                            p = root / note
                            if p.is_file() and not p.is_symlink():
                                tar.add(p, f"sites/{app}/{note}", filter=_filter)
                # Written last: it describes exactly what was read under the locks above.
                (work / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
                tar.add(work / "manifest.json", "manifest.json", filter=_filter)
            fh.flush()
            os.fsync(fh.fileno())

        check_archive(part, manifest, secrets_to_avoid)
        os.replace(part, final)
    except BaseException:
        if created:   # never remove a file someone else put under our name
            part.unlink(missing_ok=True)
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)

    old = sorted(p for p in dest.iterdir() if NAME_RE.fullmatch(p.name))
    for p in old[:-keep] if keep > 0 else []:
        p.unlink(missing_ok=True)
    return final


# ---------------------------------------------------------------- restore and apply

def restore(archive, into):
    """Unpack `archive` into the empty folder `into` and check it. Touches nothing live.
    Returns the manifest."""
    archive, into = Path(archive), Path(into)
    if not NAME_RE.fullmatch(archive.name):
        raise BackupError("not a mini-deploy backup name (mini-deploy-<id>.tar.gz)")
    into.mkdir(parents=True, exist_ok=True)
    if any(into.iterdir()):
        raise BackupError(f"{into} is not empty")
    os.chmod(into, 0o700)
    with tarfile.open(archive, "r:gz") as tar:
        members, total = 0, 0
        for m in tar:
            members += 1
            total += m.size
            if members > MAX_MEMBERS or total > MAX_RESTORE_BYTES:
                raise BackupError("the archive is larger than any backup this PC makes; not used")
            parts = m.name.split("/")
            ok = m.name in TOP_ENTRIES - {"sites"} or \
                (len(parts) >= 3 and parts[0] == "sites" and deploy_mod.APP_RE.fullmatch(parts[1]))
            if not ok:
                raise BackupError(f"unexpected entry in the archive: {m.name[:80]!r}")
        # "data": no absolute paths, no "..", no links leading outside, no devices, modes tamed
        tar.extractall(into, filter="data")
    manifest = _manifest(into)
    verify_tree(into, manifest)
    return manifest


def _manifest(into):
    try:
        manifest = json.loads((into / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise BackupError(f"the manifest is missing or unreadable ({type(e).__name__})")
    if not isinstance(manifest, dict) or manifest.get("format") != FORMAT or not isinstance(manifest.get("apps"), dict):
        raise BackupError(f"unknown backup format {manifest.get('format') if isinstance(manifest, dict) else None!r}")
    return manifest


def _check_app(root, info, label):
    """One app folder: only releases/, current and the notes; every release checked like a deploy
    (no links, nothing forbidden); `current` a link to one of its own releases, as the manifest says."""
    for entry in root.iterdir():
        if entry.name == "releases":
            ok = entry.is_dir() and not entry.is_symlink()
        elif entry.name == "current":
            ok = entry.is_symlink()
        else:
            ok = entry.name in NOTES and entry.is_file() and not entry.is_symlink()
        if not ok:
            raise BackupError(f"{label}: unexpected {entry.name[:60]!r}")
    for rel in (root / "releases").iterdir():
        if rel.is_symlink() or not rel.is_dir() or not deploy_mod.ID_RE.fullmatch(rel.name):
            raise BackupError(f"{label}: unexpected release {rel.name[:60]!r}")
        deploy_mod.check_tree(rel, f"release {label}/{rel.name}")
    target = info.get("current") if isinstance(info, dict) else None
    link = root / "current"
    found = os.readlink(link) if link.is_symlink() else None
    if found != target or (target is not None and (
            not re.fullmatch(r"releases/[0-9]{8}-[0-9]{6}(-[0-9]{1,3})?", target) or not (root / target).is_dir()
            or (root / target).is_symlink())):
        raise BackupError(f"{label}: its current link is missing or wrong")


def verify_tree(into, manifest):
    """What is REALLY in the folder, not what the manifest claims: the same apps on both sides,
    each app folder checked whole, the database whole and secret-free. Run by restore, and again
    by apply right before anything is copied (the folder could have changed in between)."""
    st = os.lstat(into)
    if not os.path.isdir(into) or os.path.islink(into) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise BackupError(f"{into} must be a private folder of this user (made by restore)")
    extra = {p.name for p in into.iterdir()} - TOP_ENTRIES
    if extra:
        raise BackupError(f"unexpected entry {sorted(extra)[0][:60]!r} in {into}")
    sites_dir = into / "sites"
    if sites_dir.is_symlink() or (sites_dir.exists() and not sites_dir.is_dir()):
        raise BackupError("sites/ must be a folder")
    found = sorted(p.name for p in sites_dir.iterdir()) if sites_dir.is_dir() else []
    if found != sorted(manifest["apps"]):
        raise BackupError("the apps in the archive do not match its manifest")
    for app in found:
        root = sites_dir / app
        if not deploy_mod.APP_RE.fullmatch(app) or root.is_symlink() or not root.is_dir():
            raise BackupError(f"unexpected app folder {app[:60]!r}")
        _check_app(root, manifest["apps"][app], app)
    lim = into / "ci-limits.json"
    if lim.is_symlink() or (lim.exists() and not lim.is_file()):
        raise BackupError("ci-limits.json must be a plain file")
    if lim.exists():
        try:
            ci_mod.valid_limits(json.loads(lim.read_text(encoding="utf-8")))
        except (ValueError, ci_mod.ConfigError) as e:
            raise BackupError(f"ci-limits.json in the archive is not usable ({e})")
    db = into / "admin.db"
    if db.is_symlink() or (db.exists() and not db.is_file()):
        raise BackupError("admin.db must be a plain file")
    if db.exists():
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        try:
            if con.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise BackupError("admin.db in the archive is damaged")
            if con.execute("SELECT COUNT(*) FROM repos WHERE secret != ''").fetchone()[0] \
                    or con.execute("SELECT COUNT(*) FROM settings").fetchone()[0] \
                    or con.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]:
                raise BackupError("admin.db in the archive holds a secret; not used")
        finally:
            con.close()


def apply(into, sites=None, db_path=None, limits_path=None):
    """Put a restored copy in place. Never replaces anything: an app folder or an admin.db
    that already exists is kept and reported. Returns (placed, kept)."""
    into = Path(into)
    sites = Path(sites or deploy_mod.SITES)
    db_path = Path(db_path or admindb.DB_PATH)
    limits_path = Path(limits_path or ci_mod.LIMITS)
    manifest = _manifest(into)
    verify_tree(into, manifest)
    placed, kept = [], []
    for app in sorted(manifest["apps"]):
        if (sites / app).exists() or (sites / app).is_symlink():
            kept.append(app)
            continue
        tmp = sites / f".tmp-restore-{app}-{os.getpid()}"
        shutil.copytree(into / "sites" / app, tmp, symlinks=True)
        try:
            # The copy is what goes live: check it, not the source it came from.
            _check_app(tmp, manifest["apps"][app], app)
        except BaseException:
            shutil.rmtree(tmp, ignore_errors=True)
            raise
        os.rename(tmp, sites / app)
        placed.append(app)
    src_db = into / "admin.db"
    if src_db.exists():
        if db_path.exists():
            kept.append(str(db_path))
        else:
            db_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            fd = os.open(db_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as out, open(src_db, "rb") as src:
                shutil.copyfileobj(src, out)
            placed.append(str(db_path))
    src_lim = into / "ci-limits.json"
    if src_lim.exists():
        if limits_path.exists():
            kept.append(str(limits_path))
        else:
            limits_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            fd = os.open(limits_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as out, open(src_lim, "rb") as src:
                shutil.copyfileobj(src, out)
            placed.append(str(limits_path))
    return placed, kept


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("make")
    p.add_argument("--dest", default=str(DEST))
    p.add_argument("--keep", type=int, default=KEEP)
    p = sub.add_parser("restore")
    p.add_argument("archive")
    p.add_argument("--into", required=True)
    p = sub.add_parser("apply")
    p.add_argument("into")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.cmd == "make":
            try:
                path = make(args.dest, args.keep)
            except BaseException as e:   # the admin page shows a failed run, not only an old one
                write_status(False, f"{type(e).__name__}: {e}")
                raise
            write_status(True, path.name)
            print(f"backup written: {path} ({path.stat().st_size // 1024} KB, no secrets inside)")
        elif args.cmd == "restore":
            m = restore(args.archive, args.into)
            print(f"restored into {args.into}: {len(m['apps'])} app(s), admin.db: "
                  f"{'yes' if m.get('admin_db') else 'no'}. Nothing live was touched.")
            print(f"next: check it, then `backup.py apply {args.into}`, then {args.into}/RESTORE.txt")
        else:
            placed, kept = apply(args.into)
            print("placed: " + (", ".join(placed) or "nothing"))
            if kept:
                print("kept (already there, not replaced): " + ", ".join(kept))
            print(f"next: the steps in {Path(args.into) / 'RESTORE.txt'}")
    except (BackupError, deploy_mod.DeployError, OSError, sqlite3.Error, tarfile.TarError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
