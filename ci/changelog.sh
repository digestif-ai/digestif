#!/usr/bin/env bash
#
# Prints the changelog.json a release carries (docs/releases.md, What's new): every version up to
# and including VERSION, newest first, each with its released_at and entries, the shape
# ui/src/lib/changelog.ts reads. The node serves it at /changelog.json with the rest of its UI, so a
# member reads what each release changed offline and without an idempotent login (DIG-135).
#
#   ci/changelog.sh VERSION [LEDGER]
#
# The versions are this checkout's release tags (v<MAJOR.MINOR.PATCH>) no newer than VERSION, and
# VERSION itself when no tag names it yet; 0.0.0, a build that is no release, takes every tag.
#
# LEDGER, when given, is the Digestif product's entries of the changelog idempotent writes: a JSON
# array of releases as `GET /dev/changelog/releases?repo=digestif-ai/digestif&product=digestif`
# answers it, each with its version, released_at, notes_built_at and entries (summary, category).
# The Digestif rollout's job reads it and hands it to `ci/release.sh changelog`, which leaves it on
# the channel branch as changelog/<commit>.json for the Release workflow to pass here.
#
# A version whose notes the ledger holds (notes_built_at set) carries those entries, none when its
# commits were all noise. Every other version carries its commit titles, the ones the manifest's
# notes hold, as entries of category other: notes are written after a version is released, so a
# release always carries its own version this way until the next release brings its entries, and
# every version does when there is no ledger. A title loses its issue key and its pull request
# number, and a merge build's title (build <id>, train of ...) names no change and is left out.
#
# Exits 0 on success, 1 on a failure, 2 on a usage error. Needs git and jq.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() {
  echo "changelog.sh: $*" >&2
  exit 1
}

[ $# -ge 1 ] && [ $# -le 2 ] || {
  echo "usage: ci/changelog.sh VERSION [LEDGER]" >&2
  exit 2
}
version="${1#v}"
ledger="${2:-}"

valid_version() {
  [[ "$1" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]]
}
valid_version "$version" || die "$version is not MAJOR.MINOR.PATCH"

# Negative, zero or positive as $1 is older than, the same as or newer than $2.
compare() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$1"
  IFS=. read -r b1 b2 b3 <<<"$2"
  if [ "$a1" != "$b1" ]; then echo $((a1 - b1)); elif [ "$a2" != "$b2" ]; then echo $((a2 - b2)); else echo $((a3 - b3)); fi
}

if [ -n "$ledger" ]; then
  [ -f "$ledger" ] || die "no ledger at $ledger"
  jq -e 'type == "array"' "$ledger" >/dev/null 2>&1 || die "$ledger is not a JSON array of releases"
else
  ledger_empty="$(mktemp)"
  trap 'rm -f "$ledger_empty"' EXIT
  echo '[]' >"$ledger_empty"
  ledger="$ledger_empty"
fi

# The versions, oldest first, each with the ref its commits end at.
versions=()
refs=()
tags="$(git -C "$root" -c safe.directory='*' tag --list 'v[0-9]*' --sort=v:refname)"
while IFS= read -r t; do
  [ -n "$t" ] || continue
  v="${t#v}"
  valid_version "$v" || continue
  if [ "$version" != 0.0.0 ] && [ "$(compare "$v" "$version")" -gt 0 ]; then
    continue
  fi
  versions+=("$v")
  refs+=("refs/tags/$t")
done <<<"$tags"
if [ "$version" != 0.0.0 ]; then
  last=""
  [ "${#versions[@]}" -eq 0 ] || last="${versions[${#versions[@]}-1]}"
  if [ "$last" != "$version" ]; then
    versions+=("$version")
    refs+=(HEAD)
  fi
fi

# One JSON line per version: its version, when its commit was made (UTC), and its commit titles.
from_git() {
  local i prev range released
  [ "${#versions[@]}" -gt 0 ] || return 0
  for i in "${!versions[@]}"; do
    if [ "$i" -gt 0 ]; then
      prev="${refs[$((i - 1))]}"
      range="$prev..${refs[$i]}"
    else
      range="${refs[$i]}"
    fi
    released=""
    [ "${refs[$i]}" = HEAD ] || released="$(TZ=UTC git -C "$root" -c safe.directory='*' log -1 --format=%cd --date=iso-strict-local "${refs[$i]}")"
    git -C "$root" -c safe.directory='*' log --no-merges --format=%s "$range" |
      jq -R -s -c --arg version "${versions[$i]}" --arg released "$released" '
        {
          version: $version,
          released_at: (if $released == "" then null else $released end),
          titles: [
            split("\n")[]
            | sub("^[A-Z][A-Z0-9]*-[0-9]+: "; "")
            | sub(" \\(#[0-9]+\\)$"; "")
            | select(. != "" and (test("^build [0-9a-f]+, train of ") | not))
          ]
        }'
  done
}

from_git | jq -s --slurpfile ledger "$ledger" '
  ($ledger[0] | map(select(type == "object" and (.version | type) == "string")) | map({key: .version, value: .}) | from_entries) as $notes
  | def category: if . == "feature" or . == "improvement" or . == "fix" then . else "other" end;
  {
    product: "digestif",
    versions: (
      reverse
      | map(
          . as $v
          | ($notes[$v.version] // null) as $n
          | {
              version: $v.version,
              released_at: ($n.released_at // $v.released_at),
              entries: (
                if $n != null and $n.notes_built_at != null then
                  [($n.entries // [])[] | select((.summary | type) == "string" and .summary != "")
                    | {summary: .summary, category: (.category | category)}]
                else
                  [$v.titles[] | {summary: ., category: "other"}]
                end
              )
            }
          | if .released_at == null then del(.released_at) else . end
        )
    )
  }'
