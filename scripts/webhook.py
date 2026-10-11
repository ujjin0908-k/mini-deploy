#!/usr/bin/env python3
"""mini-deploy stage 5: GitHub webhook receiver that builds and deploys a push.

    webhook.py [--config config/webhook.json]     run the server
    webhook.py --init-env                         create the secret in /etc/mini-deploy/env (not shown)

    POST /webhook --> signature ok? --> push to the allowed branch? --> 202 queued
                                                                         |
       worker: held? same sha? still the branch tip? -> git fetch <sha> -> build.py -> deploy.py

Everything in a request is outside input. What decides the app, branch, clone URL and
sub-folder is config/webhook.json, never the payload. A valid signature proves WHO sent
a request, not that it is still current, so the worker also checks that the pushed commit
is still the tip of the branch before building it. The server only listens on loopback;
putting it on the internet (a tunnel) is a separate decision for the owner.
Standard library only.
"""

import argparse
import collections
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
import build as build_mod    # noqa: E402  (Docker build, then deploy)
import deploy as deploy_mod  # noqa: E402  (log_event, APP_RE, hold)

ENV_FILE = Path("/etc/mini-deploy/env")        # secret lives in the WSL filesystem, mode 0600
STATE_DIR = Path("/var/lib/mini-deploy")       # delivery ids and queued jobs survive a restart
LEGACY_ENV = REPO_ROOT / ".env"                # where --init-env first put the secret (on /mnt/c)

MAX_BODY = 1024 * 1024          # a push event is a few KB; refuse anything bigger
TOTAL_DEADLINE = 20             # seconds for a whole request, headers and body (slowloris)
MAX_HANDLERS = 16               # concurrent requests; more get a 503 instead of a thread
MIN_SECRET = 32                 # characters
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$")
BRANCH_RE = re.compile(r"^[A-Za-z0-9._/-]{1,100}$")
SUBDIR_RE = re.compile(r"^[A-Za-z0-9._/-]{0,200}$")
DELIVERY_RE = re.compile(r"^[0-9A-Fa-f-]{36}$")  # GitHub's X-GitHub-Delivery GUID
NO_DELIVERY = "00000000-0000-0000-0000-000000000000"
GIT_TIMEOUT = 180               # seconds per git step
RETRY_DELAYS = (5, 20)          # git is retried after these pauses (network blips)
WORK_ROOT = "/var/tmp"          # WSL filesystem, same as build.py
HOOK_PREFIX = "mini-deploy-hook-"
STALE_AGE = 3600                # a leftover work folder older than this is swept
MIN_FREE_BYTES = 2 * 1024**3    # refuse to start a build with less free disk
MAX_CHECKOUT_BYTES = 200 * 1024**2
SHUTDOWN_WAIT = 700             # seconds a graceful stop waits for the running build
LOOPBACK = ("127.0.0.1",)


class ConfigError(Exception):
    pass


class GitError(Exception):
    pass


# ---------------------------------------------------------------- config and secret

