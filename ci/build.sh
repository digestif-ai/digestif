#!/usr/bin/env bash
#
# Builds and tests every piece of the repository that is present, from a clean clone, with
# nothing but the public toolchains: OCaml (opam, dune) for node/, Node.js (npm) for ui/ and
# conformance/.
#
# No step here calls a service. Code generated from spec/ is checked in, so a clone builds
# without regenerating it; see docs/development.md.
#
#   ci/build.sh                          build and test everything present; ui/ builds first,
#                                        because the node embeds its build
#   DIGESTIF_INSTALL_DEPS=1 ci/build.sh  first install node/'s opam dependencies into the
#                                        current switch (a fresh machine or CI image)
#
# ci-compile: ci/compile.sh
#
# `set -euo pipefail` is not style: a pipeline reports only its last command's status, so a
# swallowed failure would exit 0 and report a green build that measured nothing.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

step() { printf '\n==> %s\n' "$*"; }

# Refuses before dune runs when the switch lacks any of node/'s opam dependencies. dune
# itself would stop on the first library it cannot find, after building and running whatever
# does not need it, so the failure reads as a test run rather than as a machine that was
# never provisioned. `--show-actions` is opam's own plan for the root package, so it names
# every missing package and every system package (pkgconf) at once. `--check` is not used:
# with `--with-test` it also demands the test dependencies of every dependency.
require_node_deps() {
  local plan
  if ! plan="$(opam install "$root/node" --deps-only --with-test --show-actions 2>&1)"; then
    printf '%s\n' "$plan" >&2
    echo "ci/build.sh: opam cannot solve node/'s dependencies in switch $(opam switch show)" >&2
    exit 1
  fi
  if printf '%s\n' "$plan" | grep -qx 'Nothing to do.'; then
    return 0
  fi
  {
    echo "ci/build.sh: switch $(opam switch show) is missing node/'s opam dependencies:"
    printf '%s\n' "$plan" | sed -n '/^The following/,$p'
    echo
    echo "Install them into this switch, then re-run:"
    echo "  DIGESTIF_INSTALL_DEPS=1 ci/build.sh"
  } >&2
  exit 1
}

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
    # unsafe-yes lets opam install the system packages a dependency declares (pkgconf for
    # conf-sqlite3) rather than stop and ask; plain --yes refuses them.
    opam install "$root/node" --deps-only --with-test --yes --confirm-level=unsafe-yes
  fi
  if command -v opam >/dev/null 2>&1; then
    require_node_deps
  fi
  step "node: dune build @install @runtest"
  (cd "$root/node" && dune build @install @runtest)
}

build_ui() {
  step "ui: npm ci, check, test, build"
  (cd "$root/ui" && npm ci && npm run check && npm test && npm run build)
}

# The UI first: the node embeds ui/build in its binary, read from node/web/ui (node/web/dune).
if [ -f "$root/ui/package.json" ]; then
  build_ui
  step "ui: copy ui/build to node/web/ui for the node to embed"
  rm -rf "$root/node/web/ui"
  cp -R "$root/ui/build" "$root/node/web/ui"
else
  step "ui: no ui/package.json yet, skipped"
fi

build_node

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

# The reference behaviors (behaviors/README.md): typecheck, lint and tests, no network.
build_behaviors() {
  step "behaviors: npm ci, check, test"
  (cd "$root/behaviors" && npm ci && npm run check && npm test)
}

if [ -f "$root/behaviors/package.json" ]; then
  build_behaviors
else
  step "behaviors: no behaviors/package.json yet, skipped"
fi

# The relay: typecheck and lint, vitest inside workerd, then the conformance suite's relay cases
# against two `wrangler dev` instances (relay/README.md). Everything runs locally; no step calls
# Cloudflare.
build_relay() {
  # relay/app is generated and ignored: scripts/app.sh fills it from ui/build (built above) or the
  # placeholder, and the npm scripts below run it again before each Worker starts.
  step "relay: fill relay/app with the phone app the Worker serves under /app/"
  bash "$root/relay/scripts/app.sh"
  step "relay: npm ci, check, test, conformance"
  (cd "$root/relay" && npm ci && npm run check && npm test && npm run conformance)
}

if [ -f "$root/relay/package.json" ]; then
  build_relay
else
  step "relay: no relay/package.json yet, skipped"
fi

step "ok"
