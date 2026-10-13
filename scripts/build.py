#!/usr/bin/env python3
"""mini-deploy stage 4: build a repo inside a Docker container, then deploy dist/.

    build.py build <app> <repo-dir> [--install-scripts] [--preview <branch>]

    repo-dir --copy--> temp work folder --mounted--> [ node container, non-root ]
                                                      npm ci && npm run build
    work/dist  --deploy.py--> /sites/<app>/releases/<id>  -> current flips

The host never runs npm or node. If the build fails, nothing is deployed and the
live site stays on its old release. Builds of the same app run one at a time, so
an older commit that builds slowly cannot overwrite a newer one. Standard library only.
"""

import argparse
import base64
import collections
import html
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deploy as deploy_mod  # reuse the same atomic release logic (stage 3)
import buildlog              # full output of every build, readable on this PC only
import appenv                # per-app values, given to the build only

DEFAULT_NODE = 22
MIN_NODE, MAX_NODE = 12, 30  # anything outside this is treated as "not a real version"
IMAGE = "node:{major}-slim"  # slim: small, and glibc, so native modules still work
# Pinned by digest so a swapped tag on Docker Hub cannot silently change the build box.
# Other majors run unpinned (and say so). Refresh with: docker pull node:22-slim
IMAGE_DIGESTS = {
    22: "sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392",
}
RUN_AS = "1000:1000"        # the `node` user inside the image; never root
LABEL = "mini-deploy-build"  # lets us find leftover containers by label
TIMEOUT = 600               # seconds for the whole build
WORK_ROOT = "/var/tmp"      # WSL filesystem, not /mnt/c: npm symlinks misbehave on NTFS


class BuildError(Exception):
    pass


def node_major(repo):
    """Pick the Node major version from package.json engines.node, default 22.

    package.json is outside input. Only a small integer is taken from it and put
    into a fixed image name; the raw string never reaches the docker command.
    """
    try:
        pkg = json.loads((repo / "package.json").read_text(encoding="utf-8"))
        spec = str(pkg.get("engines", {}).get("node", ""))
    except (OSError, ValueError, AttributeError):
        return DEFAULT_NODE
    m = re.search(r"[0-9]{1,2}", spec)
    if m and MIN_NODE <= int(m.group()) <= MAX_NODE:
        return int(m.group())
    return DEFAULT_NODE


def image_ref(major):
    tag = IMAGE.format(major=major)
    digest = IMAGE_DIGESTS.get(major)
    if digest:
        return f"{tag}@{digest}"
    print(f"note: {tag} is not pinned by digest", file=sys.stderr)
    return tag


def sweep_stale():
    """A SIGKILL skips every `finally`, so old work folders and containers can pile up.
    Clean up anything clearly older than a build can last."""
    now = time.time()
    for p in Path(WORK_ROOT).glob("mini-deploy-build-*"):
        try:
            if p.is_dir() and now - p.stat().st_mtime > TIMEOUT + 300:
                shutil.rmtree(p, ignore_errors=True)
        except OSError:
            pass
    try:
        out = subprocess.run(
            ["docker", "ps", "-a", "--filter", f"label={LABEL}",
             "--format", '{{.Names}} {{.Label "' + LABEL + '"}}'],
            capture_output=True, text=True, timeout=30,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].isdigit() and now - int(parts[1]) > TIMEOUT + 120:
            subprocess.run(["docker", "rm", "-f", parts[0]], capture_output=True, timeout=30)


def chown_tree(path, uid, gid):
    """The container user must own the work folder, since it is not root."""
    os.lchown(path, uid, gid)
    for dirpath, dirnames, filenames in os.walk(path):
        for name in dirnames + filenames:
            os.lchown(os.path.join(dirpath, name), uid, gid)


CHUNK = 64 * 1024   # a "line" longer than this is handled in pieces


HIDDEN = b"[hidden]"
MIN_FORM = 8   # an encoded piece shorter than this would match random text


