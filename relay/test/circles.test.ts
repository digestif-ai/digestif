// A relay hosting many circles (docs/protocol.md, Hosted circles): the relay's own routes, a second
// circle founded under a voucher from a member of the home circle, the conformance suite's relay
// cases run on that second circle at its address while the home circle holds its own log, neither
// circle reading, appending to or admitting into the other, the founding refusals, the suspended
// state and a circle's storage share.
import { env, SELF } from "cloudflare:test";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { relayCases } from "../../conformance/src/cases/relay.ts";
import { dinnerBody } from "../../conformance/src/bodies.ts";
import { jcs } from "../../conformance/src/encoding.ts";
import { envelopeHash, signEnvelope, type SignedEnvelope } from "../../conformance/src/envelope.ts";
import { runCases } from "../../conformance/src/harness.ts";
import { Signer } from "../../conformance/src/keys.ts";
import { RelayClient } from "../../conformance/src/request.ts";
import { HEADER_VOUCHER, signVoucher } from "../../conformance/src/voucher.ts";
import { World, type Member } from "../../conformance/src/world.ts";
import circleFile from "../../conformance/fixtures/test-circle.json";
import { appendSigned } from "../src/append.ts";
import { addressOf, found, forgetMemos, hostedRow } from "../src/circles.ts";
import { foldLog, keyJson, loadKeys } from "../src/db.ts";
import { DEFAULT_HOSTING, DEFAULT_LIMITS, type HostingLimits } from "../src/env.ts";
import { fromFor, forCircle } from "../src/mail.ts";
import { circleDatabase } from "../src/store.ts";
import { RELAY } from "./helpers.ts";
import { HOME, relayExtras, TEST_ROOT } from "./root.ts";

const realFetch = globalThis.fetch;

/** A throwaway circle founded at a dinner, as the suite's test circle is: its host and its root. */
function newCircle(label: string): { hostIdentity: Signer; hostDevice: Signer; root: SignedEnvelope; rootHash: string } {
  const hostIdentity = Signer.random();
  const hostDevice = Signer.random();
  const root = signEnvelope(hostDevice, { kind: "dinner", body: dinnerBody(hostIdentity, label, [], [RELAY]), seq: 1, epoch: 0 });
  return { hostIdentity, hostDevice, root, rootHash: envelopeHash(root.envelope) };
}

/** The bootstrap append of a root to its address, with a voucher header when one is given. */
async function appendRoot(root: SignedEnvelope, voucher?: string): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (voucher !== undefined) headers[HEADER_VOUCHER] = voucher;
  return SELF.fetch(`${addressOf(RELAY, envelopeHash(root.envelope))}/v0/envelopes`, { method: "POST", headers, body: jcs(root) });
}

async function code(response: Response): Promise<string | undefined> {
  const body = await response.json<{ code?: string } | Array<{ code?: string }>>();
  return Array.isArray(body) ? body[0]?.code : body.code;
}

let home: World;
let voucherMember: Member;

beforeAll(async () => {
  globalThis.fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    if (url.startsWith(RELAY)) return SELF.fetch(url, init);
    return realFetch(input, init);
  };
  home = new World(
    { hostIdentity: Signer.fromSeed(circleFile.host_identity_seed), hostDevice: Signer.fromSeed(circleFile.host_device_seed), root: circleFile.root as SignedEnvelope, rootHash: circleFile.root_hash },
    [HOME],
  );
  await home.setup();
  [voucherMember] = (await home.members(["founder"])) as [Member];
});

afterAll(() => {
  globalThis.fetch = realFetch;
});