def load_config(path, allow_file_urls=False):
    """Allowlist of repos. Validated once at start, so request handling can trust it."""
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise ConfigError(f"cannot read {path}: {e}")
    if not isinstance(raw, dict):
        raise ConfigError("config must be a JSON object")

    listen = raw.get("listen", "127.0.0.1")
    if listen not in LOOPBACK:
        raise ConfigError(f"listen must be one of {LOOPBACK}: exposing the webhook is the owner's decision")
    port = raw.get("port", 9000)
    if not isinstance(port, int) or isinstance(port, bool) or not 1024 <= port <= 65535:
        raise ConfigError("port must be an integer from 1024 to 65535")

    repos_raw = raw.get("repos", {})
    if not isinstance(repos_raw, dict):
        raise ConfigError("repos must be an object")
    repos, apps = {}, {}
    for full_name, entry in repos_raw.items():
        if not isinstance(full_name, str) or not REPO_RE.fullmatch(full_name):
            raise ConfigError(f"bad repo name {full_name!r}")
        if not isinstance(entry, dict):
            raise ConfigError(f"{full_name}: entry must be an object")
        app = entry.get("app", "")
        branch = entry.get("branch", "main")
        subdir = entry.get("subdir", "")
        url = entry.get("url", f"https://github.com/{full_name}.git")
        for label, value in (("app", app), ("branch", branch), ("subdir", subdir), ("url", url)):
            if not isinstance(value, str):
                raise ConfigError(f"{full_name}: {label} must be a string")
        if not deploy_mod.APP_RE.fullmatch(app):
            raise ConfigError(f"{full_name}: bad app name")
        if app in apps:
            raise ConfigError(f"{full_name}: app {app!r} is already used by {apps[app]}")
        if not BRANCH_RE.fullmatch(branch) or ".." in branch or branch.startswith("-"):
            raise ConfigError(f"{full_name}: bad branch")
        if not SUBDIR_RE.fullmatch(subdir) or ".." in subdir.split("/") or subdir.startswith("/"):
            raise ConfigError(f"{full_name}: bad subdir")
        if url.startswith("https://github.com/"):
            pass
        elif url.startswith("file:///") and allow_file_urls:
            pass  # only for the test script
        else:
            raise ConfigError(f"{full_name}: url must be https://github.com/...")
        repos[full_name] = {"app": app, "branch": branch, "subdir": subdir, "url": url}
        apps[app] = full_name
    return {"listen": listen, "port": port, "repos": repos}


def read_secret(env_file):
    """WEBHOOK_SECRET from the environment (tests) or from a root-only env file.

    The file is parsed, never sourced as shell, so a `$` or `;` in it is just a
    character. It must not be readable by group or others.
    """
    value = os.environ.pop("WEBHOOK_SECRET", "")  # pop: child processes never inherit it
    if value:
        return value
    try:
        st = os.stat(env_file)
    except OSError:
        return ""
    if st.st_mode & 0o077:
        raise ConfigError(f"{env_file} must not be readable by group or others (chmod 600)")
    for line in Path(env_file).read_text(encoding="utf-8").splitlines():
        m = re.match(r"^\s*WEBHOOK_SECRET\s*=\s*(.*?)\s*$", line.rstrip("\r"))
        if m:
            v = m.group(1)
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            return v
    return ""


# ---------------------------------------------------------------- the signature

def verify_signature(secret, body, header):
    """True only if header is sha256=<hmac of the exact raw body>. Constant time."""
    if not header or not header.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(secret, body, hashlib.sha256).hexdigest()
    # encode with 'replace' so a non-ASCII header is a mismatch, not an exception
    return hmac.compare_digest(expected.encode(), header.encode("utf-8", "replace"))


# ---------------------------------------------------------------- state shared by threads

class Seen:
    """Delivery ids already accepted. A valid signature does not stop an attacker
    replaying a captured request, so a delivery is acted on only once. Persisted as
    +id / -id lines so a restart does not forget them."""

    def __init__(self, path=None, limit=2000):
        self.path, self.limit, self.lock = path, limit, threading.Lock()
        self.ids = collections.OrderedDict()
        if path and Path(path).exists():
            try:
                for line in Path(path).read_text(encoding="ascii", errors="replace").splitlines():
                    sign, _, d = line.partition(" ")
                    if sign == "+" and DELIVERY_RE.fullmatch(d):
                        self.ids[d] = True
                    elif sign == "-":
                        self.ids.pop(d, None)
                while len(self.ids) > limit:
                    self.ids.popitem(last=False)
                Path(path).write_text("".join(f"+ {d}\n" for d in self.ids), encoding="ascii")
            except OSError:
                pass

    def _append(self, line):
        if not self.path:
            return
        try:
            with open(self.path, "a", encoding="ascii") as fh:
                fh.write(line + "\n")
        except OSError:
            pass  # in-memory protection still works

    def has(self, delivery):
        with self.lock:
            return delivery in self.ids

    def add(self, delivery):
        with self.lock:
            if delivery in self.ids:
                return False
            self.ids[delivery] = True
            while len(self.ids) > self.limit:
                self.ids.popitem(last=False)
            self._append(f"+ {delivery}")
            return True

    def remove(self, delivery):
        """A job that failed may be redelivered from GitHub's page; allow it again."""
        with self.lock:
            if self.ids.pop(delivery, None):
                self._append(f"- {delivery}")


