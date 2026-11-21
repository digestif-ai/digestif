#!/usr/bin/env bash
#
# Settles DIG-320: on the Workers Free plan, do SQLite Durable Object rows written draw on the same
# 100,000-a-day allowance as D1's rows written, or on one of their own?
#
# It deploys worker.js (one SQLite Durable Object, one fresh D1 database) to the Cloudflare account
# wrangler is logged in to, checks D1 takes a write, writes past 100,000 rows into the object, then
# once a minute writes one row to each until the object refuses. The answer is D1's at that moment:
#
#   shared        the object refused and so did D1: one pool
#   separate      the object refused and D1 still wrote: two pools
#   inconclusive  the object never refused within --wait-minutes, or D1 refused before the object
#                 was spent (the account's D1 was not idle today)
#
# It deletes the Worker and the database on exit. Run it on a Workers Free account whose D1 has
# written nothing today (UTC): a fresh account is the clean case. It spends that account's whole
# Durable Object write allowance until 00:00 UTC, and D1's too when the pool is shared, so never
# run it on an account serving a relay.
#
#   probes/free-write-pool/run.sh                    run it, print the verdict
#   probes/free-write-pool/run.sh --record           also post the verdict on DIG-271 (dev issues comment)
#   probes/free-write-pool/run.sh --url URL          drive a Worker already serving at URL (wrangler dev
#                                                    for a local try); deploys and deletes nothing
#   --target N (101000)  --chunk N (2000)  --wait-minutes N (30)
#
# CLOUDFLARE_ACCOUNT_ID picks the account when the login holds several.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
relay="$(cd "$here/../../relay" && pwd)"
url=""
record=0
target=101000
chunk=2000
wait_minutes=30

while [ $# -gt 0 ]; do
  case "$1" in
    --url) url="$2"; shift 2 ;;
    --record) record=1; shift ;;
    --target) target="$2"; shift 2 ;;
    --chunk) chunk="$2"; shift 2 ;;
    --wait-minutes) wait_minutes="$2"; shift 2 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "run.sh: unknown argument $1 (see --help)" >&2; exit 2 ;;
  esac
done

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }

# post PATH: the route's JSON, or {"ok":false,"error":"..."} when the Worker did not answer JSON.
post() {
  local body
  body="$(curl -sS -X POST "$url$1" 2>&1 || true)"
  node -e '
    const s = process.argv[1];
    try { const j = JSON.parse(s); if (typeof j.ok !== "boolean") throw 0; console.log(JSON.stringify(j)); }
    catch { console.log(JSON.stringify({ ok: false, error: "not JSON: " + s.slice(0, 300) })); }
  ' "$body"
}
field() { node -e 'const j = JSON.parse(process.argv[1]); const v = j[process.argv[2]]; console.log(v === undefined ? "" : v)' "$1" "$2"; }

name=""
db=""
work=""
wrangler=""
cleanup() {
  [ -n "$name" ] || return 0
  log "deleting Worker $name and D1 database $db"
  (cd "$work" && "$wrangler" delete --name "$name" --force >/dev/null 2>&1) || log "could not delete Worker $name: delete it in the dashboard"
  (cd "$work" && "$wrangler" d1 delete "$db" --skip-confirmation >/dev/null 2>&1) || log "could not delete D1 database $db: delete it in the dashboard"
}

