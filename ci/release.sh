#!/usr/bin/env bash
#
# Digestif's release command (docs/releases.md, Cutting a release): the verbs a rollout runs, in
# order, against origin as fetched now, never this working tree. A version is a tag of main,
# v<MAJOR.MINOR.PATCH>, and pushing it starts the Release workflow (.github/workflows/release.yml).
#
#   ci/release.sh build [--version X.Y.Z] [--sha COMMIT]
#       Without --version: tag origin/main with the next patch of the newest release tag (0.1.0
#       when there is none) and push the tag; a tip already tagged is that version. With
#       --version: the tag v<X.Y.Z>, which a person pushed, and which this never mints. Then wait
#       for the Release run on the tag and succeed once the draft release holds every platform's
#       archive and digestif-update and the manifest, each archive having passed stage-test. A
#       version already built is success with nothing to do. --sha names the commit the caller
#       judged: a run whose origin/main is any other commit exits 75 having tagged nothing.
#   ci/release.sh changed [--sha COMMIT]
#       Read-only. Prints `changed` when a path in ci/release-paths differs between the newest
#       release tag and origin/main (or COMMIT), else `unchanged`, and exits 0 either way; the
#       paths that moved go to stderr. No release tag yet is `changed`.
#   ci/release.sh signatures
#       A later stage of a rollout; not built yet.
#   ci/release.sh candidate --version X.Y.Z
#       Verify both signatures again with the digestif-update the draft holds for this machine's
#       platform (DIGESTIF_UPDATE names another), publish the GitHub release as a prerelease that
#       is not Latest, write the manifest and its signatures under candidate/ on the channel
#       branch, and dispatch main's Release workflow with the version as its candidate, which
#       starts the test nodes. Run again, it dispatches again. Exits 75, writing nothing, while a
#       signer has not signed.
#   ci/release.sh publish --version X.Y.Z
#       Once every test node passed: one commit on the channel branch moves the version out of
#       candidate/ and adds it to index.json, then the GitHub release becomes Latest.
#
# Exits 0 on success, 1 on a failure, 2 on a usage error, and 75 when main moved under --sha or a
# candidate is not signed yet. Needs git, jq and an authenticated gh with write access to the
# repository.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wait_minutes="${DIGESTIF_RELEASE_WAIT_MINUTES:-60}"
poll_seconds=60

