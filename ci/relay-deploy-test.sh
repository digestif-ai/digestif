#!/usr/bin/env bash
#
# Tests `relay/scripts/deploy.sh --release` (relay/README.md "Operations", Break glass) against a
# channel in a scratch directory, with two throwaway release keys standing in for the signer set:
# a release both keys signed passes its dry run; one signature, a bundle that is not the signed
# one, and a manifest of another version are each refused before anything else runs; and wrangler
# accepts the configuration the script writes and deploys the bundle's module as it stands, not a
# build of the checkout. No step calls Cloudflare or GitHub.
#
#   ci/relay-deploy-test.sh <digestif-update>     ci/build.slow.sh passes the one it built
#
# Needs node, tar and relay/node_modules (npm ci in relay/).

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
relay="$root/relay"
update="${1:?usage: ci/relay-deploy-test.sh <digestif-update>}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "relay-deploy-test.sh: $*" >&2
  exit 1
}

# Two release keys and the signer set they make; DIGESTIF_UPDATE checks against it.
"$update" keygen "$tmp/a.key" >"$tmp/a.pub"
"$update" keygen "$tmp/b.key" >"$tmp/b.pub"
cat >"$tmp/signers.json" <<EOF
{ "format": "digestif-signers-v0",
  "signers": [ { "name": "Signer A", "key": "$(tr -d '[:space:]' <"$tmp/a.pub")" },
               { "name": "Signer B", "key": "$(tr -d '[:space:]' <"$tmp/b.pub")" } ] }
EOF
cat >"$tmp/digestif-update" <<EOF
#!/usr/bin/env bash
exec "$update" "\$@" --signers "$tmp/signers.json"
EOF
chmod 755 "$tmp/digestif-update"

