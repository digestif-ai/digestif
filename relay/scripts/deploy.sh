#!/usr/bin/env bash
# Deploys the relay to one of its two environments.
#   scripts/deploy.sh <dinners|dinners-roman> [--dry-run] [--release <version>]
# Without --release it deploys a build of this checkout. With --release it deploys the signed relay
# release <version> instead (README "Operations", Break glass): it downloads the manifest and its
# signatures from the channel, checks them with `digestif-update verify` against the release signer
# set, downloads the bundle the manifest names, checks its sha256, its size and every migration
# against the manifest, and deploys those bytes: the bundle's module (not bundled again), its app/
# and its migrations, under this environment's own settings from wrangler.jsonc. Nothing touches
# an account until all of that passed. DIGESTIF_UPDATE names the digestif-update to check with
# (default: the node's own, then one on PATH, then the newest published node release's);
# DIGESTIF_CHANNEL names another channel (a url or a directory).
# The founding dinner's hash comes from the ROOT_HASH environment variable, else from
# vars.CIRCLE_ROOT of that environment in wrangler.jsonc; with neither set the script refuses.
# --dry-run prints the plan and runs nothing that touches a Cloudflare account.
# A database whose circle row names another root is cleared only when its log is empty, after
# asking, and refused otherwise (README "Re-root").
set -euo pipefail

cd "$(dirname "$0")/.."
usage() { echo "usage: scripts/deploy.sh <dinners|dinners-roman> [--dry-run] [--release <version>]" >&2; exit 2; }

env_name="" dry=0 release=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --release) [ $# -ge 2 ] || usage; release="${2#relay-v}"; shift ;;
    dinners|dinners-roman) env_name="$1" ;;
    *) usage ;;
  esac
  shift
done
[ -n "$env_name" ] || usage
if [ -n "$release" ] && ! [[ "$release" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "refusing: --release takes a relay version, <MAJOR.MINOR.PATCH> (the tag relay-v<version>), not $release" >&2
  exit 2
fi

cfg() { node scripts/jsonc.ts wrangler.jsonc "env.$env_name.$1"; }
# Every wrangler call names the release's configuration when there is one (wcfg, set below).
wcfg=()
wrangler() { npx wrangler "$@" ${wcfg[@]+"${wcfg[@]}"}; }

# ---- --release: the signed bytes, checked before anything else runs ----

repo="digestif-ai/digestif"
channel="${DIGESTIF_CHANNEL:-https://raw.githubusercontent.com/$repo/channel/}"

# Copies a channel url or path ($1) to the file $2.
fetch() {
  case "$1" in
    http://*|https://*) curl -fsSL --retry 3 -o "$2" "$1" ;;
    *) cp "$1" "$2" ;;
  esac
}

# The digestif-update that checks the signatures. Never one from the relay release under review:
# the tool ships on the node line, and the signer set it checks against is the one built into it.
update_tool() {
  local data good os arch platform
  if [ -n "${DIGESTIF_UPDATE:-}" ]; then echo "$DIGESTIF_UPDATE"; return; fi
  if [ -n "${DIGESTIF_HOME:-}" ]; then data="$DIGESTIF_HOME"
  elif [ "$(uname -s)" = Darwin ]; then data="$HOME/Library/Application Support/Digestif"
  else data="${XDG_DATA_HOME:-$HOME/.local/share}/digestif"; fi
  good="$data/good/bin/digestif-update"
  if [ -x "$good" ]; then echo "$good"; return; fi
  if command -v digestif-update >/dev/null 2>&1; then command -v digestif-update; return; fi
  case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) echo "refusing: no digestif-update for $(uname -s); set DIGESTIF_UPDATE" >&2; return 1 ;; esac
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=x86_64 ;; *) echo "refusing: no digestif-update for $(uname -m); set DIGESTIF_UPDATE" >&2; return 1 ;; esac
  platform="$os-$arch"
  echo "no node here and no digestif-update on PATH: using the newest published node release's digestif-update-$platform" >&2
  fetch "https://github.com/$repo/releases/latest/download/digestif-update-$platform" "$stage/digestif-update" || {
    echo "refusing: could not download digestif-update-$platform; set DIGESTIF_UPDATE to one (docs/releases.md, Signing a release)" >&2
    return 1
  }
  chmod 755 "$stage/digestif-update"
  echo "$stage/digestif-update"
}