class Jobs:
    """At most one waiting build per app. A newer push replaces an older waiting one,
    and keeps it as a fallback in case the newer build fails."""

    def __init__(self):
        self.cond = threading.Condition()
        self.pending = collections.OrderedDict()

    def submit(self, job):
        with self.cond:
            replaced = self.pending.get(job["app"])
            if replaced is not None:
                job["fallback"] = replaced
                depth, node = 0, job
                while node.get("fallback") is not None:  # keep the chain short
                    depth += 1
                    if depth >= 3:
                        node["fallback"] = None
                        break
                    node = node["fallback"]
            self.pending[job["app"]] = job
            self.cond.notify()
            return replaced

    def take(self, stop):
        """Next job, or None once `stop` is set and nothing is waiting."""
        with self.cond:
            while not self.pending:
                if stop.is_set():
                    return None
                self.cond.wait(timeout=1.0)
            return self.pending.popitem(last=False)[1]

    def drain(self):
        with self.cond:
            jobs = list(self.pending.values())
            self.pending.clear()
            return jobs


class State:
    def __init__(self, secret, config, state_dir=None):
        self.secret, self.config = secret, config
        self.state_dir = Path(state_dir) if state_dir else None
        self.seen = Seen(self.state_dir / "deliveries" if self.state_dir else None)
        self.jobs = Jobs()
        self.stop = threading.Event()
        self.worker = None
        self._last_reject, self._suppressed = 0.0, 0
        self._lock = threading.Lock()

    def worker_ok(self):
        return self.worker is not None and self.worker.is_alive()

    def log(self, result, detail, app="webhook", release=None):
        deploy_mod.log_event(app, "webhook", release, result, time.monotonic(), detail)

    def log_reject(self, detail):
        """Rejections can be spammed, so write at most one line a second."""
        with self._lock:
            now = time.monotonic()
            if now - self._last_reject < 1.0:
                self._suppressed += 1
                return
            extra = f" (+{self._suppressed} suppressed)" if self._suppressed else ""
            self._last_reject, self._suppressed = now, 0
        self.log("rejected", detail + extra)


def make_job(cfg, repo, sha, delivery):
    return {"app": cfg["app"], "repo": repo, "sha": sha, "url": cfg["url"], "branch": cfg["branch"],
            "subdir": cfg["subdir"], "delivery": delivery, "fallback": None, "retried": False}


def save_pending(state):
    """On shutdown, keep the queued jobs: GitHub would not resend them."""
    if not state.state_dir:
        return
    jobs = state.jobs.drain()
    path = state.state_dir / "pending.json"
    try:
        if jobs:
            path.write_text(json.dumps(jobs), encoding="utf-8")
        elif path.exists():
            path.unlink()
    except OSError as e:
        print(f"warning: could not save pending jobs: {e}", file=sys.stderr)


def load_pending(state):
    """Re-create queued jobs from our own file, re-validated against the allowlist."""
    if not state.state_dir:
        return 0
    path = state.state_dir / "pending.json"
    if not path.exists():
        return 0

    def revive(raw):
        if not isinstance(raw, dict):
            return None
        repo, sha = raw.get("repo"), raw.get("sha")
        cfg = state.config["repos"].get(repo) if isinstance(repo, str) else None
        if cfg is None or not isinstance(sha, str) or not SHA_RE.fullmatch(sha):
            return None
        delivery = raw.get("delivery") if isinstance(raw.get("delivery"), str) else NO_DELIVERY
        job = make_job(cfg, repo, sha, delivery if DELIVERY_RE.fullmatch(delivery) else NO_DELIVERY)
        job["fallback"] = revive(raw.get("fallback"))
        return job

    count = 0
    try:
        for raw in json.loads(path.read_text(encoding="utf-8")):
            job = revive(raw)
            if job:
                state.jobs.submit(job)
                count += 1
        path.unlink()
    except (OSError, ValueError, TypeError):
        pass
    return count


