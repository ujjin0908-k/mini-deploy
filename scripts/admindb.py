#!/usr/bin/env python3
"""The admin database: /var/lib/mini-deploy/admin.db (SQLite, owner-only).

Used by the admin page (scripts/admin.py) and by the webhook (scripts/webhook.py), which reads
the repos connected from the admin page. Standard library only. Tests point it elsewhere with
MINI_DEPLOY_ADMIN_DB together with MINI_DEPLOY_TESTING=1 (the variable alone is ignored).
"""

import contextlib
import os
import sqlite3
import stat
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deploy as deploy_mod  # noqa: E402  (APP_RE for the audit log)

DB_PATH = Path("/var/lib/mini-deploy/admin.db")
if os.environ.get("MINI_DEPLOY_ADMIN_DB") and os.environ.get("MINI_DEPLOY_TESTING") == "1":
    DB_PATH = Path(os.environ["MINI_DEPLOY_ADMIN_DB"])

SCHEMA = """
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sessions (token_hash TEXT PRIMARY KEY, csrf TEXT NOT NULL,
                                     created REAL NOT NULL, last_seen REAL NOT NULL);
CREATE TABLE IF NOT EXISTS failures (ts REAL NOT NULL);
CREATE TABLE IF NOT EXISTS audit (id INTEGER PRIMARY KEY, ts TEXT NOT NULL, action TEXT NOT NULL,
                                  app TEXT NOT NULL, result TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS logins (id INTEGER PRIMARY KEY, ts TEXT NOT NULL, result TEXT NOT NULL);
-- Repos connected from the admin page (P3b). The secret is the webhook's HMAC key for this
-- repo only; it is shown once, when made, and never returned by any page afterwards.
-- full_name is unique ignoring case, like GitHub ("Foo/bar" and "foo/bar" are one repo).
CREATE TABLE IF NOT EXISTS repos (full_name TEXT PRIMARY KEY COLLATE NOCASE,
                                  hook_id TEXT NOT NULL UNIQUE,
                                  secret TEXT NOT NULL,
                                  app TEXT NOT NULL UNIQUE,
                                  branch TEXT NOT NULL,
                                  subdir TEXT NOT NULL,
                                  previews INTEGER NOT NULL,
                                  kind TEXT NOT NULL,
                                  created TEXT NOT NULL);
"""


def _private(st, what, folder=False):
    kind = stat.S_ISDIR if folder else stat.S_ISREG
    if not kind(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise RuntimeError(f"{what} is not a private {'folder' if folder else 'file'} of this user; not used")


@contextlib.contextmanager
def db():
    """A connection to the admin database, created owner-only on first use. The folder and
    the file are checked on every use (one someone else owns or can read is never trusted)."""
    DB_PATH.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    _private(os.lstat(DB_PATH.parent), DB_PATH.parent, folder=True)
    with contextlib.suppress(FileExistsError):
        os.close(os.open(DB_PATH, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600))
    _private(os.lstat(DB_PATH), DB_PATH)
    conn = sqlite3.connect(DB_PATH, timeout=10, isolation_level=None)
    try:
        conn.executescript(SCHEMA)
        yield conn
    finally:
        conn.close()


def _now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def audit(conn, action, app, result):
    """One line per change. Never a value: only fixed words and a checked app name.
    Sign-ins go to their own table, so a flood of guesses can never push changes out."""
    conn.execute("INSERT INTO audit (ts, action, app, result) VALUES (?, ?, ?, ?)",
                 (_now_iso(), action, app if deploy_mod.APP_RE.fullmatch(app) else "-", result))
    conn.execute("DELETE FROM audit WHERE id <= (SELECT MAX(id) FROM audit) - 1000")
