// Sealing a directed message (docs/protocol.md, Sealing): X25519 for the key exchange, HKDF-SHA256
// to wrap a random content key, AES-256-GCM for both. The node's own sealing is node/mail/seal.ml;
// this builds the same value so `digestif post` can open it with the member's key.

import { createCipheriv, createPublicKey, diffieHellman, generateKeyPairSync, hkdfSync, randomBytes, type KeyObject } from "node:crypto";

export const SEAL_ALG = "x25519-hkdf-sha256-a256gcm";
const CONTENT_ADATA = "digestif-v0 sealed";
const WRAP_INFO = "digestif-v0 seal";
const KEY_PREFIX = "x25519:";
// The fixed DER prefix of a raw 32-byte X25519 public key (SPKI).
const SPKI_PREFIX = Buffer.from("302a300506032b656e032100", "hex");

const b64url = (b: Buffer): string => b.toString("base64url");

/** The 32 raw bytes of a card key written `x25519:<base64url>`; throws on anything else. */
export function parseCardKey(key: string): Buffer {
  if (!key.startsWith(KEY_PREFIX)) throw new Error(`expected ${KEY_PREFIX}<base64url>`);
  const raw = Buffer.from(key.slice(KEY_PREFIX.length), "base64url");
  if (raw.length !== 32 || b64url(raw) !== key.slice(KEY_PREFIX.length)) throw new Error("an X25519 key is 32 bytes of base64url");
  return raw;
}

/** The canonical (RFC 8785) text of a plaintext of strings, in objects and arrays. */
export function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  if (typeof v === "object" && v !== null) {
    const o = v as Record<string, unknown>;
    return `{${Object.keys(o)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${canonical(o[k])}`)
      .join(",")}}`;
  }
  return JSON.stringify(v);
}

function aesGcm(key: Buffer, nonce: Buffer, plain: Buffer, adata?: string): Buffer {
  const c = createCipheriv("aes-256-gcm", key, nonce);
  if (adata !== undefined) c.setAAD(Buffer.from(adata));
  return Buffer.concat([c.update(plain), c.final(), c.getAuthTag()]);
}

export interface Sealed {
  alg: string;
  recipients: { key: string; ephemeral: string; wrapped: string }[];
  nonce: string;
  ciphertext: string;
}

/** Seals `plaintext` to the given `x25519:` keys, in order. A key of the wrong shape throws. */
export function seal(plaintext: unknown, recipients: string[]): Sealed {
  const contentKey = randomBytes(32);
  const nonce = randomBytes(12);
  const ciphertext = aesGcm(contentKey, nonce, Buffer.from(canonical(plaintext)), CONTENT_ADATA);
  const entries = recipients.map((key) => {
    const recipient = parseCardKey(key);
    const { publicKey, privateKey } = generateKeyPairSync("x25519");
    const ephemeral = publicKey.export({ format: "der", type: "spki" }).subarray(-32);
    const theirs: KeyObject = createPublicKey({ key: Buffer.concat([SPKI_PREFIX, recipient]), format: "der", type: "spki" });
    const shared = diffieHellman({ privateKey, publicKey: theirs });
    if (shared.every((b) => b === 0)) throw new Error("the shared secret is all zero");
    const wrapKey = Buffer.from(hkdfSync("sha256", shared, Buffer.concat([ephemeral, recipient]), WRAP_INFO, 32));
    return { key, ephemeral: KEY_PREFIX + b64url(ephemeral), wrapped: b64url(aesGcm(wrapKey, Buffer.alloc(12), contentKey)) };
  });
  return { alg: SEAL_ALG, recipients: entries, nonce: b64url(nonce), ciphertext: b64url(ciphertext) };
}
