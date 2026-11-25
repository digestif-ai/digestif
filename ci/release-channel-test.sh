#!/usr/bin/env bash
#
# Tests what ci/release.sh writes to and reads from the channel (docs/releases.md, The channel)
# against a scratch repository whose origin is a local bare repository, with a gh that answers for a
# prerelease: `publish` lists a version in release/index.json on main by its release's urls, copies
# in the take-backs an older digestif-update wrote to the channel branch alone, lists it on the
# branch too only while no version the branch names that reads main is unrecalled, and trims the list to the seven newest with their recalls; `channel`
# and `feed` read main's list with the branch's take-backs; `build --changelog` writes the ledger as
# the message of an annotated tag; every commit it writes carries the release's own identity on a
# machine whose git has none. ci/build.slow.sh runs it; it needs git and jq and no network.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "release-channel-test.sh: $*" >&2
  exit 1
}
expect() {
  local want="$1" got="$2" what="$3"
  [ "$got" = "$want" ] || fail "$what: expected '$want', got '$got'"
}

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

# A gh that holds every version as a prerelease with its manifest and combined signatures.
bin="$tmp/bin"
mkdir -p "$bin"
export GH_LOG="$tmp/gh.log"
cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
case "$1 $2" in
  "release view")
    case "$*" in
      *isDraft,isPrerelease*) echo prerelease ;;
      *assets*) printf '%s\n' manifest.json manifest.sig.json digestif-linux-x86_64.tar.gz \
        digestif-update-linux-x86_64 ;;
      *) exit 1 ;;
    esac
    ;;
  "release download")
    tag="$3"
    dir=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --dir) dir="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    mkdir -p "$dir"
    printf '{"format":"digestif-release-v1","version":"%s"}\n' "${tag#v}" >"$dir/manifest.json"
    printf '{"signatures":[]}\n' >"$dir/manifest.sig.json"
    ;;
  "release edit") ;;
  *)
    echo "gh stub: unexpected $*" >&2
    exit 1
    ;;
esac
EOF
chmod 755 "$bin/gh"
export PATH="$bin:$PATH"

# The deployed relay as `publish` reads it: 0.1.75 proxies the release GitHub marks Latest, and
# 0.1.76 renders install.sh from the release list (its tag holds relay/src/install-render.ts).
relay_version() { printf '{"relay_version":"%s"}' "$1" >"$tmp/relay-version.json"; }
export DIGESTIF_RELAY_VERSION_URL="file://$tmp/relay-version.json"
relay_version 0.1.76

git init --quiet --bare --initial-branch=main "$tmp/origin.git"
repo="$tmp/repo"
git init --quiet --initial-branch=main "$repo"
git -C "$repo" remote add origin "$tmp/origin.git"
mkdir -p "$repo/ci"
cp "$root/ci/release.sh" "$root/ci/release-paths" "$root/ci/relay-release-paths" "$repo/ci/"
echo '{ "platforms": [ { "platform": "linux-x86_64", "runner": "ubuntu" } ] }' >"$repo/ci/platforms.json"

# A commit on main as fetched: publish commits to main as well.
commit() {
  git -C "$repo" fetch --quiet origin main 2>/dev/null || true
  git -C "$repo" merge --quiet --ff-only FETCH_HEAD 2>/dev/null || true
  git -C "$repo" add --all
  git -C "$repo" commit --quiet --allow-empty -m "$1"
  git -C "$repo" push --quiet origin HEAD:main
}
tag() {
  git -C "$repo" tag "$1"
  git -C "$repo" push --quiet origin "refs/tags/$1"
}
# Run as a machine whose git has no identity: no global or system config and no identity in the
# environment. The commits it writes carry the release's own identity all the same. ISS-102360
release() { (
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL
  "$repo/ci/release.sh" "$@" 2>>"$tmp/stderr"
); }
main_index() { git -C "$tmp/origin.git" show main:release/index.json; }
branch_index() { git -C "$tmp/origin.git" show channel:index.json; }
main_versions() { main_index | jq -r '[ .releases[].version ] | join(" ")'; }
branch_versions() { branch_index | jq -r '[ .releases[].version ] | join(" ")'; }

# A version from before the list moved to main: its tag holds no release/.
commit "the code"
tag v0.1.1

