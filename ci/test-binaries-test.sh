#!/usr/bin/env bash
#
# Tests ci/test-binaries.sh against a fixture tree: a (tests (names ...)) stanza over several
# lines and a (test (name ...)) stanza, both linking ci_alcotest, are listed; a test stanza
# without ci_alcotest (one whose comment names it included), an executable linking ci_alcotest,
# a commented-out stanza and a dune file under _build or node_modules are not. Then the node
# tree in this checkout lists at least one binary. ci/build.slow.sh runs it; it needs nothing
# but bash, awk, find and sort.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
list="$root/ci/test-binaries.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "test-binaries-test.sh: $*" >&2
  exit 1
}

mkdir -p "$tmp/node/a/test" "$tmp/node/b" "$tmp/node/c" "$tmp/node/_build/default/x" "$tmp/node/ui/node_modules/y"
cat >"$tmp/node/a/test/dune" <<'DUNE'
(library
 (name helper)
 (libraries ci_alcotest))

(tests
 (names
  test_one
  test_two)
 (deps
  (env_var CI_ALCOTEST_LISTS))
 (libraries alcotest ci_alcotest yojson))
DUNE
cat >"$tmp/node/b/dune" <<'DUNE'
; (test (name test_commented) (libraries ci_alcotest))
(test
 (name test_three)
 (libraries
  alcotest
  ci_alcotest))

(test
 (name test_plain) ; not ci_alcotest
 (libraries alcotest))

(executable
 (name not_a_test)
 (libraries ci_alcotest))
DUNE
cat >"$tmp/node/c/dune" <<'DUNE'
(test (name test_four) (libraries ci_alcotest))
DUNE
printf '(test (name stale) (libraries ci_alcotest))\n' >"$tmp/node/_build/default/x/dune"
printf '(test (name vendored) (libraries ci_alcotest))\n' >"$tmp/node/ui/node_modules/y/dune"

got="$(bash "$list" "$tmp/node")"
want="$(printf '%s\n' test_four test_one test_three test_two)"
[ "$got" = "$want" ] || fail "fixture tree listed:
$got
expected:
$want"

real="$(bash "$list")"
[ -n "$real" ] || fail "node/ in this checkout lists no binary"
grep -qx 'test_core' <<<"$real" || fail "node/ in this checkout does not list test_core"

echo "test-binaries-test.sh: ok"
