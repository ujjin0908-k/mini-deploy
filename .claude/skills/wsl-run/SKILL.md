---
name: wsl-run
description: How to run commands inside WSL Ubuntu from this Windows session (PowerShell tool). Use for every server, Caddy, Docker, Python or shell command in mini-deploy.
---

# Running commands in WSL

The PowerShell tool runs on Windows. Everything for mini-deploy runs in **WSL Ubuntu**. Its default user is **root**, so there's no sudo and no password prompt. Be careful.

## 1. Simple command: pass arguments directly
```
wsl -d Ubuntu -- ls -la /sites
wsl -d Ubuntu -- python3 /mnt/c/Users/indra/Code/mini-deploy/server/hook.py --check
```
No pipes, `;`, `&&`, `$VAR` or quotes inside. PowerShell 5.1 mangles them before bash sees them.

## 2. Anything with pipes, variables, loops or quotes: use a script file
1. Write the script into the repo (`scripts/…sh`), or into the scratchpad for one-off probes.
2. It must use **LF** line endings. `.gitattributes` forces `*.sh` to LF. If you get `$'\r': command not found`, strip `\r`.
3. Run it: `wsl -d Ubuntu -- bash /mnt/c/Users/indra/Code/mini-deploy/scripts/<name>.sh`

Example: `.claude/skills/wsl-run/probe.sh` prints which tools are installed.

## 3. Long-running servers (Caddy, the webhook server): use tmux
```
wsl -d Ubuntu -- tmux new-session -d -s caddy caddy run --config /mnt/c/Users/indra/Code/mini-deploy/caddy/Caddyfile
wsl -d Ubuntu -- tmux capture-pane -p -t caddy
wsl -d Ubuntu -- tmux kill-session -t caddy
```
Check logs with `capture-pane`; don't block the tool on a foreground server.
`localhost` ports in WSL2 are reachable from Windows (curl or the browser pane).

## 4. Installs and destructive commands: run them directly, never inside a script
`apt`, `apt-get`, `rm -rf`, `systemctl`, `ufw`, `curl … | sh` must be visible as a direct `wsl -d Ubuntu -- <cmd>` call, so the approval gate in `~/.claude/settings.json` catches them.
Before any install, tell the owner what it is, why it's needed, and roughly how big it is. Wait for a yes.

## 5. Paths
- Windows `C:\Users\indra\…` = WSL `/mnt/c/Users/indra/…`
- Runtime data (`/sites`, logs, Docker volumes) stays in the WSL filesystem, not `/mnt/c`: it's faster, and symlinks and permissions work properly there.
