#!/usr/bin/env bash
# Deploys the relay to one of its two environments.
#   scripts/deploy.sh <relay-1|relay-2> [--dry-run]
# The founding dinner's hash comes from the ROOT_HASH environment variable, else from
# vars.CIRCLE_ROOT of that environment in wrangler.jsonc; with neither set the script refuses.
# --dry-run prints the plan and runs nothing that touches a Cloudflare account.
set -euo pipefail

cd "$(dirname "$0")/.."
usage() { echo "usage: scripts/deploy.sh <relay-1|relay-2> [--dry-run]" >&2; exit 2; }

env_name="" dry=0
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    relay-1|relay-2) env_name="$a" ;;
    *) usage ;;
  esac
done
[ -n "$env_name" ] || usage

cfg() { node scripts/jsonc.ts wrangler.jsonc "env.$env_name.$1"; }
wrangler() { npx wrangler "$@"; }

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
echo "  2. npx wrangler d1 migrations apply DB --remote --env $env_name"
echo "  3. npx wrangler deploy --env $env_name --var CIRCLE_ROOT:$root"
[ "$dry" = 1 ] && { echo "dry run: nothing was changed"; exit 0; }

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

wrangler d1 migrations apply DB --remote --env "$env_name"
wrangler deploy --env "$env_name" --var "CIRCLE_ROOT:$root"
