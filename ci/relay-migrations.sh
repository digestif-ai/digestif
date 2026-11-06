#!/usr/bin/env bash
#
# Refuses a relay migration a relay release may not carry (docs/releases.md, Relay releases). A
# rollback replaces the Worker and never the schema, so every migration the relay line has not yet
# released must be ADDITIVE: no DROP, no RENAME (an `ALTER TABLE ... DROP COLUMN` is a DROP). And a
# migration a relay release already carried is applied on a live database and recorded in its
# d1_migrations table, so it is never changed or removed afterwards.
#
#   ci/relay-migrations.sh [--since REF]
#
# Reads the working tree's relay/migrations/*.sql against REF, by default the newest relay-v* tag;
# with no relay tag yet every migration is new. Exits 0 when every new migration is additive and no
# released one moved, 1 naming each refusal, 2 on a usage error. Run by the relay release workflow
# (.github/workflows/relay-release.yml) against the version before it, and by ci/build.slow.sh on every
# change, so a pull request learns of it before a tag does.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir=relay/migrations

usage() {
  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

since=""
since_given=false
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || usage; since="$2"; since_given=true; shift 2 ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done

valid_version() {
  [[ "$1" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]]
}

if ! $since_given; then
  while IFS= read -r t; do
    if valid_version "${t#relay-v}"; then
      since="$t"
      break
    fi
  done < <(git -C "$root" tag --list 'relay-v[0-9]*' --sort=-v:refname)
fi
if [ -n "$since" ]; then
  git -C "$root" rev-parse --verify --quiet "$since^{commit}" >/dev/null ||
    { echo "relay-migrations.sh: $since names no commit" >&2; exit 2; }
fi

# A migration's SQL with its -- comments removed, upper-cased, so a word in a comment refuses nothing.
statements() {
  sed -e 's/--.*$//' "$1" | tr '[:lower:]' '[:upper:]'
}

refused=0
refuse() {
  echo "relay-migrations.sh: $*" >&2
  refused=1
}

released=()
if [ -n "$since" ]; then
  while IFS= read -r f; do released+=("$f"); done < <(git -C "$root" ls-tree --name-only "$since" -- "$dir/" | grep '\.sql$' || true)
fi

is_released() {
  local f
  for f in "${released[@]+"${released[@]}"}"; do [ "$f" = "$1" ] && return 0; done
  return 1
}

# A migration a release carried, changed or gone.
for f in "${released[@]+"${released[@]}"}"; do
  if [ ! -f "$root/$f" ]; then
    refuse "$f was released in $since and is gone; a released migration is never removed"
  elif ! git -C "$root" show "$since:$f" | cmp -s - "$root/$f"; then
    refuse "$f was released in $since and has changed; a released migration is never edited, so add a new one"
  fi
done

new=0
for path in "$root/$dir"/*.sql; do
  [ -e "$path" ] || continue
  f="$dir/$(basename "$path")"
  is_released "$f" && continue
  new=$((new + 1))
  words="$(statements "$path" | grep -oE '\b(DROP|RENAME)\b' | sort -u | tr '\n' ' ' || true)"
  if [ -n "$words" ]; then
    refuse "$f is not additive (${words% }): a relay rollback replaces the Worker and never the schema, so a relay migration only adds"
  fi
done

if [ "$refused" -ne 0 ]; then
  exit 1
fi
echo "relay-migrations.sh: $new new migration(s) since ${since:-the start of the relay line}, every one additive" >&2
