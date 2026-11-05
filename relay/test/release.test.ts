// What `scripts/deploy.sh --release` checks before it deploys a signed relay release, and the
// configuration it deploys the bundle under (scripts/release.ts, README "Operations").
// ci/relay-deploy-test.sh runs the script itself against a scratch channel.
import { describe, expect, it } from "vitest";
import raw from "../wrangler.jsonc?raw";
import { bundleProblems, bundleUrl, isVersion, readBundleJson, readManifest, releaseConfig, type BundleJson } from "../scripts/release.ts";

const h = (c: string) => `sha256:${c.repeat(64)}`;
const manifest = {
  format: "digestif-relay-release-v1",
  version: "0.1.0",
  published_at: "2026-11-12T18:00:00.000Z",
  notes: "n",
  bundle: { url: "https://github.com/digestif-ai/digestif/releases/download/relay-v0.1.0/digestif-relay-0.1.0.tar.gz", sha256: h("a"), size: 100 },
  migrations: [
    { name: "0001_init.sql", sha256: h("1") },
    { name: "0002_mailer.sql", sha256: h("2") },
  ],
  compatible_with: "0.1.0",
};
const text = (m: unknown) => JSON.stringify(m);

describe("the manifest", () => {
  it("reads a relay manifest of the asked version", () => {
    const m = readManifest(text(manifest), "0.1.0");
    expect(m.bundle).toEqual(manifest.bundle);
    expect(m.migrations.map((x) => x.name)).toEqual(["0001_init.sql", "0002_mailer.sql"]);
  });

  it("refuses a node manifest, another version, and a malformed hash", () => {
    expect(() => readManifest(text({ ...manifest, format: "digestif-release-v1" }), "0.1.0")).toThrow(/format/);
    expect(() => readManifest(text(manifest), "0.2.0")).toThrow(/relay 0.1.0, not 0.2.0/);
    expect(() => readManifest(text({ ...manifest, bundle: { ...manifest.bundle, sha256: "sha256:ABC" } }), "0.1.0")).toThrow(/bundle.sha256/);
    expect(() => readManifest(text({ ...manifest, migrations: [{ name: "../x.sql", sha256: h("1") }] }), "0.1.0")).toThrow(/migration name/);
  });

  it("takes only a version, so --release names no path", () => {
    expect(isVersion("0.1.0")).toBe(true);
    for (const v of ["latest", "0.1", "01.1.0", "0.1.0/../x", "v0.1.0"]) expect(isVersion(v)).toBe(false);
  });

  it("resolves a relative bundle url against the channel and refuses one that leaves it", () => {
    const m = readManifest(text(manifest), "0.1.0");
    expect(bundleUrl(m, "https://c.example/")).toBe(manifest.bundle.url);
    const rel = { ...m, bundle: { ...m.bundle, url: "bundles/b.tar.gz" } };
    expect(bundleUrl(rel, "/tmp/channel")).toBe("/tmp/channel/bundles/b.tar.gz");
    expect(() => bundleUrl({ ...m, bundle: { ...m.bundle, url: "../b.tar.gz" } }, "/tmp/channel")).toThrow(/leaves the channel/);
    expect(() => bundleUrl({ ...m, bundle: { ...m.bundle, url: "/etc/b.tar.gz" } }, "/tmp/channel")).toThrow(/leaves the channel/);
  });
});

describe("the bundle against the manifest", () => {
  const m = readManifest(text(manifest), "0.1.0");

  it("passes the signed bytes", () => {
    expect(bundleProblems(m, { sha256: h("a"), size: 100 }, m.migrations)).toEqual([]);
  });

  it("names a different sha256 or size", () => {
    const p = bundleProblems(m, { sha256: h("b"), size: 101 }, m.migrations);
    expect(p).toHaveLength(2);
    expect(p[0]).toContain("sha256");
    expect(p[1]).toContain("101 bytes");
  });

  it("names a migration added, changed or missing", () => {
    const p = bundleProblems(m, { sha256: h("a"), size: 100 }, [
      { name: "0001_init.sql", sha256: h("9") },
      { name: "0003_extra.sql", sha256: h("3") },
    ]);
    expect(p).toEqual([
      "migrations/0001_init.sql is not the migration the manifest signed",
      "migrations/0003_extra.sql is in the bundle and not in the manifest",
      "migrations/0002_mailer.sql is in the manifest and not in the bundle",
    ]);
  });
});

describe("the configuration a release deploys under", () => {
  const bundle: BundleJson = readBundleJson(
    JSON.stringify({
      main_module: "index.js",
      compatibility_date: "2026-09-01",
      compatibility_flags: ["nodejs_compat"],
      assets: { directory: "app", binding: "ASSETS", html_handling: "none", run_worker_first: true },
      bindings: { d1: ["DB"], vars: [], secrets: [] },
    }),
  );

  it("refuses a module or assets directory outside the bundle", () => {
    const base = { main_module: "index.js", compatibility_date: "2026-09-01", assets: { directory: "app", binding: "ASSETS" } };
    expect(() => readBundleJson(JSON.stringify({ ...base, main_module: "../index.js" }))).toThrow(/main_module/);
    expect(() => readBundleJson(JSON.stringify({ ...base, assets: { directory: "../app", binding: "ASSETS" } }))).toThrow(/assets.directory/);
  });

  it("runs the bundle's bytes under one environment's own settings", () => {
    const c = releaseConfig(raw, "dinners-roman", "/s/bundle", bundle) as Record<string, unknown> & {
      env: Record<string, { name: string; vars: Record<string, string>; assets: Record<string, unknown>; d1_databases: Record<string, string>[] }>;
    };
    expect(c.main).toBe("/s/bundle/worker/index.js");
    expect(c.no_bundle).toBe(true);
    expect(c.compatibility_date).toBe("2026-09-01");
    expect(c.$schema).toBeUndefined();
    expect(Object.keys(c.env)).toEqual(["dinners-roman"]);
    const e = c.env["dinners-roman"];
    expect(e?.name).toBe("dinners");
    expect(e?.vars.RELAY_URL).toBe("https://dinners.rcherkasov.workers.dev");
    expect(e?.assets).toEqual({ directory: "/s/bundle/app", binding: "ASSETS", html_handling: "none", run_worker_first: true });
    expect(e?.d1_databases[0]).toMatchObject({ database_name: "digestif-dinners-roman", database_id: "26e4568b-f457-46c6-af40-43a5d7880fcf", migrations_dir: "/s/bundle/migrations" });
  });
});
