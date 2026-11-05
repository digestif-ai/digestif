#!/usr/bin/env bash
#
# Tests the relay line's tagging and its migration check against a scratch repository whose origin
# is a local bare repository: `ci/release.sh relay changed` and `relay tag` (the first relay tag is
# relay-v0.1.0, a change to a relay release path cuts the next patch, a change elsewhere or only in
# wrangler.jsonc's environments cuts none, a tip already tagged is that tag, and a node tag is never
# read as a relay tag), and ci/relay-migrations.sh (a new migration with DROP or RENAME is refused,
# a released one is never edited or removed, a word in a comment refuses nothing). ci/build.sh runs
# it; it needs git and no network.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "relay-release-test.sh: $*" >&2
  exit 1
}
expect() {
  local want="$1" got="$2" what="$3"
  [ "$got" = "$want" ] || fail "$what: expected '$want', got '$got'"
}

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

git init --quiet --bare --initial-branch=main "$tmp/origin.git"
repo="$tmp/repo"
git init --quiet --initial-branch=main "$repo"
git -C "$repo" remote add origin "$tmp/origin.git"
mkdir -p "$repo/ci" "$repo/relay/src" "$repo/relay/migrations" "$repo/docs"
cp "$root/ci/release.sh" "$root/ci/relay-migrations.sh" "$root/ci/relay-release-paths" "$root/ci/release-paths" "$repo/ci/"
echo 'export default {};' >"$repo/relay/src/index.ts"
printf -- '-- the first table; nothing is dropped here\nCREATE TABLE a (id TEXT);\n' >"$repo/relay/migrations/0001_init.sql"
cat >"$repo/relay/wrangler.jsonc" <<'EOF'
{
  "name": "digestif-relay",
  "compatibility_date": "2026-08-01",
  "env": {
    // one deployment
    "dinners": {
      "vars": { "RELAY_URL": "https://a.example" }
    }
  }
}
EOF
echo docs >"$repo/docs/readme.md"

commit() {
  git -C "$repo" add --all
  git -C "$repo" commit --quiet -m "$1"
  git -C "$repo" push --quiet origin HEAD:main
}
release() { "$repo/ci/release.sh" "$@" 2>"$tmp/stderr"; }

commit "the first relay"

# No relay tag yet: changed, and the first tag is relay-v0.1.0. A node tag on the tip is not one.
git -C "$repo" tag v0.4.0 && git -C "$repo" push --quiet origin v0.4.0
expect changed "$(release relay changed)" "no relay tag yet"
expect relay-v0.1.0 "$(release relay tag)" "the first relay tag"
git -C "$tmp/origin.git" rev-parse --verify --quiet refs/tags/relay-v0.1.0 >/dev/null || fail "relay-v0.1.0 was not pushed"
expect relay-v0.1.0 "$(release relay tag)" "a tip already relay-tagged"
expect unchanged "$(release relay changed)" "the tagged tip"

# A change outside the relay paths cuts nothing.
echo more >>"$repo/docs/readme.md"
commit "docs only"
expect unchanged "$(release relay changed)" "a docs change"
expect unchanged "$(release relay tag)" "relay tag after a docs change"

# A change inside wrangler.jsonc's environments cuts nothing; one at its top level does.
sed -i.bak 's#https://a.example#https://b.example#' "$repo/relay/wrangler.jsonc" && rm "$repo/relay/wrangler.jsonc.bak"
commit "one deployment's url"
expect unchanged "$(release relay changed)" "an environment-only wrangler.jsonc change"
sed -i.bak 's#2026-08-01#2026-09-01#' "$repo/relay/wrangler.jsonc" && rm "$repo/relay/wrangler.jsonc.bak"
commit "a new compatibility date"
expect changed "$(release relay changed)" "a top-level wrangler.jsonc change"
grep -qF 'relay/wrangler.jsonc' "$tmp/stderr" || fail "the moved path is not named on stderr"
expect relay-v0.1.1 "$(release relay tag)" "the next relay patch"

# A change to the Worker cuts the next patch; --sha naming another commit tags nothing.
echo '// more' >>"$repo/relay/src/index.ts"
commit "the Worker"
code=0
release relay tag --sha 0000000 >/dev/null || code=$?
expect 75 "$code" "relay tag with main moved under --sha"
expect relay-v0.1.2 "$(release relay tag --sha "$(git -C "$repo" rev-parse HEAD)")" "relay tag at --sha"
expect v0.4.0 "$(git -C "$repo" tag --list 'v*')" "the node tags"

# Many tags: the newest is read from the whole list, so nothing is left writing into a reader that
# took its line and stopped. The list is far larger than a pipe holds, which made a pipe into
# `head -1` fail under pipefail on every run rather than on some. The answers are the ones before.
node_word="$(release changed)" || fail "release changed: $(cat "$tmp/stderr")"
tip="$(git -C "$repo" rev-parse HEAD)"
first="$(git -C "$repo" rev-list --max-parents=0 HEAD)"
for i in $(seq 1 8000); do
  echo "create refs/tags/v0.0.$i $first"
  echo "create refs/tags/v0.0.$i-x $first"
  echo "create refs/tags/relay-v0.0.$i $tip"
done | git -C "$repo" update-ref --stdin
expect "$node_word" "$(release changed)" "release changed among many tags"
expect unchanged "$(release relay changed)" "relay changed among many tags"
expect relay-v0.1.2 "$(release relay tag)" "relay tag among many tags"
git -C "$repo" tag --list 'v0.0.*' 'relay-v0.0.*' | while IFS= read -r t; do echo "delete refs/tags/$t"; done |
  git -C "$repo" update-ref --stdin

# The migration check.
migrations() { (cd "$repo" && ci/relay-migrations.sh "$@") 2>"$tmp/stderr"; }
migrations || fail "an additive line was refused: $(cat "$tmp/stderr")"
printf 'ALTER TABLE a ADD COLUMN b TEXT;\n' >"$repo/relay/migrations/0002_add.sql"
migrations || fail "an additive migration was refused: $(cat "$tmp/stderr")"
printf 'ALTER TABLE a DROP COLUMN b;\n' >"$repo/relay/migrations/0003_drop.sql"
if migrations; then fail "a DROP was not refused"; fi
grep -qF '0003_drop.sql is not additive' "$tmp/stderr" || fail "the DROP is not named: $(cat "$tmp/stderr")"
printf 'alter table a rename column b to c;\n' >"$repo/relay/migrations/0003_drop.sql"
if migrations; then fail "a RENAME was not refused"; fi
rm "$repo/relay/migrations/0003_drop.sql"
echo 'CREATE TABLE z (id TEXT);' >>"$repo/relay/migrations/0001_init.sql"
if migrations; then fail "an edit of a released migration was not refused"; fi
grep -qF '0001_init.sql was released in relay-v0.1.2' "$tmp/stderr" || fail "the edit is not named: $(cat "$tmp/stderr")"
git -C "$repo" checkout --quiet -- relay/migrations/0001_init.sql
migrations --since "$(git -C "$repo" rev-list --max-parents=0 HEAD)" || fail "--since: $(cat "$tmp/stderr")"
rm "$repo/relay/migrations/0001_init.sql"
if migrations; then fail "a removed released migration was not refused"; fi

echo "relay-release-test.sh: ok"
