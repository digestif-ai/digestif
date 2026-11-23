// What a caller the circle never admitted can make the relay do: nothing that writes. A key no
// envelope admitted spends no nonce row, an unsigned bootstrap append whose key the circle does not
// know is refused before the fold, an oversized header or body is refused before it is verified or
// buffered, and the per-address ceiling refuses a flood before the database is read. DIG-228
import { env, SELF } from "cloudflare:test";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { deviceBody, dinnerBody, INVITE_TTL_MS, joinBody } from "../../conformance/src/bodies.ts";
import { isoTime, jcs } from "../../conformance/src/encoding.ts";
import { Author, type SignedEnvelope } from "../../conformance/src/envelope.ts";
import { Signer } from "../../conformance/src/keys.ts";
import { signedHeaders } from "../../conformance/src/request.ts";
import { World, type Member } from "../../conformance/src/world.ts";
import circleFile from "../../conformance/fixtures/test-circle.json";
import { throttle } from "../src/append.ts";
import { MAX_HEADER_LENGTH } from "../src/auth.ts";
import { HOME } from "./root.ts";

// The home circle's address: every circle route answers only under it.
const RELAY = HOME;
/** The path a signature covers: the circle's address and the route under it. */
const at = (path: string): string => `${new URL(RELAY).pathname}${path}`;
const realFetch = globalThis.fetch;

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
  [member] = (await world.members(["admitted member"])) as [Member];
});

afterAll(() => {
  globalThis.fetch = realFetch;
});

async function nonceRows(key: string): Promise<number> {
  const row = await env.DB.prepare("SELECT COUNT(*) AS n FROM nonces WHERE key = ?").bind(key).first<{ n: number }>();
  return row?.n ?? 0;
}

async function envelopeCount(): Promise<number> {
  const row = await env.DB.prepare("SELECT COUNT(*) AS n FROM envelopes").first<{ n: number }>();
  return row?.n ?? 0;
}

function get(signer: Signer, path: string, headers: Record<string, string> = {}): Promise<Response> {
  return SELF.fetch(`${RELAY}${path}`, { headers: { ...signedHeaders(signer, "GET", at(path), ""), ...headers } });
}

function post(body: string, headers: Record<string, string> = {}): Promise<Response> {
  return SELF.fetch(`${RELAY}/v0/envelopes`, { method: "POST", body, headers });
}

describe("a key the circle never admitted", () => {
  it("is refused on a signed read and spends no nonce", async () => {
    const stranger = Signer.random();
    for (const path of ["/v0/circle", "/v0/envelopes?after=0"]) {
      const response = await get(stranger, path);
      expect(response.status, path).toBe(401);
      expect(await response.json()).toMatchObject({ code: "not_admitted" });
    }
    expect(await nonceRows(stranger.key)).toBe(0);
  });

  it("is refused on a signed append and spends no nonce", async () => {
    const stranger = Signer.random();
    const signed = new Author(stranger).next("summary", { text: "hello" }, 0);
    const raw = jcs(signed);
    const response = await post(raw, signedHeaders(stranger, "POST", at("/v0/envelopes"), raw));
    expect(response.status).toBe(401);
    expect(await response.json()).toMatchObject({ code: "not_admitted" });
    expect(await nonceRows(stranger.key)).toBe(0);
  });

  it("reads an invite no dinner lists as 404 and spends no nonce", async () => {
    const stranger = Signer.random();
    const response = await get(stranger, `/v0/invites/${encodeURIComponent(stranger.key)}`);
    expect(response.status).toBe(404);
    expect(await nonceRows(stranger.key)).toBe(0);
  });

  it("still spends the nonce of an admitted member, so a replay is refused", async () => {
    const headers = signedHeaders(member.device.signer, "GET", at("/v0/circle"), "");
    expect((await SELF.fetch(`${RELAY}/v0/circle`, { headers })).status).toBe(200);
    const replay = await SELF.fetch(`${RELAY}/v0/circle`, { headers });
    expect(replay.status).toBe(401);
    expect(await replay.json()).toMatchObject({ code: "replayed_nonce" });
  });
});