# ---------------------------------------------------------------- HTTP handler

class Handler(BaseHTTPRequestHandler):
    server_version = "mini-deploy"
    sys_version = ""
    timeout = 5  # per read; the whole request also has an absolute deadline (see Server)

    def log_message(self, *args):  # the default would log paths and addresses; we log our own
        pass

    def _reply(self, code, text):
        data = (text + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._reply(405 if self.path == "/webhook" else 404, "not allowed")

    do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = do_GET

    def do_POST(self):
        state = self.server.state
        if self.path != "/webhook":
            return self._reply(404, "not found")

        # 1. Size, before reading anything. Chunked bodies are not accepted.
        length = self.headers.get("Content-Length")
        if length is None:
            return self._reply(411, "length required")
        if not (length.isascii() and length.isdecimal()) or len(length) > 9:
            return self._reply(400, "bad request")
        if int(length) > MAX_BODY:
            return self._reply(413, "too large")

        # 2. Raw bytes only. Nothing is parsed until the signature has been checked.
        body = self.rfile.read(int(length))
        if len(body) != int(length):
            return self._reply(400, "bad request")

        # 3. The signature. Same bare answer for every failure, so there is nothing to probe.
        if not verify_signature(state.secret, body, self.headers.get("X-Hub-Signature-256")):
            state.log_reject("bad or missing signature")
            return self._reply(401, "unauthorized")

        # 4. From here on the sender holds the secret. Still validate everything.
        event = self.headers.get("X-GitHub-Event", "")
        delivery = self.headers.get("X-GitHub-Delivery", "")
        if not DELIVERY_RE.fullmatch(delivery):
            state.log_reject("signed request with a bad delivery id")
            return self._reply(400, "bad delivery id")
        if state.seen.has(delivery):
            state.log("ignored", f"duplicate delivery {delivery}")
            return self._reply(202, "duplicate")
        if not state.worker_ok():  # do not promise a build nobody will run
            state.log("rejected", "worker is not running")
            return self._reply(503, "unavailable")
        if event == "ping":
            state.seen.add(delivery)
            return self._reply(200, "pong")
        if event != "push":
            state.seen.add(delivery)
            return self._reply(202, "ignored")

        try:
            payload = json.loads(body)
            repo = payload["repository"]["full_name"]
            ref, after = payload["ref"], payload["after"]
            deleted = bool(payload.get("deleted", False))
        except (ValueError, KeyError, TypeError):
            state.log_reject("signed push with a bad payload")
            return self._reply(400, "bad payload")
        if not all(isinstance(x, str) for x in (repo, ref, after)) \
                or not REPO_RE.fullmatch(repo) or not SHA_RE.fullmatch(after):
            state.log_reject("signed push with malformed repo or sha")
            return self._reply(400, "bad payload")

        # 5. Is this push one we act on? The answer comes from our config only.
        cfg = state.config["repos"].get(repo)
        if cfg is None:
            state.seen.add(delivery)
            state.log("ignored", f"{repo} is not in the allowlist {delivery}")
            return self._reply(202, "ignored")
        if deleted or after == "0" * 40 or ref != f"refs/heads/{cfg['branch']}":
            state.seen.add(delivery)
            state.log("ignored", f"{repo} {ref} is not a push to {cfg['branch']}", cfg["app"])
            return self._reply(202, "ignored")

        if not state.seen.add(delivery):  # lost a race with an identical delivery
            return self._reply(202, "duplicate")
        replaced = state.jobs.submit(make_job(cfg, repo, after, delivery))
        if replaced:
            state.log("superseded", f"{replaced['sha'][:7]} replaced by {after[:7]}", cfg["app"])
        state.log("queued", f"{repo} {after[:7]} {delivery}", cfg["app"])
        return self._reply(202, "queued")


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64
    deadline = TOTAL_DEADLINE

    def __init__(self, *args, max_handlers=MAX_HANDLERS, **kwargs):
        self.slots = threading.BoundedSemaphore(max_handlers)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        # Bound concurrent handlers: past the cap, answer 503 and free the socket at once.
        if not self.slots.acquire(blocking=False):
            try:
                request.sendall(b"HTTP/1.0 503 Service Unavailable\r\nContent-Length: 0\r\n"
                                b"Connection: close\r\n\r\n")
                # Close politely: stop sending, and read what the client already sent.
                # Closing with unread data would send a reset that can eat the 503.
                request.shutdown(socket.SHUT_WR)
                request.settimeout(0.5)
                request.recv(4096)
            except OSError:
                pass
            self.shutdown_request(request)
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        # Absolute deadline: the socket timeout is per read, so a client dripping a byte
        # every few seconds could otherwise hold a thread for a long time.
        def cut():
            try:
                request.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        timer = threading.Timer(self.deadline, cut)
        timer.daemon = True
        timer.start()
        try:
            super().process_request_thread(request, client_address)
        finally:
            timer.cancel()
            self.slots.release()

    def handle_error(self, request, client_address):  # one quiet line, not a traceback
        print(f"connection error: {sys.exc_info()[0].__name__}", file=sys.stderr)


# ---------------------------------------------------------------- git, with limits

def git(args, cwd=None, allow_file=False):
    """Run git with no prompts, no hooks, no user/system config, and only https
    (or file:// for tests). Arguments are a list; there is no shell. On a timeout the
    whole process group is killed, so git-remote-https cannot linger. Returns stdout."""
    cmd = ["git", "-c", "core.hooksPath=/dev/null", "-c", "protocol.allow=never",
           "-c", "protocol.https.allow=always"]
    if allow_file:
        cmd += ["-c", "protocol.file.allow=always"]
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": "/nonexistent",
           "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/bin/false",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "LC_ALL": "C"}
    proc = subprocess.Popen(cmd + args, cwd=cwd, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=GIT_TIMEOUT)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.communicate()
        raise GitError(f"git timed out after {GIT_TIMEOUT}s")
    if proc.returncode != 0:
        raise GitError(f"git failed: {err.strip()[:200]}")
    return out


