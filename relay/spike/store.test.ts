// DIG-319: what the D1-shaped adapter (src/store.ts) over a circle's Durable Object must reproduce
// for src/ to run unchanged, checked side by side with the local D1 (env.D1), and the rows each
// store writes per signed read and per append. Runs under vitest.do.config.ts only: there env.DB is
// the adapter (spike/apply-migrations.ts) and the Worker under SELF is spike/main.ts.
import { env, SELF } from "cloudflare:test";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { summaryBody } from "../../conformance/src/bodies.ts";
import { jcs } from "../../conformance/src/encoding.ts";
import type { SignedEnvelope } from "../../conformance/src/envelope.ts";
import { Signer } from "../../conformance/src/keys.ts";
import { signedHeaders } from "../../conformance/src/request.ts";
import { World, type Member } from "../../conformance/src/world.ts";
import circleFile from "../../conformance/fixtures/test-circle.json";
import { append } from "../src/append.ts";
import { circleEpoch, ensureCircle } from "../src/db.ts";
import { DEFAULT_LIMITS, type Relay } from "../src/env.ts";
import { circle, page } from "../src/read.ts";
import { releaseSignersOf } from "../src/signers.ts";
import { StoreDatabase } from "../src/store.ts";
import { relayExtras, TEST_ROOT } from "../test/root.ts";

const RELAY = "http://relay.test";
const realFetch = globalThis.fetch;
const bound: Env = env;

function d1(): D1Database {
  if (bound.D1 === undefined) throw new Error("run under vitest.do.config.ts: env.D1 is the local D1 kept beside the store");
  return bound.D1;
}

const STORES: [string, () => D1Database][] = [
  ["D1", d1],
  ["Durable Object", () => env.DB],
];

/** One statement's share of a request's writes. */
interface Metered {
  sql: string;
  rows_written: number;
  rows_read: number;
}

/**
 * A store that reads meta off every round trip. first() is sent as all(), which D1 runs the same
 * way, so its meta is seen too.
 */
function metering(real: D1Database): { db: D1Database; log: Metered[] } {
  const log: Metered[] = [];
  const record = (sql: string, meta: D1Meta) => log.push({ sql: sql.replace(/\s+/g, " ").slice(0, 80), rows_written: meta.rows_written, rows_read: meta.rows_read });
  const unwrapped = new WeakMap<D1PreparedStatement, { inner: D1PreparedStatement; sql: string }>();
  const wrap = (inner: D1PreparedStatement, sql: string): D1PreparedStatement => {
    const statement = {
      bind: (...values: unknown[]) => wrap(inner.bind(...values), sql),
      first: async (column?: string) => {
        const result = await inner.all<Record<string, unknown>>();
        record(sql, result.meta);
        const row = result.results[0];
        if (row === undefined) return null;
        return column === undefined ? row : row[column];
      },
      run: async () => {
        const result = await inner.run();
        record(sql, result.meta);
        return result;
      },
      all: async () => {
        const result = await inner.all();
        record(sql, result.meta);
        return result;
      },
    } as unknown as D1PreparedStatement;
    unwrapped.set(statement, { inner, sql });
    return statement;
  };
  const db = {
    prepare: (sql: string) => wrap(real.prepare(sql), sql),
    batch: async <T>(statements: D1PreparedStatement[]) => {
      const parts = statements.map((s) => unwrapped.get(s) ?? { inner: s, sql: "?" });
      const results = await real.batch<T>(parts.map((p) => p.inner));
      results.forEach((result, i) => record(parts[i]?.sql ?? "?", result.meta));
      return results;
    },
  } as unknown as D1Database;
  return { db, log };
}

function relayOn(db: D1Database): Relay {
  return { ...relayExtras(), db, root: TEST_ROOT, limits: DEFAULT_LIMITS, now: new Date(), mailer: undefined, releaseSigners: releaseSignersOf(env) };
}

function signedGet(signer: Signer, path: string): { request: Request; url: URL } {
  const url = new URL(`${RELAY}${path}`);
  return { request: new Request(url, { method: "GET", headers: signedHeaders(signer, "GET", url.pathname + url.search, "") }), url };
}