if [ -n "$release" ]; then
  stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' EXIT
  base="${channel%/}/relay/$release"
  echo "release:     relay $release, from $base/"
  fetch "$base/manifest.json" "$stage/manifest.json" || { echo "refusing: relay $release is not published on the channel ($base/manifest.json)" >&2; exit 1; }
  fetch "$base/manifest.sig.json" "$stage/manifest.sig.json" || { echo "refusing: relay $release has no signatures on the channel ($base/manifest.sig.json)" >&2; exit 1; }
  tool="$(update_tool)"
  echo "signatures:  checked with $tool"
  if ! "$tool" verify "$stage/manifest.json" "$stage/manifest.sig.json" --expect-version "$release" | sed 's/^/             /'; then
    echo "refusing: the signatures of relay $release do not verify; nothing was deployed" >&2
    exit 1
  fi
  url="$(node scripts/release.ts url "$stage/manifest.json" "$release" "$channel")"
  fetch "$url" "$stage/bundle.tar.gz" || { echo "refusing: could not download the bundle $url" >&2; exit 1; }
  node scripts/release.ts check "$stage/manifest.json" "$release" "$stage/bundle.tar.gz" >/dev/null || {
    echo "refusing: the bundle $url is not the bundle relay $release signed; nothing was deployed" >&2
    exit 1
  }
  mkdir "$stage/bundle"
  tar -xzf "$stage/bundle.tar.gz" -C "$stage/bundle" || { echo "refusing: the bundle $url does not unpack" >&2; exit 1; }
  if ! checked="$(node scripts/release.ts check "$stage/manifest.json" "$release" "$stage/bundle.tar.gz" "$stage/bundle")"; then
    echo "refusing: the bundle $url is not the bundle relay $release signed; nothing was deployed" >&2
    exit 1
  fi
  echo "bundle:      $url ($checked, as signed)"
  bundle_sha="${checked%% *}"
fi

