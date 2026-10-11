# mini-deploy: notes for agents

A small Netlify-style host, built in stages to **learn** how deploy platforms work: `git push` → webhook → build → new release folder → `current` link flips → Caddy serves the site.
Plan and diagrams: `Obsidian/Projects/claude add-ons/agent-patterns-and-deploy-platform.md`. Project note: `Obsidian/Projects/Mini Deploy/Mini Deploy.md`.

## Owner's working style

- **Teach + build.** For each step: explain the idea in 2-4 plain sentences, build it, then give the owner the test command to run themselves. Short "why" comments in the code.
- List and discuss changes first. Build only after the owner says **"go"**.
- One stage per session. Use `/stage N`.
- Never expose anything to the public internet (port forwarding, firewall rules, a real domain, tunnels) without the owner asking.
- Never install software without asking first (apt, Docker, Caddy, pip packages).

## Environment

- Windows 11 + **WSL2 Ubuntu** (distro name `Ubuntu`). All server pieces run inside WSL. Use the `wsl-run` skill for every command.
- Repo on the Windows side: `C:\Users\indra\Code\mini-deploy` (= `/mnt/c/Users/indra/Code/mini-deploy` in WSL). The owner uses GitHub Desktop; `git` isn't on the Windows PATH.
- Runtime data lives in the WSL filesystem, **not** on `/mnt/c`: `/sites/<app>/releases/<id>/` + `/sites/<app>/current` symlink. NTFS symlinks and permissions behave differently.
- Installed in WSL (2026-10-11): git, python3, tmux. Missing: docker, caddy.
- Language for our own code: **Python 3, standard library first** (http.server, hmac, hashlib, subprocess, json). Shell only for tiny glue scripts.

## Owner's decisions (from the Obsidian note)

- Static sites only at first. Functions and databases come after stage 6.
- Only the owner's own code gets built (no strangers' builds), but keep builds in containers anyway.
- Local first (`*.localhost`). VPS vs home machine + Cloudflare Tunnel, and the domain, are still open.

## Stages

The owner's study notes live in `Obsidian/Projects/Mini Deploy/Notes/`. `/stage N` reads the matching note first and teaches in the same words.

| Stage | Read first (Notes/) | Build | Done when |
|---|---|---|---|
| 0 | `Where to begin.md` | Docker + Caddy installed in WSL (ask first) | `caddy version` and `docker run hello-world` work |
| 1 | `1 How a website reaches you.md` | Caddy serves a folder | `curl localhost:8080` returns the page |
| 2 | `3 Servers, Caddy and subdomains.md` | Wildcard subdomains `*.localhost` | `app1.localhost:8080` and `app2.localhost:8080` show different sites |
| 3 | `2 What a deploy really is.md` | Releases + `current` link, `deploy` + `rollback` | Deploy, roll back, deploy again with no broken request in between |
| 4 | `4 Building inside Docker.md` | Builds inside Docker | A repo with a build step deploys from a container build |
| 5 | `5 Webhooks and auto deploy.md` | GitHub webhook receiver (Python) | A signed test payload deploys; a bad signature is rejected |
| 6 | (none yet) | Logs, dashboard, previews, env vars | Owner picks |

Obsidian root on Windows: `C:\Users\indra\OneDrive\Desktop\obsidian\skeloton\ai_workspace_skeleton\Obsidian\`.

## Security rules (the reviewers check these)

- App names: `^[a-z0-9-]{1,40}$` only. Never build paths or shell commands from unchecked input.
- No `shell=True`; pass argument lists to `subprocess`.
- Webhooks: check `X-Hub-Signature-256` with `hmac.compare_digest` **before** reading anything else. Secret comes from an env var, never committed.
- Switch the `current` link atomically: `ln -sfn` into a temp link, then `mv -T`. Keep at least the last 3 releases for rollback.
- Secrets go in `.env` (gitignored). Never print them.

## Commands

- `/stage N`: run one stage (explain → build → owner tests → log).
- `/deploy-review`: security + deploy-safety reviewers in parallel.

## Code map (graphify)

- Before grepping the repo, read `graphify-out/GRAPH_REPORT.md`. For "how does X connect to Y" questions, run `graphify query "<question>"`. This is cheaper than opening many files.
- Refresh after code changes: `/graphify . --update` (re-reads only changed files).
- Build only on code. Don't run `/graphify` on the Obsidian vault (notes cost model tokens).
- Only `GRAPH_REPORT.md` and `graph.json` are committed. The rest of `graphify-out/` is ignored.

## Git

- Remote: `origin` = `https://github.com/ujjin0908-k/mini-deploy.git`. Use one commit per stage.
- Never push, open a PR or merge without the owner's yes (the approval gate also asks).

## Status

- 2026-10-11: Repo created with the Claude kit only. No stage started. Commit "Initial commit" exists locally.
- 2026-10-11: Graphify rules and code-map section added. Graph gets built after stage 1 (no code to map yet).
