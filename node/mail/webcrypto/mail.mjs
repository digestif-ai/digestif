// The mail constructions in WebCrypto alone (docs/protocol.md: Sealing, Answer links, The phone,
// Request signing, The envelope), for the mailing relay's Worker and the phone web app. It runs unchanged in a Cloudflare Worker,
// a browser and Node 20+. The OCaml node writes what this reads; ../test/vectors.json is the proof.

const enc = new TextEncoder();
const dec = new TextDecoder();
const subtle = globalThis.crypto.subtle;

export const ALG = "x25519-hkdf-sha256-a256gcm";
const CONTENT_ADATA = enc.encode("digestif-v0 sealed");
const WRAP_INFO = enc.encode("digestif-v0 seal");
const LINK_INFO = enc.encode("digestif-v0 link");
const ZERO_NONCE = new Uint8Array(12);

export function b64url(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function unb64url(text) {
  const s = text.replaceAll("-", "+").replaceAll("_", "/");
  const bin = atob(s + "=".repeat((4 - (s.length % 4)) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
};

function keyText(prefix, raw) {
  return `${prefix}:${b64url(raw)}`;
}

function keyRaw(prefix, text) {
  if (!text.startsWith(`${prefix}:`)) throw new Error(`not an ${prefix} key: ${text}`);
  return unb64url(text.slice(prefix.length + 1));
}

// RFC 8785 for what the wire uses: objects, arrays, strings, integers, booleans, null.
// JSON.stringify already escapes strings the way the RFC asks; keys sort by UTF-16 code units,
// which is JavaScript's own string order.
export function jcs(value) {
  if (value === null || typeof value !== "object") {
    if (typeof value === "number" && !Number.isInteger(value)) throw new Error("floats are not used on the wire");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(jcs).join(",")}]`;
  const keys = Object.keys(value).filter((k) => value[k] !== undefined).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${jcs(value[k])}`).join(",")}}`;
}

export async function sha256(bytes) {
  return new Uint8Array(await subtle.digest("SHA-256", bytes));
}

async function hkdf(ikm, salt, info) {
  const key = await subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, key, 256));
}

async function gcm(mode, keyBytes, iv, data, additionalData) {
  const key = await subtle.importKey("raw", keyBytes, "AES-GCM", false, [mode]);
  const params = additionalData ? { name: "AES-GCM", iv, additionalData } : { name: "AES-GCM", iv };
  return new Uint8Array(await subtle[mode](params, key, data));
}

const x25519Public = (raw) => subtle.importKey("raw", raw, { name: "X25519" }, true, []);

async function x25519Shared(privateKey, publicRaw) {
  const shared = new Uint8Array(
    await subtle.deriveBits({ name: "X25519", public: await x25519Public(publicRaw) }, privateKey, 256),
  );
  if (shared.every((b) => b === 0)) throw new Error("x25519 shared secret is all zero");
  return shared;
}

// A raw 32-byte X25519 private key (the vectors, a relay secret) as a CryptoKey. A phone's key is
// generated as a CryptoKey and never passes through here.
export function importX25519Private(privateRaw, publicRaw) {
  return subtle.importKey(
    "jwk",
    { kty: "OKP", crv: "X25519", d: b64url(privateRaw), x: b64url(publicRaw) },
    { name: "X25519" },
    false,
    ["deriveBits"],
  );
}

// Seal a JSON value to raw X25519 public keys.
export async function seal(recipients, plaintext) {
  const contentKey = crypto.getRandomValues(new Uint8Array(32));
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await gcm("encrypt", contentKey, nonce, enc.encode(jcs(plaintext)), CONTENT_ADATA);
  const entries = [];
  for (const recipient of recipients) {
    const eph = await subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]);
    const ephPublic = new Uint8Array(await subtle.exportKey("raw", eph.publicKey));
    const shared = await x25519Shared(eph.privateKey, recipient);
    const w = await hkdf(shared, concat(ephPublic, recipient), WRAP_INFO);
    entries.push({
      key: keyText("x25519", recipient),
      ephemeral: keyText("x25519", ephPublic),
      wrapped: b64url(await gcm("encrypt", w, ZERO_NONCE, contentKey)),
    });
  }
  return { alg: ALG, recipients: entries, nonce: b64url(nonce), ciphertext: b64url(ciphertext) };
}

// Open a sealed value with our X25519 private CryptoKey and its raw public half.
export async function openSealed(privateKey, publicRaw, sealed) {
  if (sealed.alg !== ALG) throw new Error(`unknown alg ${sealed.alg}`);
  const me = keyText("x25519", publicRaw);
  const entry = sealed.recipients.find((r) => r.key === me);
  if (!entry) throw new Error("not sealed to this key");
  const ephPublic = keyRaw("x25519", entry.ephemeral);
  const shared = await x25519Shared(privateKey, ephPublic);
  const w = await hkdf(shared, concat(ephPublic, publicRaw), WRAP_INFO);
  const contentKey = await gcm("decrypt", w, ZERO_NONCE, unb64url(entry.wrapped));
  const plain = await gcm("decrypt", contentKey, unb64url(sealed.nonce), unb64url(sealed.ciphertext), CONTENT_ADATA);
  return JSON.parse(dec.decode(plain));
}

// The mailing relay's confirm page: open a link's sealed answer with the secret from its URL.
// Returns { ask_title, label, signed }; throws on a wrong secret.
export async function openLink(idText, secretText, sealedAnswerText) {
  const id = unb64url(idText);
  const sealedAnswer = unb64url(sealedAnswerText);
  const key = await hkdf(unb64url(secretText), id, LINK_INFO);
  const plain = await gcm(
    "decrypt",
    key,
    sealedAnswer.slice(0, 12),
    sealedAnswer.slice(12),
    enc.encode(`digestif-v0 link ${idText}`),
  );
  return JSON.parse(dec.decode(plain));
}

export function linkUrl(relay, idText, secretText) {
  return `${relay.replace(/\/$/, "")}/v0/links/${idText}?s=${secretText}`;
}

// Verify a signed_envelope's signature and body hash; returns its envelope hash.
export async function verifyEnvelope({ envelope, body }) {
  const { signature, ...unsigned } = envelope;
  const author = await subtle.importKey("raw", keyRaw("ed25519", envelope.author), { name: "Ed25519" }, false, [
    "verify",
  ]);
  const ok = await subtle.verify({ name: "Ed25519" }, author, unb64url(signature), enc.encode(jcs(unsigned)));
  if (!ok) throw new Error("bad_signature");
  const bodyHash = `sha256:${hex(await sha256(enc.encode(jcs(body))))}`;
  if (bodyHash !== envelope.body_hash) throw new Error("body_hash does not match");
  return `sha256:${hex(await sha256(enc.encode(jcs(envelope))))}`;
}

const hex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

// What the mailing relay checks before appending a confirmed link's decision.
export async function checkAnswer(payload, { mailKeys, ask }) {
  await verifyEnvelope(payload.signed);
  const e = payload.signed.envelope;
  if (e.kind !== "decision") throw new Error("not a decision");
  if (!mailKeys.includes(e.author)) throw new Error("not_admitted");
  if (e.prev !== ask) throw new Error("the decision answers a different ask");
  return payload.signed;
}

export async function pairingCode(ed25519Raw, x25519Raw) {
  const keys = concat(ed25519Raw, x25519Raw);
  return `p1.${b64url(keys)}.${b64url((await sha256(keys)).slice(0, 3))}`;
}

// The phone's keys: both private halves stay non-extractable in the browser (keep the CryptoKeys
// in IndexedDB), and the code is what the member pastes into their node.
export async function generatePhoneKeys() {
  const signing = await subtle.generateKey({ name: "Ed25519" }, false, ["sign", "verify"]);
  const sealing = await subtle.generateKey({ name: "X25519" }, false, ["deriveBits"]);
  const ed = new Uint8Array(await subtle.exportKey("raw", signing.publicKey));
  const x = new Uint8Array(await subtle.exportKey("raw", sealing.publicKey));
  return { signing, sealing, ed25519: ed, x25519: x, code: await pairingCode(ed, x) };
}

// The phone's half of enrollment: the member's encryption private key from its device body.
export async function openEnrollment(sealingPrivateKey, sealingPublicRaw, deviceBody) {
  const p = await openSealed(sealingPrivateKey, sealingPublicRaw, deviceBody.enrollment);
  return { encryptionKey: unb64url(p.encryption_key), identityKey: p.identity_key, relays: p.relays };
}

// PKCS #8 wrappers for a raw 32-byte private key (RFC 8410): how WebCrypto imports one.
const PKCS8_ED25519 = Uint8Array.from([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]);
const PKCS8_X25519 = Uint8Array.from([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20]);
const BASEPOINT = Uint8Array.from({ length: 32 }, (_, i) => (i === 0 ? 9 : 0));

// A raw Ed25519 seed as a signing CryptoKey (the vectors and tests; a phone generates its own).
export function importEd25519Private(seedRaw, extractable = false) {
  return subtle.importKey("pkcs8", concat(PKCS8_ED25519, seedRaw), { name: "Ed25519" }, extractable, ["sign"]);
}

// The member's encryption key, as an enrollment hands it to a phone: a non-extractable CryptoKey
// and its public half, computed as X25519 with the base point since nothing exports it.
export async function importEncryptionKey(privateRaw) {
  const privateKey = await subtle.importKey("pkcs8", concat(PKCS8_X25519, privateRaw), { name: "X25519" }, false, [
    "deriveBits",
  ]);
  const publicRaw = new Uint8Array(
    await subtle.deriveBits({ name: "X25519", public: await x25519Public(BASEPOINT) }, privateKey, 256),
  );
  return { privateKey, publicRaw };
}

export const keyTextEd25519 = (raw) => keyText("ed25519", raw);
export const keyRawEd25519 = (text) => keyRaw("ed25519", text);
export const keyTextX25519 = (raw) => keyText("x25519", raw);
export const keyRawX25519 = (text) => keyRaw("x25519", text);
export const hashText = async (bytes) => `sha256:${hex(await sha256(bytes))}`;

const sign = async (signingKey, bytes) => new Uint8Array(await subtle.sign({ name: "Ed25519" }, signingKey, bytes));

// The string a request signature covers (docs/protocol.md, Request signing).
export async function requestSignedString({ method, path, timestamp, nonce, body = "" }) {
  const bodyHex = hex(await sha256(enc.encode(body)));
  return ["DIGESTIF-REQUEST-V0", method.toUpperCase(), path, timestamp, nonce, bodyHex].join("\n");
}

// The four request headers, signed by [signingKey], whose public half is [keyRaw].
export async function signRequest(signingKey, keyRaw_, { method, path, body = "", timestamp, nonce }) {
  const ts = timestamp ?? new Date().toISOString();
  const n = nonce ?? b64url(crypto.getRandomValues(new Uint8Array(16)));
  const signed = await requestSignedString({ method, path, timestamp: ts, nonce: n, body });
  return {
    "Digestif-Key": keyText("ed25519", keyRaw_),
    "Digestif-Timestamp": ts,
    "Digestif-Nonce": n,
    "Digestif-Signature": b64url(await sign(signingKey, enc.encode(signed))),
  };
}

// The envelope version this file writes; it moves with node/core/envelope.ml's.
export const ENVELOPE_VERSION = 0;

// Sign [body] as the envelope { seq, prev, created_at, epoch, kind } of [authorRaw]'s chain.
// Returns the signed_envelope and its envelope hash.
export async function signEnvelope(signingKey, authorRaw, { version, seq, prev, created_at, epoch, kind }, body) {
  const unsigned = {
    version: version ?? ENVELOPE_VERSION,
    author: keyText("ed25519", authorRaw),
    seq,
    ...(prev === undefined ? {} : { prev }),
    created_at: created_at ?? new Date().toISOString(),
    epoch,
    kind,
    body_hash: await hashText(enc.encode(jcs(body))),
  };
  const signature = b64url(await sign(signingKey, enc.encode(jcs(unsigned))));
  const envelope = { ...unsigned, signature };
  return { signed: { envelope, body }, hash: await hashText(enc.encode(jcs(envelope))) };
}

// Check a device body's identity signature over { identity_key, key, role }.
export async function verifyDevice(body) {
  const identity = await subtle.importKey("raw", keyRaw("ed25519", body.identity_key), { name: "Ed25519" }, false, [
    "verify",
  ]);
  const triple = { identity_key: body.identity_key, key: body.key, role: body.role };
  return subtle.verify({ name: "Ed25519" }, identity, unb64url(body.signature), enc.encode(jcs(triple)));
}

// A decision body (docs/protocol.md, Asks and decisions), sealed to the member's own key.
export async function decisionBody(memberPublicRaw, ask, option) {
  return { ask, sealed: await seal([memberPublicRaw], { option }) };
}
