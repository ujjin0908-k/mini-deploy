#!/usr/bin/env bash
# Start the webhook receiver. Run it in tmux so it keeps going:
#   wsl -d Ubuntu -- tmux new-session -d -s webhook bash /mnt/c/Users/indra/Code/mini-deploy/scripts/run-webhook.sh
# The secret is read from .env (gitignored) and is never echoed.
set -euo pipefail
REPO=/mnt/c/Users/indra/Code/mini-deploy
cd "$REPO"

if [ ! -f .env ]; then
  echo "no .env yet. Create the secret first:  python3 scripts/webhook.py --init-env" >&2
  exit 1
fi

# `tr -d '\r'` because .env sits on the Windows side and may have CRLF line endings.
set -a
. <(tr -d '\r' < .env)
set +a

exec python3 scripts/webhook.py "$@"
