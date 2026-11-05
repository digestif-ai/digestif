// What `scripts/deploy.sh --release <version>` checks and runs (README "Operations", Break glass):
// the signed manifest's own fields, the downloaded bundle against them, and the wrangler
// configuration that deploys the bundle's bytes as they stand. The signatures are checked before
// any of this by `digestif-update verify`; this reads only a manifest that already verified.
// Shared with test/release.test.ts.
import { parseJsonc } from "./jsonc.ts";

export const RELAY_MANIFEST_FORMAT = "digestif-relay-release-v1";

export interface Migration {
  name: string;
  sha256: string;
}

export interface RelayManifest {
  version: string;
  bundle: { url: string; sha256: string; size: number };
  migrations: Migration[];
}

/** bundle.json in a relay release bundle (docs/releases.md, Relay releases). */
export interface BundleJson {
  main_module: string;
  compatibility_date: string;
  compatibility_flags: string[];
  assets: { directory: string; binding: string; html_handling?: string; run_worker_first?: boolean };
}

const HASH = /^sha256:[0-9a-f]{64}$/;
const VERSION = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
const MIGRATION = /^[0-9]{4}_[a-z0-9_]+\.sql$/;

function record(v: unknown, what: string): Record<string, unknown> {
  if (typeof v !== "object" || v === null || Array.isArray(v)) throw new Error(`${what} is not an object`);
  return v as Record<string, unknown>;
}

function str(v: unknown, what: string): string {
  if (typeof v !== "string" || v === "") throw new Error(`${what} is not a string`);
  return v;
}

export function isVersion(v: string): boolean {
  return VERSION.test(v);
}

/** The fields a deploy reads from a relay manifest, refusing one of any other format or version. */
export function readManifest(text: string, want: string): RelayManifest {
  const m = record(JSON.parse(text) as unknown, "the manifest");
  if (m.format !== RELAY_MANIFEST_FORMAT) throw new Error(`the manifest's format is ${JSON.stringify(m.format)}, not ${RELAY_MANIFEST_FORMAT}`);
  const version = str(m.version, "version");
  if (version !== want) throw new Error(`the manifest is relay ${version}, not ${want}`);
  const b = record(m.bundle, "bundle");
  const sha256 = str(b.sha256, "bundle.sha256");
  if (!HASH.test(sha256)) throw new Error(`bundle.sha256 is not sha256:<64 lowercase hex>: ${sha256}`);
  const size = b.size;
  if (typeof size !== "number" || !Number.isInteger(size) || size <= 0) throw new Error("bundle.size is not a positive integer");
  if (!Array.isArray(m.migrations)) throw new Error("migrations is not a list");
  const migrations = m.migrations.map((x, i) => {
    const r = record(x, `migrations[${i}]`);
    const name = str(r.name, `migrations[${i}].name`);
    const hash = str(r.sha256, `migrations[${i}].sha256`);
    if (!MIGRATION.test(name)) throw new Error(`migrations[${i}] is not a migration name: ${name}`);
    if (!HASH.test(hash)) throw new Error(`migrations[${i}].sha256 is not sha256:<64 lowercase hex>`);
    return { name, sha256: hash };
  });
  return { version, bundle: { url: str(b.url, "bundle.url"), sha256, size }, migrations };
}

