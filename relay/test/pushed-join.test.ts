// A join judged by who sent it (docs/protocol.md, The admission fold). The relay's clock is set past
// the invite's expiry, as relay 2's was when a join relay 1 had accepted in time reached it: the
// guest's own unsigned append is judged at that clock and refused, the same join pushed by an
// admitted member's device is judged by its created_at and accepted, and a refold replays it at the
// clock it was judged at. append() is called directly so the relay's clock can be chosen.
import { env, SELF } from "cloudflare:test";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { jcs } from "../../conformance/src/encoding.ts";
import { envelopeHash, type SignedEnvelope } from "../../conformance/src/envelope.ts";
import { Signer } from "../../conformance/src/keys.ts";
import { signedHeaders } from "../../conformance/src/request.ts";
import { World, type Member } from "../../conformance/src/world.ts";
import circleFile from "../../conformance/fixtures/test-circle.json";
import { append } from "../src/append.ts";
import { circleEpoch, foldLog, keyJson, loadKey, loadKeys } from "../src/db.ts";
import { DEFAULT_LIMITS, type Relay } from "../src/env.ts";
import { Refusal } from "../src/errors.ts";

const RELAY = "http://relay.test";
const DAY_MS = 24 * 3600 * 1000;
const realFetch = globalThis.fetch;

interface Posted {
  status: number;
  body: unknown;
}

function relayAt(now: Date): Relay {
  return { db: env.DB, root: env.CIRCLE_ROOT, limits: DEFAULT_LIMITS, now, mailer: undefined };
}

/** POST /v0/envelopes into append() at the relay clock `now`, signed by `signer` at that clock or unsigned. */
async function postAt(now: Date, signed: SignedEnvelope, signer?: Signer): Promise<Posted> {
  const body = jcs(signed);
  const url = new URL(`${RELAY}/v0/envelopes`);
  const headers = { "content-type": "application/json", ...(signer === undefined ? {} : signedHeaders(signer, "POST", url.pathname, body, { timestamp: now })) };
  try {
    const response = await append(relayAt(now), new Request(url, { method: "POST", headers, body }), url);
    return { status: response.status, body: await response.json() };
  } catch (error) {
    if (!(error instanceof Refusal)) throw error;
    const response = error.response();
    return { status: response.status, body: await response.json() };
  }
}

async function expectRefold(): Promise<void> {
  const fold = await foldLog(env.DB, env.CIRCLE_ROOT, { all: true });
  expect((await loadKeys(env.DB)).map(keyJson)).toEqual(fold.admittedKeys().map(keyJson));
  expect(await circleEpoch(env.DB)).toBe(fold.epoch);
}

let world: World;
let pusher: Member;

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
  const [m] = await world.members(["pusher"]);
  if (m === undefined) throw new Error("a pusher expected");
  pusher = m;
});

afterAll(() => {
  globalThis.fetch = realFetch;
});

/** A fresh invite, its expiry, and the guest's join created an hour before that expiry. */
async function lateJoin(): Promise<{ member: Member; signed: SignedEnvelope; expiresAt: Date }> {
  const [invitation] = await world.dinner(["late guest"]);
  if (invitation === undefined) throw new Error("an invitation expected");
  const row = await env.DB.prepare("SELECT expires_at FROM invites WHERE key = ?").bind(invitation.invite.key).first<{ expires_at: string }>();
  const expiresAt = new Date(row?.expires_at ?? "");
  const { member, signed } = world.joinFor(invitation, new Date(expiresAt.getTime() - 3600 * 1000));
  return { member, signed, expiresAt };
}

describe("a join that reaches a relay after its invite's expiry", () => {
  it("is refused unsigned and accepted when an admitted device pushes it, and refolds at its created_at", async () => {
    const { member, signed, expiresAt } = await lateJoin();
    const late = new Date(expiresAt.getTime() + 3 * DAY_MS);
    expect(await postAt(late, signed)).toEqual({ status: 422, body: [{ code: "not_admitted", message: expect.any(String) as string }] });
    const pushed = await postAt(late, signed, pusher.device.signer);
    expect(pushed.status, JSON.stringify(pushed.body)).toBe(201);
    expect((await loadKey(env.DB, member.identity.key))?.role).toBe("identity");
    expect((await loadKey(env.DB, member.device.key))?.role).toBe("device");
    const row = await env.DB.prepare("SELECT received_at, judged_at FROM envelopes WHERE hash = ?").bind(envelopeHash(signed.envelope)).first<{ received_at: string; judged_at: string }>();
    expect(row?.judged_at).toBe(signed.envelope.created_at);
    expect(Date.parse(row?.received_at ?? "")).toBe(late.getTime());
    await expectRefold();
  });

  it("is refused unsigned when it is backdated to before the expiry", async () => {
    const { member, signed, expiresAt } = await lateJoin();
    expect(Date.parse(signed.envelope.created_at)).toBeLessThan(expiresAt.getTime());
    const posted = await postAt(new Date(expiresAt.getTime() + 60 * 1000), signed);
    expect(posted).toEqual({ status: 422, body: [{ code: "not_admitted", message: expect.any(String) as string }] });
    expect(await loadKey(env.DB, member.identity.key)).toBeUndefined();
  });

  it("is refused when pushed by a revoked device", async () => {
    const spare = await world.addDevice(pusher, "device");
    await world.publish([RELAY], pusher.device, await world.revoke(pusher.device, pusher.identity, spare.key, [spare]));
    const { member, signed, expiresAt } = await lateJoin();
    const posted = await postAt(new Date(expiresAt.getTime() + DAY_MS), signed, spare.signer);
    expect(posted).toEqual({ status: 401, body: { code: "not_admitted", message: expect.any(String) as string } });
    expect(await loadKey(env.DB, member.identity.key)).toBeUndefined();
  });

  it("is refused when pushed but created after the expiry", async () => {
    const [invitation] = await world.dinner(["created late"], [RELAY], { expired: true });
    if (invitation === undefined) throw new Error("an invitation expected");
    const { member, signed } = world.joinFor(invitation);
    const posted = await postAt(new Date(), signed, pusher.device.signer);
    expect(posted).toEqual({ status: 422, body: [{ code: "not_admitted", message: expect.any(String) as string }] });
    expect(await loadKey(env.DB, member.identity.key)).toBeUndefined();
  });

  it("is judged at the relay's clock when the guest sends it unsigned in time", async () => {
    const { signed, expiresAt } = await lateJoin();
    const now = new Date(expiresAt.getTime() - 60 * 1000);
    expect((await postAt(now, signed)).status).toBe(201);
    const row = await env.DB.prepare("SELECT judged_at FROM envelopes WHERE hash = ?").bind(envelopeHash(signed.envelope)).first<{ judged_at: string | null }>();
    expect(row?.judged_at).toBeNull();
    await expectRefold();
  });
});
