#!/usr/bin/env bash
#
# Builds this machine's Linux release archive inside an Alpine container, so the binaries link
# musl statically and run on any Linux distribution (ci/release-artifact.sh). The UI is built
# first, on the host, because it needs a Node.js the container does not carry; what it builds is
# the same static files on every platform.
#
#   ci/release-linux.sh
#
# The version is the release tag on HEAD (ci/version.sh), read here on the host and passed into
# the container as DIGESTIF_VERSION. Needs docker, curl, jq and Node.js 24.16 or later. The archive lands in
# dist/<version>/ like any other platform's, and the container's architecture is the host's.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="ocaml/opam:alpine-3.21-ocaml-5.2"

[ $# -eq 0 ] || {
  echo "usage: ci/release-linux.sh" >&2
  exit 1
}
version="$("$root/ci/version.sh")"

(cd "$root/ui" && npm ci --no-audit --no-fund && npm run build)

# The Node.js the archive carries, fetched and checked here because the container has no curl or
# jq; the container's architecture is the host's.
case "$(uname -m)" in
  arm64 | aarch64) platform=linux-arm64 ;;
  *) platform=linux-x86_64 ;;
esac
"$root/ci/node-runtime.sh" "$platform" "$root/dist/runtime-$platform"

# Root in the container, so it can write the host's checkout whatever uid owns it; the switch is
# the image's own, at /home/opam/.opam. dune builds into node/_build-linux, so a host build in
# node/_build is neither reused nor overwritten. The image runs opam 2.0 by default, whose view of
# the repository stops short of the cmdliner the node needs, and carries newer ones beside it. Its
# repository is a checkout frozen when the image was built, so the build reads opam.ocaml.org.
docker run --rm --user root --entrypoint sh -v "$root:/src" -w /src \
  -e OPAMROOT=/home/opam/.opam -e OPAMROOTISOK=1 -e OPAMYES=1 -e DUNE_BUILD_DIR=_build-linux \
  -e DIGESTIF_VERSION="$version" -e DIGESTIF_NODE_RUNTIME="/src/dist/runtime-$platform" \
  "$image" -euc '
    apk add --no-cache bash sqlite-dev sqlite-static pkgconf linux-headers binutils
    cp /usr/bin/opam-2.4 /usr/local/bin/opam
    opam repository set-url default https://opam.ocaml.org
    opam update --quiet
    opam install ./node --deps-only
    eval "$(opam env)"
    bash ci/release-artifact.sh --ui-built
  '
