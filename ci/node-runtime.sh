#!/usr/bin/env bash
#
# Lays out the Node.js a release archive carries for PLATFORM in DIR: DIR/bin/node and Node.js's
# LICENSE, from the official build named in ci/node-runtime.json and checked against the sha256
# pinned there (docs/releases.md, Cutting a release). The behaviors run with it by its path, so a
# member's machine needs no Node.js of its own.
#
#   ci/node-runtime.sh PLATFORM DIR
#
# Moving to another Node.js is an edit of ci/node-runtime.json: the version and each archive's
# sha256 from https://nodejs.org/dist/v<version>/SHASUMS256.txt.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() {
  echo "node-runtime.sh: $*" >&2
  exit 1
}

[ $# -eq 2 ] || die "usage: ci/node-runtime.sh PLATFORM DIR"
platform="$1"
dir="$2"
pins="$root/ci/node-runtime.json"

version="$(jq -er .version "$pins")"
name="$(jq -er --arg p "$platform" '.archives[$p].name' "$pins")" || die "$pins names no Node.js for $platform"
want="$(jq -er --arg p "$platform" '.archives[$p].sha256' "$pins")"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp/$name" "https://nodejs.org/dist/v$version/$name"
have="$(sha256 "$tmp/$name")"
[ "$have" = "$want" ] || die "$name hashes to $have, ci/node-runtime.json pins $want"

tar -xzf "$tmp/$name" -C "$tmp"
src="$tmp/${name%.tar.gz}"
rm -rf "$dir"
mkdir -p "$dir/bin"
cp "$src/bin/node" "$dir/bin/node"
chmod 755 "$dir/bin/node"
cp "$src/LICENSE" "$dir/LICENSE"
echo "$dir: Node.js $version for $platform"
