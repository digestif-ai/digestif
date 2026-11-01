#!/usr/bin/env bash
#
# Builds the node from this checkout, with its web UI embedded, puts the binary where the running
# service runs it, and restarts the service so it runs the new code. This is the upgrade step for a
# member who builds from source:
#
#   git pull && ./install.sh
#
#   ./install.sh                 build, replace the binary the service runs, restart the service
#   ./install.sh --to <path>     install to <path> instead; the service restarts only when it runs <path>
#   ./install.sh --service       also install the service when none is installed (a first install)
#
# Where it installs, first match wins: --to; the binary the installed launchd agent or systemd
# unit runs; `digestif` on PATH; ~/.local/bin/digestif. A symlink is followed to the file it names,
# as self-update does. The old binary is kept beside the new one as <binary>.previous.
#
# It builds and runs no tests; ci/build.sh is the whole check. `set -euo pipefail` is not style: a
# swallowed failure would install a binary that never built.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
label="com.digestif.node"
unit="digestif.service"

step() { printf '\n==> %s\n' "$*"; }
die() {
  echo "install.sh: $*" >&2
  exit 1
}

to=""
want_service=0
while [ $# -gt 0 ]; do
  case "$1" in
    --to)
      [ $# -ge 2 ] || die "--to needs a path"
      to="$2"
      shift 2
      ;;
    --to=*)
      to="${1#--to=}"
      shift
      ;;
    --service)
      want_service=1
      shift
      ;;
    -h | --help)
      sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

os="$(uname -s)"
launchd_plist="$HOME/Library/LaunchAgents/$label.plist"
systemd_unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$unit"

# The binary the installed service runs, or nothing when no service is installed. It is the first
# program argument of the plist or the unit's ExecStart, as node/core/service.ml writes them.
service_binary() {
  case "$os" in
    Darwin)
      [ -f "$launchd_plist" ] || return 0
      /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$launchd_plist" 2>/dev/null || true
      ;;
    *)
      [ -f "$systemd_unit" ] || return 0
      local exec
      exec="$(sed -n 's/^ExecStart=//p' "$systemd_unit" | head -1)"
      case "$exec" in
        \"*) exec="${exec#\"}"; printf '%s\n' "${exec%%\"*}" ;;
        *) printf '%s\n' "${exec%% *}" ;;
      esac
      ;;
  esac
}

# The file a path names once every symlink is followed; the path itself when it does not exist.
resolve() {
  if [ -e "$1" ]; then realpath "$1"; else printf '%s\n' "$1"; fi
}

running="$(service_binary)"
if [ -n "$to" ]; then
  case "$to" in /*) ;; *) to="$(pwd)/$to" ;; esac
  target="$to"
elif [ -n "$running" ]; then
  target="$running"
elif command -v digestif >/dev/null 2>&1; then
  target="$(command -v digestif)"
else
  target="$HOME/.local/bin/digestif"
fi
target="$(resolve "$target")"
[ -n "$running" ] && running="$(resolve "$running")"

# The build: the UI first, because the node embeds node/web/ui (node/web/dune), as ci/build.sh does.
if ! command -v dune >/dev/null 2>&1 && command -v opam >/dev/null 2>&1; then
  eval "$(opam env)"
fi
command -v dune >/dev/null 2>&1 || die "dune not found; install opam and run: opam install ./node --deps-only"
command -v npm >/dev/null 2>&1 || die "npm not found; install Node.js 22 or later"

step "ui: npm ci, build"
(cd "$root/ui" && npm ci --no-audit --no-fund && npm run build)
step "ui: copy ui/build to node/web/ui for the node to embed"
rm -rf "$root/node/web/ui"
cp -R "$root/ui/build" "$root/node/web/ui"

step "node: dune build @install"
(cd "$root/node" && dune build @install)
built="$root/node/_build/install/default/bin/digestif"
[ -x "$built" ] || die "dune built no $built"

# The swap, as self-update's Install.replace does it: stage beside the target, keep the old binary
# as <target>.previous, rename into place, so the target is never half-written.
step "install: $target"
mkdir -p "$(dirname "$target")"
cp "$built" "$target.next"
chmod 755 "$target.next"
if [ -e "$target" ]; then
  rm -f "$target.previous"
  ln "$target" "$target.previous" 2>/dev/null || cp -p "$target" "$target.previous"
fi
mv -f "$target.next" "$target"
cmp -s "$built" "$target" || die "$target does not match the binary dune built"

if [ -z "$running" ]; then
  if [ "$want_service" = 1 ]; then
    step "service: none installed; installing"
    "$target" service install
  else
    step "service: none installed"
    echo "Run the node as a service with: $target service install"
  fi
elif [ "$running" != "$target" ]; then
  step "service: not restarted"
  echo "The service runs $running, not $target, so it keeps its old code."
else
  step "service: restart"
  case "$os" in
    Darwin)
      domain="gui/$(id -u)"
      if launchctl print "$domain/$label" >/dev/null 2>&1; then
        launchctl kickstart -k "$domain/$label"
      else
        launchctl bootstrap "$domain" "$launchd_plist"
      fi
      ;;
    *) systemctl --user restart "$unit" ;;
  esac
  echo "The service runs $target."
fi

step "ok"
