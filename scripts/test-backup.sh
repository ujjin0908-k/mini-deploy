#!/usr/bin/env bash
# Backup test (scripts/backup.py): a backup holds what cannot be rebuilt and NO secret; a
# restore gives back the same releases; a hostile archive is refused; apply never replaces.
# Everything happens in a temp folder (/tmp/mini-deploy-bktest-*): fake /sites, fake admin.db,
# fake env store, fake backup folder. Nothing live is read or written, except part 2, which
# only checks the installed timer. It never deletes anything itself. Pass = ALL PASSED.
set -uo pipefail
REPO=/mnt/c/Users/indra/Code/mini-deploy
fail=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }

echo "== 1. make, check, restore, apply (all in a temp folder) =="
python3 - <<PY || fail=1
import hashlib, io, json, os, sqlite3, sys, tarfile, tempfile, time
from pathlib import Path
tmp = Path(tempfile.mkdtemp(prefix="mini-deploy-bktest-"))
os.environ["MINI_DEPLOY_TESTING"] = "1"
os.environ["MINI_DEPLOY_ADMIN_DB"] = str(tmp / "state" / "admin.db")
os.environ["MINI_DEPLOY_APP_ENV"] = str(tmp / "apps")
os.environ["MINI_DEPLOY_CI_LIMITS"] = str(tmp / "ci-limits.json")
sys.path.insert(0, "$REPO/scripts")
import deploy, admindb, appenv, backup, ci_forwarder
TEST_LIMITS = {"bk-app": {"models": None, "max_tokens": 1000, "at_once": 2, "per_minute": 10, "per_day": 100}}
ci_forwarder._write_private_json(ci_forwarder.LIMITS, TEST_LIMITS)
deploy.SITES = tmp / "sites"; deploy.SITES.mkdir()
deploy.LOG_FILE = tmp / "deploy.log"           # never the real deploy log
dest = tmp / "backups"

bad_count = 0
def check(cond, msg):
    global bad_count
    print(("ok    " if cond else "FAIL  ") + msg); bad_count += not cond

def tree_hashes(root):
    out = {}
    for dp, _, files in os.walk(root):
        for f in files:
            p = Path(dp, f)
            out[str(p.relative_to(root))] = hashlib.sha256(p.read_bytes()).hexdigest()
    return out

def archive_bytes(path):
    data = path.read_bytes()
    with tarfile.open(path, "r:gz") as tar:
        for m in tar.getmembers():
            if m.isfile():
                data += tar.extractfile(m).read()
    return data

# --- a small world: one app with two releases, a hold, a lock and a half-made release
app = "bk-$$"
for v in ("one", "two"):
    src = tmp / f"src-{v}"; (src / "css").mkdir(parents=True)
    (src / "index.html").write_text(f"<h1>{v}</h1>"); (src / "css" / "a.css").write_text("b{}")
    deploy.deploy(app, src)
    time.sleep(1.1)
(deploy.SITES / app / ".hold").write_text("rollback\n")
(deploy.SITES / app / "releases" / ".tmp-20990101-000000").mkdir()

REPO_SECRET = "f" * 24 + "0123456789abcdef"
admindb.DB_PATH.parent.mkdir(mode=0o700)
with admindb.db() as c:
    c.execute("INSERT INTO repos VALUES ('owner/site', ?, ?, ?, 'main', 'app', 0, 'static', 'now')",
              ("a" * 32, REPO_SECRET, app))
    c.execute("INSERT INTO settings VALUES ('password', 'scrypt\$32768\$8\$1\$salt\$HASHVALUE0123456789')")
    c.execute("INSERT INTO sessions VALUES ('sessionhash0123456789', 'csrftoken0123456789', 1, 1)")
    c.execute("INSERT INTO logins (ts, result) VALUES ('t', 'fail')")
    admindb.audit(c, "rollback", app, "ok")
ENV_VALUE = "env-secret-value-0123456789"
(tmp / "apps").mkdir(mode=0o700)
appenv.set_value(app, "API_TOKEN", ENV_VALUE)
appenv.set_value(app, "SITE_NAME", "Public Name", public=True)

# --- make
path = backup.make(dest, keep=2)
check(backup.NAME_RE.fullmatch(path.name) is not None and path.exists(), f"archive written ({path.name})")
check(not list(dest.glob(".*.part")), "no half-written file left")
data = archive_bytes(path)
for label, s in (("repo secret", REPO_SECRET), ("password hash", "HASHVALUE0123456789"),
                 ("session hash", "sessionhash0123456789"), ("CSRF token", "csrftoken0123456789"),
                 ("env value", ENV_VALUE), ("public env value", "Public Name")):
    check(s.encode() not in data, f"the {label} is not in the archive")
with tarfile.open(path, "r:gz") as tar:
    names = tar.getnames()
    manifest = json.load(tar.extractfile("manifest.json"))
