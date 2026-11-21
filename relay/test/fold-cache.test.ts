// The isolate's kept fold (src/db.ts, foldCache): an append folds only the circle-state envelopes
// committed since the fold it last built (the Worker under SELF shares this module, so its appends
// keep the fold these tests read), a log that no longer begins with what it folded is
// refolded whole, and the fold it hands out always equals the full refold. A replay of a stored
// envelope does not re-verify the key signatures inside it (conformance/src/fold.ts, stored).
import { env, SELF } from "cloudflare:test";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { deviceBody, retractBody } from "../../conformance/src/bodies.ts";
import { jcs, type Json } from "../../conformance/src/encoding.ts";
import { Author, envelopeHash, type Envelope, type SignedEnvelope } from "../../conformance/src/envelope.ts";
import { Fold } from "../../conformance/src/fold.ts";
import { Signer } from "../../conformance/src/keys.ts";
import { signedHeaders } from "../../conformance/src/request.ts";
import { World, type Member } from "../../conformance/src/world.ts";
import circleFile from "../../conformance/fixtures/test-circle.json";
import { append } from "../src/append.ts";
import { ENVELOPE_COLUMNS, foldLog, forgetKeptFold, keyJson, type EnvelopeRow } from "../src/db.ts";
import { releaseSignersOf } from "../src/signers.ts";
import { DEFAULT_LIMITS } from "../src/env.ts";

const RELAY = "http://relay.test";
const realFetch = globalThis.fetch;

/** A D1 that counts the envelope rows its reads return, batched or not: what a fold replays. */
function counting(real: D1Database): { db: D1Database; replayed: () => number } {
  let rows = 0;
  const inners = new WeakMap<D1PreparedStatement, { inner: D1PreparedStatement; sql: string }>();
  const wrap = (inner: D1PreparedStatement, sql: string): D1PreparedStatement => {
    const wrapped = {
      bind: (...values: unknown[]) => wrap(inner.bind(...values), sql),
      first: (column?: string) => (column === undefined ? inner.first() : inner.first(column)),
      run: () => inner.run(),
      all: async () => {
        const result = await inner.all();
        if (sql.includes(ENVELOPE_COLUMNS)) rows += result.results.length;
        return result;
      },
    } as unknown as D1PreparedStatement;
    inners.set(wrapped, { inner, sql });
    return wrapped;
  };
  const batch = async (statements: D1PreparedStatement[]): Promise<D1Result[]> => {
    const unwrapped = statements.map((s) => inners.get(s) ?? { inner: s, sql: "" });
    const results = await real.batch(unwrapped.map((u) => u.inner));
    results.forEach((result, i) => {
      if (unwrapped[i]?.sql.includes(ENVELOPE_COLUMNS)) rows += result.results.length;
    });
    return results;
  };
  const db = { prepare: (sql: string) => wrap(real.prepare(sql), sql), batch } as unknown as D1Database;
  return { db, replayed: () => rows };
}

const scope = () => ({ signers: releaseSignersOf(env) });

async function circleStateAfter(relayId: number): Promise<number> {
  const all = await env.DB.prepare("SELECT relay_id, kind FROM envelopes WHERE relay_id > ?").bind(relayId).all<{ kind: string }>();
  const state = new Set(["dinner", "join", "device", "revoke", "card", "relay", "release_revocation", "release_recall", "relay_release", "signer_set", "prompt"]);
  return all.results.filter((r) => state.has(r.kind)).length;
}

async function lastRelayId(): Promise<number> {
  return (await env.DB.prepare("SELECT MAX(relay_id) AS last FROM envelopes").first<{ last: number }>())?.last ?? 0;
}

/** The fold foldLog hands out, against the full refold of the whole log. */
async function expectFullRefold(fold: Fold): Promise<void> {
  const full = await foldLog(env.DB, env.CIRCLE_ROOT, { all: true, ...scope() });
  expect(fold.admittedKeys().map(keyJson)).toEqual(full.admittedKeys().map(keyJson));
  expect(fold.epoch).toBe(full.epoch);
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
  const [m] = await world.members(["first", "second"]);
  if (m === undefined) throw new Error("a member expected");
  member = m;
});

afterAll(() => {
  globalThis.fetch = realFetch;
});

