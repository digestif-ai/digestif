#!/usr/bin/env bash
#
# Builds the node from this checkout, with its web UI embedded, and installs it with the behaviors
# beside it. This is the upgrade step for a member who builds from source:
#
#   git pull && ./install.sh
#
# A checkout at a release tag (`git checkout v0.1.7`) builds that version; any other commit builds
# 0.0.0, so the node takes the newest signed release on its next update pass.
#
#   ./install.sh                 build; make it the service's release; put the CLI on PATH
#   ./install.sh --to <path>     only copy the binary to <path>; the service is left alone
#   ./install.sh --service       also install the service when none is installed (a first install)
#
# The service runs releases (docs/releases.md): `digestif service install --behaviors behaviors/`
# stages this build and its behaviors as a release under the node's data directory, self-tests it
# against a copy of the node's data, points current and good at it, and (re)starts the service,
# whose supervisor runs it. The `digestif` CLI goes to `digestif` on PATH, else ~/.local/bin, and
# the old one is kept beside it as <binary>.previous.
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
      sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

os="$(uname -s)"
launchd_plist="$HOME/Library/LaunchAgents/$label.plist"
systemd_unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$unit"

# The program and data directory the installed service runs, or nothing when no service is
# installed: the plist's ProgramArguments or the unit's ExecStart, as node/core/service.ml writes
# them (<binary> run|supervise --data-dir <dir>).
service_arg() {
  case "$os" in
    Darwin)
      [ -f "$launchd_plist" ] || return 0
      /usr/libexec/PlistBuddy -c "Print :ProgramArguments:$1" "$launchd_plist" 2>/dev/null || true
      ;;
    *)
      [ -f "$systemd_unit" ] || return 0
      local exec
      exec="$(sed -n 's/^ExecStart=//p' "$systemd_unit" | head -1)"
      # Unquoted words only; a quoted data directory falls back to the default.
      case "$exec" in
        *\"*) [ "$1" = 0 ] && { exec="${exec#\"}"; printf '%s\n' "${exec%%\"*}"; } ;;
        *) printf '%s\n' "$exec" | awk -v i="$1" '{ print $(i + 1) }' ;;
      esac
      ;;
  esac
}

# The file a path names once every symlink is followed; the path itself when it does not exist.
resolve() {
  if [ -e "$1" ]; then realpath "$1"; else printf '%s\n' "$1"; fi
}

running="$(service_arg 0)"
service_dir="$(service_arg 3)"
if [ -n "$to" ]; then
  case "$to" in /*) ;; *) to="$(pwd)/$to" ;; esac
  target="$to"
elif command -v digestif >/dev/null 2>&1; then
  target="$(command -v digestif)"
else
  target="$HOME/.local/bin/digestif"
fi
target="$(resolve "$target")"
# A release directory is never written into: the CLI goes beside it instead.
case "$target" in */releases/*/bin/digestif) target="$HOME/.local/bin/digestif" ;; esac

# The build: the UI first, because the node embeds node/web/ui (node/web/dune), as ci/build.sh does.
if ! command -v dune >/dev/null 2>&1 && command -v opam >/dev/null 2>&1; then
  eval "$(opam env)"
fi
command -v dune >/dev/null 2>&1 || die "dune not found; install opam and run: opam install ./node --deps-only"
command -v npm >/dev/null 2>&1 || die "npm not found; install Node.js 24 or later"

step "ui: npm ci, build"
(cd "$root/ui" && npm ci --no-audit --no-fund && npm run build)
step "ui: copy ui/build to node/web/ui for the node to embed"
rm -rf "$root/node/web/ui"
cp -R "$root/ui/build" "$root/node/web/ui"

# The version is the release tag this checkout is at, or 0.0.0 between tags, which every release
# is newer than (ci/version.sh).
DIGESTIF_VERSION="$("$root/ci/version.sh")"
export DIGESTIF_VERSION
step "node: dune build @install, version $DIGESTIF_VERSION"
(cd "$root/node" && dune build @install)
built="$root/node/_build/install/default/bin/digestif"
[ -x "$built" ] || die "dune built no $built"

# The CLI: stage beside the target, keep the old binary as <target>.previous, rename into place,
# so the target is never half-written.
step "cli: $target"
mkdir -p "$(dirname "$target")"
cp "$built" "$target.next"
chmod 755 "$target.next"
if [ -e "$target" ]; then
  rm -f "$target.previous"
  ln "$target" "$target.previous" 2>/dev/null || cp -p "$target" "$target.previous"
fi
mv -f "$target.next" "$target"
cmp -s "$built" "$target" || die "$target does not match the binary dune built"

if [ -n "$to" ]; then
  step "service: left alone (--to)"
elif [ -n "$running" ] || [ "$want_service" = 1 ]; then
  step "service: install this build and its behaviors as the node's release"
  if [ -n "$service_dir" ]; then
    "$target" service install --behaviors "$root/behaviors" --data-dir "$service_dir"
  else
    "$target" service install --behaviors "$root/behaviors"
  fi
else
  step "service: none installed"
  echo "Run the node as a service with: $target service install --behaviors $root/behaviors"
fi

step "ok"