check(not any(n.endswith("/.lock") or "/.tmp-" in n for n in names), "no lock files and no half-made releases inside")
check(f"sites/{app}/.hold" in names and "RESTORE.txt" in names and "admin.db" in names, "hold note, RESTORE.txt and admin.db inside")
check(manifest["env_names"].get(app) == [{"name": "API_TOKEN", "public": False}, {"name": "SITE_NAME", "public": True}],
      "the manifest lists env value NAMES only")
check(manifest["admin_db"] == {"repos": 1, "audit": 1}, f"the manifest counts repos and audit rows ({manifest['admin_db']})")
with tarfile.open(path, "r:gz") as tar:
    archived_limits = json.load(tar.extractfile("ci-limits.json")) if "ci-limits.json" in tar.getnames() else None
check(archived_limits == TEST_LIMITS and manifest["ci_limits"] is True,
      "the AI limits are in the backup (not secret; a restore without them would refuse every AI call)")

# --- restore: same releases, same live link, secrets gone, nothing live touched
into = tmp / "restored"
m = backup.restore(path, into)
src_root = deploy.SITES / app
check(tree_hashes(into / "sites" / app / "releases") ==
      {k: v for k, v in tree_hashes(src_root / "releases").items() if ".tmp-" not in k},
      "restored releases are byte-for-byte the same")
check(os.readlink(into / "sites" / app / "current") == os.readlink(src_root / "current"), "the live link points at the same release")
con = sqlite3.connect(into / "admin.db")
row = con.execute("SELECT full_name, secret, app FROM repos").fetchone()
check(row == ("owner/site", "", app), f"the repo is kept with an EMPTY secret ({row[0]}, secret length {len(row[1])})")
check(con.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == 0
      and con.execute("SELECT COUNT(*) FROM logins").fetchone()[0] == 0
      and con.execute("SELECT COUNT(*) FROM settings WHERE key='password'").fetchone()[0] == 0,
      "no sessions, sign-ins or password hash")
check(con.execute("SELECT action FROM audit").fetchone() == ("rollback",), "the audit log is kept")
con.close()
try:
    backup.restore(path, into); check(False, "restore into a folder that is not empty is refused")
except backup.BackupError:
    check(True, "restore into a folder that is not empty is refused")

# --- a secret that slipped into a site is caught: nothing is kept
leak = deploy.SITES / app / "releases" / os.readlink(src_root / "current").split("/")[1] / "leak.txt"
leak.write_text("oops " + REPO_SECRET)
before = sorted(dest.iterdir())
time.sleep(1.1)
try:
    backup.make(dest, keep=2); check(False, "a backup holding a live secret is refused")
except backup.BackupError:
    check(True, "a backup holding a live secret is refused")
check(sorted(dest.iterdir()) == before, "and leaves no file behind")
leak.unlink()

# --- keep the newest N
for _ in range(2):
    time.sleep(1.1); backup.make(dest, keep=2)
kept = sorted(p.name for p in dest.iterdir())
check(len(kept) == 2 and path.name not in kept, f"only the newest 2 are kept ({len(kept)} left)")

# --- hostile archives are refused before anything is written
def hostile(name, members):
    p = tmp / "hostile" / name; p.parent.mkdir(exist_ok=True)
    with tarfile.open(p, "w:gz") as tar:
        for info, payload in members:
            tar.addfile(info, io.BytesIO(payload) if payload is not None else None)
    return p
def file_info(n, payload):
    i = tarfile.TarInfo(n); i.size = len(payload); return i, payload
def link_info(n, target):
    i = tarfile.TarInfo(n); i.type = tarfile.SYMTYPE; i.linkname = target; return i, None
cases = {
    "path outside (..)":       hostile("mini-deploy-20990101-000001.tar.gz", [file_info("../escaped.txt", b"x")]),
    "absolute path":           hostile("mini-deploy-20990101-000002.tar.gz", [file_info("/tmp/abs.txt", b"x")]),
    "unexpected top entry":    hostile("mini-deploy-20990101-000003.tar.gz", [file_info("etc/passwd", b"x")]),
    "bad app name":            hostile("mini-deploy-20990101-000004.tar.gz", [file_info("sites/Bad_Name/releases/x", b"x")]),
    "link to /etc":            hostile("mini-deploy-20990101-000005.tar.gz", [link_info(f"sites/{app}/current", "/etc")]),
    "link inside a release":   hostile("mini-deploy-20990101-000006.tar.gz", [
        file_info("manifest.json", json.dumps({"format": 1, "apps": {app: {"current": None}}}).encode()),
        link_info(f"sites/{app}/releases/20990101-000000/x", "../../../../etc/passwd")]),
}
for label, p in cases.items():
    target = tmp / ("into-" + p.name)
    try:
        backup.restore(p, target); check(False, f"hostile archive ({label}) is refused")
    except (backup.BackupError, tarfile.TarError, deploy.DeployError):
        check(True, f"hostile archive ({label}) is refused")
