# shellcheck shell=bash
#
# TEST HEALTH, THE SHELL HALF, FOR A dune AND alcotest REPOSITORY (ISS-19890,
# design DES-18577 "Every repository with CI"). A copy of devops
# templates/dune/ci/dune-test.sh; the OCaml half is a copy of
# templates/dune/test/ci_alcotest.ml, which every suite's `Alcotest.run` goes
# through. Sourced by the build script (ci/build.fast.sh or ci/build.slow.sh), which then runs
#
#     ci_dune_test <reports dir> <the command that runs the suite...>
#
# and declares `# ci-test-reports: <reports dir>/*.xml` and
# `# ci-test-lists: required`. The command is a command or a shell function;
# it runs once, and once more if a binary failed.
#
# THE LISTS. `CI_TEST_LISTS` names a file whose first line is the lists version
# and every line after it `quarantined <spec>`, `slow <spec>` or `proof <spec>`,
# a spec being `<binary>.<group>.<case>` or a bare binary. The line printed is
# `ci-lists: version <n> quarantined <n> slow <n>`. UNSET LEAVES NOTHING OUT,
# which is a session's working tree. A FILE THAT IS NOT THE FORMAT IS THE BOX
# AND NOT THE BRANCH: nothing is run and the answer is 75. So is
# `CI_SLOW_SPECS=1` with no lists, which runs only the slow specs and has none.
#
# THE RERUN. A run that fails is asked which binaries failed — each binary
# records `running`, `passed` or `failed`, so one that died mid-run reads as
# failed rather than as nothing — and those binaries run once more. Each spec
# that failed the first run keeps that run's report as `FIRST-<spec>.xml` and
# prints `ci-flake: <spec>` when its rerun passed, or
# `ci-rerun: failed again: <spec>` when it did not; then `ci-rerun: done`. The
# build passes when every rerun binary passed. A failure no binary owns (a
# suite that does not compile) is not rerun: its status stands.

ci_lists_summary() {               # ci_lists_summary <file>
  awk '
    function refuse(why) { printf "line %d: %s\n", NR, why >"/dev/stderr"; bad = 1; exit 2 }
    { sub(/\r$/, "") }
    NR == 1 { if ($0 ~ /^(version )?[0-9]+$/) { version = $NF; next } refuse("not a lists version") }
    /^[ \t]*$/ { next }
    /^quarantined [^ \t]+$/ { quarantined++; next }
    /^slow [^ \t]+$/ { slow++; next }
    /^proof [^ \t]+$/ { next }
    { refuse("neither quarantined, slow nor proof") }
    END {
      if (bad) exit 2
      if (NR == 0) { print "the file is empty" >"/dev/stderr"; exit 2 }
      printf "ci-lists: version %s quarantined %d slow %d\n", version, quarantined, slow
    }
  ' "$1"
}

# The binaries of the last run that did not pass: `failed`, or still `running`
# because they died before alcotest could answer.
ci_dune_failed_binaries() {        # ci_dune_failed_binaries <reports dir>
  local f
  for f in "$1"/.ci-binaries/*; do
    [ -f "$f" ] || continue
    [ "$(cat "$f")" = "passed" ] || basename "$f"
  done
}

ci_dune_test() {                   # ci_dune_test <reports dir> <command...>
  local reports="$1"; shift
  local slow="" status=0 started f spec bin again=0
  [ "${CI_SLOW_SPECS:-}" != "1" ] || slow=1

  if [ -n "${CI_TEST_LISTS:-}" ]; then
    if ! ci_lists_summary "$CI_TEST_LISTS"; then
      echo "ci/dune-test.sh: INFRASTRUCTURE FAULT — CI_TEST_LISTS=$CI_TEST_LISTS is not a lists file, so this build cannot know which specs to leave out; nothing about the tree was measured" >&2
      return 75
    fi
    CI_ALCOTEST_LISTS="$(cat "$CI_TEST_LISTS")"
  elif [ -n "$slow" ]; then
    echo "ci/dune-test.sh: INFRASTRUCTURE FAULT — CI_SLOW_SPECS=1 runs only the slow specs and CI_TEST_LISTS names no lists; nothing about the tree was measured" >&2
    return 75
  else
    echo "ci-lists: none (CI_TEST_LISTS is unset; nothing is left out)"
    CI_ALCOTEST_LISTS=""
  fi
  CI_SLOW_SPECS="$slow"
  CI_ALCOTEST_RERUN=""
  rm -rf "$reports"
  mkdir -p "$reports"
  CI_ALCOTEST_REPORTS="$(cd "$reports" && pwd)"
  reports="$CI_ALCOTEST_REPORTS"
  export CI_ALCOTEST_LISTS CI_SLOW_SPECS CI_ALCOTEST_RERUN CI_ALCOTEST_REPORTS

  started=$SECONDS
  "$@" || status=$?
  echo "ci-test-phase: $((SECONDS - started))s"
  [ "$status" -ne 0 ] || return 0

  local binaries=()
  while IFS= read -r bin; do binaries+=("$bin"); done < <(ci_dune_failed_binaries "$reports")
  if [ "${#binaries[@]}" -eq 0 ]; then
    echo "ci-rerun: nothing to rerun — the run failed (exit $status) and no binary did"
    return "$status"
  fi

  local failed=()
  for f in "$reports"/TEST-*.xml; do
    [ -f "$f" ] || continue
    grep -q '<failure' "$f" || continue
    spec="$(basename "$f" .xml)"
    spec="${spec#TEST-}"
    mv "$f" "$reports/FIRST-$spec.xml"
    failed+=("$spec")
  done

  echo "ci-rerun: rerunning ${#binaries[@]} failed binary(ies) once: ${binaries[*]}"
  CI_ALCOTEST_RERUN="${binaries[*]}"
  rm -rf "$reports/.ci-binaries"
  started=$SECONDS
  "$@" || true
  echo "ci-test-phase: $((SECONDS - started))s"
  CI_ALCOTEST_RERUN=""

  for spec in ${failed[@]+"${failed[@]}"}; do
    f="$reports/TEST-$spec.xml"
    if [ -f "$f" ] && ! grep -q '<failure' "$f"; then
      echo "ci-flake: $spec"
    else
      echo "ci-rerun: failed again: $spec"
    fi
  done
  for bin in "${binaries[@]}"; do
    if [ "$(cat "$reports/.ci-binaries/$bin" 2>/dev/null)" != "passed" ]; then
      echo "ci-rerun: binary failed again: $bin"
      again=1
    fi
  done
  echo "ci-rerun: done"
  [ "$again" -eq 0 ] || return "$status"
  return 0
}
