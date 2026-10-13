#!/usr/bin/env python3
"""GitHub repos connected from the admin page (P3b), and the GitHub token they may need.

    connect    an app name, a repo, a branch, a sub-folder, previews on/off, kind build or static.
               Makes this repo's webhook secret and address: /webhook/<hook_id>. The secret is
               returned ONCE, to the page that made it.
    rotate     new secret for a repo (the old one stops working at once). Shown once, as above.
    disconnect forget a repo. Its app stays on the server until removed with deploy.py.

Repo list and secrets live in the admin database (scripts/admindb.py): private repo names
never reach git. The GitHub token (read-only, for private repos) is one root-only file,
/etc/mini-deploy/github-token. It is never stored in the database, never shown, and never
put in a command line or a URL: git gets it through its environment (git_auth).
Standard library only.
"""

import base64
import json
import os
import re
import secrets
import sqlite3
import stat
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
import admindb  # noqa: E402
import deploy as deploy_mod  # noqa: E402

# GitHub's rules: an owner is letters, digits and single hyphens; a repo name cannot be "." or
# "..", so it must start with a letter, digit, '_' or '-' ("../etc" is not a repo).
REPO_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_-][A-Za-z0-9_.-]{0,99}$")
BRANCH_RE = re.compile(r"^[A-Za-z0-9._/-]{1,100}$")
SUBDIR_RE = re.compile(r"^[A-Za-z0-9._/-]{0,200}$")
HOOK_RE = re.compile(r"^[0-9a-f]{32}$")
KINDS = ("build", "static")
# Fine-grained (github_pat_...) or classic (ghp_...) token shapes. Checked, never echoed.
TOKEN_RE = re.compile(r"^(github_pat_[A-Za-z0-9_]{20,255}|gh[pousr]_[A-Za-z0-9]{20,255})$")
TOKEN_FILE = Path("/etc/mini-deploy/github-token")
if os.environ.get("MINI_DEPLOY_TOKEN_FILE") and os.environ.get("MINI_DEPLOY_TESTING") == "1":
    TOKEN_FILE = Path(os.environ["MINI_DEPLOY_TOKEN_FILE"])


def safe_branch(branch):
    """A branch name we are willing to hand to git: a strict subset of what git allows.
    No '..', no leading '-' (could read as an option), no '//', no '.lock' ending."""
    return (isinstance(branch, str) and BRANCH_RE.fullmatch(branch) is not None
            and ".." not in branch and "//" not in branch
            and not branch.startswith(("-", "/", ".")) and not branch.endswith(("/", ".", ".lock"))
            and "/." not in branch)


