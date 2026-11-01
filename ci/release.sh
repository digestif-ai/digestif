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
#   ci/release.sh signatures | candidate | publish
#       Later stages of a rollout; not built yet.
#
# Exits 0 on success, 1 on a failure, 2 on a usage error, and 75 when main moved under --sha.
# Needs git and an authenticated gh with write access to the repository.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wait_minutes="${DIGESTIF_RELEASE_WAIT_MINUTES:-60}"
poll_seconds=60

die() {
  echo "release.sh: $*" >&2
  exit 1
}
usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
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

[ $# -ge 1 ] || usage
verb="$1"
shift
case "$verb" in
  build) cmd_build "$@" ;;
  changed) cmd_changed "$@" ;;
  signatures) cmd_not_built signatures ISS-37087 ;;
  candidate) cmd_not_built candidate ISS-37086 ;;
  publish) cmd_not_built publish ISS-37086 ;;
  -h | --help) usage ;;
  *) usage ;;
esac
