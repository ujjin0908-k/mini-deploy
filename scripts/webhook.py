#!/usr/bin/env python3
"""mini-deploy stage 5: GitHub webhook receiver that builds and deploys a push.

    webhook.py [--config config/webhook.json]     run the server (secret from $WEBHOOK_SECRET)
    webhook.py --init-env                         write a random WEBHOOK_SECRET into .env (not shown)

    POST /webhook  --> signature ok? --> push to the allowed branch? --> 202 queued
                                                                          |
                           worker: git fetch <sha> -> build.py (Docker) -> deploy.py -> flip

Everything in a request is outside input. What decides the app, branch, clone URL and
sub-folder is config/webhook.json, never the payload. The server only listens on loopback;
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
import deploy as deploy_mod  # noqa: E402  (log_event, APP_RE)

MAX_BODY = 1024 * 1024          # a push event is a few KB; refuse anything bigger
MIN_SECRET = 32                 # characters
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$")
BRANCH_RE = re.compile(r"^[A-Za-z0-9._/-]{1,100}$")
SUBDIR_RE = re.compile(r"^[A-Za-z0-9._/-]{0,200}$")
DELIVERY_RE = re.compile(r"^[0-9A-Fa-f-]{36}$")  # GitHub's X-GitHub-Delivery GUID
GIT_TIMEOUT = 180               # seconds per git step
WORK_ROOT = "/var/tmp"          # WSL filesystem, same as build.py
LOOPBACK = ("127.0.0.1", "::1")


class ConfigError(Exception):
    pass


class GitError(Exception):
    pass


# ---------------------------------------------------------------- config

def load_config(path, allow_file_urls=False):
    """Allowlist of repos. Validated once at start, so request handling can trust it."""
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise ConfigError(f"cannot read {path}: {e}")

    listen = raw.get("listen", "127.0.0.1")
    if listen not in LOOPBACK:
        raise ConfigError(f"listen must be one of {LOOPBACK}: exposing the webhook is the owner's decision")
    port = raw.get("port", 9000)
    if not isinstance(port, int) or not 1024 <= port <= 65535:
        raise ConfigError("port must be an integer from 1024 to 65535")

    repos = {}
    for full_name, entry in (raw.get("repos") or {}).items():
        if not REPO_RE.fullmatch(full_name):
            raise ConfigError(f"bad repo name {full_name!r}")
        app = entry.get("app", "")
        branch = entry.get("branch", "main")
        subdir = entry.get("subdir", "")
        url = entry.get("url", f"https://github.com/{full_name}.git")
        if not deploy_mod.APP_RE.fullmatch(app):
            raise ConfigError(f"{full_name}: bad app name")
        if not BRANCH_RE.fullmatch(branch) or ".." in branch:
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
    return {"listen": listen, "port": port, "repos": repos}


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
    """Delivery ids already handled. A valid signature does not stop an attacker
    replaying a captured request, so the same delivery is acted on only once."""

    def __init__(self, limit=2000):
        self.limit, self.lock, self.ids = limit, threading.Lock(), collections.OrderedDict()

    def add(self, delivery):
        with self.lock:
            if delivery in self.ids:
                return False
            self.ids[delivery] = True
            while len(self.ids) > self.limit:
                self.ids.popitem(last=False)
            return True


class Jobs:
    """At most one waiting build per app: a newer push replaces an older waiting one."""

    def __init__(self):
        self.cond = threading.Condition()
        self.pending = collections.OrderedDict()

    def submit(self, job):
        with self.cond:
            replaced = self.pending.get(job["app"])
            self.pending[job["app"]] = job
            self.cond.notify()
            return replaced

    def take(self):
        with self.cond:
            while not self.pending:
                self.cond.wait()
            return self.pending.popitem(last=False)[1]


class State:
    def __init__(self, secret, config):
        self.secret, self.config = secret, config
        self.seen, self.jobs = Seen(), Jobs()
        self._last_reject, self._suppressed = 0.0, 0
        self._lock = threading.Lock()

    def log(self, result, detail, app="webhook"):
        deploy_mod.log_event(app, "webhook", None, result, time.monotonic(), detail)

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


# ---------------------------------------------------------------- HTTP handler

class Handler(BaseHTTPRequestHandler):
    server_version = "mini-deploy"
    sys_version = ""
    timeout = 10  # a stalled client cannot hold a thread for long

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
        if not length.isdigit() or len(length) > 9:
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

        # 4. From here on the sender is GitHub (or someone holding the secret).
        event = self.headers.get("X-GitHub-Event", "")
        delivery = self.headers.get("X-GitHub-Delivery", "")
        if not DELIVERY_RE.fullmatch(delivery):
            return self._reply(400, "bad delivery id")
        if not state.seen.add(delivery):
            state.log("ignored", f"duplicate delivery {delivery}")
            return self._reply(202, "duplicate")
        if event == "ping":
            return self._reply(200, "pong")
        if event != "push":
            return self._reply(202, "ignored")

        try:
            payload = json.loads(body)
            repo = payload["repository"]["full_name"]
            ref, after = payload["ref"], payload["after"]
            deleted = bool(payload.get("deleted", False))
        except (ValueError, KeyError, TypeError):
            return self._reply(400, "bad payload")
        if not all(isinstance(x, str) for x in (repo, ref, after)):
            return self._reply(400, "bad payload")
        if not REPO_RE.fullmatch(repo) or not SHA_RE.fullmatch(after):
            return self._reply(400, "bad payload")

        # 5. Is this push one we act on? The answer comes from our config only.
        cfg = state.config["repos"].get(repo)
        if cfg is None:
            state.log("ignored", f"{repo} is not in the allowlist {delivery}")
            return self._reply(202, "ignored")
        if deleted or after == "0" * 40 or ref != f"refs/heads/{cfg['branch']}":
            state.log("ignored", f"{repo} {ref} is not a push to {cfg['branch']}", cfg["app"])
            return self._reply(202, "ignored")

        job = {"app": cfg["app"], "repo": repo, "sha": after, "url": cfg["url"],
               "subdir": cfg["subdir"], "delivery": delivery}
        replaced = state.jobs.submit(job)
        if replaced:
            state.log("superseded", f"{replaced['sha'][:7]} replaced by {after[:7]}", cfg["app"])
        state.log("queued", f"{repo} {after[:7]} {delivery}", cfg["app"])
        return self._reply(202, "queued")


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):  # one quiet line, not a traceback
        print(f"connection error: {sys.exc_info()[0].__name__}", file=sys.stderr)


# ---------------------------------------------------------------- the worker

def git(args, cwd=None, allow_file=False):
    """Run git with no prompts, no hooks, no user/system config, and only https
    (or file:// for tests). Arguments are a list; there is no shell."""
    cmd = ["git", "-c", "core.hooksPath=/dev/null", "-c", "protocol.allow=never",
           "-c", "protocol.https.allow=always"]
    if allow_file:
        cmd += ["-c", "protocol.file.allow=always"]
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": "/nonexistent",
           "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/bin/false",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "LC_ALL": "C"}
    try:
        r = subprocess.run(cmd + args, cwd=cwd, env=env, capture_output=True, text=True,
                           timeout=GIT_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise GitError(f"git {args[0]} timed out")
    if r.returncode != 0:
        raise GitError(f"git {args[0]} failed: {r.stderr.strip()[:200]}")


def run_job(job, allow_file):
    """Fetch exactly the pushed commit and hand it to build.py."""
    work = Path(tempfile.mkdtemp(prefix="mini-deploy-hook-", dir=WORK_ROOT))
    try:
        src = work / "repo"
        git(["init", "-q", str(src)], allow_file=allow_file)
        # Fetch the commit named in the push, not "whatever main is now": a push that
        # arrives late must not build a newer commit than the one it announced.
        git(["fetch", "-q", "--depth", "1", "--no-tags", "--no-recurse-submodules", "--",
             job["url"], job["sha"]], cwd=src, allow_file=allow_file)
        git(["-c", "advice.detachedHead=false", "checkout", "-q", "--detach", "FETCH_HEAD"],
            cwd=src, allow_file=allow_file)
        build_dir = src / job["subdir"] if job["subdir"] else src
        if not build_dir.resolve().is_relative_to(src.resolve()):
            raise GitError("sub-folder resolves outside the checkout")
        build_mod.build_and_deploy(job["app"], build_dir)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def worker(state, allow_file):
    while True:
        job = state.jobs.take()
        started = time.monotonic()
        tag = f"{job['repo']} {job['sha'][:7]}"
        try:
            run_job(job, allow_file)
        except (GitError, build_mod.BuildError, deploy_mod.DeployError) as e:
            deploy_mod.log_event(job["app"], "webhook", None, "fail", started, f"{tag} {e}")
        except Exception as e:  # the worker must never die
            deploy_mod.log_event(job["app"], "webhook", None, "crash", started,
                                 f"{tag} {type(e).__name__}: {e}")
        else:
            deploy_mod.log_event(job["app"], "webhook", None, "ok", started, tag)


# ---------------------------------------------------------------- start up

def init_env():
    """Put a random secret in .env without ever printing it."""
    path = REPO_ROOT / ".env"
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    if re.search(r"^WEBHOOK_SECRET=.{%d,}$" % MIN_SECRET, text, re.M):
        print(".env already has a WEBHOOK_SECRET; left it alone")
        return 0
    if re.search(r"^WEBHOOK_SECRET=", text, re.M):
        print("error: .env has a WEBHOOK_SECRET that is too short; edit it by hand", file=sys.stderr)
        return 1
    with open(path, "a", encoding="utf-8") as fh:
        if text and not text.endswith("\n"):
            fh.write("\n")
        fh.write(f"WEBHOOK_SECRET={secrets.token_hex(32)}\n")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    print("wrote WEBHOOK_SECRET to .env (not shown). Copy it from there when you set up GitHub.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", default=str(REPO_ROOT / "config" / "webhook.json"))
    parser.add_argument("--init-env", action="store_true")
    parser.add_argument("--allow-file-urls", action="store_true", help=argparse.SUPPRESS)  # tests only
    args = parser.parse_args()
    if args.init_env:
        return init_env()

    secret = os.environ.pop("WEBHOOK_SECRET", "")  # pop: child processes never inherit it
    if len(secret) < MIN_SECRET:
        print(f"error: WEBHOOK_SECRET is missing or shorter than {MIN_SECRET} characters "
              "(run: webhook.py --init-env, then start with scripts/run-webhook.sh)", file=sys.stderr)
        return 1
    try:
        config = load_config(args.config, args.allow_file_urls)
    except ConfigError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    state = State(secret.encode(), config)
    server = Server((config["listen"], config["port"]), Handler)
    server.state = state
    threading.Thread(target=worker, args=(state, args.allow_file_urls), daemon=True).start()
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown).start())
    print(f"listening on {config['listen']}:{config['port']} for {len(config['repos'])} repo(s)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
