#!/usr/bin/env bash
#
# Stages a built release archive the way a node stages one (`digestif-update stage-test`, the
# checks in node/update/lib/stage.ml): unpack it, find bin/digestif, run the Node.js it carries in
# runtime/ by its path, self-test the binary at VERSION. On Linux it runs in a container of another
# distribution than the Alpine the binaries were built in, holding no Node.js at all, so a binary
# that needs anything of its builder, or a release that leans on a node found on PATH, fails here
# rather than on a member's machine.
#
#   ci/release-check.sh VERSION DIR
#
# DIR holds digestif-<platform>.tar.gz and the digestif-update built beside it, for this
# machine's platform.

set -euo pipefail

die() {
  echo "release-check.sh: $*" >&2
  exit 1
}

[ $# -eq 2 ] || die "usage: ci/release-check.sh VERSION DIR"
version="$1"
dir="$(cd "$2" && pwd)"
image="debian:bookworm-slim"

archive="$(cd "$dir" && ls digestif-*.tar.gz)"
[ "$(printf '%s\n' "$archive" | wc -l)" -eq 1 ] || die "$dir holds more than one archive"
[ -f "$dir/digestif-update" ] || die "$dir holds no digestif-update"

case "$(uname -s)" in
  Linux)
    docker run --rm -v "$dir:/release:ro" "$image" sh -euc '
      cat /etc/os-release | head -1
      ! command -v node
      cp /release/digestif-update /tmp/digestif-update
      chmod 755 /tmp/digestif-update
      mkdir /tmp/unpacked && tar -xzf "/release/$2" -C /tmp/unpacked
      ldd /tmp/unpacked/bin/digestif 2>&1 || true
      /tmp/digestif-update stage-test "/release/$2" --expect-version "$1"
    ' sh "$version" "$archive"
    ;;
  Darwin)
    chmod 755 "$dir/digestif-update"
    "$dir/digestif-update" stage-test "$dir/$archive" --expect-version "$version"
    ;;
  *) die "no release is checked on $(uname -s)" ;;
esac
