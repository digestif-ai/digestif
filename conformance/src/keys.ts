// Ed25519 keys in the `ed25519:<base64url>` form docs/protocol.md fixes.
import { createPrivateKey, createPublicKey, randomBytes, sign, verify, type KeyObject } from "node:crypto";
import { b64url, fromB64url } from "./encoding.ts";

const PKCS8_ED25519_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");
const SPKI_ED25519_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

export class Signer {
  readonly seed: Buffer;
  readonly key: string;
  private readonly privateKey: KeyObject;

  constructor(seed: Buffer) {
    if (seed.length !== 32) throw new Error("an Ed25519 seed is 32 bytes");
    this.seed = seed;
    this.privateKey = createPrivateKey({
      key: Buffer.concat([PKCS8_ED25519_PREFIX, seed]),
      format: "der",
      type: "pkcs8",
    });
    const jwk = createPublicKey(this.privateKey).export({ format: "jwk" });
    if (typeof jwk.x !== "string") throw new Error("could not export the Ed25519 public key");
    this.key = `ed25519:${jwk.x}`;
  }

  static random(): Signer {
    return new Signer(randomBytes(32));
  }

  static fromSeed(seed: string): Signer {
    return new Signer(fromB64url(seed));
  }

  get seedText(): string {
    return b64url(this.seed);
  }

  /** Raw 64-byte signature, base64url without padding. */
  sign(data: string | Uint8Array): string {
    return b64url(sign(null, Buffer.from(data), this.privateKey));
  }
}

export function verifySignature(key: string, data: string | Uint8Array, signature: string): boolean {
  if (typeof key !== "string" || !key.startsWith("ed25519:")) return false;
  if (typeof signature !== "string") return false;
  const raw = fromB64url(key.slice("ed25519:".length));
  const sig = fromB64url(signature);
  if (raw.length !== 32 || sig.length !== 64) return false;
  try {
    const publicKey = createPublicKey({
      key: Buffer.concat([SPKI_ED25519_PREFIX, raw]),
      format: "der",
      type: "spki",
    });
    return verify(null, Buffer.from(data), publicKey, sig);
  } catch {
    return false;
  }
}
