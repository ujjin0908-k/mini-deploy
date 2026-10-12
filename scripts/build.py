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
import collections
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deploy as deploy_mod  # reuse the same atomic release logic (stage 3)
import buildlog              # full output of every build, readable on this PC only

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


def docker_build(work, image, install_scripts, capture=None):
    name = f"mini-deploy-build-{uuid.uuid4().hex[:12]}"
    npm = "npm ci" if install_scripts else "npm ci --ignore-scripts"
    cmd = [
        "docker", "run", "--rm", "--name", name, "--label", f"{LABEL}={int(time.time())}",
        "--pull=missing",
        # The build only needs to read and write /app. Drop everything else.
        "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges",
        "--user", RUN_AS,
        "--read-only", "--tmpfs", "/tmp:rw,exec,nosuid,size=512m",
        "-e", "HOME=/tmp", "-e", "npm_config_cache=/tmp/.npm",
        "--memory", "1g", "--cpus", "2", "--pids-limit", "512",
        "-v", f"{work}:/app", "-w", "/app",
        image,
        "sh", "-c", f"{npm} && npm run build",
    ]
    # List of arguments, no shell=True on the host. `sh -c` runs inside the box.
    # Output is echoed live and the last lines are kept, so a failure in the deploy
    # log says WHY (the reason used to exist only in the terminal).
    tail = collections.deque(maxlen=40)
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, errors="replace")

    def pump():
        for line in proc.stdout:
            print(line, end="", flush=True)
            if capture is not None:
                capture.add(line)  # the full output, for the build log (cleaned there)
            if line.strip():
                tail.append(line.strip())

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    try:
        try:
            rc = proc.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            proc.kill()
            raise BuildError(f"build timed out after {TIMEOUT}s")
    finally:
        # Killing the docker client does not stop the container, and a SIGTERM or
        # Ctrl-C lands here too, so always remove it by name.
        subprocess.run(["docker", "rm", "-f", name], capture_output=True, timeout=30)
        reader.join(timeout=5)
    if rc != 0:
        why = " | ".join(list(tail)[-4:])
        raise BuildError(f"build failed (exit {rc}); nothing was deployed: {why}")


def build_and_deploy(app, repo, install_scripts=False, commit=None):
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
    result, release, error = "fail", None, ""
    try:
        release = _build_locked(app, root, repo, image, install_scripts, capture)
        result = "ok"
        return release
    except BaseException as e:
        error = f"{type(e).__name__}: {e}" if not isinstance(e, (BuildError, deploy_mod.DeployError)) else str(e)
        deploy_mod.drop_if_empty(app)  # a failed FIRST preview build leaves no empty folder
        raise
    finally:
        # Every build gets a log, a failed one most of all. Never raises.
        buildlog.write(app, result, {
            "app": app, "commit": commit, "image": image, "started": started,
            "duration": f"{time.monotonic() - t0:.1f}s", "result": result,
            "release": release, "error": error.split("nothing was deployed:")[0].strip(),
        }, capture.text())


def _build_locked(app, root, repo, image, install_scripts, capture):
    # Separate from the deploy lock, so a rollback is never stuck behind a long build.
    with deploy_mod.locked(root, ".build.lock"):
        work = Path(tempfile.mkdtemp(prefix="mini-deploy-build-", dir=WORK_ROOT))
        try:
            app_dir = work / "app"
            # Keep host-only junk and secrets out of the box. Links are kept, not followed.
            shutil.copytree(repo, app_dir, symlinks=True, ignore=shutil.ignore_patterns(
                "node_modules", ".git", "dist", ".env", ".env.*"))
            uid, gid = (int(x) for x in RUN_AS.split(":"))
            chown_tree(app_dir, uid, gid)
            docker_build(app_dir, image, install_scripts, capture)

            dist = app_dir / "dist"
            # The build ran untrusted code, so `dist` may be anything, including a link
            # to a host folder. Only a real folder inside the work folder is accepted.
            if dist.is_symlink():
                raise BuildError("dist is a symlink; nothing was deployed")
            if not dist.is_dir() or not any(dist.iterdir()):
                raise BuildError("build finished but dist/ is missing or empty; nothing was deployed")
            if not dist.resolve().is_relative_to(app_dir.resolve()):
                raise BuildError("dist resolves outside the work folder; nothing was deployed")
            return deploy_mod.deploy(app, dist)  # the new release id
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
