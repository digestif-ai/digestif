// The release-signed documents the admission fold reads (docs/protocol.md, "The admission fold";
// docs/releases.md, "Changing the signer set" and "Revoking a release key"): a guest's
// digestif-admission-v0, a signer_set's digestif-signers-v0 and a release_revocation's
// digestif-revocation-v0. Each is the document's exact bytes in base64url and release-key
// signatures over a domain line plus those bytes. No node:crypto, so a Worker can import it.
import { b64url, bytesOf, fromB64url, type Json } from "./encoding.ts";
import { Signer, verifySignature } from "./keys.ts";
import { parseUnique } from "./strict-json.ts";

export const ADMISSION_DOMAIN = "DIGESTIF-ADMISSION-V0\n";
export const SIGNERS_DOMAIN = "DIGESTIF-SIGNERS-V0\n";
export const REVOCATION_DOMAIN = "DIGESTIF-REVOCATION-V0\n";

/** A document and its signatures as a circle message carries them, its bytes decoded. */
export interface SignedDocument {
  bytes: Uint8Array;
  value: { [key: string]: Json };
  signatures: Array<{ key: string; signature: string }>;
}

function isObject(value: Json | undefined): value is { [key: string]: Json } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * `{ document, signatures }` decoded, its document parsed as a JSON object; undefined when it is not
 * of that shape, or when the document holds a member twice (the signers were shown the first).
 */
export function signedDocumentOf(body: Json | undefined): SignedDocument | undefined {
  if (!isObject(body) || typeof body["document"] !== "string" || !Array.isArray(body["signatures"])) return undefined;
  let bytes: Uint8Array;
  let value: Json;
  try {
    bytes = fromB64url(body["document"]);
    value = parseUnique(new TextDecoder().decode(bytes), "the document") as Json;
  } catch {
    return undefined;
  }
  if (!isObject(value)) return undefined;
  const signatures: SignedDocument["signatures"] = [];
  for (const s of body["signatures"]) {
    if (isObject(s) && typeof s["key"] === "string" && typeof s["signature"] === "string") signatures.push({ key: s["key"], signature: s["signature"] });
  }
  return { bytes, value, signatures };
}

/** The keys whose signature over the domain line and the document's bytes verifies, each once. */
export function validSigners(domain: string, doc: SignedDocument): Set<string> {
  const signed = new Uint8Array([...bytesOf(domain), ...doc.bytes]);
  const valid = new Set<string>();
  for (const { key, signature } of doc.signatures) {
    if (!valid.has(key) && verifySignature(key, signed, signature)) valid.add(key);
  }
  return valid;
}

/**
 * The keys a digestif-signers-v0 names, in order: at least two, none twice. Undefined when the
 * document is not one, which is also how node/update/release-signers.json is read.
 */
export function signerKeysOf(value: Json | undefined): string[] | undefined {
  if (!isObject(value) || value["format"] !== "digestif-signers-v0" || !Array.isArray(value["signers"])) return undefined;
  const keys: string[] = [];
  for (const s of value["signers"]) {
    if (!isObject(s) || typeof s["key"] !== "string" || !s["key"].startsWith("ed25519:")) return undefined;
    keys.push(s["key"]);
  }
  if (keys.length < 2 || new Set(keys).size !== keys.length) return undefined;
  return keys;
}

/**
 * The identity each entry of a digestif-signers-v0 (or a circle root's `admins`) binds its key to
 * (docs/protocol.md, circle): key to identity, for every entry naming an ed25519 `identity`. An
 * entry without one leaves its key unbound; undefined when an `identity` is present and not an
 * ed25519 key.
 */
export function signerIdentitiesOf(entries: Json | undefined): Map<string, string> | undefined {
  const bound = new Map<string, string>();
  if (!Array.isArray(entries)) return bound;
  for (const s of entries) {
    if (!isObject(s) || typeof s["key"] !== "string" || s["identity"] === undefined) continue;
    const identity = s["identity"];
    if (typeof identity !== "string" || !identity.startsWith("ed25519:")) return undefined;
    bound.set(s["key"], identity);
  }
  return bound;
}

/**
 * The release signer set the admission fold judges dinners by, and the release keys revoked so far.
 * It starts from a set the folder trusts (a relay's build's release-signers.json) and changes only
 * by a signer_set and a release_revocation that verify against it, as a node's does.
 */
export class SignerSet {
  keys: string[];
  readonly revoked = new Set<string>();
  /** Key to the circle identity its entry names (docs/protocol.md, circle); an unbound key is absent. */
  identities: Map<string, string>;

  constructor(keys: string[], identities: ReadonlyMap<string, string> = new Map()) {
    this.keys = [...keys];
    this.identities = new Map([...identities].filter(([key]) => keys.includes(key)));
  }

  /** True while a revoked key is in the set: admissions halt, as releases do. */
  get halted(): boolean {
    return this.keys.some((k) => this.revoked.has(k));
  }

