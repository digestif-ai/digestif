#!/usr/bin/env bash
# Deploys the relay to one of its two environments.
#   scripts/deploy.sh <dinners|dinners-roman> [--dry-run]
# The founding dinner's hash comes from the ROOT_HASH environment variable, else from
# vars.CIRCLE_ROOT of that environment in wrangler.jsonc; with neither set the script refuses.
# --dry-run prints the plan and runs nothing that touches a Cloudflare account.
# A database whose circle row names another root is cleared only when its log is empty, after
# asking, and refused otherwise (README "Re-root").
set -euo pipefail

cd "$(dirname "$0")/.."
usage() { echo "usage: scripts/deploy.sh <dinners|dinners-roman> [--dry-run]" >&2; exit 2; }

env_name="" dry=0
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    dinners|dinners-roman) env_name="$a" ;;
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
echo "  2. scripts/app.sh --require-ui: the phone app from ui/build into app/ ($([ -f ../ui/build/index.html ] && echo 'built' || echo 'NOT BUILT: the deploy refuses until it is'))"
echo "     npx wrangler d1 migrations apply DB --remote --env $env_name"
echo "  3. read the database's circle row; another root over an empty log is cleared in step 5 (after asking), over a non-empty log refused"
echo "  4. npx wrangler deploy --env $env_name --var CIRCLE_ROOT:$root"
echo "  5. when step 3 cleared: DELETE FROM circle, while it still names the old root and the log is empty"
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

bash scripts/app.sh --require-ui
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

wrangler deploy --env "$env_name" --var "CIRCLE_ROOT:$root"

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