root="${ROOT_HASH:-$(cfg vars.CIRCLE_ROOT)}"
if ! [[ "$root" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "refusing: no ROOT_HASH for $env_name. Set ROOT_HASH=sha256:<64 hex> (the founding dinner's hash) or vars.CIRCLE_ROOT in wrangler.jsonc env.$env_name." >&2
  exit 1
fi

db_name="$(cfg 'd1_databases.0.database_name')"
db_id="$(cfg 'd1_databases.0.database_id')"
placeholder="00000000-0000-0000-0000-000000000000"
secrets="$(cfg secrets.required)"
mailer="$(cfg vars.MAILER)"
route="$(cfg 'routes.0.pattern')"

if [ "$dry" = 1 ]; then
  account="(not queried in a dry run; \`npx wrangler whoami\` names it)"
else
  account="$(wrangler whoami 2>&1 | grep -iE 'account|@' | head -5 || true)"
fi
echo "environment: $env_name (mailer: $mailer${route:+, route: $route})"
echo "account:     $account"
echo "root:        $root"
echo "database:    $db_name ($([ "$db_id" = "$placeholder" ] && echo 'id is a placeholder: created first' || echo "$db_id"))"
echo "secrets:     $secrets (set beforehand with: npx wrangler secret put <NAME> --env $env_name)"
echo "plan:"
[ "$db_id" = "$placeholder" ] && echo "  1. npx wrangler d1 create $db_name, and put its id in wrangler.jsonc env.$env_name"
if [ -n "$release" ]; then
  echo "  2. the signed bundle's app/ and migrations, not this checkout's"
  echo "     npx wrangler d1 migrations apply DB --remote --env $env_name (the bundle's migrations)"
else
  echo "  2. scripts/app.sh --require-ui: the phone app from ui/build into app/ ($([ -f ../ui/build/index.html ] && echo 'built' || echo 'NOT BUILT: the deploy refuses until it is'))"
  echo "     npx wrangler d1 migrations apply DB --remote --env $env_name"
fi
echo "  3. read the database's circle row; another root over an empty log is cleared in step 5 (after asking), over a non-empty log refused"
if [ -n "$release" ]; then
  echo "  4. npx wrangler deploy --env $env_name --var CIRCLE_ROOT:$root, the bundle's module as signed, tagged relay-v$release"
else
  echo "  4. npx wrangler deploy --env $env_name --var CIRCLE_ROOT:$root"
fi
echo "  5. when step 3 cleared: DELETE FROM circle, while it still names the old root and the log is empty"
if [ "$dry" = 1 ]; then
  # The release's configuration is written here too, so a bundle.json it cannot read fails the dry run.
  [ -z "$release" ] || node scripts/release.ts config wrangler.jsonc "$env_name" "$stage/bundle" >"$stage/wrangler.json"
  echo "dry run: nothing was changed"
  exit 0
fi

if [ "$db_id" = "$placeholder" ]; then
  created="$(wrangler d1 create "$db_name" 2>&1)"; echo "$created"
  db_id="$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<<"$created" | head -1)"
  [ -n "$db_id" ] || { echo "could not read the database id from wrangler's output" >&2; exit 1; }
  # Only this environment's placeholder: the first one after its database_name.
  DB_NAME="$db_name" DB_ID="$db_id" node -e '
    const fs = require("fs"); let s = fs.readFileSync("wrangler.jsonc", "utf8");
    const at = s.indexOf("\"database_name\": \"" + process.env.DB_NAME + "\"");
    const ph = "00000000-0000-0000-0000-000000000000", j = s.indexOf(ph, at);
    if (at < 0 || j < 0) throw new Error("placeholder not found");
    fs.writeFileSync("wrangler.jsonc", s.slice(0, j) + process.env.DB_ID + s.slice(j + ph.length));'
  echo "wrote database_id $db_id into wrangler.jsonc env.$env_name; commit it with the deployment"
fi

# After the database id is known, since the release's configuration carries it.
if [ -n "$release" ]; then
  node scripts/release.ts config wrangler.jsonc "$env_name" "$stage/bundle" >"$stage/wrangler.json"
  wcfg=(--config "$stage/wrangler.json")
else
  bash scripts/app.sh --require-ui
fi
wrangler d1 migrations apply DB --remote --env "$env_name"

# The Worker writes the circle row on its first request of any kind, so a database that served the
# conformance circle (or any other) answers 500 misconfigured under a new root until the row goes.
d1() { wrangler d1 execute DB --remote --env "$env_name" --json --command "$1"; }
read -r kind old count <<<"$(d1 "$(node scripts/reroot.ts query)" | node scripts/reroot.ts verdict "$root")"
case "$kind" in
  fresh|same) ;;
  refuse)
    echo "refusing: database $db_name serves circle $old and holds $count envelopes of its log; it cannot be re-rooted to $root." >&2
    echo "Deploy the new circle on a new database of that name: export and delete this one, set database_id of env.$env_name back to $placeholder, and run this again (README \"Re-root\")." >&2
    exit 1 ;;
  clear)
    echo "database $db_name was rooted in $old and holds no envelope; the Worker refuses it under $root until its circle row is cleared."
    if [ -t 0 ]; then read -r -p "clear the circle row after deploying? [y/N] " answer; else answer=""; fi
    if [ "$answer" != "y" ]; then
      echo "refusing: not cleared and not deployed. Run this again in a terminal and answer y." >&2
      exit 1
    fi ;;
  *) echo "could not read the circle row of $db_name: $kind" >&2; exit 1 ;;
esac

if [ -n "$release" ]; then
  wrangler deploy --env "$env_name" --var "CIRCLE_ROOT:$root" --tag "relay-v$release" --message "$bundle_sha"
else
  wrangler deploy --env "$env_name" --var "CIRCLE_ROOT:$root"
fi

# Cleared after the deploy, not before: until the new Worker is live, any request to the old one
# writes its root back. The statement holds only while the row names the old root and the log is empty.
if [ "$kind" = clear ]; then
  d1 "$(node scripts/reroot.ts clear "$old")" >/dev/null
  read -r after _ <<<"$(d1 "$(node scripts/reroot.ts query)" | node scripts/reroot.ts verdict "$root")"
  case "$after" in
    fresh|same) echo "cleared the circle row; the next request roots $db_name in $root" ;;
    *) echo "the circle row still names another root (a request reached the old Worker); run this again" >&2; exit 1 ;;
  esac
fi
