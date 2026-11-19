// docs/protocol.md, circle and The admission fold, step 1: a circle founded on its own has a circle
// envelope as its root, which admits its founder and records its first guests, with no dinner.
import { test } from "node:test";
import assert from "node:assert/strict";
import "../src/node-crypto.ts";
import { circleBody, dinnerBody, INVITE_TTL_MS, joinBody } from "../src/bodies.ts";
import { admissionFor, signedBody, signersDocument, SIGNERS_DOMAIN, testReleaseSigners } from "../src/admission.ts";
import { isoTime, type Json } from "../src/encoding.ts";
import { envelopeHash, signEnvelope, type SignedEnvelope } from "../src/envelope.ts";
import { Fold } from "../src/fold.ts";
import { Signer } from "../src/keys.ts";

const now = new Date("2026-11-18T12:00:00.000Z");
const relays = ["https://relay-1.example"];

function input(signed: SignedEnvelope, position: number) {
  return { hash: envelopeHash(signed.envelope), envelope: signed.envelope, body: signed.body, position, now };
}

function root(founderDevice: Signer, body: Json): SignedEnvelope {
  return signEnvelope(founderDevice, { kind: "circle", body, seq: 1, epoch: 0, createdAt: now });
}

test("a circle root admits its founder and records its first guests", () => {
  const founder = Signer.random();
  const device = Signer.random();
  const invite = Signer.random();
  const guest = { name: "Ashmer Aslam", invite_key: invite.key, expires_at: isoTime(new Date(now.getTime() + INVITE_TTL_MS)) };
  const r = root(device, circleBody(founder, "Auto dealership roll-up", [guest], relays));
  const fold = new Fold(envelopeHash(r.envelope));
  assert.equal(fold.apply(input(r, 1)), null);
  assert.equal(fold.keyState(founder.key)?.role, "identity");
  assert.equal(fold.keyState(device.key)?.role, "device");
  assert.equal(fold.hasInvite(invite.key), true);

  const identity = Signer.random();
  const guestDevice = Signer.random();
  const join = signEnvelope(invite, { kind: "join", body: joinBody(envelopeHash(r.envelope), invite, identity, guestDevice), seq: 1, epoch: 0, createdAt: now });
  assert.equal(fold.apply(input(join, 2)), null, "a join naming the circle root admits its guest");
  assert.equal(fold.keyState(identity.key)?.role, "identity");
});

test("a circle root needs no guests, and a circle envelope is only ever the root", () => {
  const founder = Signer.random();
  const device = Signer.random();
  const r = root(device, circleBody(founder, "Alone", [], relays));
  const fold = new Fold(envelopeHash(r.envelope));
  assert.equal(fold.apply(input(r, 1)), null);
  const second = signEnvelope(device, { kind: "circle", body: circleBody(founder, "Another", [], relays), seq: 2, epoch: 0, createdAt: now });
  assert.equal(fold.apply(input(second, 2)), "wrong_circle");
});

test("a circle root without a name is malformed", () => {
  const founder = Signer.random();
  const device = Signer.random();
  const r = root(device, circleBody(founder, "  ", [], relays));
  assert.equal(new Fold(envelopeHash(r.envelope)).apply(input(r, 1)), "malformed");
});

// DIG-265: a circle root that names its own admins is judged by them. A later dinner's guest counts
// only with an admission those admins signed, never one the release signers signed, and the
// circle's own signer_set changes that set.
function laterDinner(device: Signer, founder: Signer, circle: string, invite: Signer, signers: Signer[], seq: number): SignedEnvelope {
  const guest = { name: "Priya Raman", invite_key: invite.key, expires_at: isoTime(new Date(now.getTime() + INVITE_TTL_MS)) };
  const admission = admissionFor(signers, circle, guest);
  return signEnvelope(device, { kind: "dinner", body: dinnerBody(founder, "Auto dealership roll-up", [{ ...guest, admission }], relays, now), seq, epoch: 0, createdAt: now });
}

test("a circle root's admins, not the release signers, judge its later invites", () => {
  const founder = Signer.random();
  const device = Signer.random();
  const admin = Signer.random();
  const release = testReleaseSigners();
  const r = root(device, circleBody(founder, "Auto dealership roll-up", [], relays, [{ name: "Mike", key: admin.key }]));
  const circle = envelopeHash(r.envelope);
  const fold = new Fold(circle, { admission: { cutover: 0, signers: release.map((s) => s.key) } });
  assert.equal(fold.apply(input(r, 1)), null);
  assert.deepEqual(fold.signerSet?.keys, [admin.key], "the root's admins replace the release signers");

  assert.equal(fold.apply(input(laterDinner(device, founder, circle, Signer.random(), release, 2), 2)), "not_admitted", "the release signers' admission admits nobody here");
  const invite = Signer.random();
  assert.equal(fold.apply(input(laterDinner(device, founder, circle, invite, [admin], 2), 2)), null, "the circle's own admin admits");
  assert.equal(fold.hasInvite(invite.key), true);
});

test("a circle's own signer_set promotes a second admin, whose signature is then needed", () => {
  const founder = Signer.random();
  const device = Signer.random();
  const admin = Signer.random();
  const second = Signer.random();
  const r = root(device, circleBody(founder, "Promoted", [], relays, [{ name: "Mike", key: admin.key }]));
  const circle = envelopeHash(r.envelope);
  const fold = new Fold(circle, { admission: { cutover: 0, signers: testReleaseSigners().map((s) => s.key) } });
  assert.equal(fold.apply(input(r, 1)), null);
  const doc = signersDocument([{ name: "Mike", key: admin.key }, { name: "Ashmer", key: second.key }]);
  const change = signEnvelope(device, { kind: "signer_set", body: signedBody(SIGNERS_DOMAIN, doc, [admin, second]), seq: 2, epoch: 0, createdAt: now });
  assert.equal(fold.apply(input(change, 2)), null);
  assert.deepEqual(fold.signerSet?.keys, [admin.key, second.key]);
  assert.equal(fold.apply(input(laterDinner(device, founder, circle, Signer.random(), [admin], 3), 3)), "not_admitted", "one admin of two admits nobody");
  assert.equal(fold.apply(input(laterDinner(device, founder, circle, Signer.random(), [admin, second], 3), 3)), null);
});

test("a circle root whose admins are not a list of named ed25519 keys is malformed", () => {
  const founder = Signer.random();
  const device = Signer.random();
  for (const admins of [[], [{ name: "x", key: "nope" }], [{ name: "a", key: founder.key }, { name: "b", key: founder.key }]]) {
    const r = root(device, circleBody(founder, "Bad", [], relays, admins));
    assert.equal(new Fold(envelopeHash(r.envelope)).apply(input(r, 1)), "malformed");
  }
});
