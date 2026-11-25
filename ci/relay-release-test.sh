#!/usr/bin/env bash
#
# Tests the relay line's tagging and its migration check against a scratch repository whose origin
# is a local bare repository: `ci/release.sh relay changed` and `relay tag` (the first relay tag is
# relay-v0.1.0, a change to a relay release path cuts the next patch, a change elsewhere or only in
# wrangler.jsonc's environments cuts none, a tip already tagged is that tag, and a node tag is never
# read as a relay tag), the order between relay releases (`relay order` and what `relay tag` does
# with it: a Durable Object migration step is released alone and deployed before anything after it,
# and a commit another one needs is served by every relay first), and ci/relay-migrations.sh (a new
# migration with DROP or RENAME is refused, a released one is never edited or removed, a word in a
# comment refuses nothing). ci/build.slow.sh runs it; it needs git, jq and curl, and no network.

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

# The order between relay releases. Two relays, each a directory curl reads as file://.
serve() {
  mkdir -p "$tmp/$1/v0"
  printf '{"relay_version":"%s"}' "$2" >"$tmp/$1/v0/version"
}
order_file() {
  printf '# the relays\nrelay file://%s\nrelay file://%s/\nserved %s\n' "$tmp/one" "$tmp/two" "$1" >"$repo/ci/relay-release-order"
}
head_sha() { git -C "$repo" rev-parse HEAD; }
tag_sha() { git -C "$repo" rev-parse "refs/tags/$1^{commit}"; }
# `relay tag` at the tip must print $1 and exit $2; $3 is the case.
tags() {
  local code=0 out
  out="$(release relay tag --sha "$(head_sha)")" || code=$?
  expect "$2" "$code" "$3: exit ($(cat "$tmp/stderr"))"
  expect "$1" "$out" "$3"
}
# `relay order` at the tip must exit $1 and say $2; $3 is the case.
orders() {
  local code=0
  release relay order || code=$?
  expect "$1" "$code" "$3: exit ($(cat "$tmp/stderr"))"
  grep -qF -- "$2" "$tmp/stderr" || fail "$3: does not say '$2': $(cat "$tmp/stderr")"
}
worker() { echo "// $1" >>"$repo/relay/src/index.ts" && commit "$1"; }

# Nothing waits: no relay is asked (neither directory exists yet).
order_file 0.1.2
commit "the order"
orders 0 "keeps the order" "an order nothing waits on"
tags unchanged 0 "the order file cuts no release"

# The release that broke DIG-271's order: a migration step, the routes that use it and their
# removal, with no release cut between. The step is held, and what came before it is released.
serve one 0.1.2
serve two 0.1.2
worker "before the class"
before="$(head_sha)"
sed -i.bak 's#"compatibility_date"#"migrations": [{ "tag": "v1", "new_sqlite_classes": ["Store"] }],\n  "compatibility_date"#' "$repo/relay/wrangler.jsonc"
rm "$repo/relay/wrangler.jsonc.bak"
echo 'export class Store {}' >"$repo/relay/src/store.ts"
commit "the class"
class="$(head_sha)"
worker "the routes"
orders 3 "step v1 is released alone" "a step beside other relay code"
tags "" 3 "the commits before a step"
expect "$before" "$(tag_sha relay-v0.1.3)" "what is released before a step"
tags "" 3 "a step while the release before it is not served"
expect 0 "$(git -C "$repo" tag --list relay-v0.1.4 | wc -l | tr -d ' ')" "tags while that release is not served"
# Both relays serve it: the step is released alone.
serve one 0.1.3
tags "" 3 "one relay of two serves the release before a step"
serve two 0.1.3
tags "" 3 "the step alone"
expect "$class" "$(tag_sha relay-v0.1.4)" "the step's release"
tags "" 3 "the routes while a relay has not applied the step"
grep -qF 'step v1 is released alone' "$tmp/stderr" || fail "the hold does not name the step: $(cat "$tmp/stderr")"
code=0
(cd "$repo" && git checkout --quiet "$class" && ci/release.sh relay order) 2>"$tmp/stderr" || code=$?
git -C "$repo" checkout --quiet main
expect 0 "$code" "the step's own tag keeps the order"
rm "$tmp/two/v0/version"
tags "" 3 "a relay that does not answer"
grep -qF "could not read the relay release file://$tmp/two" "$tmp/stderr" || fail "the silent relay is not named: $(cat "$tmp/stderr")"
printf '{}' >"$tmp/two/v0/version"
tags "" 3 "a relay that reports no version"
serve one 0.1.4
serve two 0.1.4
tags relay-v0.1.5 0 "the routes once every relay applied the step"

