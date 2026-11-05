#!/usr/bin/env bash
#
# Refuses a pipe into a reader that stops before its input ends: `head`, and `grep` with -q, -m,
# --quiet, --silent or --max-count (egrep and fgrep too). Once such a reader has what it wants it
# exits, the producer's next write fails with a broken pipe, and under `set -o pipefail` the
# pipeline fails although the reader found its match. Whether the producer is still writing depends
# on how much it has left and on scheduling, so the failure is intermittent: `printf '%s\n' "$have" |
# grep -qxF "$a"` reported a release asset missing that the release held (ISS-47724).
#
#   ci/pipe-readers.sh             checks every ci/*.sh
#   ci/pipe-readers.sh FILE...     checks the files named
#
# Prints file:line: and the line for every site it refuses, and exits 1 when there is one.
#
# The remedy is to give the reader all of its input before it can stop: a here-string
# (`grep -qxF "$a" <<<"$have"`), a parameter expansion (`${text%%$'\n'*}` for the first line), or
# a producer with a stop condition of its own, so nothing is left to write. A site whose producer
# provably writes nothing after the match carries the allow marker on the same line (or on any line
# of a pipe continued with a trailing `|`), followed by why:
#
#   uname -a | head -1  # early-exit-ok: one line, written before head reads it
#
# A whole-line comment is never a site. ci/build.sh runs this; ci/pipe-readers-test.sh tests it.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -eq 0 ]; then
  set -- "$root"/ci/*.sh
fi

status=0
for file in "$@"; do
  [ -f "$file" ] || {
    echo "ci/pipe-readers.sh: $file is not a file" >&2
    exit 2
  }
  awk -v name="${file#"$root"/}" '
    # The reader a pipe feeds, from the text after the "|": "head", or "grep" with an option that
    # stops it at a match. Options are read up to the first word that is not one (the pattern).
    function early_reader(rest,   n, w, i) {
      sub(/^&/, "", rest)
      sub(/^[[:space:]]+/, "", rest)
      if (rest ~ /^head([[:space:];)|&]|$)/) return 1
      if (rest !~ /^[ef]?grep([[:space:]]|$)/) return 0
      n = split(rest, w, /[[:space:]]+/)
      for (i = 2; i <= n; i++) {
        if (w[i] == "--") return 0
        if (w[i] ~ /^--(quiet|silent|max-count)/) return 1
        if (w[i] ~ /^--/) continue
        if (w[i] == "-e" || w[i] == "-f") { i++; continue }
        if (w[i] !~ /^-[A-Za-z0-9]/) return 0
        # A cluster of short options; -e and -f take the rest of the cluster as their argument.
        opts = w[i]
        sub(/[ef].*$/, "", opts)
        if (opts ~ /[qm]/) return 1
      }
      return 0
    }

    # Every "|" that is a pipe: not half of "||".
    function refuses(text,   i, c) {
      for (i = 1; i <= length(text); i++) {
        if (substr(text, i, 1) != "|") continue
        if (substr(text, i + 1, 1) == "|") { i++; continue }
        if (i > 1 && substr(text, i - 1, 1) == "|") continue
        if (early_reader(substr(text, i + 1))) return 1
      }
      return 0
    }

    function marked(text) {
      return text ~ /#[[:space:]]*early-exit-ok:[[:space:]]*[^[:space:]]/
    }

    function check(text, line, shown) {
      if (allowed) return
      if (refuses(text)) {
        printf "%s:%d: %s\n", name, line, shown
        found = 1
      }
    }

    {
      if ($0 ~ /^[[:space:]]*#/ && pending == "") next
      if (pending == "") { start = NR; first = $0; allowed = 0 }
      if (marked($0)) allowed = 1
      # A pipe continued on the next line, after a trailing comment or a backslash or neither:
      # read it as one line, reported at its first.
      bare = $0
      sub(/[[:space:]]+#.*$/, "", bare)
      sub(/[[:space:]]*\\[[:space:]]*$/, "", bare)
      if (bare ~ /\|[[:space:]]*$/ && bare !~ /\|\|[[:space:]]*$/) {
        pending = pending bare " "
        next
      }
      check(pending $0, start, first)
      pending = ""
    }

    END {
      if (pending != "") check(pending, start, first)
      exit found
    }
  ' "$file" || status=1
done

if [ "$status" -ne 0 ]; then
  {
    echo
    echo "ci/pipe-readers.sh: a reader above can stop before its input ends, and under pipefail the"
    echo "producer's broken pipe then fails the pipeline. Give the reader all of its input (a"
    echo "here-string, a parameter expansion, a producer that stops itself), or, where the producer"
    echo "provably writes nothing after the match, mark the line '# early-exit-ok: <why>'."
  } >&2
fi
exit "$status"
