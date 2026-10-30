// Two appends at once, at the unit level. miniflare serializes D1 access through SELF.fetch, so
// a real race cannot be staged over HTTP; instead append() runs against a D1 that lets a competing
// append commit at a chosen point of the check (before the position read, before the fold read,
// before the chain or cap read, before the write batch), and the outcome must be the same at every
// point: the loser lands after the winner with the next relay_id, a signed loser is not refused as
// its own replay, two joins take consecutive epochs, a fork is refused, and two copies of one
// request pass once.
import { env, SELF } from "cloudflare:test";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { summaryBody } from "../../conformance/src/bodies.ts";
import { jcs } from "../../conformance/src/encoding.ts";
import { envelopeHash, type SignedEnvelope } from "../../conformance/src/envelope.ts";
import { Signer } from "../../conformance/src/keys.ts";
import { signedHeaders } from "../../conformance/src/request.ts";
import { World, type Member } from "../../conformance/src/world.ts";
import circleFile from "../../conformance/fixtures/test-circle.json";
import { append } from "../src/append.ts";
import { authenticate } from "../src/auth.ts";
import { circleEpoch, foldLog, keyJson, loadKey, loadKeys } from "../src/db.ts";
import { DEFAULT_LIMITS, type Relay } from "../src/env.ts";
import { Refusal } from "../src/errors.ts";

const RELAY = "http://relay.test";
const realFetch = globalThis.fetch;

/** Where in check() the competitor commits: the first statement matching the pattern waits for it. */
const POINTS: Record<string, RegExp> = {
  "before the position read": /MAX\(relay_id\)/,
  "before the duplicate read": /WHERE hash = \? AND relay_id < \?/,
  "before the fold read": /FROM envelopes WHERE relay_id < \? AND \(kind IN/,
  "before the chain read": /MAX\(seq\)/,
  "before the cap read": /FROM daily_appends/,
  "before the write batch": /INSERT INTO envelopes/,
};
/** A join skips the chain check, so a competitor waiting there would never run. */
const JOIN_POINTS = Object.entries(POINTS).filter(([name]) => name !== "before the chain read");

interface Interleaved {
  db: D1Database;
  /** Whether the competitor ran: a point the check never reached would prove nothing. */
  fired: () => boolean;
}

/** A D1 that runs `competitor` to completion before the first statement matching `at` executes. */
function interleaving(real: D1Database, at: RegExp, competitor: () => Promise<void>): Interleaved {
  let fired = false;
  const fire = async (sql: string): Promise<void> => {
    if (fired || !at.test(sql)) return;
    fired = true;
    await competitor();
  };
  const unwrapped = new WeakMap<D1PreparedStatement, { inner: D1PreparedStatement; sql: string }>();
  const wrap = (inner: D1PreparedStatement, sql: string): D1PreparedStatement => {
    const statement = {
      bind: (...values: unknown[]) => wrap(inner.bind(...values), sql),
      first: async (column?: string) => {
        await fire(sql);
        return column === undefined ? inner.first() : inner.first(column);
      },
      run: async () => {
        await fire(sql);
        return inner.run();
      },
      all: async () => {
        await fire(sql);
        return inner.all();
      },
    } as unknown as D1PreparedStatement;
    unwrapped.set(statement, { inner, sql });
    return statement;
  };
  const db = {
    prepare: (sql: string) => wrap(real.prepare(sql), sql),
    batch: async <T>(statements: D1PreparedStatement[]) => {
      const parts = statements.map((s) => unwrapped.get(s) ?? { inner: s, sql: "" });
      await fire(parts.map((p) => p.sql).join("\n"));
      return real.batch<T>(parts.map((p) => p.inner));
    },
  } as unknown as D1Database;
  return { db, fired: () => fired };
}

function relayOn(db: D1Database, now = new Date()): Relay {
  return { db, root: env.CIRCLE_ROOT, limits: DEFAULT_LIMITS, now, mailer: undefined };
}

interface Posted {
  status: number;
  body: unknown;
}

/** POST /v0/envelopes straight into append(), signed by `signer` or unsigned as a bootstrap append. */
function requestFor(signed: SignedEnvelope, signer?: Signer): { request: Request; url: URL } {
  const body = jcs(signed);
  const url = new URL(`${RELAY}/v0/envelopes`);
  const headers = { "content-type": "application/json", ...(signer === undefined ? {} : signedHeaders(signer, "POST", url.pathname + url.search, body)) };
  return { request: new Request(url, { method: "POST", headers, body }), url };
}

async function post(relay: Relay, request: Request, url: URL): Promise<Posted> {
  try {
    const response = await append(relay, request.clone(), url);
    return { status: response.status, body: await response.json() };
  } catch (error) {
    if (!(error instanceof Refusal)) throw error;
    const response = error.response();
    return { status: response.status, body: await response.json() };
  }
}

/** Runs `loser` against a D1 where `winner` commits at `at`; both must have run. */
async function race(at: RegExp, winner: { request: Request; url: URL }, loser: { request: Request; url: URL }): Promise<{ won: Posted; lost: Posted }> {
  let won: Posted | undefined;
  const staged = interleaving(env.DB, at, async () => {
    won = await post(relayOn(env.DB), winner.request, winner.url);
  });
  const lost = await post(relayOn(staged.db), loser.request, loser.url);
  expect(staged.fired(), "the competitor ran").toBe(true);
  if (won === undefined) throw new Error("the winner did not answer");
  return { won, lost };
}

function relayIdOf(posted: Posted): number {
  expect(posted.status, JSON.stringify(posted.body)).toBe(201);
  return (posted.body as { relay_id: number }).relay_id;
}

async function expectRefold(): Promise<void> {
  const fold = await foldLog(env.DB, env.CIRCLE_ROOT, { all: true });
  expect((await loadKeys(env.DB)).map(keyJson)).toEqual(fold.admittedKeys().map(keyJson));
  expect(await circleEpoch(env.DB)).toBe(fold.epoch);
}

let world: World;
let members: Member[];

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
  members = await world.members(["race a", "race b"]);
});

