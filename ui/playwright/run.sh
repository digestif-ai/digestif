#!/usr/bin/env bash
#
# Runs `npx playwright test` and exits 75, the exit every infrastructure fault leaves, when the run
# failed only on the machine: every test that failed did so on its last attempt to something
# playwright/faults.ts calls an infra fault (Chromium's net::ERR_NETWORK_CHANGED, ISS-81796), which
# playwright/infra-reporter.ts writes down. Any other failure keeps the suite's own exit.
#
#   playwright/run.sh [playwright test args]

set -uo pipefail

ui="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verdict="$ui/test-results/infra-verdict.txt"
rm -f "$verdict"
cd "$ui"
npx playwright test "$@"
code=$?
if [ "$code" -ne 0 ] && [ -s "$verdict" ]; then
  echo "playwright/run.sh: every failed test failed on the machine, not the code; exit 75 (infrastructure fault):" >&2
  sed 's/^/  /' "$verdict" >&2
  exit 75
fi
exit "$code"
