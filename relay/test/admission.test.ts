// The relay's admission rule (docs/protocol.md, The admission fold): after the circle's cutover a
// dinner's guest counts only with a digestif-admission-v0 every key of the folded signer set signed,
// the set starts from the release signers the relay is configured with (RELEASE_SIGNERS, the
// suite's public test signers here; src/signers.ts) and changes by signer_set, and no admission
// counts while a release_revocation's key is in the set. The tests share one D1 and run in order:
// the halt at the end holds for the rest of the file.
import { HOME, TEST_ROOT } from "./root.ts";
import { env, SELF } from "cloudflare:test";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admissionFor, REVOCATION_DOMAIN, SIGNERS_DOMAIN, signedBody, signersDocument, testReleaseSigners } from "../../conformance/src/admission.ts";
import { dinnerBody, INVITE_TTL_MS, type Guest } from "../../conformance/src/bodies.ts";
import { isoTime, type Json } from "../../conformance/src/encoding.ts";
import { type SignedEnvelope } from "../../conformance/src/envelope.ts";
import { Signer } from "../../conformance/src/keys.ts";
import type { HttpResult } from "../../conformance/src/request.ts";
import { World, type Member } from "../../conformance/src/world.ts";
import circleFile from "../../conformance/fixtures/test-circle.json";
import { admissionCutover, circleEpoch, foldLog, keyJson, loadKeys } from "../src/db.ts";
import { releaseSignersOf } from "../src/signers.ts";

// The home circle's address: every circle route answers only under it.
const RELAY = HOME;
const realFetch = globalThis.fetch;
const [s1, s2] = testReleaseSigners() as [Signer, Signer];
const s3 = Signer.random();

let world: World;
let poster: Member;

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
  [poster] = (await world.members(["signer set poster"])) as [Member];
});

afterAll(() => {
  globalThis.fetch = realFetch;
});

/** The host's dinner listing one guest whose admission `admission` makes, appended; the host's chain advances only when it is accepted. */
async function hostDinner(admission: (guest: { name: string; invite_key: string }) => Json | undefined): Promise<{ result: HttpResult; invite: Signer }> {
  const invite = Signer.random();
  const name = `guest ${invite.key.slice(8, 16)}`;
  const made = admission({ name, invite_key: invite.key });
  const guest: Guest = { name, invite_key: invite.key, expires_at: isoTime(new Date(Date.now() + INVITE_TTL_MS)), ...(made === undefined ? {} : { admission: made }) };
  const body = dinnerBody(world.host.identity, `admission ${world.tag}`, [guest], [RELAY]);
  const epoch = await world.epoch();
  const signed = world.host.device.peek("dinner", body, epoch);
  const result = await world.client(RELAY, world.host.device).append(signed);
  if (result.status === 201) world.host.device.next("dinner", body, epoch);
  return { result, invite };
}

/** A release-signed body posted by the poster's device, as a node posts a signer_set or a release_revocation. */
async function postRelease(kind: "signer_set" | "release_revocation", body: Json): Promise<HttpResult> {
  const epoch = await world.epoch();
  const signed = poster.device.peek(kind, body, epoch);
  const result = await world.client(RELAY, poster.device).append(signed);
  if (result.status === 201) poster.device.next(kind, body, epoch);
  return result;
}

/** The code of a 422's first relay_error: a 422 answers a list. */
function code(result: HttpResult): unknown {
  return (result.body as Array<{ code?: string }> | undefined)?.[0]?.code;
}

async function expectRefolds(): Promise<void> {
  const fold = await foldLog(env.DB, TEST_ROOT, { all: true, signers: releaseSignersOf(env) });
  expect((await loadKeys(env.DB)).map(keyJson), "admitted_keys against a full refold").toEqual(fold.admittedKeys().map(keyJson));
  expect(await circleEpoch(env.DB)).toBe(fold.epoch);
}

const circle = circleFile.root_hash;