describe("the relay's own routes", () => {
  it("GET /v0/relay reports the release, the mailer's key, hosting, the home circle and the last unprefixed request", async () => {
    forgetMemos();
    const before = new Date().toISOString();
    expect((await home.client(RELAY, home.host.device).circle()).status).toBe(410);
    const response = await SELF.fetch(`${RELAY}/v0/relay`);
    expect(response.status).toBe(200);
    const info = await response.json<Record<string, unknown>>();
    expect(info["home"]).toBe(TEST_ROOT);
    expect(info["mailer"]).toBe(true);
    expect(info["encryption_key"]).toMatch(/^x25519:/);
    expect(info["hosting"]).toBe(true);
    expect(info["relay_version"]).toBeTypeOf("string");
    expect(typeof info["last_unprefixed_at"] === "string" && info["last_unprefixed_at"] >= before.slice(0, 19)).toBe(true);
  });

  it("answers 404 circle_unknown for an address no circle holds, and for a malformed one", async () => {
    const unknown = await SELF.fetch(`${RELAY}/c/${"e".repeat(64)}/v0/circle`);
    expect(unknown.status).toBe(404);
    expect(await code(unknown)).toBe("circle_unknown");
    const malformed = await SELF.fetch(`${RELAY}/c/xyz/v0/circle`);
    expect(malformed.status).toBe(404);
    expect(await code(malformed)).toBe("circle_unknown");
  });

  it("answers the home circle at its address, and 410 circle_moved naming that address at every unprefixed route", async () => {
    const at = await home.client(HOME, home.host.device).circle();
    expect(at.status).toBe(200);
    expect((at.body as { root: string }).root).toBe(TEST_ROOT);
    const client = home.client(RELAY, home.host.device);
    for (const result of [await client.circle(), await client.page(0), await client.append(home.circle.root, { unsigned: true }), await client.send("POST", "/v0/mail", "{}")]) {
      expect(result.status).toBe(410);
      expect(result.body).toMatchObject({ code: "circle_moved", message: `this circle's routes are at ${HOME}` });
    }
    for (const path of ["/", "/v0/links/abc?s=def", "/install.sh"]) {
      const moved = await SELF.fetch(`${RELAY}${path}`);
      expect(moved.status, path).toBe(410);
      expect(moved.headers.get("location"), path).toBe(HOME);
      expect(await code(moved), path).toBe("circle_moved");
    }
  });
});

describe("founding a circle", () => {
  it("refuses a root with no voucher, and one vouched by a key the home circle never admitted", async () => {
    const circle = newCircle("unvouched");
    const bare = await appendRoot(circle.root);
    expect(bare.status).toBe(403);
    expect(await code(bare)).toBe("not_vouched");
    const stranger = signVoucher(Signer.random(), { root: circle.rootHash, relay: "relay.test", circle: TEST_ROOT });
    const refused = await appendRoot(circle.root, stranger);
    expect(refused.status).toBe(403);
    expect(await code(refused)).toBe("not_vouched");
    expect(await hostedRow(env.DB, circle.rootHash)).toBeUndefined();
  });

  it("refuses a voucher for another root, another relay, or past its time", async () => {
    const circle = newCircle("misvouched");
    const signer = voucherMember.device.signer;
    for (const voucher of [
      signVoucher(signer, { root: newCircle("other").rootHash, relay: "relay.test", circle: TEST_ROOT }),
      signVoucher(signer, { root: circle.rootHash, relay: "elsewhere.test", circle: TEST_ROOT }),
      signVoucher(signer, { root: circle.rootHash, relay: "relay.test", circle: TEST_ROOT }, new Date(Date.now() - 1000)),
      signVoucher(signer, { root: circle.rootHash, relay: "relay.test", circle: TEST_ROOT }, new Date(Date.now() + 24 * 3600 * 1000)),
    ]) {
      const refused = await appendRoot(circle.root, voucher);
      expect(refused.status).toBe(403);
      expect(await code(refused)).toBe("not_vouched");
    }
  });

  it("refuses anything but the root at an address no circle holds yet", async () => {
    const circle = newCircle("rootless");
    const other = newCircle("other");
    const response = await SELF.fetch(`${addressOf(RELAY, circle.rootHash)}/v0/envelopes`, { method: "POST", body: jcs(other.root) });
    expect(response.status).toBe(404);
    expect(await code(response)).toBe("circle_unknown");
  });

  it("refuses with its own code when the relay does not host, is full, or the member opened too many", async () => {
    const circle = newCircle("limits");
    const voucher = signVoucher(voucherMember.device.signer, { root: circle.rootHash, relay: "relay.test", circle: TEST_ROOT });
    const attempt = (hosting: Partial<HostingLimits>) =>
      found(env, {
        root: circle.rootHash,
        home: TEST_ROOT,
        request: new Request(`${addressOf(RELAY, circle.rootHash)}/v0/envelopes`, { method: "POST", headers: { [HEADER_VOUCHER]: voucher } }),
        url: new URL(`${addressOf(RELAY, circle.rootHash)}/v0/envelopes`),
        hosting: { ...DEFAULT_HOSTING, ...hosting },
        now: new Date(),
        skewSeconds: DEFAULT_LIMITS.skew_seconds,
      });
    await expect(attempt({ hosting: false })).rejects.toMatchObject({ status: 403, code: "not_hosting" });
    await expect(attempt({ relay_storage: 1024, circle_storage: 1024 })).rejects.toMatchObject({ status: 507, code: "relay_full" });
    const at = new Date().toISOString();
    await env.DB.prepare("INSERT INTO hosted_circles (root, opened_at, vouched_by, vouched_identity, state, state_changed_at) VALUES (?, ?, ?, ?, 'open', ?)")
      .bind(`sha256:${"c".repeat(64)}`, at, TEST_ROOT, voucherMember.identity.key, at)
      .run();
    const tooMany = attempt({ circles_per_member: 1 });
    await expect(tooMany).rejects.toMatchObject({ status: 429, code: "too_many_circles" });
    await expect(tooMany).rejects.toThrow(/the next opens on \d{4}-\d{2}-\d{2}/);
    await env.DB.prepare("DELETE FROM hosted_circles WHERE root = ?").bind(`sha256:${"c".repeat(64)}`).run();
    expect(await hostedRow(env.DB, circle.rootHash)).toBeUndefined();
  });
});