  /**
   * A signer_set body adopted under the three conditions of a signer-set change: every key of this
   * set signed it, every key of the set it names signed it, and that set has at least two keys,
   * none twice and none revoked. Returns whether it was adopted; one that does not verify changes
   * nothing, so posting one grants nothing.
   */
  adopt(body: Json | undefined): boolean {
    const doc = signedDocumentOf(body);
    if (doc === undefined) return false;
    const next = signerKeysOf(doc.value);
    const identities = signerIdentitiesOf(doc.value["signers"]);
    if (next === undefined || identities === undefined || next.some((k) => this.revoked.has(k))) return false;
    const valid = validSigners(SIGNERS_DOMAIN, doc);
    if (!this.keys.every((k) => valid.has(k)) || !next.every((k) => valid.has(k))) return false;
    this.keys = next;
    this.identities = identities;
    return true;
  }

  /**
   * docs/protocol.md, revoke: the identity an admin key revokes as. Undefined unless `key` is in the
   * set, no key of the set is revoked, and every key of the set is bound to an identity, since a set
   * with an unbound key cannot tell a sitting admin from a member.
   */
  adminIdentity(key: string): string | undefined {
    if (!this.keys.includes(key) || this.halted || !this.keys.every((k) => this.identities.has(k))) return undefined;
    return this.identities.get(key);
  }

  /** True when a key of the set is bound to this identity: they are a sitting admin. */
  seats(identity: string): boolean {
    return this.keys.some((k) => this.identities.get(k) === identity);
  }

  /**
   * A release_revocation honored when any key of this set signed it, revoked or not, as
   * node/update/lib/policy.ml's apply_revocations does: a leaked key is still held by its owner,
   * and a revocation grants nobody more than they already had. Returns whether it was honored.
   */
  revoke(body: Json | undefined): boolean {
    const doc = signedDocumentOf(body);
    if (doc === undefined || doc.value["format"] !== "digestif-revocation-v0" || typeof doc.value["key"] !== "string") return false;
    const valid = validSigners(REVOCATION_DOMAIN, doc);
    if (!this.keys.some((k) => valid.has(k))) return false;
    this.revoked.add(doc.value["key"]);
    return true;
  }

  /**
   * A guest entry's `admission` counts when it is a digestif-admission-v0 naming this circle and the
   * entry's invite key, signed by every key of this set, and no key of the set is revoked.
   */
  admits(admission: Json | undefined, circle: string, inviteKey: string): boolean {
    if (this.halted) return false;
    const doc = signedDocumentOf(admission);
    if (doc === undefined) return false;
    const { value } = doc;
    if (value["format"] !== "digestif-admission-v0" || value["circle"] !== circle || value["invite_key"] !== inviteKey) return false;
    const valid = validSigners(ADMISSION_DOMAIN, doc);
    return this.keys.every((k) => valid.has(k));
  }
}

/**
 * The release signers the suite signs admissions with. Their seeds are public on purpose, like the
 * test circle's: a relay under test is configured to trust them (relay/wrangler.jsonc's top-level
 * RELEASE_SIGNERS), and no real relay ever is.
 */
export const TEST_RELEASE_SIGNER_SEEDS = ["Rnze2ASqA9B4VXaWdRCuI_dV2DE89eww4qut6_SrhvQ", "aCPgVHRxZ6Wy7WJNtDWJr2pd2ujyb_pu3Oc9lHAka70"] as const;

export function testReleaseSigners(): Signer[] {
  return TEST_RELEASE_SIGNER_SEEDS.map((seed) => Signer.fromSeed(seed));
}

/** A digestif-signers-v0 naming these keys, as text: what RELEASE_SIGNERS and release-signers.json hold. */
export function signersDocument(signers: Array<{ name: string; key: string }>, createdAt?: string): string {
  return JSON.stringify({ format: "digestif-signers-v0", ...(createdAt === undefined ? {} : { created_at: createdAt }), signers });
}

/** A document's bytes in base64url and each signer's signature over the domain line and those bytes. */
export function signedBody(domain: string, document: string, signers: Signer[]): { document: string; signatures: Array<{ key: string; signature: string }> } {
  const bytes = bytesOf(document);
  const signed = new Uint8Array([...bytesOf(domain), ...bytes]);
  return { document: b64url(bytes), signatures: signers.map((s) => ({ key: s.key, signature: s.sign(signed) })) };
}

/** The `admission` beside a guest entry: a digestif-admission-v0 for this circle and invite key, signed by every signer given. */
export function admissionFor(signers: Signer[], circle: string, guest: { name: string; invite_key: string }, createdAt = new Date().toISOString()): Json {
  const document = JSON.stringify({
    format: "digestif-admission-v0",
    circle,
    created_at: createdAt,
    guest: { name: guest.name, email: "guest@conformance.invalid" },
    role: "member",
    invite_key: guest.invite_key,
    subject: "Join the conformance circle",
    body: "conformance",
  });
  return signedBody(ADMISSION_DOMAIN, document, signers);
}
