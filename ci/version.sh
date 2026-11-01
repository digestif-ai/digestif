#!/usr/bin/env bash
#
# Prints the version this checkout builds: the release tag on HEAD without its `v` (`v0.1.7` is
# 0.1.7), or 0.0.0 when HEAD carries none. A version is a tag (docs/releases.md, Cutting a
# release), so nothing in the tree names one, and an untagged build reports 0.0.0, which every
# release is newer than. It is 0.0.0 and never 0.0.0-dev because the node reads a version with the
# same strict MAJOR.MINOR.PATCH parser it reads a signed manifest with (node/update/lib/version.ml).
#
#   ci/version.sh            this checkout's HEAD
#
# A tag on HEAD that looks like a release but is not MAJOR.MINOR.PATCH (`v0.2.0-rc1`) is refused
# rather than read as 0.0.0, and so is a tagged HEAD whose release paths (ci/release-paths) carry
# uncommitted changes, because building either would ship a binary that reports a version whose
# code nobody tagged. ci/release-artifact.sh, ci/release-linux.sh, install.sh and the Release workflow all ask
# here, and each stamps the answer into the binary through DIGESTIF_VERSION (node/update/lib/dune).

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() {
  echo "version.sh: $*" >&2
  exit 1
}

# safe.directory: the Linux build reads a checkout another uid owns through a container mount.
tags="$(git -C "$root" -c safe.directory='*' tag --points-at HEAD --list 'v[0-9]*')"
if [ -z "$tags" ]; then
  echo 0.0.0
  exit 0
fi
[ "$(printf '%s\n' "$tags" | wc -l | tr -d ' ')" = 1 ] ||
  die "HEAD carries more than one release tag: $(printf '%s' "$tags" | tr '\n' ' ')"
version="${tags#v}"
[[ "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] ||
  die "tag $tags on HEAD is not v<MAJOR.MINOR.PATCH>"

specs=()
while IFS= read -r line; do
  case "$line" in '' | '#'*) ;; *) specs+=("$line") ;; esac
done <"$root/ci/release-paths"
dirty="$(git -C "$root" -c safe.directory='*' status --porcelain -- "${specs[@]}")"
[ -z "$dirty" ] || die "HEAD is $tags, and these release paths differ from it: $(printf '%s' "$dirty" | tr '\n' ' ')"
echo "$version"
