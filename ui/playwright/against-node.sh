#!/usr/bin/env bash
#
# Runs the Playwright suite against the node itself rather than the mock: starts `digestif demo`
# (the mock's circle, built from real keys and signed envelopes) in a throwaway directory, hands
# its address and one-time launch link to the suite, and stops it afterwards. The binary and the
# directory go to the suite too (DIGESTIF_BIN, DIGESTIF_DEMO_HOME): new-member.spec.ts plays the
# member's agent by running `digestif` against the demo's directory.
#
#   playwright/against-node.sh [playwright test args]
#   DIGESTIF_BIN=/path/to/digestif playwright/against-node.sh
#
# Build the node first (node/: dune build); DIGESTIF_BIN defaults to its build output.

set -euo pipefail

ui="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="${DIGESTIF_BIN:-$ui/../node/_build/default/bin/main.exe}"
bin="$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")"
home="$(mktemp -d "${TMPDIR:-/tmp}/digestif-demo.XXXXXX")"
out="$home.out"

"$bin" demo --home "$home" >"$out" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -rf "$home" "$out"' EXIT

launch=""
for _ in $(seq 1 100); do
  launch="$(grep -m1 '/launch?token=' "$out" || true)"
  [ -n "$launch" ] && break
  kill -0 "$pid" 2>/dev/null || { cat "$out" >&2; exit 1; }
  sleep 0.1
done
[ -n "$launch" ] || { echo "against-node.sh: the demo node printed no launch link" >&2; cat "$out" >&2; exit 1; }

export DIGESTIF_NODE="${launch%%/launch*}"
export DIGESTIF_NODE_LAUNCH="$launch"
export DIGESTIF_BIN="$bin"
export DIGESTIF_DEMO_HOME="$home"
cd "$ui"
npx playwright test "$@"
