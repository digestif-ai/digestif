#!/usr/bin/env bash
#
# Checks a built release archive carries bin/digestif-update, then stages it the way a node stages
# one (`digestif-update stage-test`, the checks in node/update/lib/stage.ml): unpack it, find
# bin/digestif, find the Node.js its behaviors need on PATH, self-test the binary at VERSION. On
# Linux it runs in a container of another distribution than the Alpine the binaries were built in,
# holding nothing but Node.js, so a binary that needs anything of its builder fails here rather
# than on a member's machine.
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
image="node:24-bookworm-slim"

archive="$(cd "$dir" && ls digestif-*.tar.gz)"
[ "$(printf '%s\n' "$archive" | wc -l)" -eq 1 ] || die "$dir holds more than one archive"
[ -f "$dir/digestif-update" ] || die "$dir holds no digestif-update"
# The archive carries the signer's tool, which a signer signs the next version with.
tar -tzf "$dir/$archive" | grep -qE '^(\./)?bin/digestif-update$' ||
  die "$archive holds no bin/digestif-update"

case "$(uname -s)" in
  Linux)
    docker run --rm -v "$dir:/release:ro" "$image" sh -euc '
      cat /etc/os-release | head -1
      node --version
      cp /release/digestif-update /tmp/digestif-update
      chmod 755 /tmp/digestif-update
      mkdir /tmp/unpacked && tar -xzf "/release/$2" -C /tmp/unpacked
      ldd /tmp/unpacked/bin/digestif 2>&1 || true
      /tmp/digestif-update stage-test "/release/$2" --expect-version "$1"
    ' sh "$version" "$archive"
    ;;
  Darwin)
    node --version
    chmod 755 "$dir/digestif-update"
    "$dir/digestif-update" stage-test "$dir/$archive" --expect-version "$version"
    ;;
  *) die "no release is checked on $(uname -s)" ;;
esac
