#!/usr/bin/env bash
# Copy the shared theme next to each site's HTML. Each site is served on its own (and the demo
# site is built from a repo checkout), so each one needs its own copy.
# Edit web/theme/pink.css only, then run this. test-sites.sh fails if a copy is stale.
# (The admin page's café look is web/admin/admin.css, laid over this copy.)
set -euo pipefail
REPO=/mnt/c/Users/indra/Code/mini-deploy

for dest in web/logs/style.css web/admin/style.css examples/static-site/src/style.css; do
  cp "$REPO/web/theme/pink.css" "$REPO/$dest"
  echo "synced $dest"
done
