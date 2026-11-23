// A founding voucher (docs/protocol.md, Hosted circles): a member of a circle a relay already hosts
// vouches for a new circle's root, so the relay hosts it. The document names the new root, the
// relay's host, the vouching circle's root, the member's device key and an expiry at most ten
// minutes out; the device key signs the domain line plus the document's exact bytes. It travels
// in the Digestif-Voucher header of the root's bootstrap append as `<document b64url>.<signature>`.
// No node:crypto, so a Worker can import it.
import { b64url, bytesOf, fromB64url, isoTime, jcs, type Json } from "./encoding.ts";
import { Signer, verifySignature } from "./keys.ts";
import { parseUnique } from "./strict-json.ts";

export const VOUCHER_DOMAIN = "DIGESTIF-VOUCHER-V0\n";
export const VOUCHER_FORMAT = "digestif-voucher-v0";
export const HEADER_VOUCHER = "Digestif-Voucher";
/** The longest a voucher stays good: a founding asks its relays within minutes of signing. */
export const VOUCHER_TTL_MS = 10 * 60 * 1000;
/** The longest header a relay reads: a voucher is about 400 characters. */
export const MAX_VOUCHER_LENGTH = 2048;

export interface Voucher {
  /** The new circle's root, sha256:<hex>. */
  root: string;
  /** The host of the relay asked to host it, as the founding node addresses it. */
  relay: string;
  /** The root of the circle the vouching member belongs to on that relay. */
  circle: string;
  /** The member's admitted device key in that circle, which signs the voucher. */
  key: string;
  expires_at: string;
}

/** The Digestif-Voucher header a device key signs for a new root. */
export function signVoucher(device: Signer, fields: Omit<Voucher, "key" | "expires_at">, expiresAt = new Date(Date.now() + VOUCHER_TTL_MS)): string {
  const document: Json = { format: VOUCHER_FORMAT, root: fields.root, relay: fields.relay, circle: fields.circle, key: device.key, expires_at: isoTime(expiresAt) };
  const bytes = bytesOf(jcs(document));
  const signature = device.sign(new Uint8Array([...bytesOf(VOUCHER_DOMAIN), ...bytes]));
  return `${b64url(bytes)}.${signature}`;
}

function isObject(value: unknown): value is { [key: string]: Json } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * The voucher a header carries when it parses and its signature verifies under the key it names;
 * a string naming what is wrong otherwise. Whether the key may vouch, and for what, is the relay's
 * to judge against the vouching circle's fold.
 */
export function readVoucher(header: string): Voucher | string {
  if (header.length > MAX_VOUCHER_LENGTH) return `the voucher is over ${MAX_VOUCHER_LENGTH} characters`;
  const dot = header.indexOf(".");
  if (dot < 0) return "a voucher is <document>.<signature>";
  let bytes: Uint8Array;
  let value: unknown;
  try {
    bytes = fromB64url(header.slice(0, dot));
    value = parseUnique(new TextDecoder().decode(bytes), "the voucher");
  } catch {
    return "the voucher's document does not parse";
  }
  if (!isObject(value) || value["format"] !== VOUCHER_FORMAT) return `the voucher is not a ${VOUCHER_FORMAT}`;
  const fields = ["root", "relay", "circle", "key", "expires_at"] as const;
  for (const field of fields) if (typeof value[field] !== "string") return `the voucher has no ${field}`;
  const voucher = Object.fromEntries(fields.map((f) => [f, value[f] as string])) as unknown as Voucher;
  if (!verifySignature(voucher.key, new Uint8Array([...bytesOf(VOUCHER_DOMAIN), ...bytes]), header.slice(dot + 1))) return "the voucher's signature does not verify";
  return voucher;
}