# The channel branch as an older digestif-update leaves it: 0.1.1 listed, a signer-set change and
# a revocation it wrote there alone.
branch="$tmp/branch"
git init --quiet --initial-branch=channel "$branch"
git -C "$branch" remote add origin "$tmp/origin.git"
mkdir -p "$branch/0.1.1" "$branch/signers" "$branch/revocations"
echo '{}' >"$branch/0.1.1/manifest.json"
echo '{"signatures":[]}' >"$branch/0.1.1/manifest.sig.json"
echo '{"format":"digestif-signers-v0","signers":[]}' >"$branch/signers/abc.json"
echo '{"signatures":[{"key":"ed25519:a","signature":"s1"}]}' >"$branch/signers/abc.sig.json"
echo '{"format":"digestif-revocation-v0"}' >"$branch/revocations/k.json"
echo '{"signatures":[]}' >"$branch/revocations/k.sig.json"
jq -n '{
  format: "digestif-feed-v0",
  releases: [ { version: "0.1.1", manifest: "0.1.1/manifest.json", signatures: "0.1.1/manifest.sig.json" } ],
  revocations: [ { document: "revocations/k.json", signatures: "revocations/k.sig.json" } ],
  signers: [ { document: "signers/abc.json", signatures: "signers/abc.sig.json" } ]
}' >"$branch/index.json"
branch_commit() {
  git -C "$branch" add --all
  git -C "$branch" commit --quiet -m "$1"
  git -C "$branch" push --quiet origin HEAD:channel
}
branch_commit "the channel"

# The version that reads main: its tree holds release/index.json, with no releases. The list is
# main's own with what it names taken out, since a real publish lists versions in it.
mkdir -p "$repo/release"
jq '.releases = [] | .revocations = [] | del(.recalls, .signers)' "$root/release/index.json" \
  >"$repo/release/index.json"
commit "the release list on main"
tag v0.2.0

tag relay-v0.1.75
mkdir -p "$repo/relay/src"
echo '// renders' >"$repo/relay/src/install-render.ts"
commit "the relay renders install.sh"
tag relay-v0.1.76

# While main's list names nothing, `channel` names nothing.
expect "" "$(release channel)" "an empty list"

# The first publish: main lists it by its release's urls with the branch's take-backs, and so does
# the branch, since no version it names reads main.
expect v0.2.0 "$(release publish --version 0.2.0)" "publish 0.2.0"
expect 0.2.0 "$(main_versions)" "main after 0.2.0"
expect "0.1.1 0.2.0" "$(branch_versions)" "the branch after 0.2.0"
expect "https://github.com/$tmp/origin/releases/download/v0.2.0/manifest.sig.json" \
  "$(main_index | jq -r '.releases[0].signatures')" "the list names the release's signatures"
expect signers/abc.json "$(main_index | jq -r '.signers[0].document')" "the branch's signer-set change"
expect revocations/k.json "$(main_index | jq -r '.revocations[0].document')" "the branch's revocation"
git -C "$tmp/origin.git" cat-file -e main:release/signers/abc.sig.json || fail "the signer-set change's signatures"
git -C "$tmp/origin.git" cat-file -e channel:0.2.0/manifest.sig.json || fail "the branch's copy of 0.2.0"
grep -q -- '--prerelease=false --latest=false' "$GH_LOG" || fail "publish marked a release Latest under a relay that renders"
for c in main channel; do
  expect "Digestif release <release@digestif.invalid>" \
    "$(git -C "$tmp/origin.git" log -1 --format='%an <%ae>' "$c")" "the author of $c"
  expect "Digestif release <release@digestif.invalid>" \
    "$(git -C "$tmp/origin.git" log -1 --format='%cn <%ce>' "$c")" "the committer of $c"
done
expect 0.2.0 "$(release channel)" "channel after 0.2.0"

# A second signature an older digestif-update added on the branch alone joins main's copy.
git -C "$branch" fetch --quiet origin
git -C "$branch" reset --quiet --hard origin/channel
echo '{"signatures":[{"key":"ed25519:a","signature":"s1"},{"key":"ed25519:b","signature":"s2"}]}' \
  >"$branch/signers/abc.sig.json"
branch_commit "the second signature"

commit "more code"
tag v0.2.1
# A deployed relay that proxies Latest has the version marked Latest. DIG-471
relay_version 0.1.75
release publish --version 0.2.1 >/dev/null
grep -q -- 'v0.2.1 .*--prerelease=false --latest=true' "$GH_LOG" || fail "publish left Latest behind a relay that proxies it"
expect "0.2.0 0.2.1" "$(main_versions)" "main after 0.2.1"
expect "0.1.1 0.2.0" "$(branch_versions)" "the branch after 0.2.1: it names 0.2.0, which reads main"
expect 2 "$(git -C "$tmp/origin.git" show main:release/signers/abc.sig.json | jq '.signatures | length')" \
  "both signatures of the signer-set change"

