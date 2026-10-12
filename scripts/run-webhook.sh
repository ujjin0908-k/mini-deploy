#!/usr/bin/env bash
# Normally the webhook runs as a systemd service (systemd/mini-deploy-webhook.service):
#   systemctl status|restart|stop mini-deploy-webhook
# Only use this script when that service is stopped (both want port 9000).
#
# Start the webhook receiver by hand. Run it in tmux so it keeps going:
#   wsl -d Ubuntu -- tmux new-session -d -s webhook bash /mnt/c/Users/indra/Code/mini-deploy/scripts/run-webhook.sh
# Stop it gracefully (it finishes the running build and saves the queue):
#   wsl -d Ubuntu -- tmux send-keys -t webhook C-c
#
# The secret is read by webhook.py itself from /etc/mini-deploy/env (mode 600, root only).
# This script does NOT source any file as shell code, and exports nothing.
set -euo pipefail
cd /mnt/c/Users/indra/Code/mini-deploy

if [ ! -f /etc/mini-deploy/env ]; then
  echo "no secret yet. Create it first:  python3 scripts/webhook.py --init-env" >&2
  exit 1
fi

exec python3 scripts/webhook.py "$@"