def with_retry(fn):
    """Run fn(); on a GitError wait and try again (a network blip must not drop a push)."""
    delays = list(RETRY_DELAYS)
    while True:
        try:
            return fn()
        except GitError:
            if not delays:
                raise
            time.sleep(delays.pop(0))


def tree_size(path, skip_git=False):
    total = 0
    for dirpath, dirnames, filenames in os.walk(path):
        if skip_git and ".git" in dirnames:
            dirnames.remove(".git")
        for name in filenames:
            try:
                total += os.lstat(os.path.join(dirpath, name)).st_size
            except OSError:
                pass
    return total


def check_disk():
    free = shutil.disk_usage(WORK_ROOT).free
    if free < MIN_FREE_BYTES:
        raise GitError(f"not enough free disk in {WORK_ROOT}: {free // 2**20} MB")


def check_checkout_size(src):
    for label, size in (("history", tree_size(Path(src) / ".git")),
                        ("checkout", tree_size(src, skip_git=True))):
        if size > MAX_CHECKOUT_BYTES:
            raise GitError(f"{label} is larger than {MAX_CHECKOUT_BYTES // 2**20} MB")


def sweep_hook_dirs():
    """A kill skips `finally`, so old checkouts can pile up. Remove clearly stale ones."""
    now = time.time()
    for p in Path(WORK_ROOT).glob(HOOK_PREFIX + "*"):
        try:
            if p.is_dir() and now - p.stat().st_mtime > STALE_AGE:
                shutil.rmtree(p, ignore_errors=True)
        except OSError:
            pass


# ---------------------------------------------------------------- the worker

