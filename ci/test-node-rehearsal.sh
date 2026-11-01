#!/usr/bin/env bash
#
# Runs ci/test-node.sh for real on a throwaway runner, against versions nobody will ever install.
# The test nodes otherwise run only on a version both signers signed, so a change that breaks them
# would first show on a real release. This builds this checkout twice with a throwaway signer set
# committed locally, as v0.0.1 and v0.0.2, signs both with those keys, and lays out a channel in a
# local directory. Then it runs the two paths of a test node: v0.0.1 installing directly with
# nothing published, and v0.0.2 updating from a published v0.0.1.
#
#   ci/test-node-rehearsal.sh
#
# It commits and tags in this checkout and replaces the machine's Digestif service, so it refuses
# anywhere GITHUB_ACTIONS is not set. Nothing it makes is pushed.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "${GITHUB_ACTIONS:-}" = true ] || {
  echo "test-node-rehearsal.sh: this commits here and replaces the machine's service; CI only" >&2
  exit 2
}
step() { printf '\n==> %s\n' "$*"; }

work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/rehearsal.XXXXXX")"
case "$(uname -s)" in Darwin) os=darwin ;; *) os=linux ;; esac
case "$(uname -m)" in arm64 | aarch64) platform="$os-arm64" ;; *) platform="$os-x86_64" ;; esac
git_commit() { git -C "$root" -c user.name=rehearsal -c user.email=rehearsal@example.invalid "$@"; }

step "a throwaway signer set"
node - "$work" "$root/node/update/release-signers.json" <<'JS'
const { generateKeyPairSync } = require("node:crypto");
const { writeFileSync } = require("node:fs");
const [dir, signersFile] = process.argv.slice(2);
const signers = ["one", "two"].map((name) => {
  const jwk = generateKeyPairSync("ed25519").privateKey.export({ format: "jwk" });
  writeFileSync(`${dir}/${name}.key`, `ed25519-secret:${jwk.d}\n`, { mode: 0o600 });
  return { name, key: `ed25519:${jwk.x}` };
});
writeFileSync(signersFile, JSON.stringify({ format: "digestif-signers-v0", signers }, null, 2) + "\n");
JS
git_commit add node/update/release-signers.json
git_commit commit --quiet -m "A throwaway signer set"

jq -n --arg p "$platform" '{ platforms: [ { platform: $p, runner: "rehearsal" } ] }' >"$work/platforms.json"
channel="$work/channel"
mkdir -p "$channel"
printf '{ "format": "digestif-feed-v0", "releases": [], "revocations": [] }\n' >"$channel/index.json"

build() {
  local version="$1"
  step "build $version"
  git_commit commit --quiet --allow-empty -m "Version $version"
  git_commit tag "v$version"
  case "$os" in
    darwin) "$root/ci/release-artifact.sh" ;;
    linux) "$root/ci/release-linux.sh" ;;
  esac
  mkdir -p "$work/archives"
  cp "$root/dist/$version/digestif-$platform.tar.gz" "$work/archives/digestif-$platform-$version.tar.gz"
  # On Linux the container wrote dist/ as root, so this copy is the one this user can run.
  tool="$work/digestif-update"
  rm -f "$tool"
  cp "$root/dist/$version/digestif-update-$platform" "$tool"
  chmod 755 "$tool"
}

# Writes $1's signed manifest under $2 of the channel.
sign_into() {
  local version="$1" dir="$channel/$2/$1"
  mkdir -p "$dir"
  "$tool" manifest "$version" --notes "A rehearsal." --platforms "$work/platforms.json" \
    --url-base "$work/archives" \
    --artifact "$platform=$work/archives/digestif-$platform-$version.tar.gz" >"$dir/manifest.json"
  "$tool" sign --key "$work/one.key" "$dir/manifest.json"
  "$tool" sign --key "$work/two.key" "$dir/manifest.json"
}

index() {
  jq -n --arg v "$1" --arg prefix "${2:-}" '{
    format: "digestif-feed-v0",
    releases: [ { version: $v, manifest: "\($prefix)\($v)/manifest.json", signatures: "\($prefix)\($v)/manifest.sig.json" } ],
    revocations: []
  }'
}

build 0.0.1
sign_into 0.0.1 candidate
index 0.0.1 >"$channel/candidate/index.json"

step "the first version installs directly"
"$root/ci/test-node.sh" 0.0.1 --channel "$channel" --feed "$channel/candidate"

step "publish 0.0.1"
mv "$channel/candidate/0.0.1" "$channel/0.0.1"
index 0.0.1 >"$channel/index.json"

build 0.0.2
sign_into 0.0.2 candidate
index 0.0.2 >"$channel/candidate/index.json"

step "the next version updates from the last published one"
"$root/ci/test-node.sh" 0.0.2 --channel "$channel" --feed "$channel/candidate"