afterAll(() => {
  globalThis.fetch = realFetch;
});

function member(index: number): Member {
  const m = members[index];
  if (m === undefined) throw new Error(`no member ${index}`);
  return m;
}

describe("a signed append that loses the relay_id race", () => {
  it.each(Object.entries(POINTS))("lands on the retry with the next relay_id, its nonce spent once (%s)", async (_name, at) => {
    const [a, b] = [member(0), member(1)];
    const epoch = await circleEpoch(env.DB);
    const winner = requestFor(b.device.next("summary", summaryBody(`winner ${world.tag}`), epoch), b.device.signer);
    const loser = requestFor(a.device.next("summary", summaryBody(`loser ${world.tag}`), epoch), a.device.signer);
    const { won, lost } = await race(at, winner, loser);
    expect(relayIdOf(lost)).toBe(relayIdOf(won) + 1);
    // The retry did not spend the nonce again, and the nonce is held: the same bytes are a replay.
    const again = await post(relayOn(env.DB), loser.request, loser.url);
    expect(again).toEqual({ status: 401, body: { code: "replayed_nonce", message: expect.any(String) as string } });
    await expectRefold();
  });
});

describe("two joins at once", () => {
  it.each(JOIN_POINTS)("take consecutive epochs, the second folded over the first (%s)", async (_name, at) => {
    const [x, y] = (await world.dinner(["race x", "race y"])).map((i) => world.joinFor(i));
    if (x === undefined || y === undefined) throw new Error("two invitations expected");
    const epoch = await circleEpoch(env.DB);
    const { won, lost } = await race(at, requestFor(y.signed), requestFor(x.signed));
    expect(relayIdOf(lost)).toBe(relayIdOf(won) + 1);
    expect(await circleEpoch(env.DB)).toBe(epoch + 2);
    expect((await loadKey(env.DB, y.member.identity.key))?.join_epoch).toBe(epoch + 1);
    expect((await loadKey(env.DB, x.member.identity.key))?.join_epoch).toBe(epoch + 2);
    await expectRefold();
  });
});

describe("a fork that races the envelope it forks", () => {
  it.each(Object.entries(POINTS))("is refused once the other has landed (%s)", async (_name, at) => {
    const a = member(0);
    const epoch = await circleEpoch(env.DB);
    const one = a.device.peek("summary", summaryBody(`one ${world.tag}`), epoch);
    const two = a.device.peek("summary", summaryBody(`two ${world.tag}`), epoch);
    expect(two.envelope.seq).toBe(one.envelope.seq);
    const { won, lost } = await race(at, requestFor(two, a.device.signer), requestFor(one, a.device.signer));
    relayIdOf(won);
    expect(lost).toEqual({ status: 422, body: [{ code: "fork", message: expect.any(String) as string }] });
    const held = await env.DB.prepare("SELECT hash FROM envelopes WHERE author = ? AND seq = ?").bind(a.device.key, one.envelope.seq).all<{ hash: string }>();
    expect(held.results.map((r) => r.hash)).toEqual([envelopeHash(two.envelope)]);
    // The author's chain continues from the envelope that landed.
    a.device.seq = two.envelope.seq;
    a.device.prev = envelopeHash(two.envelope);
    await expectRefold();
  });
});

describe("two copies of one signed request", () => {
  it("pass once: the second nonce record fails the primary key and is replayed_nonce", async () => {
    const a = member(0);
    const epoch = await circleEpoch(env.DB);
    const copy = requestFor(a.device.next("summary", summaryBody(`copied ${world.tag}`), epoch), a.device.signer);
    const { won, lost } = await race(/INSERT INTO nonces/, copy, copy);
    expect(won.status, JSON.stringify(won.body)).toBe(201);
    expect(lost).toEqual({ status: 401, body: { code: "replayed_nonce", message: expect.any(String) as string } });
    await expectRefold();
  });

  it("a nonce may be used again once its window has passed", async () => {
    const a = member(0);
    const url = new URL(`${RELAY}/v0/circle`);
    const at = new Date();
    const nonce = "race-nonce-reuse";
    const signedAt = (timestamp: Date): Request =>
      new Request(url, { method: "GET", headers: signedHeaders(a.device.signer, "GET", url.pathname, "", { timestamp, nonce }) });
    await expect(authenticate(relayOn(env.DB, at), signedAt(at), url, "")).resolves.toEqual({ key: a.device.key });
    await expect(authenticate(relayOn(env.DB, at), signedAt(at), url, "")).rejects.toMatchObject({ code: "replayed_nonce" });
    const later = new Date(at.getTime() + DEFAULT_LIMITS.skew_seconds * 1000 + 1);
    await expect(authenticate(relayOn(env.DB, later), signedAt(later), url, "")).resolves.toEqual({ key: a.device.key });
  });
});
