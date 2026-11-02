#!/usr/bin/env bash
#
# Builds this machine's release archive from this checkout: the web UI, the node with the UI
# embedded, the behaviors, and the platform's Node.js they run with (ci/node-runtime.sh), bundled
# by `digestif-update bundle` into
# dist/<version>/digestif-<platform>.tar.gz (docs/releases.md, Cutting a release). It prints the
# archive's path.
#
#   ci/release-artifact.sh              build the UI too
#   ci/release-artifact.sh --ui-built   ui/build is already built in this checkout
#
# The version is the release tag on HEAD (ci/version.sh), or 0.0.0 when HEAD carries none, and the
# build stamps it into both binaries through DIGESTIF_VERSION, so a node's check that a release's
# binary reports the manifest's version (--expect-version) holds by construction. ci/version.sh
# refuses a tagged tree whose release paths (ci/release-paths) differ from the tag, so an archive
# never holds an edit the tag does not. DIGESTIF_VERSION already set is taken as the version:
# ci/release-linux.sh reads the tag on the host and passes it into its container. The Release
# workflow (.github/workflows/release.yml) runs this on every platform in ci/platforms.json from one
# commit; on Linux inside ci/release-linux.sh's Alpine container.
#
# A binary must run on a member's machine, not only this one, so it refuses one that links
# anything a member may not have: on Linux the binaries are linked statically (the node/dune
# static profile, against musl), on macOS they may link only the system's /usr/lib and /System.
# The Node.js is the official build pinned in ci/node-runtime.json; DIGESTIF_NODE_RUNTIME set names
# a directory ci/node-runtime.sh already laid out, which ci/release-linux.sh does on the host
# because its container carries neither curl nor jq, nor the glibc the official Linux build links.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() {
  echo "release-artifact.sh: $*" >&2
  exit 1
}

ui_built=0
case "$#:${1:-}" in
  0:) ;;
  1:--ui-built) ui_built=1 ;;
  *) die "usage: ci/release-artifact.sh [--ui-built]" ;;
esac
if [ -z "${DIGESTIF_VERSION:-}" ]; then
  DIGESTIF_VERSION="$("$root/ci/version.sh")"
fi
export DIGESTIF_VERSION
version="$DIGESTIF_VERSION"

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

# The Node.js is run here only when this script fetched it: the official Linux build links glibc,
# so it cannot run in ci/release-linux.sh's musl container, which hands in a runtime the host
# already fetched.
runtime="${DIGESTIF_NODE_RUNTIME:-}"
if [ -z "$runtime" ]; then
  runtime="$root/dist/runtime-$platform"
  "$root/ci/node-runtime.sh" "$platform" "$runtime"
  "$runtime/bin/node" --version
fi
[ -x "$runtime/bin/node" ] || die "$runtime holds no bin/node"

out="$root/dist/$version/digestif-$platform.tar.gz"
mkdir -p "$(dirname "$out")"
"$bin/digestif-update" bundle --binary "$bin/digestif" --behaviors "$root/behaviors" \
  --runtime "$runtime" --out "$out"
# The signer's tool from the same build, which ci/release-check.sh stages the archive with. It is
# not part of the release.
cp "$bin/digestif-update" "$root/dist/$version/digestif-update-$platform"
echo "$out"