def secret_forms(value):
    """The ways a value commonly ends up written, as bytes: as is, as a JS/JSON string
    (escaped quotes and backslashes, \\uXXXX, <\\/script), HTML-escaped, URL-encoded, and
    base64 (plain and URL-safe) at each of the 3 byte alignments, so it is found inside a
    longer base64 text too. This is a safety net for mistakes, not a wall: code that wants
    to hide a value (reversed, split, encrypted) gets past it. The real protection is that
    secrets only reach `npm run build`, and previews never get the live ones."""
    raw = value.encode("utf-8")
    forms = {raw}
    for ascii_only in (True, False):
        js = json.dumps(value, ensure_ascii=ascii_only)[1:-1]
        forms |= {js.encode("utf-8"), js.replace("/", "\\/").encode("utf-8")}
    forms.add(html.escape(value, quote=True).encode("utf-8"))
    forms.add(html.escape(value, quote=True).replace("&#x27;", "&#39;").encode("utf-8"))
    forms |= {urllib.parse.quote(value, safe="").encode(), urllib.parse.quote_plus(value, safe="").encode()}
    for k in range(3):
        # In a longer base64 text the value starts at some byte offset; dropping the first
        # k bytes lines it up with a 3-byte group, and only whole groups are compared.
        part = raw[k:]
        part = part[:len(part) // 3 * 3]
        forms |= {base64.b64encode(part), base64.urlsafe_b64encode(part)}
    return [f for f in forms if len(f) >= MIN_FORM]


def all_forms(secrets):
    """{form bytes: KEY} for every secret, longest form first."""
    found = {}
    for key, value in secrets.items():
        for form in secret_forms(value):
            found.setdefault(form, key)
    return dict(sorted(found.items(), key=lambda kv: len(kv[0]), reverse=True))


def mask(data, forms):
    """Replace every secret form (longest first) before anything is printed or kept."""
    for f in forms:
        data = data.replace(f, HIDDEN)
    return data


def pump_output(stream, capture, tail, forms=()):
    """Read the container's output (bytes) until it ends. Build output is untrusted:
    - read at most CHUNK bytes at a time, so one endless line without a newline can never
      fill this (host-side) process's memory; the container's memory limit does not cover it;
    - mask secret values (and their encoded forms) first, so they reach neither the
      terminal nor the build log;
    - print only cleaned text, so escape codes cannot set the terminal title, write to the
      clipboard or move the cursor in your terminal or the service journal;
    - never stop reading because printing failed: an unread pipe would hang the build."""
    forms = sorted(forms, key=len, reverse=True)
    # A secret can be cut in two by the CHUNK limit. Mask first, then hold back the last
    # (longest form - 1) bytes of a cut line: any form not yet complete starts inside
    # them, so it is masked whole together with the next piece. Only a FULL chunk without
    # a newline is a cut line; a shorter one is the end of the output, and is never held.
    hold = max((len(f) for f in forms), default=1) - 1
    carry = b""
    while True:
        chunk = stream.readline(CHUNK)
        data, carry = mask(carry + chunk, forms), b""
        if not data:
            return
        if len(chunk) == CHUNK and not chunk.endswith(b"\n") and hold:
            data, carry = data[:-hold], data[-hold:]
            if not data:
                continue
        line = data.decode("utf-8", "replace")
        text = buildlog.clean(line)
        try:
            print(text, end="", flush=True)
        except Exception:  # noqa: BLE001  (closed stdout, odd encoding: keep reading)
            pass
        if capture is not None:
            capture.add(line)  # cleaned again inside; the log gets the full output
        if text.strip():
            tail.append(text.strip()[:300])


# What the docker CLIENT on the host keeps of our own environment. It needs little, and
# nothing of ours should travel next to the app's values.
CLIENT_ENV = ("PATH", "HOME", "LANG", "LC_ALL", "TZ")


def client_env(env):
    base = {k: v for k, v in os.environ.items() if k in CLIENT_ENV or k.startswith("DOCKER_")}
    return {**base, **env}


def _run_box(work, image, script, capture, tail, env, forms, deadline):
    """One `docker run` of `script` in the locked-down box. Returns the exit code."""
    name = f"mini-deploy-build-{uuid.uuid4().hex[:12]}"
    # `-e KEY` with no "=value": docker copies the value from its own environment. So the
    # value never sits in a command line, where `ps` and the journal could show it.
    env_args = [a for key in sorted(env) for a in ("-e", key)]
    cmd = [
        "docker", "run", "--rm", "--name", name, "--label", f"{LABEL}={int(time.time())}",
        "--pull=missing",
        # The build only needs to read and write /app. Drop everything else.
        "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges",
        "--user", RUN_AS,
        "--read-only", "--tmpfs", "/tmp:rw,exec,nosuid,size=512m",
        *env_args,  # before our own -e flags, so HOME and the npm cache always win
        "-e", "HOME=/tmp", "-e", "npm_config_cache=/tmp/.npm",
        "--memory", "1g", "--cpus", "2", "--pids-limit", "512",
        "-v", f"{work}:/app", "-w", "/app",
        image,
        "sh", "-c", script,
    ]
    # List of arguments, no shell=True on the host. `sh -c` runs inside the box.
    # Output is echoed live and the last lines are kept, so a failure in the deploy
    # log says WHY (the reason used to exist only in the terminal).
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=client_env(env))
    reader = threading.Thread(target=pump_output, args=(proc.stdout, capture, tail, forms), daemon=True)
    reader.start()
    try:
        try:
            return proc.wait(timeout=max(1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            proc.kill()
            raise BuildError(f"build timed out after {TIMEOUT}s")
    finally:
        # Killing the docker client does not stop the container, and a SIGTERM or
        # Ctrl-C lands here too, so always remove it by name.
        subprocess.run(["docker", "rm", "-f", name], capture_output=True, timeout=30)
        reader.join(timeout=5)


def docker_build(work, image, install_scripts, capture=None, env=None, forms=()):
    """Two boxes, one after the other, sharing only /app:
      1. `npm ci`          with NO app values: package install steps cannot see a secret;
      2. `npm run build`   with the app's values.
    Same limits for both; one TIMEOUT for the pair."""
    deadline = time.monotonic() + TIMEOUT
    tail = collections.deque(maxlen=40)
    npm = "npm ci" if install_scripts else "npm ci --ignore-scripts"
    rc = _run_box(work, image, npm, capture, tail, {}, forms, deadline)
    if rc != 0:
        why = " | ".join(list(tail)[-4:])
        raise BuildError(f"build failed (npm ci, exit {rc}); nothing was deployed: {why}")
    rc = _run_box(work, image, "npm run build", capture, tail, env or {}, forms, deadline)
    if rc != 0:
        why = " | ".join(list(tail)[-4:])
        raise BuildError(f"build failed (exit {rc}); nothing was deployed: {why}")


def _walk_strict(top):
    """os.walk that raises instead of silently skipping a folder it cannot read."""
    def fail(err):
        raise err
    return os.walk(top, onerror=fail)


def find_secret(dist, forms):
    """Name of the first secret whose value (or an encoded form, see secret_forms) appears
    in a file or file name under dist, else None. forms: {bytes: KEY}.
    - The whole tree is sized first: above the release cap it is refused before any
      reading (deploy.py would refuse it anyway, and reading 500+ MB under the build lock
      would only hold up the next build).
    - Files are read in pieces with an overlap, so a value across two pieces is found.
    - Only regular files are opened (a FIFO from the build would block the open forever);
      links and special files are refused by deploy.py anyway.
    - Anything odd (unreadable, vanished, too deep) is a clear BuildError, not a crash."""
    if not forms:
        return None
    try:
        total = 0
        for dirpath, _, filenames in _walk_strict(dist):
            for name in filenames:
                st = os.lstat(os.path.join(dirpath, name))
                if stat.S_ISREG(st.st_mode):
                    total += st.st_size
            if total > deploy_mod.MAX_RELEASE_BYTES:
                raise BuildError(f"dist/ is larger than {deploy_mod.MAX_RELEASE_BYTES // 2**20} MB; "
                                 "nothing was deployed")
        hold = max(len(f) for f in forms) - 1
        for dirpath, dirnames, filenames in _walk_strict(dist):
            for name in dirnames + filenames:
                for f, k in forms.items():
                    if f in os.fsencode(name):
                        return k
            for name in filenames:
                path = os.path.join(dirpath, name)
                if not stat.S_ISREG(os.lstat(path).st_mode):
                    continue
                with open(path, "rb") as fh:
                    prev = b""
                    while True:
                        piece = fh.read(1024 * 1024)
                        if not piece:
                            break
                        buf = prev + piece
                        for f, k in forms.items():
                            if f in buf:
                                return k
                        prev = buf[-hold:] if hold else b""
    except (OSError, RecursionError) as e:
        raise BuildError(f"could not check dist/ for secrets ({type(e).__name__}); nothing was deployed")
    return None


def build_and_deploy(app, repo, install_scripts=False, commit=None, refuse_if_held=False):
    """Build and deploy; returns the new release id. commit: the sha being built (the
    webhook knows it), shown in the build log."""
    root, _, _ = deploy_mod.app_paths(app)  # validate the name before spending time
    repo = Path(repo).resolve()
    if not (repo / "package.json").is_file():
        raise BuildError(f"{repo} has no package.json")

    major = node_major(repo)
    image = image_ref(major)
    print(f"image: {image}")
    sweep_stale()

    capture = buildlog.Capture()
    started, t0 = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), time.monotonic()
    result, release, error, info = "fail", None, "", {}
    try:
        release = _build_locked(app, root, repo, image, install_scripts, capture, info, refuse_if_held)
        result = "ok"
        return release
    except BaseException as e:
        error = f"{type(e).__name__}: {e}" if not isinstance(e, (BuildError, deploy_mod.DeployError)) else str(e)
        try:
            deploy_mod.drop_if_empty(app)  # a failed FIRST preview build leaves no half-made app
        except Exception:  # noqa: BLE001  (must never replace the real error)
            pass
        raise
    finally:
        # Every build gets a log, a failed one most of all. Fully guarded: writing a log
        # must never turn a finished deploy into an error, or hide the real one.
        try:
            buildlog.write(app, result, {
                "app": app, "commit": commit, "image": image, "env": ", ".join(info.get("env", ())),  # names only
                "started": started,
                "duration": f"{time.monotonic() - t0:.1f}s", "result": result,
                "release": release, "error": error.split("nothing was deployed:")[0].strip(),
            }, capture.text)  # a callable: the text is built inside write()'s own guard
        except Exception:  # noqa: BLE001
            pass


class EnvBuildError(BuildError):
    """The app's env file cannot be used. Building an older push would fail the same way,
    so the webhook does not fall back on it (config = fix the file, then push again)."""
    config = True


def load_env(app):
    """Values for this build (a preview gets its parent's preview values), read only once
    the build lock is held, so a value changed while a build waited is the one used."""
    try:
        return appenv.for_build(app)
    except appenv.EnvError as e:
        raise EnvBuildError(f"env values could not be used; nothing was deployed: {e}")


def _build_locked(app, root, repo, image, install_scripts, capture, info=None, refuse_if_held=False):
    info = {} if info is None else info
    # Separate from the deploy lock, so a rollback is never stuck behind a long build.
    with deploy_mod.locked(root, ".build.lock"):
        env, secrets = load_env(app)
        info["env"] = sorted(env)
        forms = all_forms(secrets)
        work = Path(tempfile.mkdtemp(prefix="mini-deploy-build-", dir=WORK_ROOT))
        try:
            app_dir = work / "app"
            # Keep host-only junk and secrets out of the box. Links are kept, not followed.
            shutil.copytree(repo, app_dir, symlinks=True, ignore=shutil.ignore_patterns(
                "node_modules", ".git", "dist", ".env", ".env.*", ".npmrc"))  # .npmrc may hold a token
            uid, gid = (int(x) for x in RUN_AS.split(":"))
            chown_tree(app_dir, uid, gid)
            docker_build(app_dir, image, install_scripts, capture, env, list(forms))

            dist = app_dir / "dist"
            # The build ran untrusted code, so `dist` may be anything, including a link
            # to a host folder. Only a real folder inside the work folder is accepted.
            if dist.is_symlink():
                raise BuildError("dist is a symlink; nothing was deployed")
            if not dist.is_dir() or not any(dist.iterdir()):
                raise BuildError("build finished but dist/ is missing or empty; nothing was deployed")
            if not dist.resolve().is_relative_to(app_dir.resolve()):
                raise BuildError("dist resolves outside the work folder; nothing was deployed")
            # Values are for the build. A secret that ends up in the site would be served
            # to everyone who can open it, so that build is refused (mark it --public if it
            # really belongs in the page).
            leaked = find_secret(dist, forms)
            if leaked:
                # The key name goes after "nothing was deployed:", so the dashboard and the
                # log header (which cut there) show only the reason.
                raise BuildError(f"a secret appears in dist/; nothing was deployed: {leaked} "
                                 f"(if it is not secret: appenv.py set ... {leaked} --public)")
            # the new release id; the webhook asks to refuse if a rollback held the app meanwhile
            return deploy_mod.deploy(app, dist, refuse_if_held=refuse_if_held)
        finally:
            shutil.rmtree(work, ignore_errors=True)  # the temp copy always goes away


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("build")
    p.add_argument("app")
    p.add_argument("repo")
    p.add_argument("--install-scripts", action="store_true",
                   help="allow npm lifecycle scripts during npm ci (off by default)")
    p.add_argument("--preview", metavar="BRANCH",
                   help="build as the preview of BRANCH (<branch>--<app>), not the live app")
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))  # so `finally` runs on kill
    started = time.monotonic()
    rc = 0
    try:
        if args.app in deploy_mod.RESERVED_APPS:
            raise BuildError(f"{args.app} is reserved: {deploy_mod.RESERVED_APPS[args.app]}")
        if deploy_mod.PREVIEW_SEP in args.app:
            raise BuildError(f"names with '{deploy_mod.PREVIEW_SEP}' are previews (use --preview <branch>)")
        if args.preview is not None:
            args.app = deploy_mod.preview_name(args.app, args.preview)
            deploy_mod.check_preview(args.app, args.preview)
        build_and_deploy(args.app, args.repo, args.install_scripts)
        if args.preview is not None:
            deploy_mod.record_preview_branch(args.app, args.preview)
    except (BuildError, deploy_mod.DeployError) as e:
        deploy_mod.log_event(args.app, "build", None, "fail", started, str(e))
        print(f"error: {e}", file=sys.stderr)
        rc = 1
    else:
        deploy_mod.log_event(args.app, "build", None, "ok", started)
        deploy_mod.clear_hold_after_manual_deploy(args.app)  # a build the owner starts lifts a hold
    deploy_mod._refresh_dashboard(args.app)  # after failures too; never turns into an error
    return rc


if __name__ == "__main__":
    sys.exit(main())