die() {
  echo "release.sh: $*" >&2
  exit 1
}
usage() {
  sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

valid_version() {
  [[ "$1" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]]
}

# The release tags, newest first.
release_tags() {
  local t
  git -C "$root" tag --list 'v[0-9]*' --sort=-v:refname | while IFS= read -r t; do
    if valid_version "${t#v}"; then echo "$t"; fi
  done
}

# The release tags on a commit, newest first.
tags_at() {
  local t
  git -C "$root" tag --points-at "$1" --list 'v[0-9]*' --sort=-v:refname | while IFS= read -r t; do
    if valid_version "${t#v}"; then echo "$t"; fi
  done
}

next_patch() {
  local newest major minor patch
  newest="$(release_tags | head -1)"
  if [ -z "$newest" ]; then
    echo 0.1.0
    return
  fi
  IFS=. read -r major minor patch <<<"${newest#v}"
  echo "$major.$minor.$((patch + 1))"
}

fetch() {
  git -C "$root" fetch --quiet --force --tags origin main
}

# origin/main as fetched, or exit 75 when the caller judged another commit.
target_commit() {
  local sha expected="$1"
  sha="$(git -C "$root" rev-parse refs/remotes/origin/main)"
  if [ -n "$expected" ] && [[ "$sha" != "$expected"* || ${#expected} -lt 7 ]]; then
    echo "release.sh: origin/main is $sha, not $expected; main moved, so nothing is tagged" >&2
    exit 75
  fi
  echo "$sha"
}

# ci/release-paths at a commit, one pathspec per line.
release_paths_at() {
  git -C "$root" show "$1:ci/release-paths" | grep -v -e '^#' -e '^[[:space:]]*$'
}

repo() {
  git -C "$root" remote get-url origin | sed -E 's#^.*github\.com[:/]##; s#\.git$##'
}

cmd_changed() {
  local sha="" target newest specs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha) [ $# -ge 2 ] || usage; sha="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  fetch
  target="$(target_commit "$sha")"
  newest="$(release_tags | head -1)"
  if [ -z "$newest" ]; then
    echo "release.sh: no release tag yet" >&2
    echo changed
    return
  fi
  if ! git -C "$root" cat-file -e "$target:ci/release-paths" 2>/dev/null; then
    echo "release.sh: $target has no ci/release-paths" >&2
    echo changed
    return
  fi
  while IFS= read -r line; do specs+=("$line"); done < <(release_paths_at "$target")
  [ "${#specs[@]}" -gt 0 ] || die "ci/release-paths at $target names no path"
  local moved
  moved="$(git -C "$root" diff --name-only "$newest" "$target" -- "${specs[@]}")"
  if [ -n "$moved" ]; then
    echo "release.sh: since $newest: $(printf '%s' "$moved" | tr '\n' ' ')" >&2
    echo changed
  else
    echo "release.sh: nothing a member runs moved since $newest" >&2
    echo unchanged
  fi
}

# Every file the draft release must hold for the version: each platform's archive and
# digestif-update, and the manifest.
expected_assets() {
  local p
  git -C "$root" show "$1:ci/platforms.json" | jq -r '.platforms[].platform' | while IFS= read -r p; do
    echo "digestif-$p.tar.gz"
    echo "digestif-update-$p"
  done
  echo manifest.json
}

# Empty when the release holds every expected asset, else what it lacks (or that it is absent).
missing_assets() {
  local tag="$1" have
  have="$(gh release view "$tag" --repo "$(repo)" --json assets --jq '.assets[].name' 2>/dev/null)" || {
    echo "the release $tag"
    return
  }
  expected_assets "$tag" | while IFS= read -r a; do
    printf '%s\n' "$have" | grep -qxF "$a" || echo "$a"
  done
}

# Waits for the Release workflow's run on the tag; fails unless it concludes success.
wait_for_run() {
  local tag="$1" deadline line status conclusion url
  deadline=$((SECONDS + wait_minutes * 60))
  while :; do
    line="$(gh run list --repo "$(repo)" --workflow release.yml --event push --branch "$tag" \
      --limit 1 --json status,conclusion,url --jq '.[0] | [.status, .conclusion, .url] | @tsv' \
      2>/dev/null || true)"
    if [ -n "$line" ]; then
      IFS=$'\t' read -r status conclusion url <<<"$line"
      if [ "$status" = completed ]; then
        [ "$conclusion" = success ] || die "the Release run on $tag ended $conclusion: $url"
        echo "release.sh: the Release run on $tag passed: $url" >&2
        return
      fi
      echo "release.sh: the Release run on $tag is $status: $url" >&2
    else
      echo "release.sh: no Release run on $tag yet" >&2
    fi
    [ "$SECONDS" -lt "$deadline" ] || die "the Release run on $tag did not finish in $wait_minutes minutes"
    sleep "$poll_seconds"
  done
}

cmd_build() {
  local version="" sha="" target tag existing
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) [ $# -ge 2 ] || usage; version="${2#v}"; shift 2 ;;
      --sha) [ $# -ge 2 ] || usage; sha="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  fetch
  if [ -n "$version" ]; then
    valid_version "$version" || die "$version is not MAJOR.MINOR.PATCH"
    tag="v$version"
    git -C "$root" rev-parse --verify --quiet "refs/tags/$tag" >/dev/null ||
      die "there is no tag $tag; push it first, since --version builds a tag and mints none"
    git -C "$root" merge-base --is-ancestor "refs/tags/$tag" refs/remotes/origin/main ||
      die "$tag is not a commit of main"
  else
    target="$(target_commit "$sha")"
    existing="$(tags_at "$target" | head -1)"
    if [ -n "$existing" ]; then
      tag="$existing"
      echo "release.sh: origin/main $target is already $tag" >&2
    else
      tag="v$(next_patch)"
      git -C "$root" tag "$tag" "$target"
      git -C "$root" push --quiet origin "refs/tags/$tag" || {
        git -C "$root" tag -d "$tag" >/dev/null
        die "could not push $tag"
      }
      echo "release.sh: tagged origin/main $target as $tag" >&2
    fi
  fi

  if [ -z "$(missing_assets "$tag")" ]; then
    echo "release.sh: $tag is already built" >&2
  else
    wait_for_run "$tag"
    local missing
    missing="$(missing_assets "$tag")"
    [ -z "$missing" ] || die "the release $tag lacks: $(printf '%s' "$missing" | tr '\n' ' ')"
  fi
  echo "$tag"
}

cmd_not_built() {
  die "$1 is not built yet ($2)"
}

# The channel (docs/releases.md, The channel): the branch every node reads, written only by
# candidate, publish and a recall. It holds no workflow, so a push to it starts nothing.
channel_branch=channel
scratch=()
cleanup() {
  local d
  for d in "${scratch[@]+"${scratch[@]}"}"; do
    git -C "$root" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"
  done
}
trap cleanup EXIT

# Sets $scratch_path to a new directory removed on exit. Not a $(...): that would record it in a
# subshell's copy of $scratch.
scratch_dir() {
  scratch_path="$(mktemp -d -t digestif-release)"
  scratch+=("$scratch_path")
}

version_option() {
  local version=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) [ $# -ge 2 ] || usage; version="${2#v}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$version" ] || usage
  valid_version "$version" || die "$version is not MAJOR.MINOR.PATCH"
  echo "$version"
}

# draft, prerelease, published, or absent.
release_state() {
  local s
  s="$(gh release view "$1" --repo "$(repo)" --json isDraft,isPrerelease \
    --jq 'if .isDraft then "draft" elif .isPrerelease then "prerelease" else "published" end' \
    2>/dev/null)" || s=absent
  echo "$s"
}

# The commit origin's channel branch is at, made with an empty index.json when it does not exist.
channel_head() {
  if git -C "$root" fetch --quiet --force origin \
    "refs/heads/$channel_branch:refs/remotes/origin/$channel_branch" 2>/dev/null; then
    git -C "$root" rev-parse "refs/remotes/origin/$channel_branch"
    return
  fi
  local index readme tree commit
  index="$(printf '%s\n' '{' '  "format": "digestif-feed-v0",' '  "releases": [],' \
    '  "revocations": []' '}' | git -C "$root" hash-object -w --stdin)"
  readme="$(printf '%s\n' '# The Digestif release channel' '' \
    'What every node reads to decide what to install: `index.json` and the signed documents it' \
    'names. Written only by `ci/release.sh candidate` and `publish` and by a recall; see' \
    '`docs/releases.md` on main, The channel.' | git -C "$root" hash-object -w --stdin)"
  tree="$(printf '100644 blob %s\tREADME.md\n100644 blob %s\tindex.json\n' "$readme" "$index" |
    git -C "$root" mktree)"
  commit="$(git -C "$root" commit-tree "$tree" -m "The release channel")"
  if git -C "$root" push --quiet origin "$commit:refs/heads/$channel_branch" 2>/dev/null; then
    echo "release.sh: made the $channel_branch branch" >&2
    echo "$commit"
  else
    # Made by somebody else meanwhile: theirs.
    git -C "$root" fetch --quiet --force origin \
      "refs/heads/$channel_branch:refs/remotes/origin/$channel_branch" ||
      die "could not make or read the $channel_branch branch"
    git -C "$root" rev-parse "refs/remotes/origin/$channel_branch"
  fi
}

# Runs `$@ <worktree>` on a worktree of the channel's head and pushes what it changed as one
# commit titled $message; a push that lost a race starts again from the new head.
channel_commit() {
  local message="$1" attempt wt head
  shift
  for attempt in 1 2 3; do
    head="$(channel_head)"
    scratch_dir
    wt="$scratch_path"
    git -C "$root" worktree add --quiet --detach "$wt" "$head"
    "$@" "$wt"
    git -C "$wt" add --all
    if git -C "$wt" diff --cached --quiet; then
      echo "release.sh: the $channel_branch branch already holds it" >&2
      return
    fi
    git -C "$wt" commit --quiet -m "$message"
    if git -C "$wt" push --quiet origin "HEAD:refs/heads/$channel_branch"; then
      echo "release.sh: $message on $channel_branch at $(git -C "$wt" rev-parse HEAD)" >&2
      return
    fi
    echo "release.sh: $channel_branch moved during attempt $attempt; trying again" >&2
  done
  die "could not push to $channel_branch"
}

# The platform name ci/platforms.json gives this machine.
this_platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) die "no release platform for $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    arm64 | aarch64) arch=arm64 ;;
    x86_64 | amd64) arch=x86_64 ;;
    *) die "no release platform for $(uname -m)" ;;
  esac
  echo "$os-$arch"
}

