#!/usr/bin/env bash
#
# Packs a relay release bundle, digestif-relay-<version>.tar.gz (docs/releases.md, Relay releases),
# from this checkout, touching no Cloudflare account:
#
#   worker/index.js, worker/index.js.map   the bundled Worker module, stamped as <version>
#   app/                                   the phone app's static files
#   migrations/*.sql                       every D1 migration from 0001_init.sql on
#   bundle.json                            what a deploy needs beside the module (relay/scripts/bundle-json.ts)
#
#   ci/relay-bundle.sh --version X.Y.Z --out DIR [--allow-placeholder]
#
# The module is `wrangler deploy --dry-run --outdir` with RELAY_VERSION_STAMP defined as the version
# (relay/src/version.ts), so GET /v0/circle answers relay_version from the signed bytes themselves.
# The phone app is ui/build, which must be built first (cd ui && npm ci && npm run build);
# --allow-placeholder packs relay/placeholder instead, for a rehearsal that is never released.
# relay/node_modules must be installed (cd relay && npm ci).
#
# Refuses a module whose source map names a file ci/relay-release-paths does not cover: such a
# file would change what a relay runs without `ci/release.sh relay changed` ever cutting a version.
# The map's sources are written repository-relative, so the bundle names no build machine's path.
#
# Prints the bundle's path on stdout and the rest on stderr. Exits 0 on success, 1 on a refusal or
# a failed step, 2 on a usage error. Run by .github/workflows/relay-release.yml on a relay-v* tag and
# by ci/build.slow.sh as a rehearsal.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
relay="$root/relay"

die() {
  echo "relay-bundle.sh: $*" >&2
  exit 1
}
usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

version=""
out=""
placeholder=false
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || usage; version="${2#v}"; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; out="$2"; shift 2 ;;
    --allow-placeholder) placeholder=true; shift ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done
[ -n "$version" ] && [ -n "$out" ] || usage
[[ "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] ||
  die "$version is not MAJOR.MINOR.PATCH"
wrangler="$relay/node_modules/.bin/wrangler"
[ -x "$wrangler" ] || die "relay/node_modules is not installed; run: (cd relay && npm ci)"
command -v node >/dev/null 2>&1 || die "node not found"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/digestif-relay-$version"
mkdir -p "$stage/migrations" "$out"
out="$(cd "$out" && pwd)"

# The phone app the Worker serves under /app/.
if $placeholder; then
  bash "$relay/scripts/app.sh" >&2
else
  bash "$relay/scripts/app.sh" --require-ui >&2
fi

echo "relay-bundle.sh: bundling the Worker as relay $version" >&2
(cd "$relay" && WRANGLER_SEND_METRICS=false WRANGLER_LOG=warn "$wrangler" deploy --dry-run --env "" --outdir "$stage/worker" \
  --define "RELAY_VERSION_STAMP:\"$version\"") >&2 ||
  die "wrangler could not bundle the Worker"
rm -f "$stage/worker/README.md"

main="$(cd "$relay" && node scripts/bundle-json.ts | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).main_module))')"
module="$stage/worker/$main"
[ -f "$module" ] || die "wrangler wrote no worker/$main"
[ -f "$module.map" ] || die "wrangler wrote no worker/$main.map"
# Defined, the identifier is replaced by the string; still there, the module would report nothing.
if grep -q 'RELAY_VERSION_STAMP' "$module"; then
  die "worker/$main still reads RELAY_VERSION_STAMP, so it is not stamped as $version"
fi
grep -qF "\"$version\"" "$module" || die "worker/$main does not carry the version $version"

# Every source the module was built from, repository-relative; anything outside the repository is
# refused, since no release path can cover it.
(cd "$root" && node -e '
  const fs = require("fs"), path = require("path");
  const [file, root] = process.argv.slice(1);
  const map = JSON.parse(fs.readFileSync(file, "utf8"));
  const real = fs.realpathSync(root);
  map.sources = map.sources.map((s) => {
    const abs = fs.realpathSync(path.resolve(path.dirname(file), s));
    const rel = path.relative(real, abs);
    if (rel.startsWith("..") || path.isAbsolute(rel)) throw new Error(`the module is built from ${abs}, outside the repository`);
    return rel.split(path.sep).join("/");
  });
  delete map.sourceRoot;
  fs.writeFileSync(file, JSON.stringify(map));
  for (const s of map.sources) console.log(s);
' "$module.map" "$root") >"$work/sources" || die "could not read the module's source map"

specs=()
while IFS= read -r line; do specs+=("$line"); done < <(grep -v -e '^#' -e '^[[:space:]]*$' "$root/ci/relay-release-paths")
[ "${#specs[@]}" -gt 0 ] || die "ci/relay-release-paths names no path"
git -C "$root" ls-files -- "${specs[@]}" | sort -u >"$work/covered"
uncovered="$(sort -u "$work/sources" | comm -23 - "$work/covered")"
[ -z "$uncovered" ] ||
  die "the module is built from files ci/relay-release-paths does not cover: $(printf '%s' "$uncovered" | tr '\n' ' ')"

cp -R "$relay/app" "$stage/app"
for m in "$relay"/migrations/*.sql; do
  [ -e "$m" ] || die "relay/migrations holds no migration"
  cp "$m" "$stage/migrations/"
done
(cd "$relay" && node scripts/bundle-json.ts) >"$stage/bundle.json" || die "could not write bundle.json"

bundle="$out/digestif-relay-$version.tar.gz"
# GNU tar (the release workflow's runner) packs the same tree into the same bytes: names sorted,
# owners and times fixed. Elsewhere the bundle is the same files in another order.
tar_opts=()
tar_version="$(tar --version 2>/dev/null)" || tar_version=""
if [[ "$tar_version" == *'GNU tar'* ]]; then
  mtime="$(git -C "$root" log -1 --format=%ct HEAD)"
  tar_opts=(--sort=name --owner=0 --group=0 --numeric-owner "--mtime=@$mtime")
fi
(cd "$stage" && tar "${tar_opts[@]+"${tar_opts[@]}"}" -cf - worker app migrations bundle.json) | gzip -n >"$bundle"
echo "relay-bundle.sh: packed $(basename "$bundle"): $(wc -c <"$bundle" | tr -d ' ') bytes, $(wc -l <"$work/sources" | tr -d ' ') source files" >&2
echo "$bundle"