def _config():
    try:
        raw = json.loads((REPO_ROOT / "config" / "webhook.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return raw if isinstance(raw, dict) else {}


def hook_base():
    """The public address of the webhook (its Funnel name), from config/webhook.json. None if unset."""
    base = _config().get("public_base")
    return base if isinstance(base, str) and base.startswith("https://") else None


def _taken_by_config(full_name, app):
    """A repo or app the config file already deploys: two sources must never fight over one app."""
    cfg = _config().get("repos")
    if not isinstance(cfg, dict):
        return False
    return any(isinstance(k, str) and k.lower() == full_name.lower() for k in cfg) or \
        any(isinstance(v, dict) and v.get("app") == app for v in cfg.values())


def _check(full_name, app, branch, subdir, previews, kind):
    """Returns the cleaned fields or raises ValueError with a plain reason."""
    if not isinstance(full_name, str) or not REPO_RE.fullmatch(full_name):
        raise ValueError("the repo must look like owner/name")
    if not isinstance(app, str) or not deploy_mod.APP_RE.fullmatch(app):
        raise ValueError("the app name may use only a-z, 0-9 and '-' (1 to 40 characters)")
    if app in deploy_mod.RESERVED_APPS:
        raise ValueError(f"the app name {app!r} is reserved ({deploy_mod.RESERVED_APPS[app]})")
    if deploy_mod.PREVIEW_SEP in app:
        raise ValueError(f"app names may not contain '{deploy_mod.PREVIEW_SEP}'")
    if not isinstance(branch, str) or not safe_branch(branch):
        raise ValueError("that branch name is not allowed")
    if not isinstance(subdir, str) or not SUBDIR_RE.fullmatch(subdir) or ".." in subdir.split("/") \
            or subdir.startswith("/"):
        raise ValueError("the sub-folder may use only letters, digits, '.', '_', '-' and '/'")
    if not isinstance(previews, bool):
        raise ValueError("previews must be on or off")
    if kind not in KINDS:
        raise ValueError("kind must be build or static")
    if kind == "static" and not subdir:
        # The folder is published as it is: the repo's root would publish its sources too.
        raise ValueError("a static site needs its sub-folder (the one with index.html), "
                         "so the rest of the repo is never published")
    if previews:
        try:
            deploy_mod.preview_name(app, "probe")   # the app name must leave room for a branch
        except deploy_mod.DeployError as e:
            raise ValueError(str(e))
    return full_name, app, branch, subdir, previews, kind


def connect(conn, full_name, app, branch="main", subdir="", previews=False, kind="build"):
    full_name, app, branch, subdir, previews, kind = _check(full_name, app, branch, subdir, previews, kind)
    if _taken_by_config(full_name, app):
        raise ValueError("that repo or app name is already used in config/webhook.json")
    hook_id, secret = secrets.token_hex(16), secrets.token_hex(32)
    # Check and insert as one step: two connects at once cannot both pass the check.
    conn.execute("BEGIN IMMEDIATE")
    try:
        taken = conn.execute("SELECT 1 FROM repos WHERE full_name = ? COLLATE NOCASE OR app = ?",
                             (full_name, app)).fetchone()
        if taken:
            raise ValueError("that repo or app name is already connected")
        conn.execute("INSERT INTO repos (full_name, hook_id, secret, app, branch, subdir, previews, kind, created)"
                     " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                     (full_name, hook_id, secret, app, branch, subdir, int(previews), kind, admindb._now_iso()))
        admindb.audit(conn, "connect", app, "ok")
        conn.execute("COMMIT")
    except sqlite3.IntegrityError:
        conn.execute("ROLLBACK")
        raise ValueError("that repo or app name is already connected")
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    # An app that already exists (e.g. one deployed by hand) is taken over by the first push.
    replaces = (deploy_mod.SITES / app / "releases").is_dir()
    return {"hook_id": hook_id, "secret": secret, "app": app, "kind": kind, "replaces_existing": replaces}


def rotate(conn, full_name):
    row = conn.execute("SELECT hook_id, app FROM repos WHERE full_name = ? COLLATE NOCASE", (full_name,)).fetchone()
    if not row:
        raise ValueError("that repo is not connected")
    secret = secrets.token_hex(32)
    conn.execute("UPDATE repos SET secret = ? WHERE full_name = ? COLLATE NOCASE", (secret, full_name))
    admindb.audit(conn, "rotate-secret", row[1], "ok")
    return {"secret": secret, "app": row[1], "hook_id": row[0]}


def disconnect(conn, full_name):
    row = conn.execute("SELECT app FROM repos WHERE full_name = ? COLLATE NOCASE", (full_name,)).fetchone()
    if not row:
        raise ValueError("that repo is not connected")
    conn.execute("DELETE FROM repos WHERE full_name = ? COLLATE NOCASE", (full_name,))
    admindb.audit(conn, "disconnect", row[0], "ok")


def _row_dict(row):
    full_name, hook_id, app, branch, subdir, previews, kind = row[:7]
    return {"repo": full_name, "hook_id": hook_id, "app": app, "branch": branch, "subdir": subdir,
            "previews": bool(previews), "kind": kind}


def list_repos(conn):
    """Everything the page may show: never a secret."""
    rows = conn.execute("SELECT full_name, hook_id, app, branch, subdir, previews, kind FROM repos "
                        "ORDER BY full_name").fetchall()
    return [_row_dict(r) for r in rows]


TEST_REPO_URL = os.environ.get("MINI_DEPLOY_TEST_REPO_URL") if os.environ.get("MINI_DEPLOY_TESTING") == "1" else None


def _full_row(row):
    """For the webhook: what a push needs, secret included (never sent to a page).
    MINI_DEPLOY_TEST_REPO_URL (tests only, with MINI_DEPLOY_TESTING=1) stands in for GitHub."""
    d = _row_dict(row[:7])
    d.update({"full": d.pop("repo"), "secret": row[7],
              "url": TEST_REPO_URL or f"https://github.com/{row[0]}.git", "private": True})
    d["previews"] = bool(d["previews"])
    return d


def repo_by_hook(hook_id):
    if not isinstance(hook_id, str) or not HOOK_RE.fullmatch(hook_id):
        return None
    with admindb.db() as conn:
        row = conn.execute("SELECT full_name, hook_id, app, branch, subdir, previews, kind, secret FROM repos "
                           "WHERE hook_id = ?", (hook_id,)).fetchone()
    return _full_row(row) if row else None


def repo_by_name(full_name):
    with admindb.db() as conn:
        row = conn.execute("SELECT full_name, hook_id, app, branch, subdir, previews, kind, secret FROM repos "
                           "WHERE full_name = ? COLLATE NOCASE", (full_name,)).fetchone()
    return _full_row(row) if row else None


# ---------------------------------------------------------------- the GitHub token

def _private_file(fd):
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise RuntimeError(f"{TOKEN_FILE} is not a private file of this user; not used")


def read_token():
    """The token, or "" if the file is empty or missing. RuntimeError if the file is unsafe."""
    try:   # O_NONBLOCK: a FIFO put at this path cannot hang us (it then fails the file check)
        fd = os.open(TOKEN_FILE, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return ""
    try:
        _private_file(fd)
        value = os.read(fd, 1024).decode("ascii", "replace").strip()
    finally:
        os.close(fd)
    return value if TOKEN_RE.fullmatch(value) else ""


def token_status():
    """For the page: 'set', 'not set' or 'check the file'. Never the value."""
    try:
        return "set" if read_token() else "not set"
    except (RuntimeError, OSError):
        return "check the file"


def set_token(value):
    """Write the token into the existing root-only file. The file must already exist (made
    once, at install), so this never creates a file in /etc."""
    if not isinstance(value, str) or not TOKEN_RE.fullmatch(value.strip()):
        raise ValueError("that does not look like a GitHub token")
    data = (value.strip() + "\n").encode("ascii")
    # No O_TRUNC here: the old token is only emptied after the file passed its checks.
    # O_NONBLOCK: a FIFO at this path fails at once instead of hanging the request.
    try:
        fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        raise RuntimeError(f"{TOKEN_FILE} does not exist yet: create it once as root (see the admin notes)")
    except OSError as e:
        raise RuntimeError(f"{TOKEN_FILE} cannot be written ({e.strerror}); "
                           "if you just created it, restart mini-deploy-admin")
    try:
        _private_file(fd)
        os.ftruncate(fd, 0)   # a reader in the next instant sees "no token", git fails and retries
        if os.write(fd, data) != len(data):
            raise RuntimeError("the token file could not be written in full")
    finally:
        os.close(fd)


def git_auth(token):
    """Environment that makes git send the token as a header to github.com only. Never a URL,
    never argv. Returns (env, strings to hide if they ever show up in output)."""
    basic = base64.b64encode(f"x-access-token:{token}".encode("ascii")).decode("ascii")
    env = {"GIT_CONFIG_COUNT": "1",
           "GIT_CONFIG_KEY_0": "http.https://github.com/.extraHeader",
           "GIT_CONFIG_VALUE_0": f"Authorization: basic {basic}"}
    return env, [token, basic]
