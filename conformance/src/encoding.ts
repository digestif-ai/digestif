// Encoding rules from docs/protocol.md, "Encoding". No `node:crypto` and no `Buffer`, so a Worker can
// import it; the hash comes from the installed SuiteCrypto (src/crypto.ts).
import { suiteCrypto } from "./crypto.ts";

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

const B64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const B64URL_VALUE = new Map([...B64URL].map((c, i) => [c, i]));
const utf8 = new TextEncoder();

/** UTF-8 bytes of a string; bytes pass through. */
export function bytesOf(data: string | Uint8Array): Uint8Array {
  return typeof data === "string" ? utf8.encode(data) : data;
}

/** base64url without padding. */
export function b64url(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const n = (bytes[i]! << 16) | ((bytes[i + 1] ?? 0) << 8) | (bytes[i + 2] ?? 0);
    const chars = Math.min(4, Math.ceil(((bytes.length - i) * 8) / 6));
    for (let j = 0; j < chars; j++) out += B64URL[(n >> (18 - 6 * j)) & 63];
  }
  return out;
}

/**
 * Decodes base64url, also taking the standard alphabet and trailing padding as Node's decoder does.
 * Throws on any other character or an impossible length, so a malformed key never decodes to bytes.
 */
export function fromB64url(text: string): Uint8Array {
  const clean = text.replace(/=+$/, "").replaceAll("+", "-").replaceAll("/", "_");
  if (clean.length % 4 === 1) throw new Error("not base64url: impossible length");
  const out = new Uint8Array(Math.floor((clean.length * 6) / 8));
  let bits = 0;
  let value = 0;
  let index = 0;
  for (const c of clean) {
    const v = B64URL_VALUE.get(c);
    if (v === undefined) throw new Error(`not base64url: ${JSON.stringify(c)}`);
    value = (value << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[index++] = (value >> bits) & 0xff;
    }
  }
  return out;
}

function hex(bytes: Uint8Array): string {
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}

/** JSON Canonicalization Scheme, RFC 8785. Object members are sorted by UTF-16 code units, which
 * is JavaScript's default string order, and primitives serialize as ECMAScript JSON does. */
export function jcs(value: unknown): string {
  if (value === null || typeof value !== "object") {
    if (typeof value === "number" && !Number.isFinite(value)) {
      throw new Error("JCS cannot encode a non-finite number");
    }
    if (value === undefined) throw new Error("JCS cannot encode undefined");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(jcs).join(",")}]`;
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, v]) => v !== undefined)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${jcs(v)}`).join(",")}}`;
}

export function sha256Hex(data: string | Uint8Array): string {
  return hex(suiteCrypto().sha256(bytesOf(data)));
}

/** `sha256:<lowercase hex>` of the canonical encoding of a value. */
export function hashOf(value: unknown): string {
  return `sha256:${sha256Hex(jcs(value))}`;
}

/** ISO 8601 UTC with a Z, millisecond precision. */
export function isoTime(date: Date): string {
  return date.toISOString();
}
