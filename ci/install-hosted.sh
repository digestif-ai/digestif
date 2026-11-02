#!/usr/bin/env bash
#
# Writes a release's hosted install script, served at https://digestif.io/install.sh, from its
# manifest: ci/install-hosted.sh.in with the version, the link to the signed manifest, and each
# platform's archive url and sha256 filled in (docs/releases.md, The hosted install script). The
# Release workflow runs it on the manifest it writes, so the script carries exactly the sha256s
# the signers sign.
#
#   ci/install-hosted.sh MANIFEST MANIFEST_URL > install.sh
#
# It refuses a manifest whose artifact url is not absolute or whose sha256 is not 64 hex digits, so
# nothing it writes into the script needs quoting.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() {
  echo "install-hosted.sh: $*" >&2
  exit 1
}

[ $# -eq 2 ] || die "usage: ci/install-hosted.sh MANIFEST MANIFEST_URL"
manifest="$1"
manifest_url="$2"

safe='^[A-Za-z0-9._~:/?#@=%+-]+$'
version="$(jq -er .version "$manifest")" || die "$manifest names no version"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$manifest names version $version"
[[ "$manifest_url" =~ ^https?:// && "$manifest_url" =~ $safe ]] || die "$manifest_url is not an http(s) url"

cases=""
while IFS=$'\t' read -r platform url sha; do
  [[ "$platform" =~ ^(darwin|linux)-(arm64|x86_64)$ ]] || die "$manifest names platform $platform"
  [[ "$url" =~ ^[a-z]+:// && "$url" =~ $safe ]] || die "$platform's url $url is not absolute"
  hex="${sha#sha256:}"
  [[ "$hex" =~ ^[0-9a-f]{64}$ ]] || die "$platform's sha256 $sha is not sha256:<64 hex>"
  cases+="  $platform)"$'\n'"    url='$url'"$'\n'"    expected='$hex'"$'\n'"    ;;"$'\n'
done < <(jq -er '.artifacts[] | [.platform, .url, .sha256] | @tsv' "$manifest")
[ -n "$cases" ] || die "$manifest lists no artifacts"

while IFS= read -r line; do
  case "$line" in
    @ARTIFACTS@) printf '%s' "$cases" ;;
    *)
      line="${line//@VERSION@/$version}"
      printf '%s\n' "${line//@MANIFEST_URL@/$manifest_url}"
      ;;
  esac
done < "$root/ci/install-hosted.sh.in"
