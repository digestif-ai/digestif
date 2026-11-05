#!/usr/bin/env bash
#
# Tests ci/pipe-readers.sh. First the failure it exists for, measured: the old missing_assets shape
# (a variable printed into grep -qxF under pipefail) against an input far larger than a pipe's
# buffer fails although the line it asks for is the first one, and the here-string #258 put in its
# place succeeds on the same input. Then the check: it refuses that shape, a printf of a variable
# into grep -q, head, grep -m and a pipe continued on the next line, each named by file and line; it
# passes the here-string, grep reading its whole input, ||, a whole-line comment, and a site carrying
# the allow marker with a reason, and refuses the marker without one. Last, it passes every ci/*.sh
# in this checkout. ci/build.sh runs it; it needs nothing but bash, awk and grep.
#
# The fixtures spell the pipe as "$bar" so that this file holds no site of its own.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check="$root/ci/pipe-readers.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bar='|'

fail() {
  echo "pipe-readers-test.sh: $*" >&2
  exit 1
}

# The failure, measured. 200,000 lines is several megabytes, so printf is still writing when grep -q
# has its match on the first line and exits.
awk 'BEGIN { print "digestif-linux-arm64.tar.gz"; for (i = 0; i < 200000; i++) print "asset-" i ".tar.gz" }' \
  >"$tmp/assets"
shape() {
  printf '%s\n' "set -euo pipefail" 'have="$(cat "$1")"' 'a="digestif-linux-arm64.tar.gz"' "$1" >"$2"
}
shape "printf '%s\\n' \"\$have\" $bar grep -qxF \"\$a\"" "$tmp/old-shape.sh"
shape "grep -qxF \"\$a\" <<<\"\$have\"" "$tmp/here-string.sh"
if bash "$tmp/old-shape.sh" "$tmp/assets" 2>/dev/null; then
  fail "the old missing_assets shape found the first line of a large input; expected the broken pipe to fail it"
fi
bash "$tmp/here-string.sh" "$tmp/assets" || fail "the here-string did not find the first line of the same input"
bash "$check" "$tmp/old-shape.sh" >/dev/null 2>&1 && fail "the check passed the old missing_assets shape"
bash "$check" "$tmp/here-string.sh" >/dev/null 2>&1 || fail "the check refused the here-string"

# Each case is one fixture file; refused cases must be named file:line, passed ones print nothing.
refused() {
  local what="$1" line="$2" body="$3" f out
  f="$tmp/refused-$RANDOM.sh"
  printf '%s\n' "$body" >"$f"
  if out="$(bash "$check" "$f" 2>/dev/null)"; then
    fail "$what: passed, expected it refused"
  fi
  grep -qF "$f:$line:" <<<"$out" || fail "$what: expected $f:$line: in what it printed, got: $out"
}
passed() {
  local what="$1" body="$2" f out
  f="$tmp/passed-$RANDOM.sh"
  printf '%s\n' "$body" >"$f"
  out="$(bash "$check" "$f" 2>&1)" || fail "$what: refused, expected it passed: $out"
}

refused "missing_assets, as it was before #258" 3 "set -euo pipefail
expected_assets \"\$tag\" $bar while IFS= read -r a; do
  printf '%s\\n' \"\$have\" $bar grep -qxF \"\$a\" || echo \"\$a\"
done"
refused "a printf of a variable into grep -q" 2 "set -euo pipefail
if printf '%s\\n' \"\$out\" $bar grep -q '^missing '; then echo waiting; fi"
refused "head -1" 1 "newest=\"\$(release_tags $bar head -1)\""
refused "head with no argument" 1 "release_tags $bar head"
refused "grep -m" 1 "release_tags $bar grep -m1 relay"
refused "grep --quiet" 1 "tar --version $bar grep --quiet 'GNU tar'"
refused "grep -q after an option" 1 "readelf -l \"\$exe\" $bar grep -E -q 'INTERP'"
refused "egrep -q" 1 "tar --version $bar egrep -q 'GNU'"
refused "a pipe continued on the next line" 2 "echo start
release_tags $bar
  head -1"
refused "a pipe continued after a comment" 1 "release_tags $bar  # the newest first
  head -1"
refused "a pipe continued after a backslash" 1 "release_tags $bar \\
  head -1"
refused "the second pipe of a line" 1 "release_tags $bar sort $bar head -1"
refused "an allow marker with no reason" 1 "uname -a $bar head -1  # early-exit-ok:"

passed "a here-string" "grep -qxF \"\$a\" <<<\"\$have\""
passed "grep reading its whole input" "tar -tzf x.tar.gz $bar grep -E '^bin/digestif-update\$' >/dev/null"
passed "grep with a pattern that looks like an option after it" "printf x $bar grep -e -q"
passed "grep after --" "printf x $bar grep -- -q"
passed "a word that only starts with head" "printf x $bar headline"
passed "||" "grep -q x file || head -1 file"
passed "a whole-line comment" "  # printf '%s\\n' \"\$have\" $bar grep -qxF \"\$a\""
passed "the allow marker" "uname -a $bar head -1  # early-exit-ok: one line, written before head reads it"
passed "the allow marker on a continued pipe" "release_tags $bar  # early-exit-ok: release_tags stops itself
  head -1"

# Every ci/*.sh in this checkout.
out="$(bash "$check" 2>&1)" || fail "ci/*.sh holds a pipe into a reader that stops early: $out"

echo "pipe-readers-test.sh: ok"
