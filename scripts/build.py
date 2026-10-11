#!/usr/bin/env python3
"""mini-deploy stage 4: build a repo inside a Docker container, then deploy dist/.

    build.py build <app> <repo-dir>

    repo-dir --copy--> temp work folder --mounted--> [ node container ]
                                                      npm ci && npm run build
    work/dist  --deploy.py--> /sites/<app>/releases/<id>  -> current flips

The host never runs npm or node. If the build fails, nothing is deployed and the
live site stays on its old release. Standard library only.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deploy as deploy_mod  # reuse the same atomic release logic (stage 3)

DEFAULT_NODE = 22
MIN_NODE, MAX_NODE = 12, 30  # anything outside this is treated as "not a real version"
IMAGE = "node:{major}-slim"  # slim: small, and glibc, so native modules still work
TIMEOUT = 600                # seconds for the whole build
WORK_ROOT = "/var/tmp"       # WSL filesystem, not /mnt/c: npm symlinks misbehave on NTFS


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


def docker_build(work, image):
    name = f"mini-deploy-build-{os.getpid()}-{int(time.time())}"
    cmd = [
        "docker", "run", "--rm", "--name", name,
        # The build only needs to read and write /app. Drop everything else.
        "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges",
        "--memory", "1g", "--cpus", "2", "--pids-limit", "512",
        "-v", f"{work}:/app", "-w", "/app",
        image,
        "sh", "-c", "npm ci && npm run build",
    ]
    try:
        # List of arguments, no shell=True on the host. `sh -c` runs inside the box.
        result = subprocess.run(cmd, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        # Killing the docker client does not stop the container, so do it by name.
        subprocess.run(["docker", "rm", "-f", name], capture_output=True)
        raise BuildError(f"build timed out after {TIMEOUT}s")
    if result.returncode != 0:
        raise BuildError(f"build failed (exit {result.returncode}); nothing was deployed")


def build_and_deploy(app, repo):
    deploy_mod.app_paths(app)  # validate the name before spending time on a build
    repo = Path(repo).resolve()
    if not (repo / "package.json").is_file():
        raise BuildError(f"{repo} has no package.json")

    major = node_major(repo)
    image = IMAGE.format(major=major)
    print(f"image: {image}")

    work = Path(tempfile.mkdtemp(prefix="mini-deploy-build-", dir=WORK_ROOT))
    try:
        app_dir = work / "app"
        # Keep host-only junk out of the box. Links are kept as links, not followed.
        shutil.copytree(repo, app_dir, symlinks=True,
                        ignore=shutil.ignore_patterns("node_modules", ".git", "dist"))
        docker_build(app_dir, image)

        dist = app_dir / "dist"
        if not dist.is_dir() or not any(dist.iterdir()):
            raise BuildError("build finished but dist/ is missing or empty; nothing was deployed")
        deploy_mod.deploy(app, dist)
    finally:
        shutil.rmtree(work, ignore_errors=True)  # the temp copy always goes away


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("build")
    p.add_argument("app")
    p.add_argument("repo")
    args = parser.parse_args()
    try:
        build_and_deploy(args.app, args.repo)
    except (BuildError, deploy_mod.DeployError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
