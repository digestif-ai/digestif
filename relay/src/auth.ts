// Request signing, docs/protocol.md "Request signing": the four Digestif headers, the skew window,
// an admitted signer and the nonce. The checks run in the fake relay's order
// (conformance/src/fake-relay.ts, authenticate), so the two refuse the same request the same way.
//
// Everything that costs the relay nothing comes before the one write: the header lengths, the
// signature, the clock and the admission lookup all run before the nonce is recorded, so a key the
// circle never admitted spends no nonce row however many requests it signs. DIG-228
import { verifySignature } from "../../conformance/src/keys.ts";
import { HEADER_KEY, HEADER_NONCE, HEADER_SIGNATURE, HEADER_TIMESTAMP, requestString } from "../../conformance/src/request.ts";
import { loadKey } from "./db.ts";
import type { KeyState } from "../../conformance/src/fold.ts";
import type { Relay } from "./env.ts";
import { Refusal } from "./errors.ts";

export interface Authenticated {
  /** The signing key, or undefined on an unsigned bootstrap append. */
  key: string | undefined;
  /** The signing key's admitted_keys row, read once here so no route reads it again. */
  state?: KeyState;
}

export interface AuthOptions {
  /** Accept a request with no Digestif-Key: the bootstrap append. */
  allowUnsigned?: boolean;
}

/**
 * Reads a route runs in the nonce's own batch, given the signer's state: one round trip for the
 * nonce and the route's answer. The batch is a transaction, so a replayed nonce answers nothing.
 */
export type WithNonce = (state: KeyState) => D1PreparedStatement[];

/** A signed request authenticated, with the results of the statements that rode its nonce batch. */
export interface AuthenticatedWith extends Authenticated {
  state: KeyState;
  results: D1Result[];
}

/**
 * The longest a Digestif header may be. Every well-formed value is far shorter (a key is 51
 * characters, a signature 86, a nonce 22, a timestamp about 24), so a longer one is refused before
 * it is verified or stored.
 */
export const MAX_HEADER_LENGTH = 128;

/** A request whose signature and clock verify, its nonce not yet spent. */
export interface Verified {
  key: string;
  nonce: string;
  /** When the nonce stops mattering: the claimed time plus the skew window. */
  until: number;
}

/** The signed string's path: the pathname with its query, as the client signed it. */
export function signedPath(url: URL): string {
  return url.pathname + url.search;
}

/** A signed request from an admitted, unrevoked device or mail key, its nonce spent; or an unsigned bootstrap append when allowed. */
export async function authenticate(relay: Relay, request: Request, url: URL, raw: string, options: AuthOptions = {}): Promise<Authenticated> {
  if (request.headers.get(HEADER_KEY) === null) {
    if (options.allowUnsigned) return { key: undefined };
    throw new Refusal(401, "not_admitted", "Digestif-Key is required");
  }
  const { key, state } = await authenticateWith(relay, request, url, raw);
  return { key, state };
}

/**
 * A signed request from an admitted, unrevoked device or mail key, its nonce spent in one batch with
 * the statements `along` builds from the signer's state: a signed read is two round trips, the key
 * and then the nonce with the answer.
 */
export async function authenticateWith(relay: Relay, request: Request, url: URL, raw: string, along?: WithNonce): Promise<AuthenticatedWith> {
  const verified = verifyRequest(relay, request, url, raw);
  const state = await loadKey(relay.db, verified.key);
  // Fold.activeAuthor without an envelope: an admitted device or mail key, not revoked.
  if (state === undefined || state.role === "identity" || state.revoked_at !== undefined) {
    throw new Refusal(401, "not_admitted", "the signing key is not admitted");
  }
  const results = await spendNonce(relay, verified, along === undefined ? [] : along(state));
  return { key: verified.key, state, results };
}

/**
 * The checks that read nothing: the four headers present and short, the signature, the clock. The
 * caller decides whether the signer may go on, and only then spends the nonce (spendNonce).
 */
export function verifyRequest(relay: Relay, request: Request, url: URL, raw: string): Verified {
  const key = request.headers.get(HEADER_KEY);
  const timestamp = request.headers.get(HEADER_TIMESTAMP);
  const nonce = request.headers.get(HEADER_NONCE);
  const signature = request.headers.get(HEADER_SIGNATURE);
  if (key === null) throw new Refusal(401, "not_admitted", "Digestif-Key is required");
  if (timestamp === null || nonce === null || signature === null) {
    throw new Refusal(401, "bad_signature", "Digestif-Timestamp, Digestif-Nonce and Digestif-Signature are required");
  }
  if ([key, timestamp, nonce, signature].some((value) => value.length > MAX_HEADER_LENGTH)) {
    throw new Refusal(401, "bad_signature", `a Digestif header is over ${MAX_HEADER_LENGTH} characters`);
  }
  const signed = requestString(request.method, signedPath(url), timestamp, nonce, raw);
  if (!verifySignature(key, signed, signature)) throw new Refusal(401, "bad_signature", "the request signature does not verify");
  const claimed = Date.parse(timestamp);
  const now = relay.now.getTime();
  const window = relay.limits.skew_seconds * 1000;
  if (Number.isNaN(claimed) || Math.abs(now - claimed) > window) {
    throw new Refusal(401, "stale_request", `timestamp ${timestamp} is outside ${relay.limits.skew_seconds}s of the relay clock`);
  }
  return { key, nonce, until: claimed + window };
}

/**
 * A nonce is refused while a request from the same key already used it inside the window. The
 * record is one INSERT against the (key, nonce) primary key, so two copies of one request arriving
 * together cannot both pass: the second's INSERT fails the constraint, and that failure is the
 * refusal. Nonces the window has passed are dropped first, in the same transaction, so a nonce
 * whose window has passed may be used again and the table stays bounded. `along` runs after the
 * insert in the same batch, and its results are returned in order.
 */
export async function spendNonce(relay: Relay, verified: Verified, along: D1PreparedStatement[] = []): Promise<D1Result[]> {
  const now = relay.now.getTime();
  try {
    const results = await relay.db.batch([
      relay.db.prepare("DELETE FROM nonces WHERE expires_at < ?").bind(now),
      relay.db.prepare("INSERT INTO nonces (key, nonce, expires_at) VALUES (?, ?, ?)").bind(verified.key, verified.nonce, verified.until),
      ...along,
    ]);
    return results.slice(2);
  } catch (error) {
    if (!isNonceConflict(error)) throw error;
    throw new Refusal(401, "replayed_nonce", "this nonce was already used by this key");
  }
}

/** D1 reports the (key, nonce) primary key failing as a UNIQUE constraint error naming the table. */
function isNonceConflict(error: unknown): boolean {
  return error instanceof Error && /UNIQUE constraint failed: nonces\./.test(error.message);
}
