// Encoding rules from docs/protocol.md, "Encoding".
import { createHash } from "node:crypto";

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

export function b64url(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64url");
}

export function fromB64url(text: string): Buffer {
  return Buffer.from(text, "base64url");
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
  return createHash("sha256").update(data).digest("hex");
}

/** `sha256:<lowercase hex>` of the canonical encoding of a value. */
export function hashOf(value: unknown): string {
  return `sha256:${sha256Hex(jcs(value))}`;
}

/** ISO 8601 UTC with a Z, millisecond precision. */
export function isoTime(date: Date): string {
  return date.toISOString();
}
