#!/usr/bin/env bash
#
# Tests the hosted install script (ci/install-hosted.sh.in, written by ci/install-hosted.sh) under
# POSIX sh against a fake release served from a file:// url: a matching archive installs and prints
# the expected and actual sha256 with the manifest link, a tampered one stops with nothing
# installed, --join reaches `digestif join`, and a manifest the generator cannot quote safely is
# refused. ci/build.sh runs it; it needs jq and curl and no network. INSTALL_SH names the shell
# that runs the script (sh by default; dash is the strictest POSIX sh at hand).

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sh="${INSTALL_SH:-sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "install-hosted-test.sh: $*" >&2
  exit 1
}
expect_in() {
  grep -qF -- "$1" "$2" || {
    cat "$2" >&2
    fail "expected '$1' in $2"
  }
}

case "$(uname -s)-$(uname -m)" in
  Darwin-*) platform=darwin-arm64 ;;
  Linux-aarch64 | Linux-arm64) platform=linux-arm64 ;;
  *) platform=linux-x86_64 ;;
esac

# A release archive whose bin/digestif stages itself the way `digestif update stage` answers, and
# records a join.
mkdir -p "$tmp/archive/bin"
cat > "$tmp/archive/bin/digestif" <<'EOF'
#!/bin/sh
case "$1" in
  update)
    [ "$2" = stage ] && [ -f "$3" ] || exit 9
    d="$HOME/data/releases/9.9.9"
    mkdir -p "$d/bin"
    cp "$0" "$d/bin/digestif"
    echo "$d"
    ;;
  join) echo "$*" > "$HOME/joined" ;;
  *) exit 9 ;;
esac
EOF
chmod 755 "$tmp/archive/bin/digestif"
tar -czf "$tmp/digestif-$platform.tar.gz" -C "$tmp/archive" bin

manifest() {
  local sha="$1" url="${2:-file://$tmp/digestif-$platform.tar.gz}"
  jq -n --arg p "$platform" --arg u "$url" --arg s "sha256:$sha" \
    '{ format: "digestif-release-v1", version: "9.9.9", artifacts: [ { platform: $p, url: $u, sha256: $s, size: 1 } ] }'
}
if command -v sha256sum >/dev/null 2>&1; then
  sha="$(sha256sum "$tmp/digestif-$platform.tar.gz" | awk '{ print $1 }')"
else
  sha="$(shasum -a 256 "$tmp/digestif-$platform.tar.gz" | awk '{ print $1 }')"
fi
link="https://github.com/digestif-ai/digestif/tree/main/releases/9.9.9"

# A matching archive installs.
manifest "$sha" > "$tmp/manifest.json"
bash "$root/ci/install-hosted.sh" "$tmp/manifest.json" "$link" > "$tmp/install.sh"
"$sh" -n "$tmp/install.sh" || fail "the written script is not valid sh"
mkdir "$tmp/home"
HOME="$tmp/home" "$sh" "$tmp/install.sh" > "$tmp/out" 2>&1 || {
  cat "$tmp/out" >&2
  fail "a matching archive did not install"
}
expect_in "Downloading Digestif 9.9.9 for $platform" "$tmp/out"
expect_in "expected sha256: $sha" "$tmp/out"
expect_in "actual sha256:   $sha" "$tmp/out"
expect_in "signed manifest: $link" "$tmp/out"
[ "$(readlink "$tmp/home/.local/bin/digestif")" = "$tmp/home/data/releases/9.9.9/bin/digestif" ] ||
  fail "~/.local/bin/digestif does not name the staged release"
echo "ok: a matching archive installs"

# A tampered archive stops before anything is installed.
manifest "$(printf '%064d' 0)" > "$tmp/bad.json"
bash "$root/ci/install-hosted.sh" "$tmp/bad.json" "$link" > "$tmp/bad.sh"
mkdir "$tmp/home2"
if HOME="$tmp/home2" "$sh" "$tmp/bad.sh" --join dg1.abc > "$tmp/out2" 2>&1; then
  fail "a mismatched sha256 did not stop the script"
fi
expect_in "expected sha256: $(printf '%064d' 0)" "$tmp/out2"
expect_in "actual sha256:   $sha" "$tmp/out2"
expect_in "signed manifest: $link" "$tmp/out2"
expect_in "nothing was installed" "$tmp/out2"
[ ! -e "$tmp/home2/.local" ] && [ ! -e "$tmp/home2/joined" ] || fail "a mismatch installed something"
echo "ok: a mismatch stops it"

# --join reaches `digestif join` when there is a terminal, and otherwise stops before it.
mkdir "$tmp/home3"
if (: </dev/tty) 2>/dev/null; then
  HOME="$tmp/home3" "$sh" "$tmp/install.sh" --join dg1.abc > "$tmp/out3" 2>&1 || {
    cat "$tmp/out3" >&2
    fail "--join failed"
  }
  [ "$(cat "$tmp/home3/joined")" = "join dg1.abc" ] || fail "--join did not reach digestif join"
  echo "ok: --join is passed through"
else
  if HOME="$tmp/home3" "$sh" "$tmp/install.sh" --join=dg1.abc > "$tmp/out3" 2>&1; then
    fail "--join with no terminal did not stop"
  fi
  expect_in "run the command in a terminal" "$tmp/out3"
  [ ! -e "$tmp/home3/joined" ] || fail "--join with no terminal reached digestif join"
  echo "ok: --join with no terminal stops before the join"
fi

# What the generator cannot write safely into the script, it refuses.
manifest "$sha" "file://$tmp/it's.tar.gz" > "$tmp/quote.json"
if bash "$root/ci/install-hosted.sh" "$tmp/quote.json" "$link" > /dev/null 2>&1; then
  fail "a url with a quote was written into the script"
fi
manifest "${sha:0:63}" > "$tmp/short.json"
if bash "$root/ci/install-hosted.sh" "$tmp/short.json" "$link" > /dev/null 2>&1; then
  fail "a short sha256 was written into the script"
fi
echo "ok: an unsafe manifest is refused"
