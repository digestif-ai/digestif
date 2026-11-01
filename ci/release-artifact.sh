#!/usr/bin/env bash
#
# Builds this machine's release archive for VERSION from this checkout: the web UI, the node with
# the UI embedded, and the behaviors, bundled by `digestif-update bundle` into
# dist/<version>/digestif-<platform>.tar.gz (docs/releases.md, Cutting a release).
#
#   ci/release-artifact.sh 0.1.0
#
# It refuses unless node/VERSION is VERSION, because a node runs a release's self-test with
# --expect-version and refuses a binary that reports any other version. Run it on each platform a
# release ships for, from the same commit.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() {
  echo "release-artifact.sh: $*" >&2
  exit 1
}

[ $# -eq 1 ] || die "usage: ci/release-artifact.sh VERSION"
version="$1"
built_version="$(tr -d '[:space:]' <"$root/node/VERSION")"
[ "$built_version" = "$version" ] || die "node/VERSION is $built_version, not $version"

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) die "no release is built for $(uname -s)" ;;
esac
case "$(uname -m)" in
  arm64 | aarch64) arch=arm64 ;;
  x86_64 | amd64) arch=x86_64 ;;
  *) die "no release is built for $(uname -m)" ;;
esac
platform="$os-$arch"

if ! command -v dune >/dev/null 2>&1 && command -v opam >/dev/null 2>&1; then
  eval "$(opam env)"
fi

(cd "$root/ui" && npm ci --no-audit --no-fund && npm run build)
rm -rf "$root/node/web/ui"
cp -R "$root/ui/build" "$root/node/web/ui"
(cd "$root/node" && dune build @install)

bin="$root/node/_build/install/default/bin"
out="$root/dist/$version/digestif-$platform.tar.gz"
mkdir -p "$(dirname "$out")"
"$bin/digestif-update" bundle --binary "$bin/digestif" --behaviors "$root/behaviors" --out "$out"
echo "$out"
