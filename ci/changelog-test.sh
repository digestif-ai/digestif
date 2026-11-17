#!/usr/bin/env bash
#
# Tests ci/changelog.sh against a fixture repository of four tags: every version up to the one
# built, newest first; a version the ledger holds notes for carries those entries (a category the UI
# does not know read as other, an entry without a summary left out), one the ledger holds with its
# notes not built yet and one it lacks carry their commit titles without the issue key, the pull
# request number or a merge build's title; a ledger version with notes but no entries carries none;
# a version not tagged yet carries the commits since the newest tag; 0.0.0 carries every tag; a
# ledger that is not an array and a version that is not MAJOR.MINOR.PATCH are refused. Then
# `ci/release.sh changelog` against a bare origin: the ledger lands on the channel branch keyed by
# the full commit, and a commit off main is refused. ci/build.slow.sh runs it; it needs bash, git
# and jq and no network.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "changelog-test.sh: $*" >&2
  exit 1
}

# The fixture: ci/changelog.sh in a repository of its own, so the tags are the fixture's.
repo="$tmp/repo"
mkdir -p "$repo/ci"
cp "$root/ci/changelog.sh" "$repo/ci/changelog.sh"
g() { git -C "$repo" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
g init --quiet
commit() { g commit --quiet --allow-empty -m "$1"; }
commit "Initial commit"
commit "DIG-1: The first page (#1)"
g tag v0.1.0
commit "DIG-2: Search (#2)"
commit "build 5e3f2a02, train of DIG-3 digestif#3, DIG-4 digestif#4"
g tag v0.1.1
commit "DIG-5: Faster sync (#5)"
g tag v0.1.2
commit "DIG-6: Replies (#6)"
g tag v0.1.3
g tag v0.1.3-rc1 HEAD
commit "DIG-7: Not tagged yet (#7)"

cat >"$tmp/ledger.json" <<'JSON'
[
  {"repo": "digestif-ai/digestif", "version": "0.1.0", "released_at": "2026-01-01T00:00:00Z",
   "notes_built_at": "2026-01-02T00:00:00Z",
   "entries": [
     {"summary": "A first page", "category": "feature", "pr_number": 1},
     {"summary": "Unknown kind", "category": "chore"},
     {"summary": "", "category": "fix"}
   ]},
  {"repo": "digestif-ai/digestif", "version": "0.1.1", "released_at": "2026-01-03T00:00:00Z",
   "notes_built_at": "2026-01-04T00:00:00Z", "entries": []},
  {"repo": "digestif-ai/digestif", "version": "0.1.2", "released_at": "2026-01-05T00:00:00Z",
   "notes_built_at": null, "entries": []}
]
JSON

run() { bash "$repo/ci/changelog.sh" "$@"; }
expect() {
  local what="$1" got="$2" want="$3"
  [ "$got" = "$want" ] || fail "$what: got $got, want $want"
}

out="$(run 0.1.2 "$tmp/ledger.json")"
expect "the versions up to 0.1.2, newest first" "$(jq -c '[.versions[].version]' <<<"$out")" '["0.1.2","0.1.1","0.1.0"]'
expect "the product" "$(jq -r .product <<<"$out")" digestif
expect "0.1.0's ledger entries" "$(jq -c '.versions[2].entries' <<<"$out")" \
  '[{"summary":"A first page","category":"feature"},{"summary":"Unknown kind","category":"other"}]'
expect "0.1.0's ledger released_at" "$(jq -r '.versions[2].released_at' <<<"$out")" 2026-01-01T00:00:00Z
expect "0.1.1's built notes with no entries" "$(jq -c '.versions[1].entries' <<<"$out")" '[]'
expect "0.1.2's commit titles while its notes are not built" "$(jq -c '.versions[0].entries' <<<"$out")" \
  '[{"summary":"Faster sync","category":"other"}]'
expect "0.1.2's ledger released_at" "$(jq -r '.versions[0].released_at' <<<"$out")" 2026-01-05T00:00:00Z

out="$(run 0.1.3 "$tmp/ledger.json")"
expect "0.1.3, which the ledger lacks, by its titles" "$(jq -c '.versions[0]|[.version,.entries]' <<<"$out")" \
  '["0.1.3",[{"summary":"Replies","category":"other"}]]'
jq -e '.versions[0].released_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' <<<"$out" >/dev/null ||
  fail "0.1.3's released_at is not its tag's commit time in UTC: $(jq -r '.versions[0].released_at' <<<"$out")"

out="$(run 0.1.1)"
expect "no ledger: every version by its titles, a merge build's left out" "$(jq -c '.versions' <<<"$out" | jq -c 'map([.version, [.entries[].summary]])')" \
  '[["0.1.1",["Search"]],["0.1.0",["The first page","Initial commit"]]]'

out="$(run 0.1.4)"
expect "a version not tagged yet carries the commits since the newest tag" "$(jq -c '.versions[0]' <<<"$out")" \
  '{"version":"0.1.4","entries":[{"summary":"Not tagged yet","category":"other"}]}'
expect "and every tag before it" "$(jq '.versions | length' <<<"$out")" 5

out="$(run 0.0.0)"
expect "0.0.0 carries every tag and nothing else" "$(jq -c '[.versions[].version]' <<<"$out")" '["0.1.3","0.1.2","0.1.1","0.1.0"]'

echo '{"versions": []}' >"$tmp/object.json"
if run 0.1.2 "$tmp/object.json" >/dev/null 2>&1; then fail "a ledger that is not an array was taken"; fi
if run 0.1 >/dev/null 2>&1; then fail "0.1 was taken as a version"; fi
if run 0.1.2 "$tmp/absent.json" >/dev/null 2>&1; then fail "an absent ledger was taken"; fi

# `ci/release.sh changelog` leaves the ledger on the channel branch of origin, keyed by the full
# commit, making the branch when origin has none, and refuses a commit that is not on main.
origin="$tmp/origin.git"
git init --quiet --bare "$origin"
g branch -M main
g remote add origin "$origin"
g push --quiet origin main
cp "$root/ci/release.sh" "$repo/ci/release.sh"
head_sha="$(g rev-parse HEAD)"
short="$(g rev-parse --short HEAD)"
rel() { GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com \
  bash "$repo/ci/release.sh" "$@"; }
said="$(rel changelog --sha "$short" --file "$tmp/ledger.json" 2>/dev/null)" || fail "release.sh changelog failed"
expect "release.sh changelog's answer" "$said" "changelog/$head_sha.json"
expect "the ledger on the channel branch" "$(git --git-dir="$origin" show "channel:changelog/$head_sha.json" | jq -c .)" \
  "$(jq -c . "$tmp/ledger.json")"
git --git-dir="$origin" show channel:index.json >/dev/null || fail "the channel branch made without its index.json"
g checkout --quiet -b side
commit "Not on main"
if rel changelog --sha "$(g rev-parse HEAD)" --file "$tmp/ledger.json" >/dev/null 2>&1; then
  fail "release.sh changelog took a commit that is not on main"
fi
g push --quiet origin side
if rel changelog --sha "$(g rev-parse HEAD)" --file "$tmp/ledger.json" >/dev/null 2>&1; then
  fail "release.sh changelog took a pushed commit that is not on main"
fi
if rel changelog --sha "$head_sha" --file "$tmp/object.json" >/dev/null 2>&1; then
  fail "release.sh changelog took a ledger that is not an array"
fi

echo "changelog-test.sh: ok"