describe("the admission rule", () => {
  it("starts a fresh database's cutover at 0 and serves it in GET /v0/circle", async () => {
    expect(await admissionCutover(env.DB)).toBe(0);
    const result = await world.client(RELAY, world.host.device).circle();
    expect(result.status).toBe(200);
    expect((result.body as { admission_cutover?: number }).admission_cutover).toBe(0);
  });

  it("judges by the configured signer set", () => {
    expect(releaseSignersOf(env)).toEqual([s1.key, s2.key]);
  });

  it("admits a guest whose admission every signer signed, and the guest joins", async () => {
    const [member] = await world.members(["admitted guest"]);
    expect(member).toBeDefined();
    await expectRefolds();
  });

  it("refuses a dinner after the cutover whose guest carries no admission", async () => {
    const { result } = await hostDinner(() => undefined);
    expect(result.status, result.text).toBe(422);
    expect(code(result)).toBe("not_admitted");
  });

  it("refuses an admission one signer short, for another circle, or for another invite key", async () => {
    const short = await hostDinner((g) => admissionFor([s1], circle, g));
    expect(short.result.status, short.result.text).toBe(422);
    const elsewhere = await hostDinner((g) => admissionFor([s1, s2], `sha256:${"0".repeat(64)}`, g));
    expect(elsewhere.result.status, elsewhere.result.text).toBe(422);
    const otherKey = await hostDinner((g) => admissionFor([s1, s2], circle, { ...g, invite_key: Signer.random().key }));
    expect(otherKey.result.status, otherKey.result.text).toBe(422);
    const forged = await hostDinner((g) => admissionFor([s1, Signer.random()], circle, g));
    expect(forged.result.status, forged.result.text).toBe(422);
  });

  it("admits an unsigned guest from a dinner at or before the cutover, as the rule before it did", async () => {
    await env.DB.prepare("UPDATE circle SET admission_cutover = (SELECT MAX(relay_id) + 1 FROM envelopes) WHERE id = 1").run();
    try {
      const { result, invite } = await hostDinner(() => undefined);
      expect(result.status, result.text).toBe(201);
      const join = world.joinFor({ name: "pre-cutover guest", invite, dinnerHash: (result.body as { hash: string }).hash });
      const joined = await world.client(RELAY, join.member.device).append(join.signed, { unsigned: true });
      expect(joined.status, joined.text).toBe(201);
    } finally {
      await env.DB.prepare("UPDATE circle SET admission_cutover = 0 WHERE id = 1").run();
    }
    // The log now holds an unsigned dinner after the cutover; a refold replays it as accepted.
    await expectRefolds();
  });

  it("accepts a signer_set the set it holds did not sign, and judges by the old set still", async () => {
    const document = signersDocument([{ name: "s1", key: s1.key }, { name: "s3", key: s3.key }]);
    const result = await postRelease("signer_set", signedBody(SIGNERS_DOMAIN, document, [s1, s3]));
    expect(result.status, result.text).toBe(201);
    const byNew = await hostDinner((g) => admissionFor([s1, s3], circle, g));
    expect(byNew.result.status, byNew.result.text).toBe(422);
    const byOld = await hostDinner((g) => admissionFor([s1, s2], circle, g));
    expect(byOld.result.status, byOld.result.text).toBe(201);
  });

  it("counts no admission while a revoked key is in the set", async () => {
    const revocation = JSON.stringify({ format: "digestif-revocation-v0", key: s2.key, reason: "test", revoked_at: isoTime(new Date()) });
    const result = await postRelease("release_revocation", signedBody(REVOCATION_DOMAIN, revocation, [s1]));
    expect(result.status, result.text).toBe(201);
    const halted = await hostDinner((g) => admissionFor([s1, s2], circle, g));
    expect(halted.result.status, halted.result.text).toBe(422);
    expect(code(halted.result)).toBe("not_admitted");
  });

  it("adopts a signer_set without the revoked key that every current and new key signed, and judges by it", async () => {
    const document = signersDocument([{ name: "s1", key: s1.key }, { name: "s3", key: s3.key }], isoTime(new Date()));
    const result = await postRelease("signer_set", signedBody(SIGNERS_DOMAIN, document, [s1, s2, s3]));
    expect(result.status, result.text).toBe(201);
    const byNew = await hostDinner((g) => admissionFor([s1, s3], circle, g));
    expect(byNew.result.status, byNew.result.text).toBe(201);
    const byOld = await hostDinner((g) => admissionFor([s1, s2], circle, g));
    expect(byOld.result.status, byOld.result.text).toBe(422);
    await expectRefolds();
  });

  it("never adopts a set naming a revoked key", async () => {
    const document = signersDocument([{ name: "s1", key: s1.key }, { name: "s2", key: s2.key }, { name: "s3", key: s3.key }], isoTime(new Date()));
    const result = await postRelease("signer_set", signedBody(SIGNERS_DOMAIN, document, [s1, s2, s3]));
    expect(result.status, result.text).toBe(201);
    const byNew = await hostDinner((g) => admissionFor([s1, s3], circle, g));
    expect(byNew.result.status, byNew.result.text).toBe(201);
  });

  it("records a serving database's head as its cutover in the migration that ships the rule", async () => {
    const migration = (env.TEST_MIGRATIONS ?? []).find((m) => m.name.startsWith("0004_"));
    const update = migration?.queries.find((q) => q.startsWith("UPDATE circle"));
    expect(update).toBeDefined();
    await env.DB.prepare(update!).run();
    const head = await env.DB.prepare("SELECT MAX(relay_id) AS head FROM envelopes").first<{ head: number }>();
    expect(head?.head).toBeGreaterThan(1);
    expect(await admissionCutover(env.DB)).toBe(head?.head);
    // Every dinner the log holds is now at or before the cutover, and the log refolds the same.
    await expectRefolds();
  });
});