deploy() {
  [ -x "$relay/node_modules/.bin/wrangler" ] || (cd "$relay" && npm ci --silent)
  wrangler="$relay/node_modules/.bin/wrangler"
  "$wrangler" whoami
  work="$(mktemp -d "${TMPDIR:-/tmp}/free-write-pool.XXXXXX")"
  local suffix; suffix="$(node -e 'console.log(require("node:crypto").randomBytes(3).toString("hex"))')"
  name="dig320-pool-$suffix"
  db="$name"
  trap cleanup EXIT
  cp "$here/worker.js" "$work/worker.js"
  local created id
  created="$(cd "$work" && "$wrangler" d1 create "$db" 2>&1)" || { echo "$created" >&2; exit 1; }
  id="$(printf '%s\n' "$created" | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  [ -n "$id" ] || { echo "$created" >&2; echo "run.sh: no database id in wrangler's answer" >&2; exit 1; }
  cat > "$work/wrangler.jsonc" <<JSON
{
  "name": "$name",
  "main": "worker.js",
  "compatibility_date": "2026-11-01",
  "workers_dev": true,
  "durable_objects": { "bindings": [{ "name": "POOL", "class_name": "Pool" }] },
  "migrations": [{ "tag": "v1", "new_sqlite_classes": ["Pool"] }],
  "d1_databases": [{ "binding": "DB", "database_name": "$db", "database_id": "$id" }]
}
JSON
  local out
  out="$(cd "$work" && "$wrangler" deploy 2>&1)" || { echo "$out" >&2; exit 1; }
  url="$(printf '%s\n' "$out" | grep -Eo 'https://[^ ]+\.workers\.dev' | head -1)"
  [ -n "$url" ] || { echo "$out" >&2; echo "run.sh: no workers.dev URL in wrangler's answer (register a workers.dev subdomain on the account)" >&2; exit 1; }
  log "deployed $name at $url with D1 $db ($id)"
}

[ -n "$url" ] || deploy

# D1 must take a write before the object spends anything, or the account's D1 is not idle.
d1=""
for _ in $(seq 1 12); do
  d1="$(post /d1/write)"
  [ "$(field "$d1" ok)" = true ] && break
  case "$(field "$d1" error)" in "not JSON"*) sleep 5 ;; *) break ;; esac
done
if [ "$(field "$d1" ok)" != true ]; then
  echo "DIG-320 verdict: inconclusive. D1 refused before the object wrote anything: $(field "$d1" error)"
  exit 3
fi
log "D1 baseline write ok"

total=0
do_error=""
while [ "$total" -lt "$target" ]; do
  r="$(post "/do/write?n=$chunk")"
  if [ "$(field "$r" ok)" = true ]; then
    total=$((total + $(field "$r" rowsWritten)))
    continue
  fi
  e="$(field "$r" error)"
  if [ "$chunk" -gt 100 ] && printf '%s' "$e" | grep -qiE 'cpu|exceeded resources|time limit|not JSON'; then
    chunk=$((chunk / 2)); log "the object refused a chunk ($e); chunk now $chunk"; continue
  fi
  do_error="$e"; break
done
log "the object wrote $total rows${do_error:+ and then refused: $do_error}"

d1_after=""
for minute in $(seq 0 "$wait_minutes"); do
  [ "$minute" -eq 0 ] || sleep 60
  if [ -z "$do_error" ]; then
    r="$(post '/do/write?n=1')"
    [ "$(field "$r" ok)" = true ] && total=$((total + 1)) || do_error="$(field "$r" error)"
  fi
  d1_after="$(post /d1/write)"
  log "minute $minute: object ${do_error:+refused}${do_error:-writes}; D1 $([ "$(field "$d1_after" ok)" = true ] && echo writes || echo "refused: $(field "$d1_after" error)")"
  [ -z "$do_error" ] || break
done

if [ -z "$do_error" ]; then
  verdict="inconclusive. The object wrote $total rows today and did not refuse within $wait_minutes minutes, so Free enforcement did not show; D1 $([ "$(field "$d1_after" ok)" = true ] && echo "still wrote" || echo "refused: $(field "$d1_after" error)")."
elif [ "$(field "$d1_after" ok)" = true ]; then
  verdict="separate. On the Workers Free plan a SQLite Durable Object's rows written draw on their own daily allowance: after the object wrote $total rows it refused (\"$do_error\") while D1 on the same account still wrote."
else
  verdict="shared. On the Workers Free plan SQLite Durable Object rows written and D1 rows written draw on one daily allowance: after the object wrote $total rows it refused (\"$do_error\") and D1 on the same account refused too (\"$(field "$d1_after" error)\")."
fi
echo "DIG-320 verdict: $verdict"
if [ "$record" -eq 1 ]; then
  dev issues comment DIG-271 --comment "DIG-320 measured on a Workers Free account ($(date -u +%Y-%m-%d)), probes/free-write-pool/run.sh: Durable Object vs D1 Free write pool is $verdict"
  dev issues comment DIG-320 --comment "Recorded on DIG-271: $verdict"
fi