/** The bundle's address: the manifest's url, or one relative to the channel resolved against it. */
export function bundleUrl(manifest: RelayManifest, channel: string): string {
  const url = manifest.bundle.url;
  if (/^https?:\/\//.test(url)) return url;
  if (url.startsWith("/") || url.split("/").includes("..")) throw new Error(`bundle.url ${url} leaves the channel`);
  return channel.endsWith("/") ? channel + url : `${channel}/${url}`;
}

/**
 * Every way the downloaded bundle differs from the signed manifest: its sha256 and size, and the
 * migrations it carries, which must be exactly the manifest's, in order, each with its sha256.
 * Empty when the bytes are the signed ones.
 */
export function bundleProblems(manifest: RelayManifest, bundle: { sha256: string; size: number }, migrations: Migration[]): string[] {
  const out: string[] = [];
  if (bundle.sha256 !== manifest.bundle.sha256) out.push(`the bundle's sha256 is ${bundle.sha256}, the manifest signed ${manifest.bundle.sha256}`);
  if (bundle.size !== manifest.bundle.size) out.push(`the bundle is ${bundle.size} bytes, the manifest signed ${manifest.bundle.size}`);
  const signed = new Map(manifest.migrations.map((m) => [m.name, m.sha256]));
  const carried = new Map(migrations.map((m) => [m.name, m.sha256]));
  for (const m of migrations) {
    const want = signed.get(m.name);
    if (want === undefined) out.push(`migrations/${m.name} is in the bundle and not in the manifest`);
    else if (want !== m.sha256) out.push(`migrations/${m.name} is not the migration the manifest signed`);
  }
  for (const m of manifest.migrations) if (!carried.has(m.name)) out.push(`migrations/${m.name} is in the manifest and not in the bundle`);
  return out;
}

/** Reads bundle.json, refusing a module or assets path that is not a plain name inside the bundle. */
export function readBundleJson(text: string): BundleJson {
  const b = record(JSON.parse(text) as unknown, "bundle.json");
  const main = str(b.main_module, "bundle.json main_module");
  if (!/^[A-Za-z0-9._-]+\.js$/.test(main) || main.startsWith(".")) throw new Error(`bundle.json main_module is not a module name: ${main}`);
  const flags = b.compatibility_flags ?? [];
  if (!Array.isArray(flags) || !flags.every((f) => typeof f === "string")) throw new Error("bundle.json compatibility_flags is not a list of strings");
  const assets = record(b.assets, "bundle.json assets");
  const directory = str(assets.directory, "bundle.json assets.directory").replace(/^\.\//, "").replace(/\/$/, "");
  if (!/^[A-Za-z0-9._-]+$/.test(directory) || directory.startsWith(".")) throw new Error(`bundle.json assets.directory is not a directory of the bundle: ${directory}`);
  return {
    main_module: main,
    compatibility_date: str(b.compatibility_date, "bundle.json compatibility_date"),
    compatibility_flags: flags,
    assets: { ...(assets as BundleJson["assets"]), directory, binding: str(assets.binding, "bundle.json assets.binding") },
  };
}

/**
 * The wrangler configuration that deploys an unpacked bundle at `dir` (an absolute path) to the
 * environment `envName` of the checkout's wrangler.jsonc: the deployment's own settings (its name,
 * routes, vars, D1 database and its id) from the checkout, and every byte that runs from the
 * bundle: its module, not bundled again, its compatibility settings, its app/ and its migrations.
 * Only that environment is kept. Every path is absolute, since wrangler resolves them against the
 * configuration's own directory.
 */
export function releaseConfig(wranglerText: string, envName: string, dir: string, bundle: BundleJson): Record<string, unknown> {
  const top = record(parseJsonc(wranglerText), "wrangler.jsonc");
  const { env, $schema: _schema, ...rest } = top;
  const environment = record(record(env, "wrangler.jsonc env")[envName], `wrangler.jsonc env.${envName}`);
  const join = (...parts: string[]) => [dir.replace(/\/$/, ""), ...parts].join("/");
  const assets = (a: unknown) => ({ ...(a === undefined ? {} : record(a, "assets")), ...bundle.assets, directory: join(bundle.assets.directory) });
  const databases = (d: unknown) => {
    if (!Array.isArray(d)) throw new Error("d1_databases is not a list");
    return d.map((x, i) => ({ ...record(x, `d1_databases[${i}]`), migrations_dir: join("migrations") }));
  };
  const scope = (s: Record<string, unknown>) => ({
    ...s,
    ...("assets" in s ? { assets: assets(s.assets) } : {}),
    ...("d1_databases" in s ? { d1_databases: databases(s.d1_databases) } : {}),
  });
  return {
    ...scope(rest),
    main: join("worker", bundle.main_module),
    no_bundle: true,
    compatibility_date: bundle.compatibility_date,
    compatibility_flags: bundle.compatibility_flags,
    env: { [envName]: scope(environment) },
  };
}

// CLI, run by scripts/deploy.sh:
//   node scripts/release.ts url <manifest.json> <version> <channel>
//       checks the manifest's fields and prints the bundle's address
//   node scripts/release.ts check <manifest.json> <version> <bundle.tar.gz> [<unpacked dir>]
//       checks the bundle's sha256 and size, and with the directory it unpacked into its
//       migrations too; exits 1 naming every difference. deploy.sh runs it before unpacking, so
//       tar never reads bytes nobody signed, and again after.
//   node scripts/release.ts config <wrangler.jsonc> <environment> <unpacked dir>
//       prints the wrangler configuration that deploys the unpacked bundle
if (typeof process !== "undefined" && process.argv[1]?.endsWith("release.ts") === true) {
  const { readFileSync, readdirSync, statSync } = await import("node:fs");
  const { createHash } = await import("node:crypto");
  const path = await import("node:path");
  const sha = (bytes: Buffer) => `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
  const [command, ...args] = process.argv.slice(2);
  try {
    if (command === "url" && args.length === 3) {
      const [file, version, channel] = args as [string, string, string];
      console.log(bundleUrl(readManifest(readFileSync(file, "utf8"), version), channel));
    } else if (command === "check" && (args.length === 3 || args.length === 4)) {
      const [file, version, archive, dir] = args as [string, string, string, string | undefined];
      const manifest = readManifest(readFileSync(file, "utf8"), version);
      const mdir = dir === undefined ? undefined : path.join(dir, "migrations");
      // Before unpacking, the bundle's own migrations are not known yet: count the signed ones as carried.
      const migrations =
        mdir === undefined
          ? manifest.migrations
          : readdirSync(mdir)
              .filter((n) => !n.startsWith("."))
              .sort()
              .map((name) => ({ name, sha256: sha(readFileSync(path.join(mdir, name))) }));
      const problems = bundleProblems(manifest, { sha256: sha(readFileSync(archive)), size: statSync(archive).size }, migrations);
      if (problems.length > 0) {
        for (const p of problems) console.error(p);
        process.exit(1);
      }
      console.log(`${manifest.bundle.sha256} ${manifest.bundle.size} bytes, ${migrations.length} migrations`);
    } else if (command === "config" && args.length === 3) {
      const [wrangler, envName, dir] = args as [string, string, string];
      const bundle = readBundleJson(readFileSync(path.join(dir, "bundle.json"), "utf8"));
      console.log(JSON.stringify(releaseConfig(readFileSync(wrangler, "utf8"), envName, path.resolve(dir), bundle), null, 2));
    } else {
      console.error("usage: release.ts url <manifest> <version> <channel> | check <manifest> <version> <bundle> <dir> | config <wrangler.jsonc> <env> <dir>");
      process.exit(2);
    }
  } catch (e) {
    console.error(e instanceof Error ? e.message : String(e));
    process.exit(1);
  }
}
