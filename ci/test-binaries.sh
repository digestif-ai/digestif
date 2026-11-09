#!/usr/bin/env bash
#
# Prints every Test Health binary the node defines, one per line, sorted: the name of each
# `(test ...)` and `(tests ...)` stanza under the directory given (node/ by default) whose
# libraries include ci_alcotest, so whose run goes through Ci_alcotest and is named for its
# binary. ci/build.slow.sh writes this to the file CI_TEST_BINARIES names, which is how devops'
# dune-test.sh tells a listed spec of a binary deleted from the tree (`ci-lists: unknown`) from
# one dune simply did not rerun. A stanza that runs without ci_alcotest writes no specs and is
# never listed, so it is left out.
#
#   ci/test-binaries.sh [<dir>]
#
# The dune files are read as text: comments are dropped, then each top-level stanza is read by
# paren depth. Every binary that wrote specs in a run must appear here; ci/build.slow.sh checks
# that after the suite, so a stanza this misses fails the build rather than calling its rows gone.

set -euo pipefail

dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../node" && pwd)}"

find "$dir" \( -name _build -o -name node_modules -o -name '.*' ! -name . \) -prune -o -type f -name dune -print |
  LC_ALL=C sort |
  while IFS= read -r f; do
    awk '
      # One stanza: its head is (test or (tests, it links ci_alcotest, and its names follow
      # (name or (names.
      function flush(   s, m, n, i, parts) {
        s = stanza
        stanza = ""
        if (s !~ /^[ \t\n]*\([ \t\n]*tests?[ \t\n]/) return
        if (s !~ /[( \t\n]ci_alcotest[) \t\n]/) return
        if (match(s, /\([ \t\n]*names?[ \t\n]+[^()]*\)/)) {
          m = substr(s, RSTART, RLENGTH)
          sub(/^\([ \t\n]*names?[ \t\n]+/, "", m)
          sub(/\)$/, "", m)
          n = split(m, parts, /[ \t\n]+/)
          for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
        }
      }
      {
        line = $0
        sub(/;.*/, "", line)
        for (i = 1; i <= length(line); i++) {
          c = substr(line, i, 1)
          if (depth > 0 || c == "(") stanza = stanza c
          if (c == "(") depth++
          else if (c == ")") { depth--; if (depth == 0) flush() }
        }
        if (depth > 0) stanza = stanza "\n"
      }
    ' "$f"
  done |
  LC_ALL=C sort -u
