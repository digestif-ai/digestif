// Ed25519 keys in the `ed25519:<base64url>` form docs/protocol.md fixes. The primitives come from the
// installed SuiteCrypto (src/crypto.ts), so a Worker can import this file.
import { suiteCrypto } from "./crypto.ts";
import { b64url, bytesOf, fromB64url } from "./encoding.ts";

export class Signer {
  readonly seed: Uint8Array;
  readonly key: string;

  constructor(seed: Uint8Array) {
    if (seed.length !== 32) throw new Error("an Ed25519 seed is 32 bytes");
    this.seed = seed;
    this.key = `ed25519:${b64url(suiteCrypto().ed25519PublicKey(seed))}`;
  }

  static random(): Signer {
    return new Signer(globalThis.crypto.getRandomValues(new Uint8Array(32)));
  }

  static fromSeed(seed: string): Signer {
    return new Signer(fromB64url(seed));
  }

  get seedText(): string {
    return b64url(this.seed);
  }

  /** Raw 64-byte signature, base64url without padding. */
  sign(data: string | Uint8Array): string {
    return b64url(suiteCrypto().ed25519Sign(this.seed, bytesOf(data)));
  }
}

export function verifySignature(key: string, data: string | Uint8Array, signature: string): boolean {
  if (typeof key !== "string" || !key.startsWith("ed25519:")) return false;
  if (typeof signature !== "string") return false;
  let raw: Uint8Array;
  let sig: Uint8Array;
  try {
    raw = fromB64url(key.slice("ed25519:".length));
    sig = fromB64url(signature);
  } catch {
    return false;
  }
  if (raw.length !== 32 || sig.length !== 64) return false;
  return suiteCrypto().ed25519Verify(raw, bytesOf(data), sig);
}
