#!/usr/bin/env bash
#
# One test node (docs/releases.md, Test nodes): on a throwaway runner, takes a signed version the
# way a member's node does, before any member can. It installs the last published version under its
# supervisor and the service manager, runs `digestif update apply --feed <candidate>`, restarts the
# service for the trial, restarts it again so the new version's own supervisor runs, and runs one
# more update pass with the new version's code. With nothing published yet, the version installs
# directly and the rest is the same.
#
#   ci/test-node.sh VERSION [--feed DIR_OR_URL] [--channel DIR_OR_URL]
#
# --feed is the candidate feed and --channel the published one; by default both are on the channel
# branch of this repository. A local directory is what the rehearsal uses
# (ci/test-node-rehearsal.sh).
#
# Exits 0 when the node took the version, 1 when the version failed on it (refused, rolled back, or
# its own supervisor or update pass did not work), and 75 when this run observed nothing about the
# version, such as a download or a runner that would not start a service. The Release workflow and
# `ci/release.sh test-nodes` keep 1 and 75 apart, since only 1 ends a rollout. It takes over the
# machine's com.digestif.node service, so it runs only on a throwaway runner: anywhere GITHUB_ACTIONS
# is not set, it refuses.

set -uo pipefail

no() {
  echo "test-node.sh: VERSION FAILED: $*" >&2
  show_logs
  exit 1
}
unobserved() {
  echo "test-node.sh: NOT OBSERVED: $*" >&2
  show_logs
  exit 75
}
step() { printf '\n==> %s\n' "$*"; }

[ "${GITHUB_ACTIONS:-}" = true ] || {
  echo "test-node.sh: this replaces the machine's Digestif service, so it runs only on a CI runner" >&2
  exit 2
}
[ $# -ge 1 ] || {
  echo "usage: ci/test-node.sh VERSION [--feed DIR_OR_URL] [--channel DIR_OR_URL]" >&2
  exit 2
}
version="$1"
shift
repo="${GITHUB_REPOSITORY:-digestif-ai/digestif}"
channel="https://raw.githubusercontent.com/$repo/channel/"
feed=""
while [ $# -gt 0 ]; do
  case "$1" in
    --feed) feed="$2"; shift 2 ;;
    --channel) channel="$2"; shift 2 ;;
    *) echo "test-node.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$feed" ] || feed="${channel%/}/candidate/"

work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/test-node.XXXXXX")"
data="$work/data"
label=com.digestif.node
unit=digestif.service

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) unobserved "no test node on $(uname -s)" ;;
esac
case "$(uname -m)" in
  arm64 | aarch64) platform="$os-arm64" ;;
  x86_64 | amd64) platform="$os-x86_64" ;;
  *) unobserved "no test node on $(uname -m)" ;;
esac

show_logs() {
  step "what the node said"
  case "$os" in
    darwin) tail -n 60 "$data/digestif.log" 2>/dev/null ;;
    linux) journalctl --user -u "$unit" --no-pager -n 60 2>/dev/null ;;
  esac
  cat "$data/update-report.json" 2>/dev/null
}

# A systemd user manager that runs with no login session, which is what a runner has.
prepare_service_manager() {
  [ "$os" = linux ] || return 0
  sudo loginctl enable-linger "$(id -un)" || return 1
  XDG_RUNTIME_DIR="/run/user/$(id -u)"
  DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  export XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
  local i
  for i in $(seq 1 30); do
    systemctl --user is-system-running >/dev/null 2>&1
    [ $? -ne 1 ] && [ -S "$XDG_RUNTIME_DIR/bus" ] && return 0
    sleep 1
  done
  return 1
}

restart_service() {
  case "$os" in
    darwin) launchctl kickstart -k "gui/$(id -u)/$label" ;;
    linux) systemctl --user restart "$unit" ;;
  esac
}

fetch() {
  case "$1" in
    https://*) curl --fail --silent --show-error --location --retry 3 --max-time 600 "$1" ;;
    *) cat "$1" ;;
  esac
}

# The newest version the channel publishes that is older than this one, or nothing.
last_published() {
  fetch "${channel%/}/index.json" | jq -r --arg v "$version" '
    def key: split(".") | map(tonumber);
    [ .releases[].version | select(key < ($v | key)) ] | sort_by(key) | last // empty'
}

# Unpacks this platform's archive of the manifest at $1 into $2, checking its sha256.
unpack() {
  local manifest="$1" into="$2" url want got archive
  url="$(jq -r --arg p "$platform" '.artifacts[] | select(.platform == $p) | .url' "$manifest")"
  want="$(jq -r --arg p "$platform" '.artifacts[] | select(.platform == $p) | .sha256' "$manifest")"
  [ -n "$url" ] || return 2
  archive="$work/archive.tar.gz"
  fetch "$url" >"$archive" || return 1
  got="sha256:$(shasum -a 256 "$archive" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || return 3
  mkdir -p "$into" && tar -xzf "$archive" -C "$into" || return 3
}

