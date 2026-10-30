#!/usr/bin/env bash
#
# Compiles every piece of the repository that is present, and runs nothing else: no test, no
# lint, no ui build. This is what a batch build's Prepare runs (`# ci-compile:` in ci/build.sh)
# to know the merged tree compiles before its suites are planned; ci/build.sh is the whole check.
#
#   node/         dune build @install @all (the node embeds ui/build only when it is there)
#   ui/           npm ci, svelte-kit sync, svelte-check
#   conformance/  npm ci, tsc

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

step() { printf '\n==> %s\n' "$*"; }

if ! command -v dune >/dev/null 2>&1 && command -v opam >/dev/null 2>&1; then
  eval "$(opam env)"
fi
if ! command -v dune >/dev/null 2>&1; then
  # 75: nothing was measured. A machine with no OCaml toolchain says nothing about the code.
  echo "ci/compile.sh: dune not found; install opam and run: opam install ./node --deps-only --with-test" >&2
  exit 75
fi
# The same refusal as ci/build.sh's require_node_deps, as 75: a switch missing node/'s opam
# dependencies fails dune on the first library it cannot find, which reads as broken code.
if command -v opam >/dev/null 2>&1; then
  plan="$(opam install "$root/node" --deps-only --with-test --show-actions 2>&1)" || plan=""
  if ! printf '%s\n' "$plan" | grep -qx 'Nothing to do.'; then
    printf '%s\n' "$plan" >&2
    echo "ci/compile.sh: switch $(opam switch show) cannot build node/: run DIGESTIF_INSTALL_DEPS=1 ci/build.sh" >&2
    exit 75
  fi
fi
step "node: dune build @install @all"
(cd "$root/node" && dune build @install @all)

if [ -f "$root/ui/package.json" ]; then
  step "ui: npm ci, svelte-kit sync, svelte-check"
  (cd "$root/ui" && npm ci --no-audit --no-fund && npx svelte-kit sync && npx svelte-check --tsconfig ./tsconfig.json)
fi

if [ -f "$root/conformance/package.json" ]; then
  step "conformance: npm ci, tsc"
  (cd "$root/conformance" && npm ci --no-audit --no-fund && npx tsc -p tsconfig.json)
fi

step "ok"