# The digestif-update the release holds for this machine, downloaded into $2.
update_tool() {
  local tag="$1" dir="$2" platform
  if [ -n "${DIGESTIF_UPDATE:-}" ]; then
    echo "$DIGESTIF_UPDATE"
    return
  fi
  platform="$(this_platform)"
  gh release download "$tag" --repo "$(repo)" --dir "$dir" --clobber \
    --pattern "digestif-update-$platform" >/dev/null ||
    die "the release $tag holds no digestif-update-$platform; set DIGESTIF_UPDATE to one"
  chmod 755 "$dir/digestif-update-$platform"
  echo "$dir/digestif-update-$platform"
}

# Downloads the release's manifest and every signature asset into $3 and verifies them as a node
# does, writing the signatures every signer gave as $3/manifest.sig.json. Exits 75 while a signer
# has not signed.
verified_signatures() {
  local tag="$1" version="$2" dir="$3" tool sigs=() f
  gh release download "$tag" --repo "$(repo)" --dir "$dir/assets" --clobber \
    --pattern manifest.json --pattern '*.sig.json' >/dev/null ||
    die "could not download the manifest of $tag"
  [ -f "$dir/assets/manifest.json" ] || die "the release $tag holds no manifest.json"
  for f in "$dir"/assets/*.sig.json; do
    [ -e "$f" ] && sigs+=("$f")
  done
  tool="$(update_tool "$tag" "$dir")"
  if ! "$tool" verify "$dir/assets/manifest.json" "${sigs[@]+"${sigs[@]}"}" \
    --expect-version "$version" --out "$dir/manifest.sig.json" >"$dir/verify.out"; then
    cat "$dir/verify.out" >&2
    if grep -q '^missing ' "$dir/verify.out"; then
      echo "release.sh: $tag waits for signatures; nothing was published" >&2
      exit 75
    fi
    die "the signatures of $tag do not verify"
  fi
  cat "$dir/verify.out" >&2
}

# candidate/ holds the one version on its way to the test nodes, as a feed of its own: its
# index.json names that version and the channel's revocations, and nodes never read it.
write_candidate() {
  local version="$1" dir="$2" wt="$3"
  rm -rf "$wt/candidate"
  mkdir -p "$wt/candidate/$version"
  cp "$dir/assets/manifest.json" "$wt/candidate/$version/manifest.json"
  cp "$dir/manifest.sig.json" "$wt/candidate/$version/manifest.sig.json"
  jq --arg v "$version" '{
      format,
      releases: [ { version: $v, manifest: "\($v)/manifest.json", signatures: "\($v)/manifest.sig.json" } ],
      revocations: [ .revocations[] | { document: "../\(.document)", signatures: "../\(.signatures)" } ]
    }' "$wt/index.json" >"$wt/candidate/index.json"
}

cmd_candidate() {
  local version tag state dir
  version="$(version_option "$@")"
  tag="v$version"
  fetch
  git -C "$root" rev-parse --verify --quiet "refs/tags/$tag" >/dev/null || die "there is no tag $tag"
  state="$(release_state "$tag")"
  case "$state" in
    absent) die "the release $tag is gone, so there is nothing to send to the test nodes" ;;
    published)
      echo "release.sh: $tag is already published" >&2
      echo "$tag"
      return
      ;;
  esac
  scratch_dir
  dir="$scratch_path"
  verified_signatures "$tag" "$version" "$dir"
  if [ "$state" = draft ]; then
    # Its archives must be fetchable by a test node, and the front page must not offer it yet.
    gh release edit "$tag" --repo "$(repo)" --draft=false --prerelease --latest=false >/dev/null
    echo "release.sh: published $tag as a prerelease" >&2
  fi
  channel_commit "Candidate $version" write_candidate "$version" "$dir"
  gh workflow run release.yml --repo "$(repo)" --ref main -f candidate="$version" >/dev/null ||
    die "could not dispatch the Release workflow for the candidate $version"
  echo "release.sh: dispatched the Release workflow on main with candidate $version" >&2
  echo "$tag"
}

# Moves candidate/<version> to <version> and lists it in index.json, in version order.
publish_candidate() {
  local version="$1" wt="$2"
  if jq -e --arg v "$version" 'any(.releases[]; .version == $v)' "$wt/index.json" >/dev/null; then
    return
  fi
  [ -f "$wt/candidate/$version/manifest.json" ] ||
    die "$version is not the candidate on $channel_branch; run candidate first"
  [ ! -e "$wt/$version" ] || die "$channel_branch already has $version/"
  mv "$wt/candidate/$version" "$wt/$version"
  rm -rf "$wt/candidate"
  jq --arg v "$version" '.releases = (.releases
      + [ { version: $v, manifest: "\($v)/manifest.json", signatures: "\($v)/manifest.sig.json" } ]
      | sort_by(.version | split(".") | map(tonumber)))' "$wt/index.json" >"$wt/index.json.next"
  mv "$wt/index.json.next" "$wt/index.json"
}

cmd_publish() {
  local version tag
  version="$(version_option "$@")"
  tag="v$version"
  fetch
  [ "$(release_state "$tag")" != absent ] || die "the release $tag is gone"
  channel_commit "Publish $version" publish_candidate "$version"
  gh release edit "$tag" --repo "$(repo)" --draft=false --prerelease=false --latest >/dev/null
  echo "release.sh: $tag is published and Latest" >&2
  echo "$tag"
}

[ $# -ge 1 ] || usage
verb="$1"
shift
case "$verb" in
  build) cmd_build "$@" ;;
  changed) cmd_changed "$@" ;;
  signatures) cmd_not_built signatures ISS-37087 ;;
  candidate) cmd_candidate "$@" ;;
  publish) cmd_publish "$@" ;;
  -h | --help) usage ;;
  *) usage ;;
esac
