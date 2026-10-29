import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  checkAnswer,
  decisionBody,
  importEd25519Private,
  importEncryptionKey,
  openEnrollment,
  signEnvelope,
  signRequest,
  verifyDevice,
  generatePhoneKeys,
  importX25519Private,
  jcs,
  linkUrl,
  openLink,
  openSealed,
  pairingCode,
  seal,
  unb64url,
  b64url as b64,
  verifyEnvelope,
} from "./mail.mjs";

const vectors = JSON.parse(
  readFileSync(process.env.DIGESTIF_MAIL_VECTORS ?? new URL("../test/vectors.json", import.meta.url), "utf8"),
);

const keyOf = async ({ private: priv, public: pub }) => [
  await importX25519Private(unb64url(priv), unb64url(pub)),
  unb64url(pub),
];

test("opens what the node sealed, for every recipient", async () => {
  for (const r of vectors.seal.recipients) {
    const [priv, pub] = await keyOf(r);
    const plain = await openSealed(priv, pub, vectors.seal.sealed);
    assert.equal(jcs(plain), vectors.seal.plaintext_jcs);
  }
});

test("seals what it opens", async () => {
  const [priv, pub] = await keyOf(vectors.seal.recipients[0]);
  const sealed = await seal([pub], { option: "yes" });
  assert.deepEqual(await openSealed(priv, pub, sealed), { option: "yes" });
});

test("opens an answer link and checks its decision", async () => {
  const v = vectors.link;
  const payload = await openLink(v.id, v.secret, v.sealed_answer);
  assert.equal(jcs(payload), v.payload_jcs);
  assert.equal(await verifyEnvelope(payload.signed), v.envelope_hash);
  const ask = payload.signed.envelope.prev;
  await checkAnswer(payload, { mailKeys: [payload.signed.envelope.author], ask });
  await assert.rejects(checkAnswer(payload, { mailKeys: [], ask }), /not_admitted/);
  const [priv, pub] = await keyOf(v.member);
  assert.deepEqual(await openSealed(priv, pub, payload.signed.body.sealed), { option: v.option });
  assert.equal(linkUrl("https://relay-1.example/", v.id, v.secret), v.url);
});

test("a wrong secret opens nothing", async () => {
  const v = vectors.link;
  await assert.rejects(openLink(v.id, v.id + v.id, v.sealed_answer));
});

test("a tampered decision does not verify", async () => {
  const payload = await openLink(vectors.link.id, vectors.link.secret, vectors.link.sealed_answer);
  payload.signed.envelope.seq += 1;
  await assert.rejects(verifyEnvelope(payload.signed), /bad_signature/);
});

test("pairing code matches the node's", async () => {
  const v = vectors.pairing;
  assert.equal(await pairingCode(unb64url(v.ed25519), unb64url(v.x25519)), v.code);
  const phone = await generatePhoneKeys();
  assert.match(phone.code, /^p1\.[A-Za-z0-9_-]{86}\.[A-Za-z0-9_-]{4}$/);
});

test("signs a request exactly as the node does", async () => {
  const v = vectors.request;
  const seed = unb64url(v.seed);
  const key = await importEd25519Private(seed);
  const pub = unb64url(v["Digestif-Key"].slice("ed25519:".length));
  const headers = await signRequest(key, pub, {
    method: v.method,
    path: v.path,
    body: v.body,
    timestamp: v.timestamp,
    nonce: v.nonce,
  });
  for (const name of ["Digestif-Key", "Digestif-Timestamp", "Digestif-Nonce", "Digestif-Signature"])
    assert.equal(headers[name], v[name], name);
});

test("signs an envelope the node verifies to the same hash", async () => {
  const v = vectors.link;
  const payload = await openLink(v.id, v.secret, v.sealed_answer);
  const e = payload.signed.envelope;
  const key = await importEd25519Private(unb64url(vectors.request.seed));
  const { signed, hash } = await signEnvelope(
    key,
    unb64url(e.author.slice("ed25519:".length)),
    { seq: e.seq, prev: e.prev, created_at: e.created_at, epoch: e.epoch, kind: e.kind },
    payload.signed.body,
  );
  assert.equal(hash, v.envelope_hash);
  assert.equal(signed.envelope.signature, e.signature);
  assert.equal(await verifyEnvelope(signed), v.envelope_hash);
});

test("imports the member's encryption key and opens what is sealed to it", async () => {
  const m = vectors.link.member;
  const { privateKey, publicRaw } = await importEncryptionKey(unb64url(m.private));
  assert.deepEqual(publicRaw, unb64url(m.public));
  const body = await decisionBody(publicRaw, "sha256:" + "a".repeat(64), "no");
  assert.deepEqual(await openSealed(privateKey, publicRaw, body.sealed), { option: "no" });
});

test("opens an enrollment sealed to the phone", async () => {
  const phone = await generatePhoneKeys();
  const enrollment = await seal([phone.x25519], {
    encryption_key: "BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU",
    identity_key: "ed25519:x",
    relays: ["https://relay-1.example"],
  });
  const opened = await openEnrollment(phone.sealing.privateKey, phone.x25519, { enrollment });
  assert.equal(opened.identityKey, "ed25519:x");
  assert.deepEqual(opened.relays, ["https://relay-1.example"]);
  assert.equal(opened.encryptionKey.length, 32);
});

test("checks a device body's identity signature", async () => {
  const identity = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  const idRaw = new Uint8Array(await crypto.subtle.exportKey("raw", identity.publicKey));
  const triple = { identity_key: "ed25519:" + b64(idRaw), key: "ed25519:" + "A".repeat(43), role: "device" };
  const sig = new Uint8Array(
    await crypto.subtle.sign({ name: "Ed25519" }, identity.privateKey, new TextEncoder().encode(jcs(triple))),
  );
  assert.equal(await verifyDevice({ ...triple, signature: b64(sig) }), true);
  assert.equal(await verifyDevice({ ...triple, role: "mail", signature: b64(sig) }), false);
});
