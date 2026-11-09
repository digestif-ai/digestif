#!/usr/bin/env bash
#
# Re-runs a failed Release run whose only failures are jobs GitHub never started for lack of a
# hosted runner (docs/releases.md, A job no runner took). GitHub-hosted macOS arm64 runners run
# short: a job waits, then GitHub cancels it with the annotation "The job was not acquired by Runner
# of type hosted even after multiple attempts", and the run fails though nothing in the code is
# wrong. `.github/workflows/release-retry.yml` runs this when a Release run completes.
#
#   ci/release-retry.sh decide REPO RUN ATTEMPT   prints `retry: <jobs>` or `final: <why>`
#   ci/release-retry.sh rerun REPO RUN ATTEMPT    the same, and on `retry` re-runs the failed jobs
#
# REPO is owner/name, RUN the run's id and ATTEMPT the attempt that completed. A run is retried only
# when every job of that attempt that ended neither success nor skipped carries the annotation, and
# only while ATTEMPT is below 3: two retries, then the run fails as it stands. A job that failed for
# any other reason is never retried, so a real red still fails. It reads through `gh api` (the
# attempt's jobs, and each job's check-run annotations, a job's id being its check run's) and writes
# only the rerun. Exits non-zero when an API call fails.

set -euo pipefail

not_acquired='was not acquired by Runner'
max_attempts=3

die() {
  echo "release-retry.sh: $*" >&2
  exit 2
}

decide() {
  local repo="$1" run="$2" attempt="$3" failed id conclusion name messages names=""
  [[ "$attempt" =~ ^[1-9][0-9]*$ ]] || die "attempt $attempt is not a number"
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "final: attempt $attempt is the last this retries"
    return
  fi
  failed="$(gh api --paginate "repos/$repo/actions/runs/$run/attempts/$attempt/jobs" \
    --jq '.jobs[] | select(.conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral")
          | [.id, (.conclusion // "unfinished"), .name] | @tsv')" ||
    die "could not list the jobs of run $run attempt $attempt"
  if [ -z "$failed" ]; then
    echo "final: no job of attempt $attempt failed"
    return
  fi
  while IFS=$'\t' read -r id conclusion name; do
    messages="$(gh api --paginate "repos/$repo/check-runs/$id/annotations" --jq '.[].message')" ||
      die "could not read the annotations of job $id ($name)"
    if ! grep -qF "$not_acquired" <<<"$messages"; then
      echo "final: $name ended $conclusion, not for lack of a runner"
      return
    fi
    names="${names:+$names, }$name"
  done <<<"$failed"
  echo "retry: $names"
}

[ "$#" -eq 4 ] || die "usage: ci/release-retry.sh decide|rerun REPO RUN ATTEMPT"
mode="$1"
repo="$2"
run="$3"
attempt="$4"
[[ "$run" =~ ^[0-9]+$ ]] || die "run $run is not a run id"

verdict="$(decide "$repo" "$run" "$attempt")"
echo "$verdict"
case "$mode" in
  decide) ;;
  rerun)
    if [ "${verdict%%:*}" = retry ]; then
      gh api --method POST "repos/$repo/actions/runs/$run/rerun-failed-jobs" >/dev/null ||
        die "could not re-run the failed jobs of run $run"
      echo "re-ran the failed jobs of run $run (attempt $((attempt + 1)))"
    fi
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "Release run $run attempt $attempt: $verdict" >>"$GITHUB_STEP_SUMMARY"
    fi
    ;;
  *) die "unknown mode $mode" ;;
esac
