// The `node:crypto` implementation of SuiteCrypto (src/crypto.ts), installed as the default on import.
// Every Node-only module of the suite imports this file, so a Node caller never installs anything.
import { createHash, createPrivateKey, createPublicKey, sign, verify, type KeyObject } from "node:crypto";
import { installDefaultCrypto, type SuiteCrypto } from "./crypto.ts";

const PKCS8_ED25519_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");
const SPKI_ED25519_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

function privateKey(seed: Uint8Array): KeyObject {
  if (seed.length !== 32) throw new Error("an Ed25519 seed is 32 bytes");
  return createPrivateKey({ key: Buffer.concat([PKCS8_ED25519_PREFIX, seed]), format: "der", type: "pkcs8" });
}

export const nodeCrypto: SuiteCrypto = {
  ed25519PublicKey(seed) {
    const der = createPublicKey(privateKey(seed)).export({ format: "der", type: "spki" });
    return new Uint8Array(der.subarray(SPKI_ED25519_PREFIX.length));
  },
  ed25519Sign(seed, data) {
    return new Uint8Array(sign(null, data, privateKey(seed)));
  },
  ed25519Verify(publicKey, data, signature) {
    if (publicKey.length !== 32 || signature.length !== 64) return false;
    try {
      const key = createPublicKey({ key: Buffer.concat([SPKI_ED25519_PREFIX, publicKey]), format: "der", type: "spki" });
      return verify(null, data, key, signature);
    } catch {
      return false;
    }
  },
  sha256(data) {
    return new Uint8Array(createHash("sha256").update(data).digest());
  },
};

installDefaultCrypto(nodeCrypto);
