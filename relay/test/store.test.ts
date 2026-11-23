// A circle's store (src/store.ts): the object applies the relay's schema on first use, returns an
// expected refusal as a value, and the adapter rethrows it; src/schema.ts is what migrations/ makes.
// The whole suite against the store runs under vitest.do.config.ts (spike/).
import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { applySchema, circleDatabase, StoreDatabase, type CircleStore } from "../src/store.ts";
import { SCHEMA } from "../src/schema.ts";
import index from "../src/index.ts?raw";

/** A fresh circle's store, never touched before this test. */
function fresh(): DurableObjectStub<CircleStore> {
  return env.CIRCLE_STORE.get(env.CIRCLE_STORE.newUniqueId());
}

describe("the schema", () => {
  it("is every migration the tests apply to D1, split the same way", () => {
    const migrations = env.TEST_MIGRATIONS ?? [];
    expect(migrations.length).toBeGreaterThan(0);
    expect(SCHEMA.map(({ name, queries }) => ({ name, queries }))).toEqual(migrations.map(({ name, queries }) => ({ name, queries })));
  });

  it("is applied by the object before its first statement, and recorded as wrangler records it", async () => {
    const db = circleDatabase(env.CIRCLE_STORE, `sha256:${"0".repeat(63)}1`);
    const tables = await db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").all<{ name: string }>();
    expect(tables.results.map((t) => t.name)).toEqual(expect.arrayContaining(["circle", "envelopes", "admitted_keys", "invites", "nonces", "daily_appends", "links", "mailed_digests", "d1_migrations"]));
    const applied = await db.prepare("SELECT name FROM d1_migrations ORDER BY id").all<{ name: string }>();
    expect(applied.results.map((r) => r.name)).toEqual(SCHEMA.map((m) => m.name));
  });

  it("applies only what a store lacks, each migration whole", async () => {
    const stub = fresh();
    await runInDurableObject(stub, (_instance, state) => {
      expect(applySchema(state.storage)).toEqual([]);
      const extra = [{ name: "9999_more.sql", queries: ["CREATE TABLE more (x)", "INSERT INTO more VALUES (1)"] }];
      expect(applySchema(state.storage, [...SCHEMA, ...extra])).toEqual(["9999_more.sql"]);
      const broken = [{ name: "9999_broken.sql", queries: ["CREATE TABLE broken (x)", "INSERT INTO nowhere VALUES (1)"] }];
      expect(() => applySchema(state.storage, [...SCHEMA, ...broken])).toThrow(/nowhere/);
      expect(state.storage.sql.exec("SELECT name FROM sqlite_master WHERE name = 'broken'").toArray()).toEqual([]);
      expect(state.storage.sql.exec("SELECT name FROM d1_migrations WHERE name = '9999_broken.sql'").toArray()).toEqual([]);
    });
  });
});

describe("a refusal", () => {
  it("crosses the call as a value, and the adapter rethrows its text", async () => {
    const stub = fresh();
    const insert = { sql: "INSERT INTO nonces (key, nonce, expires_at) VALUES ('k', 'n', 0)", params: [] };
    expect(await stub.run(insert)).toMatchObject({ ok: { meta: { changes: 1 } } });
    const again = await stub.run(insert);
    expect(again).toEqual({ refused: expect.stringMatching(/UNIQUE constraint failed: nonces\./) as unknown });
    const db = new StoreDatabase(() => stub);
    await expect(db.prepare("INSERT INTO nonces (key, nonce, expires_at) VALUES ('k', 'n', 0)").run()).rejects.toThrow(/UNIQUE constraint failed: nonces\./);
  });
});

describe("the handle", () => {
  it("names one object per root, so two circles never share a store", async () => {
    const a = circleDatabase(env.CIRCLE_STORE, `sha256:${"a".repeat(64)}`);
    const b = circleDatabase(env.CIRCLE_STORE, `sha256:${"b".repeat(64)}`);
    const again = circleDatabase(env.CIRCLE_STORE, `sha256:${"a".repeat(64)}`);
    await a.prepare("INSERT INTO nonces (key, nonce, expires_at) VALUES ('only-a', 'n', 0)").run();
    expect(await again.prepare("SELECT COUNT(*) AS n FROM nonces WHERE key = 'only-a'").first("n")).toBe(1);
    expect(await b.prepare("SELECT COUNT(*) AS n FROM nonces WHERE key = 'only-a'").first("n")).toBe(0);
  });

  it("is used by no route of the Worker yet", () => {
    expect(index).not.toContain(".CIRCLE_STORE");
    expect(index).not.toContain("circleDatabase");
  });
});