/** The error a statement or batch throws, as text. */
async function failure(work: Promise<unknown>): Promise<string> {
  try {
    await work;
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
  throw new Error("expected the store to refuse");
}

/** Copies every relay table of the Durable Object store into the local D1, so both hold one circle. */
async function mirrorIntoD1(): Promise<void> {
  const tables = await env.DB.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name <> 'd1_migrations'").all<{ name: string }>();
  for (const { name } of tables.results) {
    const { results } = await env.DB.prepare(`SELECT * FROM ${name}`).all<Record<string, unknown>>();
    const statements = [d1().prepare(`DELETE FROM ${name}`)];
    for (const row of results) {
      const columns = Object.keys(row);
      statements.push(d1().prepare(`INSERT INTO ${name} (${columns.join(", ")}) VALUES (${columns.map(() => "?").join(", ")})`).bind(...Object.values(row)));
    }
    await d1().batch(statements);
  }
}

let world: World;
let member: Member;

beforeAll(async () => {
  globalThis.fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    return url.startsWith(RELAY) ? SELF.fetch(url, init) : realFetch(input, init);
  };
  world = new World(
    {
      hostIdentity: Signer.fromSeed(circleFile.host_identity_seed),
      hostDevice: Signer.fromSeed(circleFile.host_device_seed),
      root: circleFile.root as SignedEnvelope,
      rootHash: circleFile.root_hash,
    },
    [RELAY],
  );
  await world.setup();
  const [m] = await world.members(["storage spike"]);
  if (m === undefined) throw new Error("no member");
  member = m;
  await mirrorIntoD1();
});

afterAll(() => {
  globalThis.fetch = realFetch;
});

describe("the swap", () => {
  it("hands the suite the adapter, and the Worker under SELF writes the object, not D1", async () => {
    const before = await d1().prepare("SELECT COUNT(*) AS n FROM nonces").first<number>("n");
    expect((await SELF.fetch(signedGet(member.device.signer, "/v0/circle").request)).status).toBe(200);
    expect(await d1().prepare("SELECT COUNT(*) AS n FROM nonces").first<number>("n")).toBe(before);
    expect(env.DB).toBeInstanceOf(StoreDatabase);
    const inObject = await env.DB.prepare("SELECT COUNT(*) AS n FROM envelopes").first<number>("n");
    const inD1 = await d1().prepare("SELECT COUNT(*) AS n FROM envelopes").first<number>("n");
    expect(inObject).toBeGreaterThan(0);
    expect(inD1).toBe(inObject); // beforeAll mirrored the object into D1; nothing else wrote it
  });
});

