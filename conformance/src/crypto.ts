// The suite's three cryptographic primitives behind one injectable module, so the modules a relay or
// node can import (encoding.ts, keys.ts, envelope.ts, fold.ts) carry no `node:crypto` and no `Buffer`.
// On Node, src/node-crypto.ts installs the `node:crypto` implementation as the default the moment any
// Node-only module of the suite loads. Elsewhere (a Cloudflare Worker), the host installs its own with
// installCrypto() before it signs, verifies or hashes anything.
//
// Every primitive is synchronous because the admission fold is: Fold.apply decides an envelope in one
// call, and a relay folds appends in order with no await between the check and the write.

export interface SuiteCrypto {
  /** The 32-byte Ed25519 public key of a 32-byte seed. */
  ed25519PublicKey(seed: Uint8Array): Uint8Array;
  /** The raw 64-byte Ed25519 signature of `data` by the key whose 32-byte seed is `seed`. */
  ed25519Sign(seed: Uint8Array, data: Uint8Array): Uint8Array;
  /** Whether `signature` (64 bytes) is `publicKey`'s (32 bytes) Ed25519 signature of `data`. Never throws. */
  ed25519Verify(publicKey: Uint8Array, data: Uint8Array, signature: Uint8Array): boolean;
  /** The 32-byte SHA-256 digest of `data`. */
  sha256(data: Uint8Array): Uint8Array;
}

let installed: SuiteCrypto | undefined;

/** Installs the implementation every later sign, verify and hash uses, replacing any installed before. */
export function installCrypto(crypto: SuiteCrypto): void {
  installed = crypto;
}

/** Installs `crypto` unless an implementation is already installed: how a default yields to a host's own. */
export function installDefaultCrypto(crypto: SuiteCrypto): void {
  installed ??= crypto;
}

export function suiteCrypto(): SuiteCrypto {
  if (installed === undefined) {
    throw new Error(
      "no SuiteCrypto installed: on Node import conformance/src/node-crypto.ts; elsewhere call installCrypto() first",
    );
  }
  return installed;
}
