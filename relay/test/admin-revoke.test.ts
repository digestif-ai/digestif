// The relay's revoke check with the admin signer set (docs/protocol.md, revoke): an admin key of the
// signer set the relay's fold holds revokes a member no key of that set is bound to, posted by a
// device of the identity its own key is bound to, and only while every key of the set is bound and
// none is revoked. The relay starts from RELEASE_SIGNERS (src/signers.ts), whose keys are unbound,
// and binds them by a signer_set in the log. What these add to the conformance suite's cases: the
// D1 state an accepted revoke leaves equals a full refold, a fold the relay builds cold from the log
// (a fresh isolate) judges the same, and a stored revoke stays applied after the set halts. The
// tests share one D1 and run in order. DIG-393
import { HOME, TEST_ROOT } from "./root.ts";
import { env, SELF } from "cloudflare:test";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { REVOCATION_DOMAIN, signedBody, testReleaseSigners } from "../../conformance/src/admission.ts";
import { isoTime } from "../../conformance/src/encoding.ts";
import { type SignedEnvelope } from "../../conformance/src/envelope.ts";
import { Signer } from "../../conformance/src/keys.ts";
import type { HttpResult } from "../../conformance/src/request.ts";
import { World, type Member } from "../../conformance/src/world.ts";
import circleFile from "../../conformance/fixtures/test-circle.json";
import { circleEpoch, foldLog, forgetKeptFold, keyJson, loadKeys } from "../src/db.ts";
import { releaseSignersOf } from "../src/signers.ts";

const RELAY = HOME;
const realFetch = globalThis.fetch;
const [s1] = testReleaseSigners() as [Signer, Signer];

let world: World;
let first: Member;
let second: Member;
let bystander: Member;

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
  [first, second, bystander] = (await world.members(["first admin", "second admin", "bystander"])) as [Member, Member, Member];
});

afterAll(() => {
  globalThis.fetch = realFetch;
});

/** The code of a 422's first relay_error: a 422 answers a list. */
function code(result: HttpResult): unknown {
  return (result.body as Array<{ code?: string }> | undefined)?.[0]?.code;
}

/** An admin key's revoke of `target`, stopping its first device, posted by `poster`'s device. */
async function adminRevoke(poster: Member, by: Signer, target: Member): Promise<HttpResult> {
  return world.client(RELAY, poster.device).append(await world.revoke(poster.device, by, target.identity.key, [target.device]));
}

async function revokedAt(key: string): Promise<unknown> {
  const result = await world.client(RELAY, world.host.device).circle();
  expect(result.status).toBe(200);
  return (result.body as { keys: Array<{ key: string; revoked_at?: unknown }> }).keys.find((k) => k.key === key)?.revoked_at ?? null;
}

async function expectRefolds(): Promise<void> {
  const fold = await foldLog(env.DB, TEST_ROOT, { all: true, signers: releaseSignersOf(env) });
  expect((await loadKeys(env.DB)).map(keyJson), "admitted_keys against a full refold").toEqual(fold.admittedKeys().map(keyJson));
  expect(await circleEpoch(env.DB)).toBe(fold.epoch);
}

describe("an admin-signed revoke on the relay", () => {
  it("refuses one while the configured signer set's keys are bound to no identity", async () => {
    const [member] = (await world.members(["member of an unbound set"])) as [Member];
    const result = await adminRevoke(first, s1, member);
    expect(result.status, result.text).toBe(422);
    expect(code(result)).toBe("not_admitted");
    expect(await revokedAt(member.identity.key)).toBeNull();
  });

  it("accepts a member's revoke once a signer_set binds every key, and D1 equals a full refold", async () => {
    const [firstKey] = await world.bindAdmins([first, second]);
    const [member] = (await world.members(["member an admin removes"])) as [Member];
    const result = await adminRevoke(first, firstKey!, member);
    expect(result.status, result.text).toBe(201);
    expect(await revokedAt(member.identity.key)).not.toBeNull();
    expect(await revokedAt(member.device.key)).not.toBeNull();
    expect(await revokedAt(bystander.identity.key)).toBeNull();
    const after = await world.client(RELAY, member.device).append(await world.summary(member.device, "after removal"));
    expect([401, 422], after.text).toContain(after.status);
    await expectRefolds();
  });

  it("refuses the admin key posted by a device of an identity it is not bound to", async () => {
    const [firstKey] = world.releaseSigners;
    const [member] = (await world.members(["member a bystander targets"])) as [Member];
    const result = await adminRevoke(bystander, firstKey!, member);
    expect(result.status, result.text).toBe(422);
    expect(code(result)).toBe("not_admitted");
  });

  it("refuses a revoke of a sitting admin, from a kept fold and from one built cold", async () => {
    const [firstKey] = world.releaseSigners;
    const kept = await adminRevoke(first, firstKey!, second);
    expect(kept.status, kept.text).toBe(422);
    expect(code(kept)).toBe("not_admitted");
    forgetKeptFold();
    const cold = await adminRevoke(first, firstKey!, second);
    expect(cold.status, cold.text).toBe(422);
    expect(code(cold)).toBe("not_admitted");
    expect(await revokedAt(second.identity.key)).toBeNull();
  });

  it("accepts a member's revoke from a fold built cold from the log", async () => {
    forgetKeptFold();
    const [firstKey] = world.releaseSigners;
    const [member] = (await world.members(["member removed after a cold start"])) as [Member];
    forgetKeptFold();
    const result = await adminRevoke(first, firstKey!, member);
    expect(result.status, result.text).toBe(201);
    expect(await revokedAt(member.identity.key)).not.toBeNull();
    await expectRefolds();
  });

  it("revokes nobody while a key of the set is revoked, and keeps every stored revoke applied", async () => {
    const [firstKey, secondKey] = world.releaseSigners;
    const revocation = JSON.stringify({ format: "digestif-revocation-v0", key: secondKey!.key, reason: "test", revoked_at: isoTime(new Date()) });
    const body = signedBody(REVOCATION_DOMAIN, revocation, [firstKey!]);
    const posted = await world.client(RELAY, world.host.device).append(world.host.device.next("release_revocation", body, await world.epoch()));
    expect(posted.status, posted.text).toBe(201);
    // A halted set admits no guest either, so the target is a member admitted before the halt.
    const target = bystander;
    const result = await adminRevoke(first, firstKey!, target);
    expect(result.status, result.text).toBe(422);
    expect(code(result)).toBe("not_admitted");
    expect(await revokedAt(target.identity.key)).toBeNull();
    forgetKeptFold();
    await expectRefolds();
  });
});
