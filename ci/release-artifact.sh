#!/usr/bin/env bash
#
# Builds this machine's release archive for VERSION from this checkout: the web UI, the node with
# the UI embedded, and the behaviors, bundled by `digestif-update bundle` into
# dist/<version>/digestif-<platform>.tar.gz (docs/releases.md, Cutting a release).
#
#   ci/release-artifact.sh 0.1.0              build the UI too
#   ci/release-artifact.sh 0.1.0 --ui-built   ui/build is already built in this checkout
#
# It refuses unless node/VERSION is VERSION, because a node runs a release's self-test with
# --expect-version and refuses a binary that reports any other version. The release workflow
# (.github/workflows/release.yml) runs it on every platform in ci/platforms.json from one commit;
# on Linux it runs inside ci/release-linux.sh's Alpine container.
#
# A binary must run on a member's machine, not only this one, so it refuses one that links
# anything a member may not have: on Linux the binaries are linked statically (the node/dune
# static profile, against musl), on macOS they may link only the system's /usr/lib and /System.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() {
  echo "release-artifact.sh: $*" >&2
  exit 1
}

ui_built=0
case "$#:${2:-}" in
  1:) ;;
  2:--ui-built) ui_built=1 ;;
  *) die "usage: ci/release-artifact.sh VERSION [--ui-built]" ;;
esac
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

if [ "$ui_built" = 1 ]; then
  [ -f "$root/ui/build/index.html" ] || die "--ui-built, but ui/build holds no index.html"
else
  (cd "$root/ui" && npm ci --no-audit --no-fund && npm run build)
fi
rm -rf "$root/node/web/ui"
cp -R "$root/ui/build" "$root/node/web/ui"
case "$os" in
  linux) (cd "$root/node" && dune build @install --profile static) ;;
  *) (cd "$root/node" && dune build @install) ;;
esac

bin="$root/node/${DUNE_BUILD_DIR:-_build}/install/default/bin"

# What each binary links, printed for the run's log, and refused when a member's machine may lack it.
check_links() {
  local exe="$1"
  case "$os" in
    linux)
      ldd "$exe" 2>&1 || true
      if readelf -l "$exe" | grep -q 'INTERP'; then
        die "$exe is dynamically linked; a Linux release binary must be static"
      fi
      ;;
    darwin)
      otool -L "$exe"
      local outside
      outside="$(otool -L "$exe" | tail -n +2 | awk '{ print $1 }' | grep -v -E '^(/usr/lib/|/System/)' || true)"
      [ -z "$outside" ] || die "$exe links libraries outside the system: $outside"
      ;;
  esac
}
check_links "$bin/digestif"
check_links "$bin/digestif-update"

out="$root/dist/$version/digestif-$platform.tar.gz"
mkdir -p "$(dirname "$out")"
"$bin/digestif-update" bundle --binary "$bin/digestif" --behaviors "$root/behaviors" --out "$out"
# The signer's tool from the same build, which ci/release-check.sh stages the archive with. It is
# not part of the release.
cp "$bin/digestif-update" "$root/dist/$version/digestif-update-$platform"
echo "$out"
