// docs/protocol.md, circle and The admission fold, step 1: a circle founded on its own has a circle
// envelope as its root, which admits its founder and records its first guests, with no dinner.
import { test } from "node:test";
import assert from "node:assert/strict";
import "../src/node-crypto.ts";
import { circleBody, INVITE_TTL_MS, joinBody } from "../src/bodies.ts";
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
