#!/usr/bin/env bash
# Copy the shared theme next to each site's HTML. Every site is its own deployed app
# (and the demo site is built from a repo checkout), so each one needs its own copy.
# Edit web/theme/pink.css (the look) and web/theme/explain.css (diagram pieces for the
# *-explained pages) only, then run this. test-sites.sh fails if a copy is stale.
set -euo pipefail
REPO=/mnt/c/Users/indra/Code/mini-deploy

for dest in web/dashboard/style.css web/landing/style.css examples/static-site/src/style.css \
            dashboard-explained/style.css demo-site-explained/style.css landing-explained/style.css; do
  cp "$REPO/web/theme/pink.css" "$REPO/$dest"
  echo "synced $dest"
done

for dest in dashboard-explained/explain.css demo-site-explained/explain.css landing-explained/explain.css; do
  cp "$REPO/web/theme/explain.css" "$REPO/$dest"
  echo "synced $dest"
done
