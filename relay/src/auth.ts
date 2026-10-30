// Request signing, docs/protocol.md "Request signing": the four Digestif headers, the skew window,
// the nonce, and an admitted signer. The checks run in the fake relay's order
// (conformance/src/fake-relay.ts, authenticate), so the two refuse the same request the same way.
import { verifySignature } from "../../conformance/src/keys.ts";
import { HEADER_KEY, HEADER_NONCE, HEADER_SIGNATURE, HEADER_TIMESTAMP, requestString } from "../../conformance/src/request.ts";
import { loadKey } from "./db.ts";
import type { Relay } from "./env.ts";
import { Refusal } from "./errors.ts";

export interface Authenticated {
  /** The signing key, or undefined on an unsigned bootstrap append. */
  key: string | undefined;
}

export interface AuthOptions {
  /** Accept a request with no Digestif-Key: the bootstrap append. */
  allowUnsigned?: boolean;
  /** Require the signer to be an admitted, unrevoked device or mail key (false on the bootstrap read). */
  admitted?: boolean;
}

/** The signed string's path: the pathname with its query, as the client signed it. */
export function signedPath(url: URL): string {
  return url.pathname + url.search;
}

export async function authenticate(relay: Relay, request: Request, url: URL, raw: string, options: AuthOptions = {}): Promise<Authenticated> {
  const key = request.headers.get(HEADER_KEY) ?? undefined;
  if (key === undefined) {
    if (options.allowUnsigned) return { key: undefined };
    throw new Refusal(401, "not_admitted", "Digestif-Key is required");
  }
  const timestamp = request.headers.get(HEADER_TIMESTAMP);
  const nonce = request.headers.get(HEADER_NONCE);
  const signature = request.headers.get(HEADER_SIGNATURE);
  if (timestamp === null || nonce === null || signature === null) {
    throw new Refusal(401, "bad_signature", "Digestif-Timestamp, Digestif-Nonce and Digestif-Signature are required");
  }
  const signed = requestString(request.method, signedPath(url), timestamp, nonce, raw);
  if (!verifySignature(key, signed, signature)) throw new Refusal(401, "bad_signature", "the request signature does not verify");
  const claimed = Date.parse(timestamp);
  const now = relay.now.getTime();
  const window = relay.limits.skew_seconds * 1000;
  if (Number.isNaN(claimed) || Math.abs(now - claimed) > window) {
    throw new Refusal(401, "stale_request", `timestamp ${timestamp} is outside ${relay.limits.skew_seconds}s of the relay clock`);
  }
  await recordNonce(relay, key, nonce, claimed + window);
  if (options.admitted !== false) {
    const state = await loadKey(relay.db, key);
    // Fold.activeAuthor without an envelope: an admitted device or mail key, not revoked.
    if (state === undefined || state.role === "identity" || state.revoked_at !== undefined) {
      throw new Refusal(401, "not_admitted", "the signing key is not admitted");
    }
  }
  return { key };
}

/**
 * A nonce is refused while a request from the same key already used it inside the window. The
 * record is one INSERT against the (key, nonce) primary key, so two copies of one request arriving
 * together cannot both pass: the second's INSERT fails the constraint, and that failure is the
 * refusal. Nonces the window has passed are dropped first, in the same transaction, so a nonce
 * whose window has passed may be used again and the table stays bounded.
 */
async function recordNonce(relay: Relay, key: string, nonce: string, until: number): Promise<void> {
  const now = relay.now.getTime();
  try {
    await relay.db.batch([
      relay.db.prepare("DELETE FROM nonces WHERE expires_at < ?").bind(now),
      relay.db.prepare("INSERT INTO nonces (key, nonce, expires_at) VALUES (?, ?, ?)").bind(key, nonce, until),
    ]);
  } catch (error) {
    if (!isNonceConflict(error)) throw error;
    throw new Refusal(401, "replayed_nonce", "this nonce was already used by this key");
  }
}

/** D1 reports the (key, nonce) primary key failing as a UNIQUE constraint error naming the table. */
function isNonceConflict(error: unknown): boolean {
  return error instanceof Error && /UNIQUE constraint failed: nonces\./.test(error.message);
}