# A bundle in the shape the relay release build packs, its module a Worker no build of the
# checkout would produce, so the test can tell which one wrangler deployed.
bundle() {
  local dir="$tmp/pack-$1"
  mkdir -p "$dir/worker" "$dir/app" "$dir/migrations"
  printf 'export default { fetch() { return new Response("%s"); } };\n' "$1" >"$dir/worker/index.js"
  echo '{"version":3,"sources":[],"mappings":""}' >"$dir/worker/index.js.map"
  echo '<!doctype html><title>app</title>' >"$dir/app/index.html"
  cp "$relay"/migrations/*.sql "$dir/migrations/"
  cat >"$dir/bundle.json" <<'EOF'
{ "main_module": "index.js", "compatibility_date": "2026-08-01", "compatibility_flags": ["nodejs_compat"],
  "assets": { "directory": "app", "binding": "ASSETS", "html_handling": "none", "run_worker_first": true },
  "bindings": { "d1": ["DB"], "vars": [], "secrets": [] } }
EOF
  (cd "$dir" && tar -czf "$tmp/digestif-relay-$1.tar.gz" worker app migrations bundle.json)
}

# Publishes $1 to the channel under relay/$2, signed by the keys named after it.
publish() {
  local version="$1" under="$2" sigs=() k
  shift 2
  bundle "$version"
  mkdir -p "$tmp/channel/bundles" "$tmp/channel/relay/$under"
  cp "$tmp/digestif-relay-$version.tar.gz" "$tmp/channel/bundles/"
  "$update" relay-manifest "$version" --bundle "$tmp/digestif-relay-$version.tar.gz" \
    --url-base bundles --compatible-with "$version" --notes "test" >"$tmp/channel/relay/$under/manifest.json"
  for k in "$@"; do
    (cd "$tmp" && "$update" sign --key "$tmp/$k.key" "$tmp/channel/relay/$under/manifest.json" >/dev/null)
    mv "$tmp/channel/relay/$under/manifest.sig.json" "$tmp/$k.sig.json"
    sigs+=("$tmp/$k.sig.json")
  done
  # The channel's combined signatures, as ci/release.sh writes them: verify --out, or for a test of
  # a missing signer the one signature as it is.
  if ! "$tmp/digestif-update" verify "$tmp/channel/relay/$under/manifest.json" "${sigs[@]}" \
    --out "$tmp/channel/relay/$under/manifest.sig.json" >/dev/null 2>&1; then
    cp "${sigs[0]}" "$tmp/channel/relay/$under/manifest.sig.json"
  fi
}

deploy() {
  (cd "$relay" && DIGESTIF_UPDATE="$tmp/digestif-update" DIGESTIF_CHANNEL="$tmp/channel" \
    bash scripts/deploy.sh dinners --dry-run --release "$@") >"$tmp/out" 2>&1
}

publish 0.1.0 0.1.0 a b
deploy 0.1.0 || fail "a release both signers signed was refused: $(cat "$tmp/out")"
grep -qF 'signed Signer A' "$tmp/out" || fail "the signers are not printed: $(cat "$tmp/out")"
grep -qF 'as signed' "$tmp/out" || fail "the bundle check is not printed: $(cat "$tmp/out")"
grep -qF 'dry run: nothing was changed' "$tmp/out" || fail "no dry run: $(cat "$tmp/out")"
deploy relay-v0.1.0 || fail "--release relay-v0.1.0 was refused: $(cat "$tmp/out")"

publish 0.1.1 0.1.1 a
if deploy 0.1.1; then fail "a release one signer signed was deployed"; fi
grep -qF 'missing Signer B' "$tmp/out" || fail "the missing signer is not named: $(cat "$tmp/out")"
grep -qF 'do not verify' "$tmp/out" || fail "the refusal is not said: $(cat "$tmp/out")"

publish 0.1.2 0.1.2 a b
echo '// another byte' >>"$tmp/pack-0.1.2/worker/index.js"
(cd "$tmp/pack-0.1.2" && tar -czf "$tmp/channel/bundles/digestif-relay-0.1.2.tar.gz" worker app migrations bundle.json)
if deploy 0.1.2; then fail "a bundle that is not the signed one was deployed"; fi
grep -qF 'is not the bundle relay 0.1.2 signed' "$tmp/out" || fail "the bundle refusal is not said: $(cat "$tmp/out")"
grep -qF "the bundle's sha256 is" "$tmp/out" || fail "the sha256 is not named: $(cat "$tmp/out")"

publish 0.1.3 0.2.0 a b
if deploy 0.2.0; then fail "a manifest of 0.1.3 was deployed as 0.2.0"; fi

if deploy 0.3.0; then fail "a version the channel does not hold was deployed"; fi
grep -qF 'is not published on the channel' "$tmp/out" || fail "the absent version is not said: $(cat "$tmp/out")"

if (cd "$relay" && bash scripts/deploy.sh dinners --release latest --dry-run) >"$tmp/out" 2>&1; then
  fail "--release latest was accepted"
fi

# The configuration: this environment's settings, the bundle's bytes, and wrangler accepts it. A
# dry run deploy writes the module it would upload, which must be the bundle's, unchanged.
mkdir "$tmp/unpacked"
tar -xzf "$tmp/digestif-relay-0.1.0.tar.gz" -C "$tmp/unpacked"
(cd "$relay" && node scripts/release.ts config wrangler.jsonc dinners "$tmp/unpacked") >"$tmp/wrangler.json"
node -e '
  const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")), dir = process.argv[2];
  const e = c.env.dinners, want = (ok, what) => { if (!ok) { console.error(what); process.exit(1); } };
  want(c.main === dir + "/worker/index.js" && c.no_bundle === true, "main is not the bundle module");
  want(Object.keys(c.env).join() === "dinners", "another environment is kept");
  want(e.name === "digestif-dinners" && e.routes.length === 2, "the environment lost its name or routes");
  want(e.assets.directory === dir + "/app" && e.assets.binding === "ASSETS", "assets are not the bundle app/");
  want(e.d1_databases[0].migrations_dir === dir + "/migrations", "migrations are not the bundle migrations/");
  want(e.d1_databases[0].database_id === "e04c58e6-c628-4801-a31f-221fcb9fdb04", "the database id is not the checkout one");
' "$tmp/wrangler.json" "$tmp/unpacked" || fail "the configuration is wrong: $(cat "$tmp/wrangler.json")"
(cd "$relay" && npx wrangler deploy --dry-run --config "$tmp/wrangler.json" --env dinners --outdir "$tmp/out-dir") \
  >"$tmp/out" 2>&1 || fail "wrangler refused the release configuration: $(cat "$tmp/out")"
cmp -s "$tmp/out-dir/index.js" "$tmp/unpacked/worker/index.js" ||
  fail "wrangler would not upload the bundle's module as it stands: $(ls "$tmp/out-dir")"

echo "relay-deploy-test.sh: ok"