describe("an unsigned bootstrap append whose key the circle does not know", () => {
  async function refused(signed: SignedEnvelope): Promise<void> {
    const before = await envelopeCount();
    const response = await post(jcs(signed));
    expect(response.status).toBe(422);
    const body = await response.json<Array<{ code: string; message: string }>>();
    expect(body[0]).toMatchObject({ code: "not_admitted" });
    expect(body[0]?.message).toContain("does not know the key");
    expect(await envelopeCount()).toBe(before);
  }

  it("refuses a dinner from a self-generated device", async () => {
    const identity = Signer.random();
    const guest = { name: "nobody", invite_key: Signer.random().key, expires_at: isoTime(new Date(Date.now() + INVITE_TTL_MS)) };
    await refused(new Author(Signer.random()).next("dinner", dinnerBody(identity, "a dinner nobody hosted", [guest], [RELAY]), 0));
  });

  it("refuses a join whose invite key no dinner lists", async () => {
    const invite = Signer.random();
    await refused(new Author(invite).next("join", joinBody(world.circle.rootHash, invite, Signer.random(), Signer.random()), 0));
  });

  it("refuses a self-authored device of an identity the circle never admitted", async () => {
    const device = Signer.random();
    await refused(new Author(device).next("device", deviceBody(Signer.random(), device.key, "device"), 0));
  });

  it("accepts the self-authored device of an admitted identity", async () => {
    const device = Signer.random();
    const signed = new Author(device).next("device", deviceBody(member.identity, device.key, "device"), await world.epoch());
    const response = await post(jcs(signed));
    expect(response.status).toBe(201);
  });
});

describe("sizes", () => {
  it("refuses a Digestif header over the cap before verifying it", async () => {
    const headers = signedHeaders(member.device.signer, "GET", at("/v0/circle"), "", { nonce: "n".repeat(MAX_HEADER_LENGTH + 1) });
    const response = await SELF.fetch(`${RELAY}/v0/circle`, { headers });
    expect(response.status).toBe(401);
    expect(await response.json()).toMatchObject({ code: "bad_signature" });
  });

  it("refuses an append on its Content-Length", async () => {
    const limit = Number(env.MAX_ENVELOPE_BYTES ?? "65536");
    const response = await post("x".repeat(limit + 1));
    expect(response.status).toBe(422);
    expect(await response.json()).toMatchObject([{ code: "too_large" }]);
  });

  it("refuses a streamed append with no Content-Length once it passes the limit", async () => {
    const limit = Number(env.MAX_ENVELOPE_BYTES ?? "65536");
    const chunk = new TextEncoder().encode("x".repeat(4096));
    let sent = 0;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (sent > limit * 4) return controller.close();
        sent += chunk.byteLength;
        controller.enqueue(chunk);
      },
    });
    const response = await SELF.fetch(`${RELAY}/v0/envelopes`, { method: "POST", body });
    expect(response.status).toBe(422);
    expect(await response.json()).toMatchObject([{ code: "too_large" }]);
  });
});

describe("the per-address ceiling", () => {
  it("refuses with 429 rate_limited once the limiter says no, keyed by the client address", async () => {
    const keys: string[] = [];
    let allow = true;
    const limiter: RateLimit = {
      limit: ({ key }: { key: string }) => {
        keys.push(key);
        return Promise.resolve({ success: allow });
      },
    };
    const request = new Request(`${RELAY}/v0/envelopes`, { method: "POST", headers: { "cf-connecting-ip": "203.0.113.7" } });
    await expect(throttle(limiter, request)).resolves.toBeUndefined();
    allow = false;
    await expect(throttle(limiter, request)).rejects.toMatchObject({ status: 429, code: "rate_limited" });
    expect(keys).toEqual(["203.0.113.7", "203.0.113.7"]);
  });

  it("is no ceiling where the binding is absent", async () => {
    await expect(throttle(undefined, new Request(`${RELAY}/v0/envelopes`, { method: "POST" }))).resolves.toBeUndefined();
  });
});
