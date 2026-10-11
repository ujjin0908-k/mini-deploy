#!/usr/bin/env bash
# Copy the shared theme next to each site's HTML. Every site is its own deployed app
# (and the demo site is built from a repo checkout), so each one needs its own copy.
# Edit web/theme/pink.css only, then run this. test-sites.sh fails if a copy is stale.
set -euo pipefail
REPO=/mnt/c/Users/indra/Code/mini-deploy
for dest in web/dashboard/style.css web/landing/style.css examples/static-site/src/style.css; do
  cp "$REPO/web/theme/pink.css" "$REPO/$dest"
  echo "synced $dest"
done
