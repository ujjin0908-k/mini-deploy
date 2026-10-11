#!/usr/bin/env bash
set -euo pipefail
for c in git python3 tmux docker caddy; do printf '%s: ' "$c"; command -v "$c" || echo missing; done
echo "user=$(whoami) home=$HOME"
ls -ld /sites 2>/dev/null || echo '/sites: not created yet'
