#!/usr/bin/env bash
# Deploys the relay to one of the environments wrangler.jsonc defines, one per relay.
#   scripts/deploy.sh <environment> [--dry-run] [--release <version>]
# An environment wrangler.jsonc does not define is refused, naming the ones it does.
# Without --release it deploys a build of this checkout. With --release it deploys the signed relay
# release <version> instead (README "Operations", Break glass): it downloads the manifest and its
# combined signatures from the version's GitHub release (relay-v<version>), checks them with
# `digestif-update verify` against the release signer
# set, downloads the bundle the manifest names, checks its sha256, its size and every migration
# against the manifest, and deploys those bytes: the bundle's module (not bundled again), its app/
# and its migrations, under this environment's own settings from wrangler.jsonc. Nothing touches
# an account until all of that passed. DIGESTIF_UPDATE names the digestif-update to check with
# (default: the node's own, then one on PATH, then the digestif-update of the newest version the
# release list on main names that no recall takes out); DIGESTIF_RELEASES names another place the
# releases' files are read from (a url or a directory holding relay-v<version>/).
# The relay's home circle is HOME_ROOT (README "Configuration"): a fresh relay has none, and
# `digestif circle found --relay` sets it; every deploy keeps the one the deployment holds
# (keep_vars). The ROOT_HASH environment variable sets it at deploy time instead; an environment
# whose wrangler.jsonc vars name CIRCLE_ROOT keeps that circle as its home.
# --dry-run prints the plan and runs nothing that touches a Cloudflare account.
# A database whose circle row names another root than the home circle given is cleared only when
# its log is empty, after asking, and refused otherwise (README "Re-root").
set -euo pipefail

cd "$(dirname "$0")/.."
usage() { echo "usage: scripts/deploy.sh <environment> [--dry-run] [--release <version>]" >&2; exit 2; }

env_name="" dry=0 release=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --release) [ $# -ge 2 ] || usage; release="${2#relay-v}"; shift ;;
    -*) usage ;;
    *) [ -z "$env_name" ] || usage; env_name="$1" ;;
  esac
  shift
done
[ -n "$env_name" ] || usage
# The environments wrangler.jsonc defines, one per relay.
defined="$(node scripts/jsonc.ts wrangler.jsonc env --keys)"
case " $defined " in
  *" $env_name "*) ;;
  *) echo "refusing: wrangler.jsonc defines no environment $env_name; it defines: $defined" >&2; exit 2 ;;
esac
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
releases="${DIGESTIF_RELEASES:-https://github.com/$repo/releases/download/}"
# The channel (docs/releases.md, The channel): release/ on main, and the channel branch's root while
# main's release list names no version.
channel="https://raw.githubusercontent.com/$repo/main/release/"
branch_channel="https://raw.githubusercontent.com/$repo/channel/"

# Copies a url or path ($1) to the file $2.
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
  fetch "${channel}index.json" "$stage/index.json" || { echo "refusing: could not read the release list ${channel}index.json; set DIGESTIF_UPDATE" >&2; return 1; }
  if [ "$(node scripts/release.ts listed "$stage/index.json")" = 0 ]; then
    fetch "${branch_channel}index.json" "$stage/index.json" || { echo "refusing: could not read ${branch_channel}index.json; set DIGESTIF_UPDATE" >&2; return 1; }
  fi
  published="$(node scripts/release.ts newest "$stage/index.json")" || { echo "refusing: the release list names no version no recall takes out; set DIGESTIF_UPDATE" >&2; return 1; }
  echo "no node here and no digestif-update on PATH: using $published's digestif-update-$platform, the newest listed version no recall takes out" >&2
  fetch "https://github.com/$repo/releases/download/v$published/digestif-update-$platform" "$stage/digestif-update" || {
    echo "refusing: could not download digestif-update-$platform; set DIGESTIF_UPDATE to one (docs/releases.md, Signing a release)" >&2
    return 1
  }
  chmod 755 "$stage/digestif-update"
  echo "$stage/digestif-update"
}

if [ -n "$release" ]; then
  stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' EXIT
  base="${releases%/}/relay-v$release"
  echo "release:     relay $release, from $base/"
  fetch "$base/manifest.json" "$stage/manifest.json" || { echo "refusing: relay $release is not published ($base/manifest.json)" >&2; exit 1; }
  fetch "$base/manifest.sig.json" "$stage/manifest.sig.json" || { echo "refusing: relay $release has no combined signatures on its release ($base/manifest.sig.json)" >&2; exit 1; }
  tool="$(update_tool)"
  echo "signatures:  checked with $tool"
  if ! "$tool" verify "$stage/manifest.json" "$stage/manifest.sig.json" --expect-version "$release" | sed 's/^/             /'; then
    echo "refusing: the signatures of relay $release do not verify; nothing was deployed" >&2
    exit 1
  fi
  url="$(node scripts/release.ts url "$stage/manifest.json" "$release" "$base")"
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

# The home circle: ROOT_HASH, else what the environment's vars name; none on a fresh relay, which
# `digestif circle found --relay` gives one.
root="${ROOT_HASH:-$(cfg vars.HOME_ROOT)}"
root="${root:-$(cfg vars.CIRCLE_ROOT)}"
if [ -n "$root" ] && ! [[ "$root" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "refusing: the home circle $root of $env_name is not sha256:<64 hex>. Set ROOT_HASH to the home circle root's hash, or leave it unset for a relay with no home yet." >&2
  exit 1
fi
# Only a home given at deploy time is passed as a variable; any other the deployment holds is kept.
home_var=()
[ -z "${ROOT_HASH:-}" ] || home_var=(--var "HOME_ROOT:$ROOT_HASH")

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
echo "home:        ${root:-none: the relay hosts nothing until \`digestif circle found --relay\` gives it a home}"
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
[ -z "$root" ] || echo "  3. read the database's circle row; another root over an empty log is cleared in step 5 (after asking), over a non-empty log refused"
if [ -n "$release" ]; then
  echo "  4. npx wrangler deploy --env $env_name ${home_var[*]:-}, the bundle's module as signed, tagged relay-v$release"
else
  echo "  4. npx wrangler deploy --env $env_name ${home_var[*]:-}"
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
kind=fresh
[ -z "$root" ] || read -r kind old count <<<"$(d1 "$(node scripts/reroot.ts query)" | node scripts/reroot.ts verdict "$root")"
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
  wrangler deploy --env "$env_name" ${home_var[@]+"${home_var[@]}"} --tag "relay-v$release" --message "$bundle_sha"
else
  wrangler deploy --env "$env_name" ${home_var[@]+"${home_var[@]}"}
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
