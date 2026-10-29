#!/usr/bin/env bash
#
# Builds and tests every piece of the repository that is present, from a clean clone, with
# nothing but the public toolchains: OCaml (opam, dune) for node/, Node.js (npm) for ui/ and
# conformance/.
#
# No step here calls a service. Code generated from spec/ is checked in, so a clone builds
# without regenerating it; see docs/development.md.
#
#   ci/build.sh                          build and test everything present
#   DIGESTIF_INSTALL_DEPS=1 ci/build.sh  first install node/'s opam dependencies into the
#                                        current switch (a fresh machine or CI image)
#
# `set -euo pipefail` is not style: a pipeline reports only its last command's status, so a
# swallowed failure would exit 0 and report a green build that measured nothing.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

step() { printf '\n==> %s\n' "$*"; }

build_node() {
  if ! command -v dune >/dev/null 2>&1 && command -v opam >/dev/null 2>&1; then
    eval "$(opam env)"
  fi
  if ! command -v dune >/dev/null 2>&1; then
    echo "ci/build.sh: dune not found; install opam and run: opam install ./node --deps-only --with-test" >&2
    exit 1
  fi
  if [ "${DIGESTIF_INSTALL_DEPS:-0}" = "1" ]; then
    step "node: opam install --deps-only"
    opam install "$root/node" --deps-only --with-test --yes
  fi
  step "node: dune build @install @runtest"
  (cd "$root/node" && dune build @install @runtest)
}

build_ui() {
  step "ui: npm ci, check, test, build"
  (cd "$root/ui" && npm ci && npm run check && npm test && npm run build)
}

build_node

if [ -f "$root/ui/package.json" ]; then
  build_ui
else
  step "ui: no ui/package.json yet, skipped"
fi

build_conformance() {
  step "conformance: npm ci, check, self-test"
  (cd "$root/conformance" && npm ci && npm run check && npm test)
}

# The node cases against the OCaml node built above, through its `conformance sync` adapter
# (conformance/README.md, The node adapter contract). The runner splits --node on whitespace, so
# the binary's path must hold none. A case that fails means the node or the README's merge-order
# rule is wrong; docs/protocol.md settles which.
node_conformance() {
  local digestif="$root/node/_build/install/default/bin/digestif"
  step "conformance: node cases against $digestif"
  case "$digestif" in
    *[[:space:]]*)
      echo "ci/build.sh: $digestif contains whitespace, which the node adapter command cannot carry" >&2
      exit 1
      ;;
  esac
  (cd "$root/conformance" && node bin/digestif-conformance.ts node --node "$digestif conformance")
}

if [ -f "$root/conformance/package.json" ]; then
  build_conformance
  node_conformance
else
  step "conformance: no conformance/package.json yet, skipped"
fi

# relay/ adds its own step here when it gains a build.

step "ok"