describe("two circles hosted by one relay", () => {
  const second = newCircle("the second circle");
  const address = addressOf(RELAY, second.rootHash);
  let world: World;

  beforeAll(async () => {
    const voucher = signVoucher(voucherMember.device.signer, { root: second.rootHash, relay: "relay.test", circle: TEST_ROOT });
    const opened = await appendRoot(second.root, voucher);
    expect(opened.status, await opened.clone().text()).toBe(201);
    world = new World(second, [address]);
    await world.setup();
  });

  it("records who vouched, keeps the circle in its own store, and answers its own root", async () => {
    const row = await hostedRow(env.DB, second.rootHash);
    expect(row).toMatchObject({ root: second.rootHash, vouched_by: TEST_ROOT, vouched_identity: voucherMember.identity.key, state: "open", store: "object" });
    const store = circleDatabase(env.CIRCLE_STORE, second.rootHash);
    expect(await store.prepare("SELECT root FROM circle WHERE id = 1").first("root")).toBe(second.rootHash);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM envelopes WHERE hash = ?").bind(second.rootHash).first("n")).toBe(0);
    const read = await world.client(address, world.host.device).circle();
    expect((read.body as { root: string }).root).toBe(second.rootHash);
  });

  it("passes every single-relay conformance case at the second circle's address", async () => {
    const lines: string[] = [];
    const outcomes = await runCases({ cases: relayCases, relayCount: 1, context: () => Promise.resolve({ value: world }), log: (line) => lines.push(line) });
    const failed = outcomes.filter((o) => o.result === "fail");
    expect(failed.map((o) => `${o.id}: ${o.message ?? ""}`), lines.join("\n")).toEqual([]);
    const store = circleDatabase(env.CIRCLE_STORE, second.rootHash);
    const fold = await foldLog(store, second.rootHash, { all: true });
    expect((await loadKeys(store)).map(keyJson)).toEqual(fold.admittedKeys().map(keyJson));
  });

  it("lets neither circle read, append to or admit into the other", async () => {
    const [guest] = (await world.members(["only-second"])) as [Member];
    // A member of the second circle is a stranger to the home circle, and the reverse.
    expect((await new RelayClient(HOME, guest.device.signer).circle()).status).toBe(401);
    expect((await new RelayClient(address, voucherMember.device.signer).circle()).status).toBe(401);
    const summary = await world.summary(guest.device, "second only", address);
    const crossed = await new RelayClient(HOME, guest.device.signer).append(summary);
    expect(crossed.status).toBe(401);
    // A request signed for one circle's address never verifies at the other's.
    const signedForSecond = await new RelayClient(address, guest.device.signer).append(summary);
    expect(signedForSecond.status).toBe(201);
    const replayed = await SELF.fetch(`${HOME}/v0/envelopes`, { method: "POST", headers: signedForSecond.request.headers, body: signedForSecond.request.body });
    expect(replayed.status).toBe(401);
    // An invite of one circle admits nobody into the other.
    const [invitation] = await world.dinner(["cross"]);
    const { signed } = world.joinFor(invitation!);
    const joinedHome = await new RelayClient(HOME, invitation!.invite).append(signed, { unsigned: true });
    expect(joinedHome.status).toBe(422);
    const homeLog = await env.DB.prepare("SELECT COUNT(*) AS n FROM envelopes WHERE hash = ?").bind(envelopeHash(summary.envelope)).first("n");
    expect(homeLog).toBe(0);
  });

  it("answers the relay's own bootstrap read for an invite of either circle, naming its address", async () => {
    const [invitation] = await world.dinner(["by-index"]);
    const read = await new RelayClient(RELAY, invitation!.invite).invite(invitation!.invite.key);
    expect(read.status).toBe(200);
    expect(read.body).toMatchObject({ hash: invitation!.dinnerHash, circle: address });
    const [homeInvite] = await home.dinner(["home-guest"]);
    const homeRead = await new RelayClient(RELAY, homeInvite!.invite).invite(homeInvite!.invite.key);
    expect(homeRead.status).toBe(200);
    expect(homeRead.body).toMatchObject({ hash: homeInvite!.dinnerHash, circle: HOME });
  });

  it("answers 410 circle_suspended at every route of a suspended circle, and serves it again once resumed", async () => {
    await env.DB.prepare("UPDATE hosted_circles SET state = 'suspended' WHERE root = ?").bind(second.rootHash).run();
    const client = world.client(address, world.host.device);
    for (const result of [await client.circle(), await client.page(0), await client.append(second.root, { unsigned: true })]) {
      expect(result.status).toBe(410);
      expect((result.body as { code: string }).code).toBe("circle_suspended");
    }
    expect((await home.client(HOME, home.host.device).circle()).status).toBe(200);
    await env.DB.prepare("UPDATE hosted_circles SET state = 'open' WHERE root = ?").bind(second.rootHash).run();
    expect((await client.circle()).status).toBe(200);
  });

  it("refuses an append past the circle's share of the relay's storage", async () => {
    const [member] = (await world.members(["full"])) as [Member];
    const store = circleDatabase(env.CIRCLE_STORE, second.rootHash);
    const relay = {
      ...relayExtras(),
      db: store,
      root: second.rootHash,
      address,
      hosting: { ...DEFAULT_HOSTING, circle_storage: 1 },
      limits: DEFAULT_LIMITS,
      now: new Date(),
      mailer: undefined,
      releaseSigners: [],
    };
    const summary = await world.summary(member.device, "too much", address);
    await expect(appendSigned(relay, { key: member.device.key }, summary)).rejects.toMatchObject({ status: 507, code: "circle_full" });
  });
});

describe("the mail of a named circle", () => {
  it("names the circle in the From name and the subject, and leaves a circle with no name as it was", () => {
    expect(fromFor("Digestif <digest@mail.digestif.io>", "Luxury Car Roll Up")).toBe('"Luxury Car Roll Up (Digestif)" <digest@mail.digestif.io>');
    expect(fromFor("Digestif <digest@mail.digestif.io>", undefined)).toBe("Digestif <digest@mail.digestif.io>");
    const email = { subject: "Digestif, October 29", text: "t", html: "h" };
    expect(forCircle(email, "Luxury Car Roll Up").subject).toBe("Luxury Car Roll Up: Digestif, October 29");
    expect(forCircle(email, undefined)).toBe(email);
  });
});
