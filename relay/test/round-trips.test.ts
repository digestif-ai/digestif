// How many D1 round trips each route costs once an isolate is warm: a signed read is the key and
// then the nonce batch carrying the answer, and an append adds one batch of the check's reads and
// the write. Each first/all/run and each batch is one round trip. DIG-234
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

const RELAY = "http://relay.test";
const realFetch = globalThis.fetch;

/** A D1 that counts its round trips. */
function counting(real: D1Database): { db: D1Database; trips: () => number } {
  let trips = 0;
  const unwrapped = new WeakMap<D1PreparedStatement, D1PreparedStatement>();
  const wrap = (inner: D1PreparedStatement): D1PreparedStatement => {
    const statement = {
      bind: (...values: unknown[]) => wrap(inner.bind(...values)),
      first: (column?: string) => {
        trips++;
        return column === undefined ? inner.first() : inner.first(column);
      },
      run: () => {
        trips++;
        return inner.run();
      },
      all: () => {
        trips++;
        return inner.all();
      },
    } as unknown as D1PreparedStatement;
    unwrapped.set(statement, inner);
    return statement;
  };
  const db = {
    prepare: (sql: string) => wrap(real.prepare(sql)),
    batch: <T>(statements: D1PreparedStatement[]) => {
      trips++;
      return real.batch<T>(statements.map((s) => unwrapped.get(s) ?? s));
    },
  } as unknown as D1Database;
  return { db, trips: () => trips };
}

function relayOn(db: D1Database): Relay {
  return { db, root: env.CIRCLE_ROOT, limits: DEFAULT_LIMITS, now: new Date(), mailer: undefined, releaseSigners: releaseSignersOf(env) };
}

function signedGet(signer: Signer, path: string): { request: Request; url: URL } {
  const url = new URL(`${RELAY}${path}`);
  return { request: new Request(url, { method: "GET", headers: signedHeaders(signer, "GET", url.pathname + url.search, "") }), url };
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
  const [m] = await world.members(["round trips"]);
  if (m === undefined) throw new Error("no member");
  member = m;
});

afterAll(() => {
  globalThis.fetch = realFetch;
});

describe("a warm isolate", () => {
  it("checks the circle row once per database and root", async () => {
    const { db, trips } = counting(env.DB);
    await ensureCircle(db, env.CIRCLE_ROOT);
    const first = trips();
    await ensureCircle(db, env.CIRCLE_ROOT);
    expect(first).toBeLessThanOrEqual(1);
    expect(trips()).toBe(first);
  });

  it("answers GET /v0/envelopes in two round trips", async () => {
    const { db, trips } = counting(env.DB);
    const { request, url } = signedGet(member.device.signer, "/v0/envelopes?after=0");
    expect((await page(relayOn(db), request, url)).status).toBe(200);
    expect(trips()).toBe(2);
  });

  it("answers GET /v0/circle in two round trips", async () => {
    const { db, trips } = counting(env.DB);
    const { request, url } = signedGet(member.device.signer, "/v0/circle");
    expect((await circle(relayOn(db), request, url)).status).toBe(200);
    expect(trips()).toBe(2);
  });

  it("appends a content envelope in four round trips", async () => {
    // The first append folds what this test's setup appended; the second starts from that fold.
    for (const [index, expected] of [[1, undefined], [2, 4]] as const) {
      const signed = member.device.next("summary", summaryBody(`trip ${index} ${world.tag}`), await circleEpoch(env.DB));
      const body = jcs(signed);
      const url = new URL(`${RELAY}/v0/envelopes`);
      const request = new Request(url, { method: "POST", headers: { "content-type": "application/json", ...signedHeaders(member.device.signer, "POST", url.pathname, body) }, body });
      const { db, trips } = counting(env.DB);
      expect((await append(relayOn(db), request, url)).status).toBe(201);
      if (expected !== undefined) expect(trips(), "key, nonce, the check's reads, the write").toBe(expected);
    }
  });
});