# Waits for the node to report healthy as $1, for $2 seconds.
wait_healthy() {
  local want="$1" budget="$2" start=$SECONDS
  while [ $((SECONDS - start)) -lt "$budget" ]; do
    [ "$(jq -r .version "$data/health.json" 2>/dev/null)" = "$want" ] && return 0
    sleep 2
  done
  return 1
}

# Installs an unpacked release as a member's first install does and starts its service.
service_install() {
  local unpacked="$1"
  # `service install` stages it as a release, self-tests it, and starts the service.
  "$unpacked/bin/digestif" service install --behaviors "$unpacked/behaviors" --data-dir "$data"
}

check() { "$data/current/bin/digestif" update check --data-dir "$data" --feed "$feed"; }

step "$platform: the service manager"
prepare_service_manager || unobserved "the runner gave no service manager"

step "what is published"
if ! start="$(last_published)"; then
  unobserved "the channel's index.json could not be read"
fi

manifest="$work/manifest.json"
if [ -n "$start" ]; then
  step "install the last published version, $start"
  fetch "${channel%/}/$start/manifest.json" >"$manifest" || unobserved "the manifest of $start could not be read"
  unpack "$manifest" "$work/start"
  case $? in
    0) ;;
    2)
      # A platform added since the last published version has nothing to update from.
      echo "$start has no archive for $platform, so $version installs directly"
      start=""
      ;;
    *) unobserved "$start could not be fetched for $platform" ;;
  esac
fi

if [ -n "$start" ]; then
  service_install "$work/start" || unobserved "$start did not install"
  wait_healthy "$start" 300 || unobserved "$start did not report healthy under its supervisor"
  # Its first pass reads the channel and writes the report, so the apply below is the only writer of
  # update.json.
  i=0
  until [ -f "$data/update-report.json" ] || [ $i -ge 60 ]; do
    sleep 2
    i=$((i + 1))
  done
  check

  step "update apply --feed $feed"
  out="$("$data/current/bin/digestif" update apply --data-dir "$data" --feed "$feed" 2>&1)" ||
    unobserved "update apply exited nonzero: $out"
  echo "$out"
  case "$out" in
    *"switched to $version"*) ;;
    *"was refused"* | *"was not installed"*) no "$start would not take it: $out" ;;
    *) unobserved "the pass switched to nothing: $out" ;;
  esac

  step "the restart: the supervisor of $start runs $version on trial"
  restart_service || unobserved "the service did not restart"
  # The supervisor's bound is ten minutes of awake time, so this outlasts its verdict.
  deadline=$((SECONDS + 720))
  while :; do
    state="$(check 2>&1)"
    case "$state" in
      *"refused for good $version"*) no "the node rolled it back: $state" ;;
    esac
    if printf '%s\n' "$state" | grep -qx "installed $version" &&
      ! printf '%s\n' "$state" | grep -q '^on trial'; then
      break
    fi
    [ "$SECONDS" -lt "$deadline" ] || unobserved "no verdict on the trial: $state"
    sleep 5
  done
  echo "$version is healthy on trial"
else
  step "nothing to update from: install $version directly"
  fetch "${feed%/}/$version/manifest.json" >"$manifest" || unobserved "the manifest of $version could not be read"
  unpack "$manifest" "$work/version"
  case $? in
    0) ;;
    1) unobserved "$version could not be fetched for $platform" ;;
    *) no "this platform's archive is missing or does not match the manifest" ;;
  esac
  service_install "$work/version" || no "$version did not install"
fi

step "the restart: $version's own supervisor"
wait_healthy "$version" 300 || no "$version did not report healthy"
rm -f "$data/health.json"
restart_service || unobserved "the service did not restart"
wait_healthy "$version" 300 || no "$version's own supervisor did not bring it back"
supervisor="$(readlink "$data/good")"
echo "good is $supervisor"

step "a second update pass, $version's own code"
for attempt in 1 2 3; do
  out="$("$data/current/bin/digestif" update apply --data-dir "$data" --feed "$feed" 2>&1)"
  status=$?
  echo "$out"
  case "$status:$out" in
    0:*"could not be read"* | 0:*"update check failed"*) ;;
    0:*"was refused"* | 0:*"was not installed"*) no "the second pass refused something: $out" ;;
    0:*"nothing switched"*) break ;;
    *) no "the second pass did not finish: $out" ;;
  esac
  [ "$attempt" -lt 3 ] || no "the second pass could not read the channel: $out"
  sleep 30
done
state="$(check)" || no "update check failed: $state"
echo "$state"
printf '%s\n' "$state" | grep -qx "installed $version" || no "the node does not say it installed $version"
printf '%s\n' "$state" | grep -q '^refused for good' && no "the node refused a version: $state"

step "$platform took $version"
exit 0