describe("the isolate's kept fold", () => {
  it("is the full refold when the isolate starts with none", async () => {
    forgetKeptFold();
    const { db, replayed } = counting(env.DB);
    const fold = await foldLog(db, env.CIRCLE_ROOT, scope());
    expect(replayed()).toBe(await circleStateAfter(0));
    await expectFullRefold(fold);
  });

  it("replays nothing when no circle-state envelope was committed since it was built", async () => {
    await foldLog(env.DB, env.CIRCLE_ROOT, scope());
    await world.post(member.device, "content leaves the circle-state fold as it was");
    const { db, replayed } = counting(env.DB);
    const fold = await foldLog(db, env.CIRCLE_ROOT, scope());
    expect(replayed()).toBe(0);
    await expectFullRefold(fold);
  });

  it("replays only the circle-state envelopes committed elsewhere since it was built", async () => {
    const since = await lastRelayId();
    await world.members(["third"]);
    const added = await circleStateAfter(since);
    expect(added).toBeGreaterThan(0);
    forgetKeptFold();
    await foldLog(env.DB, env.CIRCLE_ROOT, { ...scope(), before: since + 1 });
    const { db, replayed } = counting(env.DB);
    const fold = await foldLog(db, env.CIRCLE_ROOT, scope());
    expect(replayed()).toBe(added);
    await expectFullRefold(fold);
  });

  it("keeps the fold an append committed, so the next append replays nothing", async () => {
    await foldLog(env.DB, env.CIRCLE_ROOT, scope());
    const key = new Author(Signer.random());
    const signed = member.device.next("device", deviceBody(member.identity, key.key, "device"), await world.epoch());
    const body = jcs(signed);
    const url = new URL(`${RELAY}/v0/envelopes`);
    const headers = { "content-type": "application/json", ...signedHeaders(member.device.signer, "POST", url.pathname, body) };
    const relay = { db: env.DB, root: env.CIRCLE_ROOT, limits: DEFAULT_LIMITS, now: new Date(), mailer: undefined, releaseSigners: releaseSignersOf(env) };
    const response = await append(relay, new Request(url, { method: "POST", headers, body }), url);
    expect(response.status, await response.clone().text()).toBe(201);
    const { db, replayed } = counting(env.DB);
    const fold = await foldLog(db, env.CIRCLE_ROOT, scope());
    expect(replayed()).toBe(0);
    expect(fold.keys.get(key.key)?.role).toBe("device");
    await expectFullRefold(fold);
  });

  it("folds a retract from the kept fold, replaying no envelope, and still judges it by the target's author", async () => {
    const note = await world.post(member.device, "to be retracted");
    const target = envelopeHash(note.envelope);
    await foldLog(env.DB, env.CIRCLE_ROOT, scope());
    const relayOn = (db: D1Database) => ({ db, root: env.CIRCLE_ROOT, limits: DEFAULT_LIMITS, now: new Date(), mailer: undefined, releaseSigners: releaseSignersOf(env) });
    const send = async (db: D1Database, author: Author): Promise<Response> => {
      const signed = author.next("retract", retractBody(target), await world.epoch());
      const body = jcs(signed);
      const url = new URL(`${RELAY}/v0/envelopes`);
      const headers = { "content-type": "application/json", ...signedHeaders(author.signer, "POST", url.pathname, body) };
      return append(relayOn(db), new Request(url, { method: "POST", headers, body }), url);
    };
    const [other] = await world.members(["retract interloper"]);
    if (other === undefined) throw new Error("a second member expected");
    await foldLog(env.DB, env.CIRCLE_ROOT, scope());
    const refused = counting(env.DB);
    await expect(send(refused.db, other.device)).rejects.toMatchObject({ status: 422, code: "retract_not_author" });
    expect(refused.replayed()).toBe(0);
    const accepted = counting(env.DB);
    const response = await send(accepted.db, member.device);
    expect(response.status, await response.clone().text()).toBe(201);
    expect(accepted.replayed()).toBe(0);
  });

  it("refolds the whole log when it no longer begins with the envelopes the kept fold read", async () => {
    await foldLog(env.DB, env.CIRCLE_ROOT, scope());
    await env.DB.prepare("UPDATE envelopes SET judged_at = '2000-01-01T00:00:00.000Z' WHERE relay_id = 1").run();
    try {
      const { db, replayed } = counting(env.DB);
      const fold = await foldLog(db, env.CIRCLE_ROOT, scope());
      expect(replayed()).toBe(await circleStateAfter(0));
      await expectFullRefold(fold);
    } finally {
      await env.DB.prepare("UPDATE envelopes SET judged_at = NULL WHERE relay_id = 1").run();
    }
  });

  it("hands out a copy: applying to it leaves the kept fold as it was", async () => {
    const first = await foldLog(env.DB, env.CIRCLE_ROOT, scope());
    const identity = first.keys.get(member.identity.key);
    if (identity === undefined) throw new Error("the member's identity expected");
    identity.revoked_at = 1;
    first.epoch += 100;
    const again = await foldLog(env.DB, env.CIRCLE_ROOT, scope());
    expect(again.keys.get(member.identity.key)?.revoked_at).toBeUndefined();
    await expectFullRefold(again);
  });
});

describe("a stored replay", () => {
  it("does not re-verify a join's key signatures, which an unstored apply refuses", async () => {
    const { results } = await env.DB.prepare(`SELECT ${ENVELOPE_COLUMNS} FROM envelopes ORDER BY relay_id`).all<EnvelopeRow>();
    const join = results.find((r) => r.kind === "join");
    if (join === undefined) throw new Error("a join expected");
    const replayTo = (stored: boolean): string | null => {
      const fold = new Fold(env.CIRCLE_ROOT);
      for (const row of results) {
        if (row.relay_id > join.relay_id) break;
        let body = row.body === null ? undefined : (JSON.parse(row.body) as Json);
        if (row.relay_id === join.relay_id) body = { ...(body as Record<string, Json>), identity_signature: Signer.random().sign("not this join") };
        const error = fold.apply({
          hash: row.hash,
          envelope: JSON.parse(row.envelope) as Envelope,
          body,
          position: row.relay_id,
          now: new Date(row.judged_at ?? row.received_at),
          stored: stored || row.relay_id !== join.relay_id,
        });
        if (error !== null) return error;
      }
      return null;
    };
    expect(replayTo(true)).toBeNull();
    expect(replayTo(false)).toBe("bad_signature");
  });
});