# And main alone again: the branch is left after the hop.
commit "even more code"
tag v0.2.2
# So has one whose version cannot be read.
rm "$tmp/relay-version.json"
release publish --version 0.2.2 >/dev/null
grep -q -- 'v0.2.2 .*--prerelease=false --latest=true' "$GH_LOG" || fail "publish left Latest behind an unread relay"
relay_version 0.1.76
expect "0.2.0 0.2.1 0.2.2" "$(main_versions)" "main after 0.2.2"
expect "0.1.1 0.2.0" "$(branch_versions)" "the branch is left after the hop"

# A recall of the hop version and of 0.2.1, written to the branch alone: the next publish lists on
# the branch again, and main takes the recalls of the versions it lists.
git -C "$branch" fetch --quiet origin
git -C "$branch" reset --quiet --hard origin/channel
mkdir -p "$branch/recalls"
for v in 0.2.0 0.2.1; do
  echo "{\"format\":\"digestif-recall-v0\",\"version\":\"$v\"}" >"$branch/recalls/$v.json"
  echo '{"signatures":[]}' >"$branch/recalls/$v.sig.json"
done
jq '.recalls = [ "0.2.0", "0.2.1" | { version: ., document: "recalls/\(.).json", signatures: "recalls/\(.).sig.json" } ]' \
  "$branch/index.json" >"$branch/index.json.next"
mv "$branch/index.json.next" "$branch/index.json"
branch_commit "recall the hop versions"

commit "a fix"
tag v0.2.3
release publish --version 0.2.3 >/dev/null
grep -q -- 'v0.2.3 .*--prerelease=false --latest=false' "$GH_LOG" || fail "publish marked 0.2.3 Latest under a relay that renders"
expect "0.1.1 0.2.0 0.2.3" "$(branch_versions)" "the branch after a recall of its hop version"
expect "0.2.0 0.2.1" "$(main_index | jq -r '[ .recalls[].version ] | join(" ")')" "main takes the recalls"

# Seven newest: the oldest leave the list, and their recalls with them.
for v in 0.2.4 0.2.5 0.2.6 0.2.7 0.2.8 0.2.9; do
  commit "code for $v"
  tag "v$v"
  release publish --version "$v" >/dev/null
done
expect "0.2.3 0.2.4 0.2.5 0.2.6 0.2.7 0.2.8 0.2.9" "$(main_versions)" "the seven newest"
expect 0 "$(main_index | jq '.recalls | length')" "a recall goes with its version"
git -C "$tmp/origin.git" cat-file -e main:release/recalls/0.2.0.json 2>/dev/null &&
  fail "a trimmed version's recall file stayed"
expect "0.1.1 0.2.0 0.2.3" "$(branch_versions)" "the branch names 0.2.3, which reads main"
# A trimmed recall is not brought back from the branch.
expect 0 "$(main_index | jq '.recalls | length')" "the branch's recall of a trimmed version"
expect 0.2.9 "$(release channel)" "channel names the newest"

# A publish runs again as a no-op.
release publish --version 0.2.9 >/dev/null
expect "0.2.3 0.2.4 0.2.5 0.2.6 0.2.7 0.2.8 0.2.9" "$(main_versions)" "publish again"

# The one-entry feed a test node takes 0.3.0 from: the channel's take-backs, and 0.3.0 alone.
release feed --version 0.3.0 --dir "$tmp/feed"
expect 0.3.0 "$(jq -r '[ .releases[].version ] | join(" ")' "$tmp/feed/index.json")" "the feed's one version"
expect signers/abc.json "$(jq -r '.signers[0].document' "$tmp/feed/index.json")" "the feed's signer-set chain"
[ -f "$tmp/feed/signers/abc.json" ] || fail "the feed lacks the signer-set change"

# build --changelog: the tag it mints carries the ledger, verbatim, as its message.
printf '[\n  {"version": "x"}\n]\n' >"$tmp/ledger.json"
commit "the next version"
expect v0.2.10 "$(release build --changelog "$tmp/ledger.json")" "build --changelog"
expect tag "$(git -C "$tmp/origin.git" cat-file -t refs/tags/v0.2.10)" "an annotated tag"
git -C "$tmp/origin.git" cat-file tag v0.2.10 | sed '1,/^$/d' >"$tmp/message"
cmp -s "$tmp/message" "$tmp/ledger.json" || fail "the tag's message is not the ledger verbatim: $(cat "$tmp/message")"
echo '{}' >"$tmp/not-a-ledger.json"
commit "another"
if release build --changelog "$tmp/not-a-ledger.json" >/dev/null; then
  fail "build took a ledger that is not an array"
fi

echo "release-channel-test.sh: ok"