# A step whose one commit also adds a D1 migration.
serve one 0.1.5
serve two 0.1.5
sed -i.bak 's#\["Store"\] }#["Store"] }, { "tag": "v2", "new_sqlite_classes": ["Other"] }#' "$repo/relay/wrangler.jsonc"
rm "$repo/relay/wrangler.jsonc.bak"
printf 'CREATE TABLE y (id TEXT);\n' >"$repo/relay/migrations/0002_y.sql"
commit "a second class and a table"
orders 3 "its commit also changes relay/migrations/0002_y.sql" "a step beside a D1 migration"
tags "" 3 "a step beside a D1 migration is not tagged"
git -C "$repo" revert --no-edit HEAD >/dev/null
git -C "$repo" push --quiet origin HEAD:main
expect unchanged "$(release relay changed)" "the second class reverted"

# A commit that needs an earlier one live on the relays.
order_file 0.1.5
commit "every relay serves 0.1.5"
worker "the new address"
address="$(head_sha)"
echo "needs $address the old address goes" >>"$repo/ci/relay-release-order"
worker "the old address goes"
orders 3 "it needs $address live on every relay first" "a needed commit not released yet"
tags "" 3 "a commit whose need is not released"
expect "$address" "$(tag_sha relay-v0.1.6)" "the needed commit's own release"
serve one 0.1.6
tags "" 3 "a need one relay of two does not serve"
serve two 0.1.6
tags relay-v0.1.7 0 "a need every relay serves"

# A file that says nothing readable refuses, rather than holding nothing.
sed -i.bak "s/^needs .*/needs ${address%????}/" "$repo/ci/relay-release-order" && rm "$repo/ci/relay-release-order.bak"
commit "a short id"
orders 1 "is no full commit id" "a short commit id"
order_file 0.1.7
echo "needs 0123456789012345678901234567890123456789" >>"$repo/ci/relay-release-order"
commit "an unknown id"
orders 1 "which is no commit before it" "an unknown commit"
order_file 9.9.9
commit "an unknown release"
orders 1 "there is no tag relay-v9.9.9" "an unknown served release"
git -C "$repo" rm --quiet ci/relay-release-order
commit "no order"
orders 0 "keeps the order" "no order file"

# The repository's own file: every line an entry, every needed commit one of this history.
sed -e '/^needs /d' -e 's/^served .*/served 0.1.7/' "$root/ci/relay-release-order" >"$repo/ci/relay-release-order"
commit "the repository's own order"
orders 0 "keeps the order" "the repository's own order file"
while read -r need; do
  git -C "$root" merge-base --is-ancestor "$need" HEAD ||
    fail "ci/relay-release-order needs $need, which is no commit of this history"
done < <(sed -n 's/^needs \([^ ]*\).*/\1/p' "$root/ci/relay-release-order")

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
grep -qF '0001_init.sql was released in relay-v0.1.7' "$tmp/stderr" || fail "the edit is not named: $(cat "$tmp/stderr")"
git -C "$repo" checkout --quiet -- relay/migrations/0001_init.sql
migrations --since "$(git -C "$repo" rev-list --max-parents=0 HEAD)" || fail "--since: $(cat "$tmp/stderr")"
rm "$repo/relay/migrations/0001_init.sql"
if migrations; then fail "a removed released migration was not refused"; fi

echo "relay-release-test.sh: ok"
