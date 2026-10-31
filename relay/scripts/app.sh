#!/usr/bin/env bash
# Fills relay/app, the directory the Worker serves under /app/ (wrangler.jsonc, assets), with the
# phone app: ui/build when the web UI was built, else placeholder/index.html. app/ is generated and
# ignored, so a build or a deploy never dirties the tree. Run by the npm scripts that start a Worker
# (dev, test, conformance, types), by scripts/deploy.sh and by ci/build.sh.
#   scripts/app.sh [--require-ui]   --require-ui refuses when ui/build is absent
set -euo pipefail

relay="$(cd "$(dirname "$0")/.." && pwd)"
ui="$relay/../ui/build"
rm -rf "$relay/app"
if [ -f "$ui/index.html" ]; then
  cp -R "$ui" "$relay/app"
  echo "relay/app: the phone app from ui/build" >&2
elif [ "${1:-}" = "--require-ui" ]; then
  echo "refusing: ui/build has no index.html; build the web UI first (cd ui && npm ci && npm run build)" >&2
  exit 1
else
  mkdir -p "$relay/app"
  cp "$relay/placeholder/index.html" "$relay/app/index.html"
  echo "relay/app: the placeholder page (ui/build is not built)" >&2
fi