check(not (tmp / "escaped.txt").exists() and not Path("/tmp/abs.txt").exists(), "nothing was written outside the restore folder")
try:
    backup.restore(tmp / "hostile" / "site-copy.tar.gz", tmp / "x")
    check(False, "a file without a backup name is refused")
except backup.BackupError:
    check(True, "a file without a backup name is refused")

# --- the review's case: what the archive REALLY holds is checked, not what its manifest claims.
# A link 4 levels up stays inside the restore folder (so tar's "data" filter allows it), but once
# copied into /sites it would point at /etc/shadow.
rel_id = "20990101-000000"
def fake_archive(name, manifest_apps, extra):
    members = [file_info("manifest.json", json.dumps({"format": 1, "apps": manifest_apps}).encode())]
    return hostile(name, members + extra)
# Python 3.10.12's "data" filter refuses every link with ".." (it judges them from the restore
# folder), but newer Pythons judge from the link's own folder and allow it. So these cases use
# entries the filter lets through, and it must be OUR checks that refuse them (the error type says).
plain = [file_info(f"sites/sneak/releases/{rel_id}/index.html", b"<h1>x</h1>")]
inner_link = plain + [link_info(f"sites/sneak/releases/{rel_id}/again.html", "index.html")]
for label, p, want in [
    ("an app the manifest does not list", fake_archive("mini-deploy-20990101-000011.tar.gz", {}, plain),
     backup.BackupError),
    ("a listed app with a link in a release", fake_archive("mini-deploy-20990101-000012.tar.gz",
                                                           {"sneak": {"current": None}}, inner_link), deploy.DeployError),
    ("a listed app with an unexpected file", fake_archive("mini-deploy-20990101-000013.tar.gz",
        {"odd": {"current": None}}, [file_info("sites/odd/releases/" + rel_id + "/index.html", b"x"),
                                     file_info("sites/odd/run.sh", b"x")]), backup.BackupError),
    ("a manifest that names a current release not in the archive", fake_archive(
        "mini-deploy-20990101-000014.tar.gz", {"sneak": {"current": "releases/20990101-999999"}}, plain),
     backup.BackupError),
]:
    target = tmp / ("into-" + p.name)
    try:
        backup.restore(p, target); check(False, f"refused by our own check: {label}")
    except (backup.BackupError, deploy.DeployError, tarfile.TarError) as e:
        check(isinstance(e, want), f"refused by our own check: {label} ({type(e).__name__})")

# --- a restored folder edited before apply: apply checks it again and places nothing
edited = tmp / "edited"
backup.restore(sorted(dest.glob("mini-deploy-*.tar.gz"))[-1], edited)
rel = next((edited / "sites" / app / "releases").iterdir())
os.symlink("../../../../etc/shadow", rel / "planted")   # copied into /sites, this IS /etc/shadow
sites_e = tmp / "sites-edited"; sites_e.mkdir()
try:
    backup.apply(edited, sites=sites_e, db_path=tmp / "state-e" / "admin.db"); check(False, "apply re-checks an edited folder")
except deploy.DeployError:
    check(True, "apply re-checks an edited folder and refuses it")
check(not any(sites_e.iterdir()) and not (tmp / "state-e" / "admin.db").exists(), "and places nothing")
(rel / "planted").unlink()

# --- a deploy holding the app's lock: the backup waits for it (or gives up), never reads mid-flip
import fcntl, threading
lock_fd = os.open(deploy.SITES / app / ".lock", os.O_RDONLY)
fcntl.flock(lock_fd, fcntl.LOCK_EX)
backup.LOCK_WAIT = 1
try:
    time.sleep(1.1); backup.make(dest, keep=2); check(False, "a backup gives up on a lock held too long")
except backup.BackupError as e:
    check("still running" in str(e), "a backup gives up on a lock held too long, with a reason")
check(not list(dest.glob(".*.part")), "and leaves no half-written file")
backup.LOCK_WAIT = 10
time.sleep(1.1)   # a new second: a new archive name
threading.Timer(0.8, lambda: fcntl.flock(lock_fd, fcntl.LOCK_UN)).start()
started = time.monotonic(); made = backup.make(dest, keep=2); waited = time.monotonic() - started
check(waited >= 0.5 and made.exists(), f"a backup waits for a short deploy, then runs ({waited:.1f}s)")
os.close(lock_fd)

# --- a secret in a file NAME is caught too
name_leak = deploy.SITES / app / "releases" / os.readlink(src_root / "current").split("/")[1] / REPO_SECRET
name_leak.write_text("x")
time.sleep(1.1)
try:
    backup.make(dest, keep=2); check(False, "a secret in a file name is refused")
