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

## 3. Long-running servers: systemd services (Caddy, the webhook)
Both run as services that start with WSL; don't start them in tmux too (same ports).
```
wsl -d Ubuntu -- systemctl status mini-deploy-caddy mini-deploy-webhook
wsl -d Ubuntu -- systemctl reload mini-deploy-caddy        # after editing caddy/Caddyfile
wsl -d Ubuntu -- systemctl restart mini-deploy-webhook     # after editing webhook.py or its config
wsl -d Ubuntu -- journalctl -u mini-deploy-caddy -n 30 --no-pager
wsl -d Ubuntu -- bash /mnt/c/Users/indra/Code/mini-deploy/scripts/run-caddy.sh status   # Wi-Fi or this PC only?
```
Caddy listens on the home Wi-Fi only when `run-caddy.sh` recognises home (address + router);
a 30 s timer follows network changes. For any other long-running one-off, use tmux
(`tmux new-session -d -s <name> <cmd>`, `tmux capture-pane -p -t <name>`); note that
killing a tmux session does not always stop the program in it (check with `pgrep -af`).
`localhost` ports in WSL2 are reachable from Windows (curl or the browser pane).

## 4. Installs and destructive commands: run them directly, never inside a script
`apt`, `apt-get`, `rm -rf`, `systemctl`, `ufw`, `curl … | sh` must be visible as a direct `wsl -d Ubuntu -- <cmd>` call, so the approval gate in `~/.claude/settings.json` catches them.
Before any install, tell the owner what it is, why it's needed, and roughly how big it is. Wait for a yes.

## 5. Paths
- Windows `C:\Users\indra\…` = WSL `/mnt/c/Users/indra/…`
- Runtime data (`/sites`, logs, Docker volumes) stays in the WSL filesystem, not `/mnt/c`: it's faster, and symlinks and permissions work properly there.