describe.each(STORES)("%s", (name, store) => {
  it("rolls a batch back whole when a later statement fails", async () => {
    const db = store();
    const key = `atomic-${name}`;
    const text = await failure(
      db.batch([
        db.prepare("INSERT INTO nonces (key, nonce, expires_at) VALUES (?, 'a', 0)").bind(key),
        db.prepare("INSERT INTO nonces (key, nonce, expires_at) VALUES (?, 'b', 0)").bind(key),
        db.prepare("INSERT INTO nonces (key, nonce, expires_at) VALUES (?, 'a', 0)").bind(key),
      ]),
    );
    expect(text).toMatch(/UNIQUE constraint failed: nonces\./);
    expect(await db.prepare("SELECT COUNT(*) AS n FROM nonces WHERE key = ?").bind(key).first("n")).toBe(0);
  });

  it("reports meta.changes as the statement's own count, and 0 for a read after a write", async () => {
    const db = store();
    const digest = `changes-${name}`;
    const insert = () => db.prepare("INSERT OR IGNORE INTO mailed_digests (digest, sent_at) VALUES (?, 'now')").bind(digest);
    const [first, read, second] = await db.batch([insert(), db.prepare("SELECT 1"), insert()]);
    expect([first?.meta.changes, read?.meta.changes, second?.meta.changes]).toEqual([1, 0, 0]);
    expect((await db.prepare("DELETE FROM mailed_digests WHERE digest = ?").bind(digest).run()).meta.changes).toBe(1);
  });

  it("names the envelopes table in a lost race, as isLostRace (src/append.ts) matches", async () => {
    const db = store();
    const text = await failure(db.prepare("INSERT INTO envelopes SELECT * FROM envelopes ORDER BY relay_id LIMIT 1").run());
    console.log(`DIG-319 error text, ${name}, envelopes: ${text}`);
    expect(text).toMatch(/UNIQUE constraint failed: envelopes\./);
  });

  it("names the nonces table in a replay, as isNonceConflict (src/auth.ts) matches", async () => {
    const db = store();
    await db.prepare("INSERT INTO nonces (key, nonce, expires_at) VALUES ('replay', 'n', 0)").run();
    const text = await failure(db.prepare("INSERT INTO nonces (key, nonce, expires_at) VALUES ('replay', 'n', 0)").run());
    console.log(`DIG-319 error text, ${name}, nonces: ${text}`);
    expect(text).toMatch(/UNIQUE constraint failed: nonces\./);
  });

  it("carries the trigger's link_used, as isLinkUsed (src/links.ts) matches", async () => {
    const db = store();
    await db.prepare("INSERT INTO links (id, digest, ask, expires_at, used_at) VALUES ('used', 'd', 'a', 'x', 'then')").run();
    const text = await failure(db.prepare("UPDATE links SET used_at = 'again' WHERE id = 'used'").run());
    console.log(`DIG-319 error text, ${name}, link_used: ${text}`);
    expect(text).toMatch(/link_used/);
  });

  it("answers first(column), raw() and exec() as D1 does", async () => {
    const db = store();
    expect(await db.prepare("SELECT 7 AS seven").first("seven")).toBe(7);
    expect(await db.prepare("SELECT 1 AS a, 'b' AS b").raw()).toEqual([[1, "b"]]);
    expect(await db.prepare("SELECT 1 AS a, 'b' AS b").raw({ columnNames: true })).toEqual([["a", "b"], [1, "b"]]);
    expect((await db.exec("SELECT 1;\nSELECT 2;")).count).toBe(2);
  });
});

describe("rows written", () => {
  it("per signed read and per append, in both stores", async () => {
    await mirrorIntoD1();
    const report: Record<string, Record<string, { rows_written: number; rows_read: number; statements: Metered[] }>> = {};
    const total = (log: Metered[]) => ({
      rows_written: log.reduce((n, m) => n + m.rows_written, 0),
      rows_read: log.reduce((n, m) => n + m.rows_read, 0),
      statements: log,
    });
    const signed = member.device.next("summary", summaryBody(`writes ${world.tag}`), await circleEpoch(env.DB));
    const body = jcs(signed);
    for (const [name, store] of STORES) {
      await ensureCircle(store(), TEST_ROOT);
      const entry: (typeof report)[string] = {};
      for (const path of ["/v0/circle", "/v0/envelopes?after=0"]) {
        const { db, log } = metering(store());
        const { request, url } = signedGet(member.device.signer, path);
        const response = path === "/v0/circle" ? await circle(relayOn(db), request, url) : await page(relayOn(db), request, url);
        expect(response.status).toBe(200);
        entry[`signed GET ${path}`] = total(log);
      }
      const url = new URL(`${RELAY}/v0/envelopes`);
      const request = new Request(url, { method: "POST", headers: { "content-type": "application/json", ...signedHeaders(member.device.signer, "POST", url.pathname, body) }, body });
      const { db, log } = metering(store());
      expect((await append(relayOn(db), request, url)).status).toBe(201);
      entry["signed POST /v0/envelopes (summary)"] = total(log);
      report[name] = entry;
    }
    console.log(`DIG-319 rows written: ${JSON.stringify(report, null, 2)}`);
    for (const route of Object.keys(report["D1"] ?? {})) {
      expect(report["Durable Object"]?.[route]?.rows_written, route).toBe(report["D1"]?.[route]?.rows_written);
    }
  });
});
