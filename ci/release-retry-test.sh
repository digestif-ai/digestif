#!/usr/bin/env bash
#
# Tests ci/release-retry.sh against a fake `gh` answering from fixture files: a run whose only
# failed and cancelled jobs carry the not-acquired annotation is re-run, and only under `rerun`; a
# run with one job that failed for another reason, a run on its third attempt, and a run with no
# failed job are left as they stand; a failed API read exits non-zero. ci/build.slow.sh runs it; it
# needs bash and jq and no network.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
retry="$root/ci/release-retry.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "release-retry-test.sh: $*" >&2
  exit 1
}

# The fake gh: `gh api [--paginate] [--method M] PATH [--jq EXPR]` answers GET from
# $tmp/api/PATH.json through jq, and records a POST in $tmp/posts.
mkdir -p "$tmp/bin" "$tmp/api"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || exit 9
shift
method=GET path="" expr=.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paginate) shift ;;
    --method) method="$2"; shift 2 ;;
    --jq) expr="$2"; shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
if [ "$method" = POST ]; then
  echo "$path" >>"$FAKE_GH_DIR/posts"
  exit 0
fi
file="$FAKE_GH_DIR/api/$path.json"
[ -f "$file" ] || { echo "fake gh: no fixture for $path" >&2; exit 1; }
jq -r "$expr" "$file"
GH
chmod 755 "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" FAKE_GH_DIR="$tmp"

repo=digestif-ai/digestif
not_acquired='[{"message":"The job was not acquired by Runner of type hosted even after multiple attempts"}]'

jobs() { # RUN ATTEMPT JSON
  mkdir -p "$tmp/api/repos/$repo/actions/runs/$1/attempts/$2"
  printf '%s\n' "$3" >"$tmp/api/repos/$repo/actions/runs/$1/attempts/$2/jobs.json"
}
annotations() { # JOB JSON
  mkdir -p "$tmp/api/repos/$repo/check-runs/$1"
  printf '%s\n' "$2" >"$tmp/api/repos/$repo/check-runs/$1/annotations.json"
}
expect() { # WANT MODE RUN ATTEMPT
  local got
  got="$(bash "$retry" "$2" "$repo" "$3" "$4")" || fail "$2 $3 $4 exited $?: $got"
  [ "${got%%$'\n'*}" = "$1" ] || fail "$2 $3 $4 printed '$got', expected '$1'"
}
posts() { cat "$tmp/posts" 2>/dev/null || true; }

annotations 11 "$not_acquired"
annotations 12 "$not_acquired"
annotations 13 '[{"message":"Process completed with exit code 1."}]'
annotations 14 '[]'

# Only not-acquired jobs failed: one failure and one cancel, the rest passed or were skipped.
jobs 100 1 '{"jobs":[
  {"id":1,"name":"plan","conclusion":"success"},
  {"id":11,"name":"build darwin-arm64","conclusion":"failure"},
  {"id":12,"name":"test node darwin-arm64","conclusion":"cancelled"},
  {"id":2,"name":"build linux-x86_64","conclusion":"success"},
  {"id":3,"name":"publish","conclusion":"skipped"}]}'
expect "retry: build darwin-arm64, test node darwin-arm64" decide 100 1
[ -z "$(posts)" ] || fail "decide re-ran a run: $(posts)"
expect "retry: build darwin-arm64, test node darwin-arm64" rerun 100 1
[ "$(posts)" = "repos/$repo/actions/runs/100/rerun-failed-jobs" ] || fail "rerun posted: $(posts)"
: >"$tmp/posts"

# The second attempt is retried once more, the third never.
jobs 100 2 '{"jobs":[{"id":11,"name":"build darwin-arm64","conclusion":"cancelled"}]}'
expect "retry: build darwin-arm64" rerun 100 2
: >"$tmp/posts"
jobs 100 3 '{"jobs":[{"id":11,"name":"build darwin-arm64","conclusion":"cancelled"}]}'
expect "final: attempt 3 is the last this retries" rerun 100 3
[ -z "$(posts)" ] || fail "the third attempt was re-run"

# A real red beside a not-acquired cancel: the run fails as it stands.
jobs 200 1 '{"jobs":[
  {"id":11,"name":"build darwin-arm64","conclusion":"cancelled"},
  {"id":13,"name":"check linux-x86_64","conclusion":"failure"}]}'
expect "final: check linux-x86_64 ended failure, not for lack of a runner" rerun 200 1
[ -z "$(posts)" ] || fail "a run with a real failure was re-run"

# A job that timed out carries no annotation.
jobs 300 1 '{"jobs":[{"id":14,"name":"build darwin-arm64","conclusion":"timed_out"}]}'
expect "final: build darwin-arm64 ended timed_out, not for lack of a runner" rerun 300 1

# No failed job (the plan refused, say, failing the run before any job): nothing to retry.
jobs 400 1 '{"jobs":[{"id":1,"name":"plan","conclusion":"success"}]}'
expect "final: no job of attempt 1 failed" rerun 400 1
[ -z "$(posts)" ] || fail "a run with no failed job was re-run"

# An API read that fails is an error, never a verdict.
if bash "$retry" rerun "$repo" 500 1 >/dev/null 2>&1; then
  fail "a run whose jobs could not be read exited 0"
fi
jobs 600 1 '{"jobs":[{"id":99,"name":"build darwin-arm64","conclusion":"cancelled"}]}'
if bash "$retry" rerun "$repo" 600 1 >/dev/null 2>&1; then
  fail "a job whose annotations could not be read exited 0"
fi
[ -z "$(posts)" ] || fail "a run that could not be read was re-run"

echo "release-retry-test.sh: ok"