def read_deployed(app_root):
    try:
        data = json.loads((app_root / ".deployed").read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def write_deployed(app_root, sha, release):
    tmp = app_root / ".deployed.tmp"
    tmp.write_text(json.dumps({"sha": sha, "release": release}), encoding="utf-8")
    os.replace(tmp, app_root / ".deployed")


def run_job(job, allow_file, check_tip=True):
    """Returns (status, release): ok, held, same or stale. Raises on a real failure."""
    app_root = deploy_mod.SITES / job["app"]
    if deploy_mod.is_held(app_root):                      # a rollback is in force
        return "held", None
    deployed = read_deployed(app_root)
    try:
        live = deploy_mod.current_id(app_root / "current")
    except deploy_mod.DeployError:
        live = None
    if deployed.get("sha") == job["sha"] and deployed.get("release") == live:
        return "same", None                               # this exact commit is already live

    if check_tip:
        # A valid signature does not mean "latest": an old push can be redelivered or
        # replayed. Only build a commit that is still the tip of the branch.
        out = with_retry(lambda: git(["ls-remote", "--", job["url"], f"refs/heads/{job['branch']}"],
                                     allow_file=allow_file))
        tip = out.split()[0] if out.split() else ""
        if tip != job["sha"]:
            return "stale", None

    check_disk()
    work = Path(tempfile.mkdtemp(prefix=HOOK_PREFIX, dir=WORK_ROOT))
    try:
        src = work / "repo"
        git(["init", "-q", str(src)], allow_file=allow_file)
        # Fetch the commit named in the push, not "whatever main is now".
        with_retry(lambda: git(["-c", "fetch.fsckObjects=true", "fetch", "-q", "--depth", "1",
                                "--no-tags", "--no-recurse-submodules", "--", job["url"], job["sha"]],
                               cwd=src, allow_file=allow_file))
        git(["-c", "advice.detachedHead=false", "checkout", "-q", "--detach", "FETCH_HEAD"],
            cwd=src, allow_file=allow_file)
        check_checkout_size(src)
        build_dir = src / job["subdir"] if job["subdir"] else src
        if not build_dir.resolve().is_relative_to(src.resolve()):
            raise GitError("sub-folder resolves outside the checkout")
        release = build_mod.build_and_deploy(job["app"], build_dir)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    try:
        write_deployed(app_root, job["sha"], release)
    except OSError as e:
        print(f"warning: could not record the deployed sha: {e}", file=sys.stderr)
    return "ok", release


def process(state, job, allow_file):
    """Build the job; if that fails, try the push it superseded (a good older push
    must not be lost because a newer one was broken)."""
    chain, node = [], job
    while node is not None:
        chain.append(node)
        node = node.get("fallback")
    for i, j in enumerate(chain):
        started = time.monotonic()
        tag = f"{j['repo']} {j['sha'][:7]} {j['delivery']}" + (" (fallback)" if i else "")
        try:
            status, release = run_job(j, allow_file, check_tip=(i == 0))
        except (GitError, build_mod.BuildError, deploy_mod.DeployError) as e:
            deploy_mod.log_event(j["app"], "webhook", None, "fail", started, f"{tag} {e}")
            state.seen.remove(j["delivery"])
            if getattr(e, "busy", False) and i == 0 and not j.get("retried"):
                j["retried"] = True
                state.jobs.submit(j)  # the app was busy for 10 minutes: try once more
                deploy_mod.log_event(j["app"], "webhook", None, "requeued", started, tag)
                return
            continue
        if status == "ok":
            deploy_mod.log_event(j["app"], "webhook", release, "ok", started, tag)
        else:
            # held / same / stale: nothing was built, so let GitHub's "Redeliver" work
            # once the owner has unheld the app. A stale one is refused again anyway.
            deploy_mod.log_event(j["app"], "webhook", None, status, started, tag)
            state.seen.remove(j["delivery"])
        return


def worker(state, allow_file):
    sweep_hook_dirs()
    while True:
        job = state.jobs.take(state.stop)
        if job is None:
            return
        try:
            process(state, job, allow_file)
        except BaseException as e:  # SystemExit too: the worker must never die silently
            deploy_mod.log_event(job["app"], "webhook", None, "crash", time.monotonic(),
                                 f"{job['repo']} {job['sha'][:7]} {type(e).__name__}: {e}")
            state.seen.remove(job["delivery"])
        sweep_hook_dirs()


# ---------------------------------------------------------------- start up

def init_env(env_file=ENV_FILE):
    """Make sure a secret exists in a root-only file, without ever printing it.
    Moves one found in the old repo .env (on /mnt/c) instead of making a second."""
    env_file = Path(env_file)
    try:
        if read_secret_from_file(env_file):
            print(f"{env_file} already has a WEBHOOK_SECRET; left it alone")
            return 0
    except ConfigError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    secret, moved = "", False
    if LEGACY_ENV.exists():
        text = LEGACY_ENV.read_text(encoding="utf-8")
        m = re.search(r"^WEBHOOK_SECRET=(\S{%d,})\s*$" % MIN_SECRET, text, re.M)
        if m:
            secret, moved = m.group(1), True
    if not secret:
        secret = secrets.token_hex(32)

    env_file.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(env_file.parent, 0o700)
    fd = os.open(env_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)  # 0600 from the start
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(f"WEBHOOK_SECRET={secret}\n")
    if moved:  # one copy only: take it out of the file on /mnt/c
        kept = re.sub(r"^WEBHOOK_SECRET=.*\n?", "", LEGACY_ENV.read_text(encoding="utf-8"), flags=re.M)
        LEGACY_ENV.write_text(kept, encoding="utf-8")
    print(f"{'moved' if moved else 'wrote'} WEBHOOK_SECRET to {env_file} (mode 600, not shown).")
    return 0


def read_secret_from_file(env_file):
    """Like read_secret, but ignores the environment (used by --init-env)."""
    saved = os.environ.pop("WEBHOOK_SECRET", None)
    try:
        return read_secret(env_file)
    finally:
        if saved is not None:
            os.environ["WEBHOOK_SECRET"] = saved


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", default=str(REPO_ROOT / "config" / "webhook.json"))
    parser.add_argument("--init-env", action="store_true")
    parser.add_argument("--env-file", default=str(ENV_FILE))
    parser.add_argument("--state-dir", default=str(STATE_DIR))
    # test-only switches
    parser.add_argument("--allow-file-urls", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--deadline", type=float, default=TOTAL_DEADLINE, help=argparse.SUPPRESS)
    parser.add_argument("--max-handlers", type=int, default=MAX_HANDLERS, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.init_env:
        return init_env(args.env_file)

    try:
        secret = read_secret(args.env_file)
        if len(secret) < MIN_SECRET:
            raise ConfigError(f"WEBHOOK_SECRET is missing or shorter than {MIN_SECRET} characters "
                              f"(run: webhook.py --init-env; expected in {args.env_file})")
        config = load_config(args.config, args.allow_file_urls)
    except ConfigError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    state_dir = Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(state_dir, 0o700)
    except OSError:
        pass
    state = State(secret.encode(), config, state_dir)
    revived = load_pending(state)

    server = Server((config["listen"], config["port"]), Handler, max_handlers=args.max_handlers)
    server.state = state
    server.deadline = args.deadline

    # Not a daemon thread: a stop waits for the build that is running, and the jobs
    # still queued are saved to disk instead of being lost.
    state.worker = threading.Thread(target=worker, args=(state, args.allow_file_urls))
    state.worker.start()

    def stop(*_):
        threading.Thread(target=server.shutdown, daemon=True).start()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, stop)

    print(f"listening on {config['listen']}:{config['port']} for {len(config['repos'])} repo(s)"
          f"{f', {revived} queued job(s) restored' if revived else ''}", flush=True)
    try:
        server.serve_forever()
    finally:
        save_pending(state)       # queued jobs go to disk (drains the queue)
        state.stop.set()          # the worker exits after the build it is running
        server.server_close()
        state.worker.join(timeout=SHUTDOWN_WAIT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