except backup.BackupError:
    check(True, "a secret in a file name is refused")
name_leak.unlink()

# --- a link planted under the next .part name is never followed
victim = tmp / "victim.txt"; victim.write_text("keep me")
real_now = backup._now_id
backup._now_id = lambda: "20990101-235959"
os.symlink(victim, dest / ".mini-deploy-20990101-235959.tar.gz.part")
try:
    backup.make(dest, keep=2); check(False, "a planted .part link is refused")
except OSError:
    check(True, "a planted .part link is refused")
check(victim.read_text() == "keep me", "and its target is untouched")
(dest / ".mini-deploy-20990101-235959.tar.gz.part").unlink()
backup._now_id = real_now

# --- every setting is dropped, not only the password
with admindb.db() as c:
    c.execute("INSERT INTO settings VALUES ('future-setting', 'future-value-0123456789')")
time.sleep(1.1)
newest = backup.make(dest, keep=2)
check(b"future-value-0123456789" not in archive_bytes(newest), "a setting added later never reaches a backup")

# --- restore refuses an archive bigger than any this PC makes
backup.MAX_MEMBERS, real_max = 3, backup.MAX_MEMBERS
try:
    backup.restore(newest, tmp / "too-many"); check(False, "an archive with too many entries is refused")
except backup.BackupError:
    check(True, "an archive with too many entries is refused")
backup.MAX_MEMBERS = real_max

# --- the status file the admin page reads
st = backup.read_status()
check(st["stale"] is True and st["last_ok"] is None, f"no status file yet = stale (got {st['stale']})")
backup.write_status(True, newest.name)
st = backup.read_status()
check(st["stale"] is False and st["last_result"] == "ok" and st["age_days"] == 0.0, f"after a good run: not stale ({st})")
check(oct(os.stat(backup.status_path()).st_mode & 0o777) == "0o600", "the status file is 600")
backup.write_status(False, "OSError: [Errno 2] No such file or directory: '/mnt/c/x'")
st = backup.read_status()
check(st["stale"] is True and st["last_result"] == "fail" and st["last_ok"] is not None,
      "after a failed run: stale, and the last good one is kept")
backup.write_status(True, newest.name)
check(backup.read_status(now=time.time() + 9 * 86400)["stale"] is True, "nine days without a good run: stale")

# --- apply: places what is missing, never replaces
sites2 = tmp / "sites2"; sites2.mkdir()
db2 = tmp / "state2" / "admin.db"
lim2 = tmp / "etc2" / "ci-limits.json"
placed, kept = backup.apply(into, sites=sites2, db_path=db2, limits_path=lim2)
check(app in placed and str(db2) in placed and str(lim2) in placed and not kept,
      f"apply places the app, admin.db and the AI limits ({len(placed)} placed)")
check(json.loads(lim2.read_text()) == TEST_LIMITS and oct(os.stat(lim2).st_mode & 0o777) == "0o600",
      "the placed AI limits are the backed-up ones, 600")
check(oct(os.stat(db2).st_mode & 0o777) == "0o600" and oct(os.stat(db2.parent).st_mode & 0o777) == "0o700",
      "the placed admin.db is 600 in a 700 folder")
check(tree_hashes(sites2 / app / "releases") == tree_hashes(into / "sites" / app / "releases")
      and os.readlink(sites2 / app / "current") == os.readlink(src_root / "current"), "the placed app is the restored one")
(sites2 / app / "marker").write_text("mine")
placed, kept = backup.apply(into, sites=sites2, db_path=db2, limits_path=lim2)
check(not placed and app in kept and str(db2) in kept and str(lim2) in kept and (sites2 / app / "marker").exists(),
      "a second apply replaces nothing (app, admin.db and AI limits kept)")
# limits in an archive that would not work are refused before anything is copied
bad_lim = hostile("mini-deploy-20990101-000021.tar.gz", [
    file_info("manifest.json", json.dumps({"format": 1, "apps": {}}).encode()),
    file_info("ci-limits.json", json.dumps({"x": {"models": None}}).encode())])
try:
    backup.restore(bad_lim, tmp / "into-badlim"); check(False, "unusable AI limits in an archive are refused")
except backup.BackupError:
    check(True, "unusable AI limits in an archive are refused")
print("leftovers for the owner:", tmp)
sys.exit(1 if bad_count else 0)
PY

echo
echo "== 2. the installed timer =="
systemctl is-enabled --quiet mini-deploy-backup.timer && ok "mini-deploy-backup.timer is enabled" || bad "mini-deploy-backup.timer is not enabled"
systemctl is-active --quiet mini-deploy-backup.timer && ok "mini-deploy-backup.timer is active" || bad "mini-deploy-backup.timer is not active"

echo
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOMETHING FAILED"; fi
exit $fail
