import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  checkAnswer,
  generatePhoneKeys,
  importX25519Private,
  jcs,
  linkUrl,
  openLink,
  openSealed,
  pairingCode,
  seal,
  unb64url,
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
