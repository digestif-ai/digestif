// docs/protocol.md, revoke and circle: an admin key of the circle's signer set revokes a member whose
// identity no key of the set is bound to, and only while every key of the set is bound and none is
// revoked. DIG-392
import { test } from "node:test";
import assert from "node:assert/strict";
import "../src/node-crypto.ts";
import { circleBody, INVITE_TTL_MS, joinBody, releaseRevocationBody, revokeBody } from "../src/bodies.ts";
import { signedBody, SIGNERS_DOMAIN } from "../src/admission.ts";
import { isoTime, type Json } from "../src/encoding.ts";
import { envelopeHash, signEnvelope, type SignedEnvelope } from "../src/envelope.ts";
import { Fold, type FoldInput } from "../src/fold.ts";
import { Signer } from "../src/keys.ts";

const now = new Date("2026-11-22T12:00:00.000Z");
const relays = ["https://relay-1.example"];

interface Circle {
  fold: Fold;
  founder: Signer;
  device: Signer;
  admin: Signer;
  member: { identity: Signer; device: Signer };
  seq: number;
  position: number;
}

function input(signed: SignedEnvelope, position: number, stored = false): FoldInput {
  return { hash: envelopeHash(signed.envelope), envelope: signed.envelope, body: signed.body, position, now, stored };
}

/** A circle whose root names one admin key (with `identity`, or none), and one joined member. */
function circle(admins: (founder: Signer, admin: Signer) => Array<{ name: string; key: string; identity?: string }>): Circle {
  const founder = Signer.random();
  const device = Signer.random();
  const admin = Signer.random();
  const invite = Signer.random();
  const guest = { name: "Ashmer Aslam", invite_key: invite.key, expires_at: isoTime(new Date(now.getTime() + INVITE_TTL_MS)) };
  const root = signEnvelope(device, { kind: "circle", body: circleBody(founder, "Review", [guest], relays, admins(founder, admin)), seq: 1, epoch: 0, createdAt: now });
  const fold = new Fold(envelopeHash(root.envelope), { admission: { cutover: 0, signers: [] } });
  assert.equal(fold.apply(input(root, 1)), null);
  const identity = Signer.random();
  const memberDevice = Signer.random();
  const join = signEnvelope(invite, { kind: "join", body: joinBody(envelopeHash(root.envelope), invite, identity, memberDevice), seq: 1, epoch: 0, createdAt: now });
  assert.equal(fold.apply(input(join, 2)), null);
  return { fold, founder, device, admin, member: { identity, device: memberDevice }, seq: 1, position: 2 };
}

function post(c: Circle, kind: "revoke" | "signer_set" | "release_revocation", body: Json, stored = false): ReturnType<Fold["apply"]> {
  c.seq += 1;
  c.position += 1;
  return c.fold.apply(input(signEnvelope(c.device, { kind, body, seq: c.seq, epoch: 1, createdAt: now }), c.position, stored));
}

function adminRevoke(c: Circle, target: string, by: Signer = c.admin, stored = false): ReturnType<Fold["apply"]> {
  return post(c, "revoke", revokeBody(by, target, {}), stored);
}

test("a root naming one admin and no identity binds the key to its host, who revokes a member with it", () => {
  const c = circle((_, admin) => [{ name: "Founder", key: admin.key }]);
  assert.equal(c.fold.signerSet?.identities.get(c.admin.key), c.founder.key);
  assert.equal(adminRevoke(c, c.member.identity.key, Signer.random()), "not_admitted", "a key outside the set revokes nobody");
  assert.equal(adminRevoke(c, c.member.identity.key), null);
  assert.notEqual(c.fold.keyState(c.member.identity.key)?.revoked_at, undefined);
  assert.notEqual(c.fold.keyState(c.member.device.key)?.revoked_at, undefined, "every key under the identity is stopped");
});

test("an admin key never revokes a device key, nor a sitting admin", () => {
  const c = circle((founder, admin) => [{ name: "Founder", key: admin.key, identity: founder.key }]);
  assert.equal(adminRevoke(c, c.member.device.key), "not_admitted", "a device key is revoked only by its identity");
  assert.equal(adminRevoke(c, c.founder.key), "not_admitted", "the founder's key is in the set");
});

test("a set with an unbound key revokes nobody, until a signer_set binds every key", () => {
  const second = Signer.random();
  const c = circle((founder, admin) => [{ name: "Founder", key: admin.key, identity: founder.key }, { name: "Second", key: second.key }]);
  assert.equal(adminRevoke(c, c.member.identity.key), "not_admitted");
  const secondIdentity = Signer.random();
  const doc = JSON.stringify({
    format: "digestif-signers-v0",
    signers: [{ name: "Founder", key: c.admin.key, identity: c.founder.key }, { name: "Second", key: second.key, identity: secondIdentity.key }],
  });
  assert.equal(post(c, "signer_set", signedBody(SIGNERS_DOMAIN, doc, [c.admin, second])), null);
  assert.deepEqual(c.fold.signerSet?.keys, [c.admin.key, second.key]);
  assert.equal(c.fold.signerSet?.identities.get(second.key), secondIdentity.key, "the set change binds the second key");
  assert.equal(adminRevoke(c, c.member.identity.key), null);
});

test("a set holding a revoked key revokes nobody, and a stored revoke is not judged again", () => {
  const c = circle((founder, admin) => [{ name: "Founder", key: admin.key, identity: founder.key }]);
  const revocation = JSON.stringify({ format: "digestif-revocation-v0", key: c.admin.key, revoked_at: isoTime(now) });
  assert.equal(post(c, "release_revocation", releaseRevocationBody(c.admin, revocation)), null);
  assert.equal(c.fold.signerSet?.halted, true);
  assert.equal(adminRevoke(c, c.member.identity.key), "not_admitted");
  assert.equal(adminRevoke(c, c.member.identity.key, c.admin, true), null, "a relay replaying its log refolds what it accepted");
});
