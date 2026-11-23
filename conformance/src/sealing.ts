// The one sealing construction (docs/protocol.md, Sealing) on `node:crypto`, for the node cases and
// the reference node: a random content key encrypts JCS(plaintext) with AES-256-GCM, and each
// recipient gets that key wrapped under HKDF-SHA256 of an X25519 exchange with an ephemeral key of
// its own. Node-only, like src/node-crypto.ts: a relay never opens a sealed body.
import { createCipheriv, createDecipheriv, createPrivateKey, createPublicKey, diffieHellman, hkdfSync, randomBytes, type KeyObject } from "node:crypto";
import { b64url, bytesOf, fromB64url, jcs, type Json } from "./encoding.ts";

const ALG = "x25519-hkdf-sha256-a256gcm";
const CONTENT_ADATA = "digestif-v0 sealed";
const WRAP_INFO = "digestif-v0 seal";
const PKCS8_X25519_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex");
const SPKI_X25519_PREFIX = Buffer.from("302a300506032b656e032100", "hex");

function privateKey(secret: Uint8Array): KeyObject {
  return createPrivateKey({ key: Buffer.concat([PKCS8_X25519_PREFIX, secret]), format: "der", type: "pkcs8" });
}

function publicKey(raw: Uint8Array): KeyObject {
  return createPublicKey({ key: Buffer.concat([SPKI_X25519_PREFIX, raw]), format: "der", type: "spki" });
}

function publicOf(secret: Uint8Array): Uint8Array {
  const der = createPublicKey(privateKey(secret)).export({ format: "der", type: "spki" });
  return new Uint8Array(der.subarray(SPKI_X25519_PREFIX.length));
}

/** An X25519 key a node opens sealed bodies with: its 32-byte secret and the `x25519:` public half. */
export class EncryptionKey {
  readonly secret: Uint8Array;
  readonly raw: Uint8Array;
  readonly key: string;

  constructor(secret: Uint8Array) {
    if (secret.length !== 32) throw new Error("an X25519 secret is 32 bytes");
    this.secret = secret;
    this.raw = publicOf(secret);
    this.key = `x25519:${b64url(this.raw)}`;
  }

  static random(): EncryptionKey {
    return new EncryptionKey(new Uint8Array(randomBytes(32)));
  }

  get secretText(): string {
    return b64url(this.secret);
  }
}

function wrapKey(shared: Uint8Array, ephemeral: Uint8Array, recipient: Uint8Array): Buffer {
  return Buffer.from(hkdfSync("sha256", shared, Buffer.concat([ephemeral, recipient]), WRAP_INFO, 32));
}

function encrypt(key: Uint8Array, nonce: Uint8Array, data: Uint8Array, adata?: string): string {
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  if (adata !== undefined) cipher.setAAD(bytesOf(adata));
  return b64url(new Uint8Array(Buffer.concat([cipher.update(data), cipher.final(), cipher.getAuthTag()])));
}

function decrypt(key: Uint8Array, nonce: Uint8Array, data: Uint8Array, adata?: string): Uint8Array {
  const decipher = createDecipheriv("aes-256-gcm", key, nonce);
  if (adata !== undefined) decipher.setAAD(bytesOf(adata));
  decipher.setAuthTag(data.subarray(data.length - 16));
  return new Uint8Array(Buffer.concat([decipher.update(data.subarray(0, data.length - 16)), decipher.final()]));
}

/** `plaintext` sealed to every recipient's raw 32-byte X25519 public key. */
export function seal(plaintext: Json, recipients: Uint8Array[]): Json {
  const content = new Uint8Array(randomBytes(32));
  const nonce = new Uint8Array(randomBytes(12));
  return {
    alg: ALG,
    recipients: recipients.map((recipient) => {
      const ephemeral = EncryptionKey.random();
      const shared = new Uint8Array(diffieHellman({ privateKey: privateKey(ephemeral.secret), publicKey: publicKey(recipient) }));
      return {
        key: `x25519:${b64url(recipient)}`,
        ephemeral: ephemeral.key,
        wrapped: encrypt(wrapKey(shared, ephemeral.raw, recipient), new Uint8Array(12), content),
      };
    }),
    nonce: b64url(nonce),
    ciphertext: encrypt(content, nonce, bytesOf(jcs(plaintext)), CONTENT_ADATA),
  };
}

/** The plaintext of `sealed` when it is sealed to `key` and opens, else undefined. Never throws. */
export function openSealed(sealed: Json | undefined, key: EncryptionKey): Json | undefined {
  try {
    if (typeof sealed !== "object" || sealed === null || Array.isArray(sealed) || sealed["alg"] !== ALG) return undefined;
    const recipients = sealed["recipients"];
    if (!Array.isArray(recipients)) return undefined;
    const entry = recipients.find((r) => typeof r === "object" && r !== null && !Array.isArray(r) && r["key"] === key.key);
    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) return undefined;
    const ephemeralText = entry["ephemeral"];
    const wrapped = entry["wrapped"];
    const nonce = sealed["nonce"];
    const ciphertext = sealed["ciphertext"];
    if (typeof ephemeralText !== "string" || !ephemeralText.startsWith("x25519:") || typeof wrapped !== "string" || typeof nonce !== "string" || typeof ciphertext !== "string") return undefined;
    const ephemeral = fromB64url(ephemeralText.slice("x25519:".length));
    const shared = new Uint8Array(diffieHellman({ privateKey: privateKey(key.secret), publicKey: publicKey(ephemeral) }));
    const content = decrypt(wrapKey(shared, ephemeral, key.raw), new Uint8Array(12), fromB64url(wrapped));
    const plaintext = decrypt(content, fromB64url(nonce), fromB64url(ciphertext), CONTENT_ADATA);
    return JSON.parse(new TextDecoder().decode(plaintext)) as Json;
  } catch {
    return undefined;
  }
}
